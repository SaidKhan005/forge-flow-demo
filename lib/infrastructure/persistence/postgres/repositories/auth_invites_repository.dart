// Phase 9 live-closeout B20 - AuthInvitesRepository.
//
// Persistence layer for the 9.0 `auth_invites` table:
//
//   invite_id uuid pk default gen_random_uuid()
//   email text not null
//   operator_id uuid (FK operators)
//   role_id uuid (FK roles)
//   location_id uuid null
//   invited_by uuid (FK users)
//   expires_at timestamptz not null
//   accepted_at timestamptz null
//   revoked_at timestamptz null
//   invite_token_hash text not null
//   created_at timestamptz default now()
//
// Per-tenant RLS (operator_id leading) lands in the 9.2 migration
// auth-table flip — every read/write goes through `withTenant` so
// the per-tenant policy admits the row.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class AuthInvitesRepository extends OperatorScopedRepository {
  AuthInvitesRepository(super.tenantWrapper);

  /// INSERT a fresh invite row. Returns the generated `invite_id`.
  /// Caller has already computed `tokenHash` (the proxy hashes the
  /// magic-link token before calling) — the raw token never reaches
  /// the repository.
  Future<String> insertInvite({
    required String operatorId,
    required String locationId,
    required String email,
    required String roleId,
    required String invitedByUserId,
    required DateTime expiresAt,
    required String tokenHash,
    String? targetLocationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: invitedByUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into auth_invites ('
        'email, operator_id, role_id, location_id, '
        'invited_by, expires_at, invite_token_hash) '
        'values (@email, @operator_id::uuid, @role_id::uuid, '
        '@target_location_id::uuid, @invited_by::uuid, '
        '@expires_at, @token_hash) '
        'returning invite_id::text as invite_id',
        parameters: <String, Object?>{
          'email': email,
          'operator_id': operatorId,
          'role_id': roleId,
          'target_location_id': targetLocationId,
          'invited_by': invitedByUserId,
          'expires_at': expiresAt,
          'token_hash': tokenHash,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'auth_invites insert returned no rows — RLS may have blocked',
        );
      }
      final id = rows.single['invite_id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'auth_invites insert returned a malformed invite_id',
        );
      }
      return id;
    });
  }

  /// SET `accepted_at = now()` on a pending invite. Returns the
  /// affected-row count (0 means already accepted, revoked, or
  /// gone). Caller (proxy) re-validates expiry / revocation on the
  /// returned record before completing the user-creation flow.
  Future<int> markAccepted({
    required String operatorId,
    required String locationId,
    required String inviteId,
    required String acceptingUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: acceptingUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update auth_invites '
        'set accepted_at = now() '
        'where invite_id = @invite_id::uuid '
        'and accepted_at is null '
        'and revoked_at is null '
        'and expires_at > now()',
        parameters: <String, Object?>{'invite_id': inviteId},
      );
    });
  }

  /// SET `revoked_at = now()` on a pending invite. Idempotent —
  /// re-revoking returns 0 affected rows so the caller knows not to
  /// emit a duplicate audit event.
  Future<int> revokeInvite({
    required String operatorId,
    required String locationId,
    required String inviteId,
    required String actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update auth_invites '
        'set revoked_at = now() '
        'where invite_id = @invite_id::uuid '
        'and accepted_at is null '
        'and revoked_at is null',
        parameters: <String, Object?>{'invite_id': inviteId},
      );
    });
  }
}
