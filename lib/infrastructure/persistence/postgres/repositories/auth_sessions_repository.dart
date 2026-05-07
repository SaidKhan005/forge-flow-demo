// Phase 9 live-closeout B6 - AuthSessionsRepository.
//
// The auth-session ledger (`auth_sessions` table from the 9.0 schema
// foundation) routes every read and write through the
// `OperatorScopedRepository` + `TenantTransactionWrapper` path so the
// per-user RLS policy (`auth_sessions_per_user`, lands in the 9.2
// migration) and the SET LOCAL transaction-scoped tenant injection
// stay intact.
//
// The 9.0 `auth_sessions` table has a per-user RLS policy that filters
// rows by `current_setting('app.user_id', true)::uuid`. Every method
// here therefore builds a `TenantContext` with the user's
// `operator_id`, `location_id`, and `user_id` so the policy admits
// the row.
//
// `revokeAllSessionsForUser` runs through `withSystem` so an admin
// "force logout all sessions" path can revoke rows it does not own.
// The reason string is audited via the wrapper's
// `app.bypass_rls_audit = 'system:<reason>'` marker.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// Read projection of an `auth_sessions` row for the self-service
/// Active Sessions viewer (Phase 9.UX.5). Carries device / network
/// metadata the proxy collected at login time so the operator can
/// recognise their own devices without leaking token material.
class AuthSessionRow {
  const AuthSessionRow({
    required this.sessionId,
    required this.createdAt,
    required this.lastSeenAt,
    this.userAgent,
    this.ip,
    this.geoCountry,
    this.deviceFingerprint,
    this.revokedAt,
    this.revokedReason,
  });

  final String sessionId;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final String? userAgent;
  final String? ip;
  final String? geoCountry;
  final String? deviceFingerprint;
  final DateTime? revokedAt;
  final String? revokedReason;
}

class AuthSessionsRepository extends OperatorScopedRepository {
  AuthSessionsRepository(super.tenantWrapper);

  /// Returns the actor's own active (non-revoked) sessions, newest
  /// first. The per-user RLS policy filters cross-user rows server-
  /// side; this method only ever reads the actor's own audit ledger.
  Future<List<AuthSessionRow>> listActiveSessionsForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<AuthSessionRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select session_id::text as session_id, '
        'created_at, last_seen_at, '
        'user_agent, host(ip) as ip, geo_country, device_fingerprint, '
        'revoked_at, revoked_reason '
        'from auth_sessions '
        'where user_id = @user_id::uuid '
        'and revoked_at is null '
        'order by last_seen_at desc, created_at desc',
        parameters: <String, Object?>{'user_id': userId},
      );
      return rows.map(_projectSessionRow).toList(growable: false);
    });
  }

  static AuthSessionRow _projectSessionRow(Map<String, Object?> row) {
    DateTime asDateTime(Object? value) {
      if (value is DateTime) return value.toUtc();
      if (value is String) return DateTime.parse(value).toUtc();
      throw StateError('auth_sessions row missing timestamp');
    }

    DateTime? asOptionalDateTime(Object? value) {
      if (value == null) return null;
      return asDateTime(value);
    }

    String? asOptionalString(Object? value) {
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final sessionId = row['session_id'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('auth_sessions row missing session_id');
    }
    return AuthSessionRow(
      sessionId: sessionId,
      createdAt: asDateTime(row['created_at']),
      lastSeenAt: asDateTime(row['last_seen_at']),
      userAgent: asOptionalString(row['user_agent']),
      ip: asOptionalString(row['ip']),
      geoCountry: asOptionalString(row['geo_country']),
      deviceFingerprint: asOptionalString(row['device_fingerprint']),
      revokedAt: asOptionalDateTime(row['revoked_at']),
      revokedReason: asOptionalString(row['revoked_reason']),
    );
  }

  /// INSERT a new `auth_sessions` row at login time. Returns the
  /// freshly generated `session_id`. Caller stores the `session_id`
  /// alongside the [AuthSession] so subsequent
  /// [markRefreshed] / [revokeSession] calls can address the same row.
  ///
  /// [tokenHash] is the SHA-256 hex digest of the credential token
  /// associated with this session (today: the Firebase ID token,
  /// because the SDK does not expose the raw refresh token). Honest
  /// naming here matches the `auth_sessions.token_hash` column the
  /// audit-fix migration renamed from `refresh_token_hash`. A
  /// future slice can add a true refresh-token column alongside
  /// without a contract clash.
  Future<String> insertLogin({
    required String operatorId,
    required String locationId,
    required String userId,
    required String tokenHash,
    String? ip,
    String? userAgent,
    String? deviceFingerprint,
    String? geoCountry,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into auth_sessions ('
        'user_id, token_hash, ip, user_agent, '
        'device_fingerprint, geo_country) '
        'values (@user_id::uuid, @token_hash, '
        // INET cast lets a null parameter stay null while a non-null
        // text parameter is parsed by Postgres.
        '@ip::inet, @user_agent, @device_fingerprint, @geo_country) '
        'returning session_id::text as session_id',
        parameters: <String, Object?>{
          'user_id': userId,
          'token_hash': tokenHash,
          'ip': ip,
          'user_agent': userAgent,
          'device_fingerprint': deviceFingerprint,
          'geo_country': geoCountry,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'auth_sessions insert returned no rows — RLS policy may '
          'have blocked the row even though SET LOCAL ran',
        );
      }
      final sessionId = rows.single['session_id'];
      if (sessionId is! String || sessionId.isEmpty) {
        throw StateError(
          'auth_sessions insert returned a malformed session_id',
        );
      }
      return sessionId;
    });
  }

  /// UPDATE `last_seen_at = now()` on a single row. No-op when the
  /// row is already revoked. Used by the refresh-token rotation
  /// path so dormancy sweeps see the latest activity.
  Future<int> markRefreshed({
    required String operatorId,
    required String locationId,
    required String userId,
    required String sessionId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update auth_sessions '
        'set last_seen_at = now() '
        'where session_id = @session_id::uuid '
        'and user_id = @user_id::uuid '
        'and revoked_at is null',
        parameters: <String, Object?>{
          'session_id': sessionId,
          'user_id': userId,
        },
      );
    });
  }

  /// SET `revoked_at = now()` and `revoked_reason = [reason]` on a
  /// single row. Idempotent. Used for single-session sign-out.
  Future<int> revokeSession({
    required String operatorId,
    required String locationId,
    required String userId,
    required String sessionId,
    required String reason,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update auth_sessions '
        'set revoked_at = now(), revoked_reason = @reason '
        'where session_id = @session_id::uuid '
        'and user_id = @user_id::uuid '
        'and revoked_at is null',
        parameters: <String, Object?>{
          'session_id': sessionId,
          'user_id': userId,
          'reason': reason,
        },
      );
    });
  }

  /// SET `revoked_at = now()` on every active row whose `user_id`
  /// matches [userId]. Used for "log out everywhere" + force-logout
  /// admin paths. The user themselves can run this through their
  /// own tenant context; admins use [revokeAllSessionsForUserAsAdmin].
  Future<int> revokeAllSessionsForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required String reason,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update auth_sessions '
        'set revoked_at = now(), revoked_reason = @reason '
        'where user_id = @user_id::uuid '
        'and revoked_at is null',
        parameters: <String, Object?>{
          'user_id': userId,
          'reason': reason,
        },
      );
    });
  }

  /// Admin "force logout all sessions" path. Runs as `forge_admin`
  /// (BYPASSRLS) because the actor is not the row owner. The
  /// [adminReason] string is audited via the wrapper's
  /// `app.bypass_rls_audit = 'system:<reason>'` marker.
  ///
  /// Code-health L3 (C5): `auth_sessions` is a per-user table without
  /// its own `operator_id` column, so the WHERE adds an EXISTS
  /// subquery against `users` keyed on `(user_id, operator_id)`. A
  /// `withSystem` (BYPASSRLS) UPDATE that targets a `userId` from
  /// operator A while the caller believes it lives in operator B
  /// returns 0 affected rows instead of leaking across tenants.
  Future<int> revokeAllSessionsForUserAsAdmin({
    required String userId,
    required String operatorId,
    required String reason,
    required String adminReason,
  }) {
    return withSystem<int>(
      (exec) async {
        return exec.execute(
          'update auth_sessions '
          'set revoked_at = now(), revoked_reason = @reason '
          'where user_id = @user_id::uuid '
          'and revoked_at is null '
          'and exists ('
          '  select 1 from users u '
          '  where u.user_id = @user_id::uuid '
          '  and u.operator_id = @operator_id::uuid'
          ')',
          parameters: <String, Object?>{
            'user_id': userId,
            'operator_id': operatorId,
            'reason': reason,
          },
        );
      },
      reason: adminReason,
    );
  }
}
