// Phase 9 live-closeout - invited-user first-login activation.
//
// Invites are delivered as Firebase password-reset emails. When the invited
// user completes that email action and signs in for the first time, the proxy
// calls this repository before writing the auth_sessions row. The whole invite
// acceptance transition runs in one forge_admin transaction so `users.status`,
// `auth_invites.accepted_at`, and the audit row cannot drift apart.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import 'audit_logs_repository.dart';

class InvitedUserActivationResult {
  const InvitedUserActivationResult._({required this.activated, this.inviteId});

  const InvitedUserActivationResult.skipped() : this._(activated: false);

  const InvitedUserActivationResult.accepted({required String inviteId})
    : this._(activated: true, inviteId: inviteId);

  final bool activated;
  final String? inviteId;
}

class InvitedUserActivationRepository extends OperatorScopedRepository {
  InvitedUserActivationRepository(
    super.tenantWrapper, {
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    AuditLogsCutoverFlag cutoverFlag = const FixedAuditLogsCutoverFlag(true),
  }) : _auditLogsRepository = auditLogsRepository,
       _cutoverFlag = cutoverFlag;

  /// Phase 9.0Σ.f B.2 — fan-out target for the hash-chained
  /// `public.audit_logs` table. The invited-user activation runs raw
  /// SQL through `withSystem`, so the fan-out lives at this gateway
  /// boundary too.
  final AuditLogsRepository _auditLogsRepository;

  /// Phase 9.0Σ.f B.2 — live-wired flag resolver. Production reads
  /// the seeded `feature_flags` row so flipping it to `false` routes
  /// new writes back to the legacy `auth_events_audit`-only path.
  final AuditLogsCutoverFlag _cutoverFlag;

  Future<InvitedUserActivationResult> acceptPendingInviteAfterLogin({
    required String operatorId,
    required String locationId,
    required String userId,
  }) {
    return withSystem<InvitedUserActivationResult>((exec) async {
      final users = await exec.query(
        'select email, status '
        'from users '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
        },
      );
      if (users.isEmpty) return const InvitedUserActivationResult.skipped();

      final row = users.single;
      final status = row['status'];
      if (status != 'invited') {
        return const InvitedUserActivationResult.skipped();
      }
      final email = row['email'];
      if (email is! String || email.trim().isEmpty) {
        throw StateError('invited user row is missing an email');
      }

      final acceptedInvites = await exec.query(
        'update auth_invites '
        'set accepted_at = now() '
        'where operator_id = @operator_id::uuid '
        'and lower(email) = lower(@email) '
        'and accepted_at is null '
        'and revoked_at is null '
        'and expires_at > now() '
        'returning invite_id::text as invite_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'email': email,
        },
      );
      if (acceptedInvites.isEmpty) {
        throw StateError('invited user has no open invite to accept');
      }
      final inviteId = acceptedInvites.single['invite_id'];
      if (inviteId is! String || inviteId.isEmpty) {
        throw StateError('accepted invite returned a malformed invite_id');
      }

      final updatedUsers = await exec.execute(
        'update users '
        "set status = 'active', "
        'password_set_at = coalesce(password_set_at, now()), '
        'last_login_at = now(), '
        'last_active_at = now(), '
        'updated_at = now() '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid '
        "and status = 'invited' "
        'and deleted_at is null',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
        },
      );
      if (updatedUsers != 1) {
        throw StateError('invited user activation updated no rows');
      }

      final eventPayload = <String, Object?>{
        'invite_id': inviteId,
        'first_password_completed': true,
      };
      await exec.query(
        'insert into auth_events_audit ('
        'event_type, operator_id, location_id, actor_user_id, target_user_id, '
        'event_payload) '
        'values ('
        '@event_type, @operator_id::uuid, @location_id::uuid, '
        '@actor_user_id::uuid, @target_user_id::uuid, '
        "@event_payload::jsonb) "
        'returning event_id::text as event_id',
        parameters: <String, Object?>{
          'event_type': 'auth.invite_accepted',
          'operator_id': operatorId,
          'location_id': locationId,
          'actor_user_id': userId,
          'target_user_id': userId,
          'event_payload': jsonEncode(eventPayload),
        },
      );
      if (await _cutoverFlag.isEnabled(exec)) {
        await _auditLogsRepository.writeRow(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          actorKind: 'user',
          actorUserId: userId,
          targetKind: 'user',
          targetId: userId,
          action: 'auth.invite_accepted',
          payload: eventPayload,
        );
      }

      return InvitedUserActivationResult.accepted(inviteId: inviteId);
    }, reason: 'auth.invite_acceptance');
  }
}
