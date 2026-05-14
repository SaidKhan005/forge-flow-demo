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

class AuthInvitePendingRow {
  const AuthInvitePendingRow({
    required this.inviteId,
    required this.email,
    required this.roleId,
    required this.roleLabel,
    required this.scopeType,
    required this.expiresAt,
    required this.createdAt,
    this.locationId,
    this.locationLabel,
    this.orgUnitId,
    this.orgUnitLabel,
  });

  final String inviteId;
  final String email;
  final String roleId;
  final String roleLabel;
  final String scopeType;
  final String? locationId;
  final String? locationLabel;
  final String? orgUnitId;
  final String? orgUnitLabel;
  final DateTime expiresAt;
  final DateTime createdAt;
}

class AuthInvitesRepository extends OperatorScopedRepository {
  AuthInvitesRepository(super.tenantWrapper);

  Future<List<AuthInvitePendingRow>> listPendingInvites({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<List<AuthInvitePendingRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select i.invite_id::text as invite_id, '
        'i.email, i.role_id::text as role_id, '
        "coalesce(r.display_name, 'Unknown role') as role_label, "
        'i.scope_type, '
        'i.location_id::text as location_id, '
        'l.name as location_label, '
        'i.org_unit_id::text as org_unit_id, '
        'ou.name as org_unit_label, '
        'i.expires_at, i.created_at '
        'from auth_invites i '
        'left join roles r on r.role_id = i.role_id '
        'left join locations l on l.location_id = i.location_id '
        'left join org_units ou on ou.id = i.org_unit_id '
        'where i.operator_id = @operator_id::uuid '
        'and i.accepted_at is null '
        'and i.revoked_at is null '
        'order by i.expires_at asc, lower(i.email)',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return rows.map(_projectPendingInviteRow).toList(growable: false);
    });
  }

  /// INSERT a fresh invite row. Returns the generated `invite_id`.
  /// Caller has already computed `tokenHash` (the proxy hashes the
  /// magic-link token before calling) — the raw token never reaches
  /// the repository.
  Future<String> insertInvite({
    required String operatorId,
    required String locationId,
    required String email,
    required String roleId,
    required String scopeType,
    required String invitedByUserId,
    required DateTime expiresAt,
    required String tokenHash,
    String? targetLocationId,
    String? targetOrgUnitId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: invitedByUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into auth_invites ('
        'email, operator_id, role_id, scope_type, location_id, org_unit_id, '
        'invited_by, expires_at, invite_token_hash) '
        'values (@email, @operator_id::uuid, @role_id::uuid, '
        '@scope_type, @target_location_id::uuid, @target_org_unit_id::uuid, '
        '@invited_by::uuid, '
        '@expires_at, @token_hash) '
        'returning invite_id::text as invite_id',
        parameters: <String, Object?>{
          'email': email,
          'operator_id': operatorId,
          'role_id': roleId,
          'scope_type': scopeType,
          'target_location_id': targetLocationId,
          'target_org_unit_id': targetOrgUnitId,
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
        throw StateError('auth_invites insert returned a malformed invite_id');
      }
      return id;
    });
  }

  /// SET `accepted_at = now()` on a pending invite. Returns the
  /// affected-row count (0 means already accepted, revoked, or
  /// gone). Caller (proxy) re-validates expiry / revocation on the
  /// returned record before completing the user-creation flow.
  ///
  /// Code-health L3 (C5): the WHERE includes `operator_id = $N` so a
  /// caller passing an `inviteId` from operator A while believing it
  /// lives in operator B writes 0 rows instead of accepting an invite
  /// from a different tenant. RLS already filters reads through
  /// `withTenant`, but the predicate keeps this defense-in-depth even
  /// if RLS were ever loosened or bypassed.
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
        'and operator_id = @operator_id::uuid '
        'and accepted_at is null '
        'and revoked_at is null '
        'and expires_at > now()',
        parameters: <String, Object?>{
          'invite_id': inviteId,
          'operator_id': operatorId,
        },
      );
    });
  }

  /// SET `revoked_at = now()` on a pending invite. Idempotent —
  /// re-revoking returns 0 affected rows so the caller knows not to
  /// emit a duplicate audit event.
  ///
  /// Code-health L3 (C5): the WHERE includes `operator_id = $N` so a
  /// caller passing an `inviteId` from operator A while believing it
  /// lives in operator B writes 0 rows instead of revoking an invite
  /// from a different tenant. RLS already filters reads through
  /// `withTenant`, but the predicate keeps this defense-in-depth even
  /// if RLS were ever loosened or bypassed.
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
        'and operator_id = @operator_id::uuid '
        'and accepted_at is null '
        'and revoked_at is null',
        parameters: <String, Object?>{
          'invite_id': inviteId,
          'operator_id': operatorId,
        },
      );
    });
  }

  /// Wave 2 W-2 — Cancel pending invite end-to-end.
  ///
  /// Returns the `email` for a pending (`accepted_at` and `revoked_at`
  /// both null) invite so the gateway can resolve the matching shadow
  /// `users` row (`createInvite` provisions one with the same email +
  /// `status = 'invited'`) and call Firebase Identity Platform
  /// `accounts:delete` on the shadow account. Returns null when the
  /// invite is already revoked, accepted, or does not exist —
  /// keeping the caller idempotent on the wire.
  ///
  /// Code-health L3 (C5): the WHERE includes `operator_id = $N` so a
  /// caller passing an `inviteId` from operator A while believing it
  /// lives in operator B reads no rows instead of leaking the email
  /// of an invite in a different tenant.
  Future<String?> pendingInviteEmail({
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
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select email from auth_invites '
        'where invite_id = @invite_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and accepted_at is null '
        'and revoked_at is null '
        'limit 1',
        parameters: <String, Object?>{
          'invite_id': inviteId,
          'operator_id': operatorId,
        },
      );
      if (rows.isEmpty) return null;
      final email = rows.single['email'];
      if (email is! String || email.isEmpty) return null;
      return email;
    });
  }

  static AuthInvitePendingRow _projectPendingInviteRow(
    Map<String, Object?> row,
  ) {
    final inviteId = row['invite_id'];
    final email = row['email'];
    final roleId = row['role_id'];
    final roleLabel = row['role_label'];
    final scopeType = row['scope_type'];
    final expiresAt = row['expires_at'];
    final createdAt = row['created_at'];
    if (inviteId is! String ||
        inviteId.isEmpty ||
        email is! String ||
        email.isEmpty ||
        roleId is! String ||
        roleId.isEmpty ||
        roleLabel is! String ||
        roleLabel.isEmpty ||
        scopeType is! String ||
        scopeType.isEmpty ||
        expiresAt is! DateTime ||
        createdAt is! DateTime) {
      throw StateError('auth_invites pending list returned a malformed row');
    }
    final locationId = row['location_id'];
    final locationLabel = row['location_label'];
    final orgUnitId = row['org_unit_id'];
    final orgUnitLabel = row['org_unit_label'];
    return AuthInvitePendingRow(
      inviteId: inviteId,
      email: email,
      roleId: roleId,
      roleLabel: roleLabel,
      scopeType: scopeType,
      locationId: locationId is String && locationId.isNotEmpty
          ? locationId
          : null,
      locationLabel: locationLabel is String && locationLabel.isNotEmpty
          ? locationLabel
          : null,
      orgUnitId: orgUnitId is String && orgUnitId.isNotEmpty ? orgUnitId : null,
      orgUnitLabel: orgUnitLabel is String && orgUnitLabel.isNotEmpty
          ? orgUnitLabel
          : null,
      expiresAt: expiresAt,
      createdAt: createdAt,
    );
  }
}
