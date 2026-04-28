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

class UsersRepository extends OperatorScopedRepository {
  UsersRepository(super.tenantWrapper);

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
}
