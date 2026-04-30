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
    this.userRoleId,
    this.locationId,
    this.locationLabel,
    this.lastActiveAt,
  });

  final String userId;
  final String email;
  final String displayName;
  final String roleId;
  final String roleLabel;
  final String status;
  final bool mfaEnrolled;
  final String? userRoleId;
  final String? locationId;
  final String? locationLabel;
  final DateTime? lastActiveAt;
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

class UsersRepository extends OperatorScopedRepository {
  UsersRepository(super.tenantWrapper);

  Future<List<TeamUserRepositoryRow>> listTeamUsers({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
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
        '  where mf.user_id = u.user_id and mf.revoked_at is null'
        ') as mfa_enrolled, '
        'u.last_active_at '
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
        'and admin.operator_id = oa.operator_id '
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
