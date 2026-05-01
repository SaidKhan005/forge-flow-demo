// Phase 9 live-closeout B20 - UsersRepository.
//
// Persistence layer for the `users` table (the user lifecycle row,
// not the auth_invites / auth_sessions tables). The 9.0 schema
// extends `users` with:
//
//   firebase_uid uuid unique not null
//   external_id text unique null
//   status text default 'invited' check in (
//     invited / active / suspended /
//     dormant_30 / dormant_60 / dormant_90 / deleted)
//   deleted_at timestamptz null
//   roles_version int default 0
//   mfa_required bool default false
//   last_login_at timestamptz null
//   last_active_at timestamptz null
//   password_set_at timestamptz null
//   email_verified_at timestamptz null
//
// `users` per-tenant RLS lives in the cloud-foundation flip slice
// (B10). This repo therefore mostly runs through `withSystem`
// (forge_admin BYPASSRLS) for now — the audit reason marker carries
// the lifecycle action so audit trails can attribute the bypass
// correctly.

import 'dart:convert' show jsonDecode;

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class TeamUserRepositoryRow {
  const TeamUserRepositoryRow({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.roleId,
    required this.roleLabel,
    required this.status,
    required this.mfaEnrolled,
    required this.mfaRemovalPending,
    this.mfaRemovalRequestId,
    this.userRoleId,
    this.locationId,
    this.locationLabel,
    this.lastActiveAt,
    this.grants = const <TeamUserGrantRepositoryRow>[],
  });

  final String userId;
  final String email;
  final String displayName;
  final String roleId;
  final String roleLabel;
  final String status;
  final bool mfaEnrolled;
  final bool mfaRemovalPending;
  final String? mfaRemovalRequestId;
  final String? userRoleId;
  final String? locationId;
  final String? locationLabel;
  final DateTime? lastActiveAt;
  final List<TeamUserGrantRepositoryRow> grants;
}

/// Phase 9.UX.grant-payload — per-user grant snapshot bundled with the
/// team-users projection. Mirrors the `user_roles` row shape consumed by
/// the role-change dialog's inheritance hint, plus the materialized
/// `user_effective_locations` set so an `org_unit` grant carries its
/// reachable locations without a follow-up read.
class TeamUserGrantRepositoryRow {
  const TeamUserGrantRepositoryRow({
    required this.userRoleId,
    required this.roleId,
    required this.roleLabel,
    required this.scopeType,
    this.orgUnitId,
    this.locationId,
    this.sourceOrgUnitId,
    this.effectiveLocationIds = const <String>[],
    this.validFrom,
    this.validUntil,
    this.revokedAt,
  });

  final String userRoleId;
  final String roleId;

  /// `roles.display_name` for the granted role, joined inside the
  /// projection so the dialog never needs to wait on the role-catalog
  /// load to resolve a label. Falls back to the raw `role_id::text`
  /// when no `roles` row exists (defense-in-depth — should not happen
  /// under the FK).
  final String roleLabel;

  /// One of `'operator_wide'`, `'org_unit'`, or `'location'`. Matches the
  /// `user_roles.scope_type` CHECK constraint.
  final String scopeType;
  final String? orgUnitId;
  final String? locationId;
  final String? sourceOrgUnitId;
  final List<String> effectiveLocationIds;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final DateTime? revokedAt;
}

class SelfProfileRepositoryRow {
  const SelfProfileRepositoryRow({
    required this.displayName,
    required this.email,
    required this.status,
    required this.locationLabel,
    required this.roleLabels,
    required this.mfaEnabled,
    this.lastActiveAt,
    this.lastLoginAt,
    this.passwordUpdatedAt,
  });

  final String displayName;
  final String email;
  final String status;
  final String locationLabel;
  final List<String> roleLabels;
  final bool mfaEnabled;
  final DateTime? lastActiveAt;
  final DateTime? lastLoginAt;
  final DateTime? passwordUpdatedAt;
}

class MfaRecoveryAdminRecipientRow {
  const MfaRecoveryAdminRecipientRow({
    required this.userId,
    required this.email,
    required this.scopeType,
    required this.isSuperAdmin,
  });

  final String userId;
  final String email;
  final String scopeType;
  final bool isSuperAdmin;
}

class MfaRecoveryTargetRow {
  const MfaRecoveryTargetRow({
    required this.userId,
    required this.operatorId,
    required this.email,
    required this.admins,
    this.locationId,
  });

  final String userId;
  final String operatorId;
  final String? locationId;
  final String email;
  final List<MfaRecoveryAdminRecipientRow> admins;
}

class UserAuthLookupRow {
  const UserAuthLookupRow({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.email,
    this.firebaseUid,
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final String email;
  final String? firebaseUid;
}

class UsersRepository extends OperatorScopedRepository {
  UsersRepository(super.tenantWrapper);

  Future<List<TeamUserRepositoryRow>> listTeamUsers({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    try {
      return await _listTeamUsers(
        ctx: ctx,
        operatorId: operatorId,
        includeMfaRemovalRequests: true,
      );
    } catch (error) {
      if (!_isMissingMfaRemovalRequestsTable(error)) rethrow;
      return _listTeamUsers(
        ctx: ctx,
        operatorId: operatorId,
        includeMfaRemovalRequests: false,
      );
    }
  }

  Future<List<TeamUserRepositoryRow>> _listTeamUsers({
    required TenantContext ctx,
    required String operatorId,
    required bool includeMfaRemovalRequests,
  }) {
    final mfaRemovalRequestProjection = includeMfaRemovalRequests
        ? '('
              '  select mfr.request_id::text '
              '  from mfa_factor_removal_requests mfr '
              '  where mfr.user_id = u.user_id '
              '  and mfr.operator_id = @operator_id::uuid '
              '  and mfr.completed_at is null '
              '  and mfr.cancelled_at is null'
              '  order by mfr.requested_at desc '
              '  limit 1'
              ') as mfa_removal_request_id, '
        : 'null::text as mfa_removal_request_id, ';
    return withTenant<List<TeamUserRepositoryRow>>(ctx, (exec) async {
      final rows = await exec.query(
        "select u.user_id::text as user_id, "
        'u.email, '
        "coalesce(nullif(u.display_name, ''), "
        "nullif(trim(concat_ws(' ', u.first_name, u.last_name)), ''), "
        'u.email) as display_name, '
        'coalesce(ur.role_id::text, u.primary_role_id::text, '
        "'unassigned') as role_id, "
        "coalesce(r.display_name, 'Unassigned') as role_label, "
        'u.status, '
        'ur.user_role_id::text as user_role_id, '
        'coalesce(ur.location_id::text, u.primary_location_id::text) '
        'as location_id, '
        'l.name as location_label, '
        'exists ('
        '  select 1 from mfa_factors mf '
        '  where mf.user_id = u.user_id '
        "  and mf.factor_type = 'totp' "
        '  and mf.revoked_at is null'
        ') as mfa_enrolled, '
        '$mfaRemovalRequestProjection'
        'u.last_active_at, '
        '('
        '  select coalesce(jsonb_agg('
        '    jsonb_build_object('
        "      'user_role_id', urg.user_role_id::text, "
        "      'role_id', urg.role_id::text, "
        "      'role_label', coalesce(rg.display_name, urg.role_id::text), "
        "      'scope_type', urg.scope_type, "
        "      'org_unit_id', urg.org_unit_id::text, "
        "      'location_id', urg.location_id::text, "
        "      'source_org_unit_id', urg.org_unit_id::text, "
        "      'effective_location_ids', ("
        '        select coalesce(array_agg(uel.location_id::text order by '
        '          uel.location_id::text), array[]::text[]) '
        '        from user_effective_locations uel '
        '        where uel.operator_id = urg.operator_id '
        '        and uel.user_id = urg.user_id '
        '        and uel.source_user_role_id = urg.user_role_id'
        '      ),'
        "      'valid_from', urg.valid_from, "
        "      'valid_until', urg.valid_until, "
        "      'revoked_at', urg.revoked_at"
        '    )'
        "    order by urg.valid_from"
        "  ), '[]'::jsonb)::text "
        '  from user_roles urg '
        '  left join roles rg on rg.role_id = urg.role_id '
        '  where urg.user_id = u.user_id '
        '  and urg.operator_id = @operator_id::uuid '
        '  and urg.revoked_at is null '
        '  and urg.valid_from <= now() '
        '  and (urg.valid_until is null or urg.valid_until > now())'
        ') as grants '
        'from users u '
        'left join lateral ('
        '  select user_role_id, role_id, location_id '
        '  from user_roles '
        '  where user_id = u.user_id '
        '  and operator_id = @operator_id::uuid '
        '  and revoked_at is null '
        '  and valid_from <= now() '
        '  and (valid_until is null or valid_until > now()) '
        '  order by case when location_id is null then 0 else 1 end, '
        '  valid_from desc '
        '  limit 1'
        ') ur on true '
        'left join roles r on r.role_id = coalesce(ur.role_id, '
        'u.primary_role_id) '
        'left join locations l on l.location_id = coalesce(ur.location_id, '
        'u.primary_location_id) '
        'where u.operator_id = @operator_id::uuid '
        'and u.deleted_at is null '
        'order by u.status, lower(u.email)',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return rows.map(_projectTeamUserRow).toList(growable: false);
    });
  }

  Future<SelfProfileRepositoryRow?> findSelfProfile({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<SelfProfileRepositoryRow?>(ctx, (exec) async {
      final rows = await exec.query(
        "select coalesce(nullif(u.display_name, ''), "
        "nullif(trim(concat_ws(' ', u.first_name, u.last_name)), ''), "
        'u.email) as display_name, '
        'u.email, '
        'u.status, '
        "coalesce(l.name, primary_l.name, 'Current location') "
        'as location_label, '
        'coalesce('
        '  array_agg(distinct r.display_name) '
        '    filter (where r.display_name is not null), '
        '  array_remove(array[pr.display_name], null), '
        "  array[]::text[]"
        ') as role_labels, '
        'exists ('
        '  select 1 from mfa_factors mf '
        '  where mf.user_id = u.user_id '
        "  and mf.factor_type = 'totp' "
        '  and mf.revoked_at is null'
        ') as mfa_enabled, '
        'u.last_active_at, '
        'u.last_login_at, '
        'u.password_set_at as password_updated_at '
        'from users u '
        'left join locations l '
        '  on l.location_id = @location_id::uuid '
        '  and l.operator_id = @operator_id::uuid '
        'left join locations primary_l '
        '  on primary_l.location_id = u.primary_location_id '
        'left join roles pr on pr.role_id = u.primary_role_id '
        'left join user_roles ur '
        '  on ur.user_id = u.user_id '
        '  and ur.operator_id = @operator_id::uuid '
        '  and ur.revoked_at is null '
        '  and ur.valid_from <= now() '
        '  and (ur.valid_until is null or ur.valid_until > now()) '
        'left join roles r on r.role_id = ur.role_id '
        'where u.user_id = @user_id::uuid '
        'and u.operator_id = @operator_id::uuid '
        'and u.deleted_at is null '
        "and u.status != 'deleted' "
        'group by u.user_id, u.display_name, u.first_name, u.last_name, '
        'u.email, u.status, l.name, primary_l.name, pr.display_name, '
        'u.last_active_at, u.last_login_at, u.password_set_at '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': actorUserId,
        },
      );
      if (rows.isEmpty) return null;
      return _projectSelfProfileRow(rows.single);
    });
  }

  /// INSERT the cloud-foundation `users` row for a newly invited Team user.
  ///
  /// This is a system path because the invited user does not yet have a
  /// tenant session. The caller still supplies [operatorId] and
  /// [primaryLocationId] so the row is scoped before any invite / grant rows
  /// are written.
  Future<int> insertInvitedUser({
    required String userId,
    required String firebaseUid,
    required String operatorId,
    required String email,
    required String primaryRoleId,
    required String primaryLocationId,
    required String adminReason,
  }) {
    return withSystem<int>((exec) {
      return exec.execute(
        'insert into users ('
        'user_id, firebase_uid, operator_id, email, status, '
        'primary_role_id, primary_location_id, roles_version'
        ') values ('
        '@user_id::uuid, @firebase_uid::uuid, @operator_id::uuid, '
        '@email, '
        "'invited', "
        '@primary_role_id::uuid, @primary_location_id::uuid, 0'
        ')',
        parameters: <String, Object?>{
          'user_id': userId,
          'firebase_uid': firebaseUid,
          'operator_id': operatorId,
          'email': email,
          'primary_role_id': primaryRoleId,
          'primary_location_id': primaryLocationId,
        },
      );
    }, reason: adminReason);
  }

  /// UPDATE `users.status` to [newStatus]. Used by the lifecycle
  /// state machine post-transition. Caller passes the actor +
  /// reason so the audit row writer (separate concern) can attribute
  /// the change.
  Future<int> updateStatus({
    required String userId,
    required String newStatus,
    required String adminReason,
  }) {
    return withSystem<int>((exec) async {
      return exec.execute(
        'update users '
        'set status = @status, updated_at = now() '
        'where user_id = @user_id::uuid '
        'and status != @status',
        parameters: <String, Object?>{'user_id': userId, 'status': newStatus},
      );
    }, reason: adminReason);
  }

  /// SET `last_login_at = now()` + bump `last_active_at`. Called from
  /// the post-login orchestrator after a successful sign-in.
  Future<int> markLoggedIn({
    required String operatorId,
    required String locationId,
    required String userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update users '
        'set last_login_at = now(), last_active_at = now(), '
        'updated_at = now() '
        'where user_id = @user_id::uuid',
        parameters: <String, Object?>{'user_id': userId},
      );
    });
  }

  /// SET `last_active_at = now()` only (no last_login_at touch).
  /// Background dormancy sweep + activity heartbeats use this.
  Future<int> markActive({
    required String operatorId,
    required String locationId,
    required String userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update users '
        'set last_active_at = now(), updated_at = now() '
        'where user_id = @user_id::uuid',
        parameters: <String, Object?>{'user_id': userId},
      );
    });
  }

  /// Resolve the locked-out user and restaurant-admin recipients for the
  /// pre-auth MFA recovery request path. The caller returns only a generic
  /// accepted response to the client; this lookup must not leak existence.
  Future<MfaRecoveryTargetRow?> findMfaRecoveryTargetByEmail({
    required String email,
    required String adminReason,
  }) {
    return withSystem<MfaRecoveryTargetRow?>((exec) async {
      final rows = await exec.query(
        'select u.user_id::text as user_id, '
        'u.operator_id::text as operator_id, '
        'coalesce(u.primary_location_id::text, '
        'o.primary_location_id::text) as location_id, '
        'u.email '
        'from users u '
        'left join operators o on o.operator_id = u.operator_id '
        'where lower(u.email) = lower(@email) '
        'and u.deleted_at is null '
        "and u.status != 'deleted' "
        'limit 1',
        parameters: <String, Object?>{'email': email},
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final userId = row['user_id'];
      final operatorId = row['operator_id'];
      final locationId = row['location_id'];
      final userEmail = row['email'];
      if (userId is! String ||
          userId.isEmpty ||
          operatorId is! String ||
          operatorId.isEmpty ||
          userEmail is! String ||
          userEmail.isEmpty) {
        throw StateError('mfa recovery target lookup returned malformed row');
      }
      final adminRows = await exec.query(
        'select admin.user_id::text as user_id, '
        'admin.email, '
        "coalesce(oa.scope_type, 'operator_owner') as scope_type, "
        'oa.is_super_admin '
        'from operator_admins oa '
        'join users admin on admin.user_id = oa.user_id '
        'where oa.operator_id = @operator_id::uuid '
        'and admin.deleted_at is null '
        "and admin.status != 'deleted' "
        'order by oa.is_super_admin desc, oa.created_at asc',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      final admins = <MfaRecoveryAdminRecipientRow>[
        for (final adminRow in adminRows)
          _projectMfaRecoveryAdminRecipient(adminRow),
      ];
      return MfaRecoveryTargetRow(
        userId: userId,
        operatorId: operatorId,
        locationId: locationId is String && locationId.isNotEmpty
            ? locationId
            : null,
        email: userEmail,
        admins: List<MfaRecoveryAdminRecipientRow>.unmodifiable(admins),
      );
    }, reason: adminReason);
  }

  Future<UserAuthLookupRow?> findActiveAuthUserByEmail({
    required String email,
    required String adminReason,
  }) {
    return withSystem<UserAuthLookupRow?>((exec) async {
      final rows = await exec.query(
        'select u.user_id::text as user_id, '
        'u.operator_id::text as operator_id, '
        'coalesce(u.primary_location_id::text, '
        'o.primary_location_id::text) as location_id, '
        'u.email, '
        'u.firebase_uid::text as firebase_uid '
        'from users u '
        'left join operators o on o.operator_id = u.operator_id '
        'where lower(u.email) = lower(@email) '
        'and u.deleted_at is null '
        "and u.status != 'deleted' "
        'limit 1',
        parameters: <String, Object?>{'email': email},
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final userId = row['user_id'];
      final operatorId = row['operator_id'];
      final locationId = row['location_id'];
      final userEmail = row['email'];
      final firebaseUid = row['firebase_uid'];
      if (userId is! String ||
          userId.isEmpty ||
          operatorId is! String ||
          operatorId.isEmpty ||
          locationId is! String ||
          locationId.isEmpty ||
          userEmail is! String ||
          userEmail.isEmpty) {
        throw StateError('auth user lookup returned malformed row');
      }
      return UserAuthLookupRow(
        userId: userId,
        operatorId: operatorId,
        locationId: locationId,
        email: userEmail,
        firebaseUid: firebaseUid is String && firebaseUid.isNotEmpty
            ? firebaseUid
            : null,
      );
    }, reason: adminReason);
  }

  /// SELECT the user's email inside the actor's tenant. Used by server-side
  /// Firebase Admin calls; the value never flows back to Flutter unless a
  /// specific route intentionally returns it.
  Future<String> emailForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required String actorUserId,
  }) {
    return _singleStringForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      actorUserId: actorUserId,
      columnSql: 'email',
      columnAlias: 'email',
      missingMessage: 'users lookup returned no email for target user',
    );
  }

  /// SELECT the Firebase UID for a user. F&F creates Firebase users with the
  /// same UUID-shaped value as `users.user_id`, but this read keeps the
  /// choreography honest if that ever changes.
  Future<String> firebaseUidForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required String actorUserId,
  }) {
    return _singleStringForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      actorUserId: actorUserId,
      columnSql: 'firebase_uid::text',
      columnAlias: 'firebase_uid',
      missingMessage: 'users lookup returned no firebase_uid for target user',
    );
  }

  /// System/background lookup for Firebase UID. Workers run outside a live
  /// operator session, so they use the admin wrapper and an explicit audit
  /// reason instead of trying to borrow a user's tenant context.
  Future<String> firebaseUidForUserSystem({
    required String userId,
    required String adminReason,
  }) {
    return withSystem<String>((exec) async {
      final rows = await exec.query(
        'select firebase_uid::text as firebase_uid '
        'from users '
        'where user_id = @user_id::uuid '
        'and deleted_at is null '
        'limit 1',
        parameters: <String, Object?>{'user_id': userId},
      );
      if (rows.isEmpty) {
        throw StateError('users lookup returned no firebase_uid');
      }
      final value = rows.single['firebase_uid'];
      if (value is String && value.isNotEmpty) return value;
      throw StateError('users lookup returned malformed firebase_uid');
    }, reason: adminReason);
  }

  /// SELECT `roles_version` so Firebase custom claims can be refreshed after
  /// grant/revoke operations.
  Future<int> rolesVersionForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required String actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      final rows = await exec.query(
        'select roles_version from users '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError('users lookup returned no roles_version');
      }
      final value = rows.single['roles_version'];
      if (value is int) return value;
      throw StateError('users lookup returned a malformed roles_version');
    });
  }

  /// SET `password_set_at = now()` after a successful Firebase password
  /// change.
  Future<int> markPasswordChanged({
    required String operatorId,
    required String locationId,
    required String userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update users '
        'set password_set_at = now(), updated_at = now() '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
        },
      );
    });
  }

  /// Soft-delete: mark `deleted_at` + flip status to 'deleted'.
  /// Idempotent — repeated calls are a no-op.
  Future<int> softDelete({
    required String userId,
    required String adminReason,
  }) {
    return withSystem<int>((exec) async {
      return exec.execute(
        'update users '
        "set deleted_at = now(), status = 'deleted', updated_at = now() "
        'where user_id = @user_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{'user_id': userId},
      );
    }, reason: adminReason);
  }

  /// Bump `roles_version` so cached permission snapshots invalidate.
  /// Used by anything that grants / revokes roles outside the
  /// `UserRolesRepository` path (e.g. status flips that strip access).
  Future<int> bumpRolesVersion({
    required String userId,
    required String adminReason,
  }) {
    return withSystem<int>((exec) async {
      return exec.execute(
        'update users '
        'set roles_version = roles_version + 1, updated_at = now() '
        'where user_id = @user_id::uuid',
        parameters: <String, Object?>{'user_id': userId},
      );
    }, reason: adminReason);
  }

  /// GDPR redaction: replace email with `redacted-{user_id}@deleted.local`,
  /// null out `display_name`, `first_name`, `last_name`. Per the
  /// `ErasureRedactionTemplate` contract from 9.8 — Art. 17(3) preserves
  /// `firebase_uid` (link integrity) + `user_id` + `created_at` so audit
  /// rows still have a stable join key.
  Future<int> redactPii({required String userId, required String adminReason}) {
    return withSystem<int>((exec) async {
      return exec.execute(
        'update users '
        "set email = 'redacted-' || user_id::text || '@deleted.local', "
        'first_name = null, last_name = null, display_name = null, '
        'avatar_url = null, preferred_locale = null, updated_at = now() '
        'where user_id = @user_id::uuid',
        parameters: <String, Object?>{'user_id': userId},
      );
    }, reason: adminReason);
  }

  Future<String> _singleStringForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required String actorUserId,
    required String columnSql,
    required String columnAlias,
    required String missingMessage,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'select $columnSql as $columnAlias from users '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(missingMessage);
      }
      final value = rows.single[columnAlias];
      if (value is String && value.isNotEmpty) return value;
      throw StateError('users lookup returned malformed $columnAlias');
    });
  }

  static TeamUserRepositoryRow _projectTeamUserRow(Map<String, Object?> row) {
    final userId = row['user_id'];
    final email = row['email'];
    final displayName = row['display_name'];
    final roleId = row['role_id'];
    final roleLabel = row['role_label'];
    final status = row['status'];
    final mfaEnrolled = row['mfa_enrolled'];
    final mfaRemovalRequestId = row['mfa_removal_request_id'];
    final pendingRemovalRequestId =
        mfaRemovalRequestId is String && mfaRemovalRequestId.isNotEmpty
        ? mfaRemovalRequestId
        : null;
    final mfaRemovalPending = pendingRemovalRequestId != null;
    if (userId is! String ||
        userId.isEmpty ||
        email is! String ||
        email.isEmpty ||
        displayName is! String ||
        displayName.isEmpty ||
        roleId is! String ||
        roleId.isEmpty ||
        roleLabel is! String ||
        roleLabel.isEmpty ||
        status is! String ||
        status.isEmpty ||
        mfaEnrolled is! bool) {
      throw StateError('team users lookup returned a malformed row');
    }
    final userRoleId = row['user_role_id'];
    final locationId = row['location_id'];
    final locationLabel = row['location_label'];
    final lastActiveAt = row['last_active_at'];
    return TeamUserRepositoryRow(
      userId: userId,
      email: email,
      displayName: displayName,
      roleId: roleId,
      roleLabel: roleLabel,
      status: status,
      mfaEnrolled: mfaEnrolled,
      mfaRemovalPending: mfaRemovalPending,
      mfaRemovalRequestId: pendingRemovalRequestId,
      userRoleId: userRoleId is String && userRoleId.isNotEmpty
          ? userRoleId
          : null,
      locationId: locationId is String && locationId.isNotEmpty
          ? locationId
          : null,
      locationLabel: locationLabel is String && locationLabel.isNotEmpty
          ? locationLabel
          : null,
      lastActiveAt: lastActiveAt is DateTime ? lastActiveAt : null,
      grants: _projectTeamUserGrants(row['grants']),
    );
  }

  static List<TeamUserGrantRepositoryRow> _projectTeamUserGrants(Object? raw) {
    final decoded = _decodeGrantsJson(raw);
    if (decoded.isEmpty) return const <TeamUserGrantRepositoryRow>[];
    final grants = <TeamUserGrantRepositoryRow>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final map = Map<String, Object?>.from(entry);
      final userRoleId = map['user_role_id'];
      final roleId = map['role_id'];
      final scopeType = map['scope_type'];
      if (userRoleId is! String ||
          userRoleId.isEmpty ||
          roleId is! String ||
          roleId.isEmpty ||
          scopeType is! String ||
          scopeType.isEmpty) {
        continue;
      }
      final rawLabel = _readOptionalString(map['role_label']);
      grants.add(
        TeamUserGrantRepositoryRow(
          userRoleId: userRoleId,
          roleId: roleId,
          roleLabel: rawLabel ?? roleId,
          scopeType: scopeType,
          orgUnitId: _readOptionalString(map['org_unit_id']),
          locationId: _readOptionalString(map['location_id']),
          sourceOrgUnitId: _readOptionalString(map['source_org_unit_id']),
          effectiveLocationIds: _readStringList(map['effective_location_ids']),
          validFrom: _readOptionalDateTime(map['valid_from']),
          validUntil: _readOptionalDateTime(map['valid_until']),
          revokedAt: _readOptionalDateTime(map['revoked_at']),
        ),
      );
    }
    return List<TeamUserGrantRepositoryRow>.unmodifiable(grants);
  }

  static List<Object?> _decodeGrantsJson(Object? raw) {
    if (raw == null) return const <Object?>[];
    if (raw is List) return raw;
    if (raw is String) {
      if (raw.isEmpty) return const <Object?>[];
      final decoded = _safeJsonDecode(raw);
      if (decoded is List) return decoded;
    }
    return const <Object?>[];
  }

  static Object? _safeJsonDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static String? _readOptionalString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _readOptionalDateTime(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value)?.toUtc();
    }
    return null;
  }

  static List<String> _readStringList(Object? value) {
    if (value is List) {
      return List<String>.unmodifiable(
        value.whereType<String>().where((entry) => entry.isNotEmpty),
      );
    }
    return const <String>[];
  }

  static bool _isMissingMfaRemovalRequestsTable(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('mfa_factor_removal_requests') &&
        (text.contains('does not exist') ||
            text.contains('undefined_table') ||
            text.contains('42p01'));
  }

  static SelfProfileRepositoryRow _projectSelfProfileRow(
    Map<String, Object?> row,
  ) {
    final displayName = row['display_name'];
    final email = row['email'];
    final status = row['status'];
    final locationLabel = row['location_label'];
    final rawRoleLabels = row['role_labels'];
    final mfaEnabled = row['mfa_enabled'];
    if (displayName is! String ||
        displayName.isEmpty ||
        email is! String ||
        email.isEmpty ||
        status is! String ||
        status.isEmpty ||
        locationLabel is! String ||
        locationLabel.isEmpty ||
        mfaEnabled is! bool) {
      throw StateError('self profile lookup returned a malformed row');
    }
    final roleLabels = rawRoleLabels is List
        ? rawRoleLabels
              .whereType<String>()
              .map((label) => label.trim())
              .where((label) => label.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final lastActiveAt = row['last_active_at'];
    final lastLoginAt = row['last_login_at'];
    final passwordUpdatedAt = row['password_updated_at'];
    return SelfProfileRepositoryRow(
      displayName: displayName,
      email: email,
      status: status,
      locationLabel: locationLabel,
      roleLabels: List<String>.unmodifiable(roleLabels),
      mfaEnabled: mfaEnabled,
      lastActiveAt: lastActiveAt is DateTime ? lastActiveAt : null,
      lastLoginAt: lastLoginAt is DateTime ? lastLoginAt : null,
      passwordUpdatedAt: passwordUpdatedAt is DateTime
          ? passwordUpdatedAt
          : null,
    );
  }
}

MfaRecoveryAdminRecipientRow _projectMfaRecoveryAdminRecipient(
  Map<String, Object?> row,
) {
  final userId = row['user_id'];
  final email = row['email'];
  final scopeType = row['scope_type'];
  final isSuperAdmin = row['is_super_admin'];
  if (userId is! String ||
      userId.isEmpty ||
      email is! String ||
      email.isEmpty ||
      scopeType is! String ||
      scopeType.isEmpty ||
      isSuperAdmin is! bool) {
    throw StateError('mfa recovery admin lookup returned malformed row');
  }
  return MfaRecoveryAdminRecipientRow(
    userId: userId,
    email: email,
    scopeType: scopeType,
    isSuperAdmin: isSuperAdmin,
  );
}
