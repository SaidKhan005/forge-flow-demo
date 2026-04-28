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

  /// UPDATE `users.status` to [newStatus]. Used by the lifecycle
  /// state machine post-transition. Caller passes the actor +
  /// reason so the audit row writer (separate concern) can attribute
  /// the change.
  Future<int> updateStatus({
    required String userId,
    required String newStatus,
    required String adminReason,
  }) {
    return withSystem<int>(
      (exec) async {
        return exec.execute(
          'update users '
          'set status = @status, updated_at = now() '
          'where user_id = @user_id::uuid '
          'and status != @status',
          parameters: <String, Object?>{
            'user_id': userId,
            'status': newStatus,
          },
        );
      },
      reason: adminReason,
    );
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

  /// Soft-delete: mark `deleted_at` + flip status to 'deleted'.
  /// Idempotent — repeated calls are a no-op.
  Future<int> softDelete({
    required String userId,
    required String adminReason,
  }) {
    return withSystem<int>(
      (exec) async {
        return exec.execute(
          'update users '
          "set deleted_at = now(), status = 'deleted', updated_at = now() "
          'where user_id = @user_id::uuid '
          'and deleted_at is null',
          parameters: <String, Object?>{'user_id': userId},
        );
      },
      reason: adminReason,
    );
  }

  /// Bump `roles_version` so cached permission snapshots invalidate.
  /// Used by anything that grants / revokes roles outside the
  /// `UserRolesRepository` path (e.g. status flips that strip access).
  Future<int> bumpRolesVersion({
    required String userId,
    required String adminReason,
  }) {
    return withSystem<int>(
      (exec) async {
        return exec.execute(
          'update users '
          'set roles_version = roles_version + 1, updated_at = now() '
          'where user_id = @user_id::uuid',
          parameters: <String, Object?>{'user_id': userId},
        );
      },
      reason: adminReason,
    );
  }

  /// GDPR redaction: replace email with `redacted-{user_id}@deleted.local`,
  /// null out `display_name`, `first_name`, `last_name`. Per the
  /// `ErasureRedactionTemplate` contract from 9.8 — Art. 17(3) preserves
  /// `firebase_uid` (link integrity) + `user_id` + `created_at` so audit
  /// rows still have a stable join key.
  Future<int> redactPii({
    required String userId,
    required String adminReason,
  }) {
    return withSystem<int>(
      (exec) async {
        return exec.execute(
          'update users '
          "set email = 'redacted-' || user_id::text || '@deleted.local', "
          'first_name = null, last_name = null, display_name = null, '
          'avatar_url = null, preferred_locale = null, updated_at = now() '
          'where user_id = @user_id::uuid',
          parameters: <String, Object?>{'user_id': userId},
        );
      },
      reason: adminReason,
    );
  }
}
