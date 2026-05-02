// Phase 11A.4 — ProviderCredentialsRepository.
//
// Persistence layer for `public.provider_credentials` (the masked-
// display ledger backing the admin Integrations surface). The table
// is platform-wide (one Anthropic key, one Voyage key, one Azure DB
// secret), not operator-scoped, so every statement runs through
// `withSystem` with a non-blank [adminReason] string.
//
// Plaintext is never persisted here. The proxy hands plaintext to the
// KMS provider (live or stub), receives the opaque
// `kms://...` reference, and stores that reference plus the masked
// display string in this table. The Flutter admin console then reads
// only the masked column.
//
// Rotation contract:
//
//   * `rotate` runs in a single transaction:
//       1. UPDATE the prior active row for the same `key_kind` to
//          `is_active = false`.
//       2. INSERT the new row with `is_active = true`.
//     The partial unique index `provider_credentials_active_uq`
//     guarantees there is only ever one active row per kind once the
//     transaction commits; the order (UPDATE then INSERT) keeps the
//     constraint satisfied at every point.
//
//   * If the INSERT throws (e.g. the proxy decided the KMS write
//     failed and re-raised), the transaction rolls back and the
//     prior row stays `is_active = true`.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

const Set<String> kProviderCredentialKinds = <String>{
  'anthropic',
  'voyage',
  'azure_db',
  'gemini',
};

class ProviderCredentialsRepository extends OperatorScopedRepository {
  ProviderCredentialsRepository(super.tenantWrapper);

  static const String _selectColumns =
      'credential_id::text as credential_id, '
      'key_kind, '
      'masked_value, '
      'kms_secret_name, '
      'created_by::text as created_by, '
      'updated_by::text as updated_by, '
      'is_active, '
      'rotated_at, '
      'created_at, '
      'updated_at';

  /// SELECT every active row, one per `key_kind`. The admin console
  /// projects this list straight into the integrations grid.
  Future<List<ProviderCredentialRow>> listActive({
    required String adminReason,
  }) {
    return withSystem<List<ProviderCredentialRow>>((exec) async {
      final rows = await exec.query(
        'select $_selectColumns from provider_credentials '
        'where is_active = true '
        'order by key_kind asc',
      );
      return <ProviderCredentialRow>[
        for (final row in rows) _rowFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// Append a new row for [keyKind], flipping the prior active row's
  /// `is_active` to false in the same transaction. Returns the freshly
  /// inserted row.
  ///
  /// [keyKind] must be one of [kProviderCredentialKinds]; otherwise
  /// the database CHECK constraint rejects the INSERT and the proxy
  /// surfaces a 400 to the caller.
  ///
  /// [actorUserId] is REQUIRED and must be a UUID-shaped Postgres
  /// `users.user_id`. The proxy resolves the verified Firebase UID
  /// into a Postgres user UUID via [IntegrationAdminActorResolver]
  /// and rejects with 403 `actor_user_not_resolvable` before this
  /// repository is touched, so audit attribution stays intact.
  Future<ProviderCredentialRow> rotate({
    required String keyKind,
    required String maskedValue,
    required String kmsSecretName,
    required String actorUserId,
    required String adminReason,
  }) {
    return withSystem<ProviderCredentialRow>((exec) async {
      await exec.execute(
        'update provider_credentials '
        'set is_active = false, '
        '    updated_by = @actor::uuid, '
        '    updated_at = now() '
        'where key_kind = @key_kind and is_active = true',
        parameters: <String, Object?>{
          'key_kind': keyKind,
          'actor': actorUserId,
        },
      );
      final rows = await exec.query(
        'insert into provider_credentials ('
        'key_kind, masked_value, kms_secret_name, '
        'created_by, updated_by, is_active, rotated_at'
        ') values ('
        '@key_kind, @masked_value, @kms_secret_name, '
        '@actor::uuid, @actor::uuid, true, now()'
        ') returning $_selectColumns',
        parameters: <String, Object?>{
          'key_kind': keyKind,
          'masked_value': maskedValue,
          'kms_secret_name': kmsSecretName,
          'actor': actorUserId,
        },
      );
      if (rows.isEmpty) {
        throw StateError('provider_credentials rotate returned no rows');
      }
      return _rowFromMap(rows.single);
    }, reason: adminReason);
  }
}

class ProviderCredentialRow {
  const ProviderCredentialRow({
    required this.credentialId,
    required this.keyKind,
    required this.maskedValue,
    required this.kmsSecretName,
    required this.createdBy,
    required this.updatedBy,
    required this.isActive,
    required this.rotatedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String credentialId;
  final String keyKind;
  final String maskedValue;
  final String kmsSecretName;
  final String? createdBy;
  final String? updatedBy;
  final bool isActive;
  final DateTime rotatedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'credential_id': credentialId,
    'key_kind': keyKind,
    'masked_value': maskedValue,
    'kms_secret_name': kmsSecretName,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'is_active': isActive,
    'rotated_at': rotatedAt.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

ProviderCredentialRow _rowFromMap(PostgresRow row) {
  return ProviderCredentialRow(
    credentialId: row['credential_id']! as String,
    keyKind: row['key_kind']! as String,
    maskedValue: row['masked_value']! as String,
    kmsSecretName: row['kms_secret_name']! as String,
    createdBy: row['created_by'] as String?,
    updatedBy: row['updated_by'] as String?,
    isActive: row['is_active'] as bool? ?? false,
    rotatedAt: _toDateTime(row['rotated_at'])!,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
