// Phase 9 live-closeout B12 - MfaFactorsRepository.
//
// Persistence layer for the `mfa_factors` table from the 9.0 schema
// foundation. RLS is per-user (`mfa_factors_per_user`), so every
// method takes operator/location/user context for the SET LOCAL
// payload + per-user policy match.
//
// Schema (from 202604250008_auth_schema_foundation.sql):
//
//   factor_id uuid pk default gen_random_uuid()
//   user_id uuid (FK users)
//   factor_type text check in ('passkey', 'totp', 'recovery_code')
//   factor_metadata jsonb default '{}'
//   enrolled_at timestamptz default now()
//   last_used_at timestamptz null
//   revoked_at timestamptz null
//   created_at / updated_at timestamptz default now()
//
// Recovery codes are stored ONE ROW PER CODE so consumption can mark
// individual codes used without re-writing the bundle. This matches
// the `recovery_code_hasher.dart` "salt per user, hash per code"
// model.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// Snapshot of an `mfa_factors` row used for read paths. The
/// repository projects rows into this value class so callers don't
/// touch the raw `PostgresRow`.
class MfaFactorRecord {
  const MfaFactorRecord({
    required this.factorId,
    required this.userId,
    required this.factorType,
    required this.factorMetadata,
    required this.enrolledAt,
    this.lastUsedAt,
    this.revokedAt,
  });

  final String factorId;
  final String userId;
  final String factorType;
  final Map<String, Object?> factorMetadata;
  final DateTime enrolledAt;
  final DateTime? lastUsedAt;
  final DateTime? revokedAt;

  bool get isActive => revokedAt == null;
}

class MfaFactorsRepository extends OperatorScopedRepository {
  MfaFactorsRepository(super.tenantWrapper);

  /// INSERT a new TOTP factor row. Returns the freshly generated
  /// `factor_id`. The [firebaseFactorUid] is the Firebase
  /// MultiFactor uid the proxy got from the `firebase_auth` adapter
  /// (so the table can map back to Firebase later for unenroll).
  Future<String> insertTotpFactor({
    required String operatorId,
    required String locationId,
    required String userId,
    required String firebaseFactorUid,
    String issuerName = 'Forge & Flow',
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    final metadata = <String, Object?>{
      'firebase_factor_uid': firebaseFactorUid,
      'issuer': issuerName,
    };
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into mfa_factors (user_id, factor_type, factor_metadata) '
        "values (@user_id::uuid, 'totp', @metadata::jsonb) "
        'returning factor_id::text as factor_id',
        parameters: <String, Object?>{
          'user_id': userId,
          'metadata': jsonEncode(metadata),
        },
      );
      return _projectFactorId(rows);
    });
  }

  /// INSERT a single recovery-code factor row. The metadata carries
  /// the salt + hash pair from [HashedRecoveryCode]. Caller invokes
  /// this N times — once per code — within a single transaction
  /// boundary established outside the repository.
  Future<String> insertRecoveryCodeFactor({
    required String operatorId,
    required String locationId,
    required String userId,
    required Map<String, Object?> hashedCodeJson,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into mfa_factors (user_id, factor_type, factor_metadata) '
        "values (@user_id::uuid, 'recovery_code', @metadata::jsonb) "
        'returning factor_id::text as factor_id',
        parameters: <String, Object?>{
          'user_id': userId,
          'metadata': jsonEncode(hashedCodeJson),
        },
      );
      return _projectFactorId(rows);
    });
  }

  /// Mark a recovery code consumed. Sets `last_used_at = now()` AND
  /// `revoked_at = now()` (per the decision lock: each code is
  /// single-use; setting both ensures the same row never matches a
  /// future verify). Returns the affected-row count (0 when the
  /// code was already used / revoked).
  Future<int> markRecoveryCodeUsed({
    required String operatorId,
    required String locationId,
    required String userId,
    required String factorId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update mfa_factors '
        'set last_used_at = now(), revoked_at = now(), updated_at = now() '
        'where factor_id = @factor_id::uuid '
        'and user_id = @user_id::uuid '
        "and factor_type = 'recovery_code' "
        'and revoked_at is null',
        parameters: <String, Object?>{
          'factor_id': factorId,
          'user_id': userId,
        },
      );
    });
  }

  /// Revoke a TOTP factor (24-hour-delayed removal flow).
  Future<int> revokeTotpFactor({
    required String operatorId,
    required String locationId,
    required String userId,
    required String factorId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update mfa_factors '
        'set revoked_at = now(), updated_at = now() '
        'where factor_id = @factor_id::uuid '
        'and user_id = @user_id::uuid '
        "and factor_type = 'totp' "
        'and revoked_at is null',
        parameters: <String, Object?>{
          'factor_id': factorId,
          'user_id': userId,
        },
      );
    });
  }

  /// Lists every active recovery-code factor row for [userId]. The
  /// consumer service iterates these and tries the hash against each
  /// in constant-time (see `RecoveryCodeConsumer`).
  Future<List<MfaFactorRecord>> listActiveRecoveryCodeFactors({
    required String operatorId,
    required String locationId,
    required String userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<MfaFactorRecord>>(ctx, (exec) async {
      final rows = await exec.query(
        'select factor_id::text as factor_id, '
        'user_id::text as user_id, '
        'factor_type, '
        'factor_metadata::text as factor_metadata, '
        'enrolled_at, last_used_at, revoked_at '
        'from mfa_factors '
        'where user_id = @user_id::uuid '
        "and factor_type = 'recovery_code' "
        'and revoked_at is null '
        'order by enrolled_at',
        parameters: <String, Object?>{
          'user_id': userId,
        },
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  static String _projectFactorId(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) {
      throw StateError(
        'mfa_factors insert returned no rows — RLS policy may have '
        'blocked the row even though SET LOCAL ran',
      );
    }
    final id = rows.single['factor_id'];
    if (id is! String || id.isEmpty) {
      throw StateError('mfa_factors insert returned a malformed factor_id');
    }
    return id;
  }

  static MfaFactorRecord _projectRow(Map<String, Object?> row) {
    final metadataJson = row['factor_metadata'];
    Map<String, Object?> metadata;
    if (metadataJson is String) {
      try {
        final decoded = jsonDecode(metadataJson);
        metadata = decoded is Map<String, Object?>
            ? decoded
            : Map<String, Object?>.from(decoded as Map);
      } catch (_) {
        metadata = const <String, Object?>{};
      }
    } else if (metadataJson is Map<String, Object?>) {
      metadata = metadataJson;
    } else {
      metadata = const <String, Object?>{};
    }
    return MfaFactorRecord(
      factorId: row['factor_id'] as String,
      userId: row['user_id'] as String,
      factorType: row['factor_type'] as String,
      factorMetadata: metadata,
      enrolledAt: row['enrolled_at'] as DateTime,
      lastUsedAt: row['last_used_at'] as DateTime?,
      revokedAt: row['revoked_at'] as DateTime?,
    );
  }
}
