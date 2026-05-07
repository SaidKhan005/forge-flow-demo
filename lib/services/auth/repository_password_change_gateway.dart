// Phase 9 live-closeout - production password-change orchestration.
//
// Runs only in the proxy. Flutter sends the signed-in command to the proxy;
// this service verifies the current Firebase password, applies local policy
// checks, updates Firebase, records password_history, and writes audit rows.

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'firebase_admin_auth_client.dart';
import 'hibp_pwned_password_screener.dart';
import 'password_change_gateway.dart';
import 'password_change_service.dart';
import 'repository_password_history_check.dart';

class RepositoryPasswordChangeGateway implements PasswordChangeGateway {
  RepositoryPasswordChangeGateway({
    required this.firebaseAdmin,
    required this.usersRepository,
    required this.passwordHistoryRepository,
    required this.auditRepository,
    required this.hibpScreener,
    required this.passwordHistoryHasher,
    this.pepper,
    this.failClosedOnHibpUnavailable = false,
  });

  final FirebaseAdminAuthClient firebaseAdmin;
  final UsersRepository usersRepository;
  final PasswordHistoryRepository passwordHistoryRepository;
  final AuthEventsAuditRepository auditRepository;
  final HibpPwnedPasswordScreener hibpScreener;
  final PasswordHistoryHasher passwordHistoryHasher;
  // CODE_HEALTH L12 follow-up: optional pepper override threaded into
  // the internal RepositoryPasswordHistoryCheck. Production binds null
  // so the check reads PASSWORD_HISTORY_PEPPER from the env (matching
  // the pre-L12 bootstrap surface). Tests inject a literal pepper via
  // PasswordHistoryPepperConfig.literal so construction never tries to
  // read the env in non-demo mode.
  final PasswordHistoryPepperConfig? pepper;
  final bool failClosedOnHibpUnavailable;

  @override
  Future<PasswordChangeCompleted> changePassword(
    PasswordChangeCommand command,
  ) async {
    final email = await usersRepository.emailForUser(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
      actorUserId: command.actorUserId,
    );
    final firebaseUid =
        command.firebaseUid ??
        await usersRepository.firebaseUidForUser(
          operatorId: command.operatorId,
          locationId: command.locationId,
          userId: command.actorUserId,
          actorUserId: command.actorUserId,
        );

    final verified = await firebaseAdmin.verifyPassword(
      email: email,
      password: command.currentPassword,
      expectedUid: firebaseUid,
    );
    if (!verified) {
      throw const PasswordChangeRejected(
        code: 'current_password_invalid',
        message: 'The current password is incorrect.',
        statusCode: 403,
      );
    }
    if (command.currentPassword == command.newPassword) {
      throw const PasswordChangeRejected(
        code: 'password_reused',
        message: 'Choose a password you have not used recently.',
        rejections: <String>['reused_from_history'],
      );
    }

    final historyCheck = RepositoryPasswordHistoryCheck(
      repository: passwordHistoryRepository,
      hasher: passwordHistoryHasher,
      operatorId: command.operatorId,
      locationId: command.locationId,
      pepper: pepper,
    );
    final service = PasswordChangeService(
      hibpScreener: hibpScreener,
      historyCheck: historyCheck,
      failClosedOnHibpUnavailable: failClosedOnHibpUnavailable,
    );
    final outcome = await service.evaluate(
      userId: command.actorUserId,
      candidate: command.newPassword,
    );
    if (!outcome.allowed) {
      throw PasswordChangeRejected(
        code: _codeFor(outcome.rejections),
        message: _messageFor(outcome.rejections),
        rejections: _rejectionCodes(outcome.rejections),
      );
    }

    if (outcome.hibpResult == PwnedPasswordResult.screenerUnavailable) {
      await _audit(
        command,
        eventType: 'auth.hibp_unavailable',
        payload: const <String, Object?>{'path': 'password_change'},
      );
    }

    await firebaseAdmin.updatePassword(
      uid: firebaseUid,
      password: command.newPassword,
    );
    await historyCheck.recordAndPrune(
      userId: command.actorUserId,
      candidate: command.newPassword,
    );
    await usersRepository.markPasswordChanged(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );
    await _audit(command, eventType: 'auth.password_changed');

    return PasswordChangeCompleted(
      hibpUnavailable:
          outcome.hibpResult == PwnedPasswordResult.screenerUnavailable,
    );
  }

  Future<void> _audit(
    PasswordChangeCommand command, {
    required String eventType,
    Map<String, Object?> payload = const <String, Object?>{},
  }) async {
    // User-initiated: password change runs on the HTTP path with the
    // actor's JWT. The forgot-password / reset-link path uses the
    // separate `password_reset_*_gateway.dart` boundaries which tag
    // their own audit rows as 'system'.
    await auditRepository.insertEvent(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorKind: 'user',
      actorUserId: command.actorUserId,
      targetUserId: command.actorUserId,
      eventType: eventType,
      payload: payload,
    );
  }

  static String _codeFor(Set<PasswordChangeRejection> rejections) {
    if (rejections.contains(PasswordChangeRejection.violatesPolicy)) {
      return 'password_policy_failed';
    }
    if (rejections.contains(PasswordChangeRejection.pwnedInBreach)) {
      return 'password_pwned';
    }
    if (rejections.contains(PasswordChangeRejection.reusedFromHistory)) {
      return 'password_reused';
    }
    if (rejections.contains(PasswordChangeRejection.hibpUnavailable)) {
      return 'hibp_unavailable';
    }
    if (rejections.contains(PasswordChangeRejection.historyCheckUnavailable)) {
      return 'password_history_unavailable';
    }
    return 'password_change_rejected';
  }

  static String _messageFor(Set<PasswordChangeRejection> rejections) {
    if (rejections.contains(PasswordChangeRejection.violatesPolicy)) {
      return 'Choose a password that meets the password policy.';
    }
    if (rejections.contains(PasswordChangeRejection.pwnedInBreach)) {
      return 'Choose a password that has not appeared in a known breach.';
    }
    if (rejections.contains(PasswordChangeRejection.reusedFromHistory)) {
      return 'Choose a password you have not used recently.';
    }
    if (rejections.contains(PasswordChangeRejection.hibpUnavailable)) {
      return 'Password screening is unavailable. Please try again.';
    }
    if (rejections.contains(PasswordChangeRejection.historyCheckUnavailable)) {
      return 'Password history is unavailable. Please try again.';
    }
    return 'Password change was rejected. Please try another password.';
  }

  static List<String> _rejectionCodes(Set<PasswordChangeRejection> rejections) {
    return rejections
        .map((rejection) {
          switch (rejection) {
            case PasswordChangeRejection.violatesPolicy:
              return 'violates_policy';
            case PasswordChangeRejection.pwnedInBreach:
              return 'pwned_in_breach';
            case PasswordChangeRejection.hibpUnavailable:
              return 'hibp_unavailable';
            case PasswordChangeRejection.reusedFromHistory:
              return 'reused_from_history';
            case PasswordChangeRejection.historyCheckUnavailable:
              return 'history_check_unavailable';
          }
        })
        .toList(growable: false);
  }
}
