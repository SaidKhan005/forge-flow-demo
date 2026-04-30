// Phase 9.UX.7 - password reset email-link parity.
//
// Firebase action links still own oobCode issuance and expiry, but the final
// password set goes through the proxy so HIBP screening and last-5 password
// history match the in-app password-change path.

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'firebase_admin_auth_client.dart';
import 'hibp_pwned_password_screener.dart';
import 'password_change_gateway.dart';
import 'password_change_service.dart';
import 'repository_password_history_check.dart';

class PasswordResetConfirmCommand {
  const PasswordResetConfirmCommand({
    required this.oobCode,
    required this.newPassword,
  });

  final String oobCode;
  final String newPassword;
}

class PasswordResetConfirmCompleted {
  const PasswordResetConfirmCompleted({this.hibpUnavailable = false});

  final bool hibpUnavailable;
}

abstract class PasswordResetConfirmGateway {
  Future<PasswordResetConfirmCompleted> confirmPasswordReset(
    PasswordResetConfirmCommand command,
  );
}

class RepositoryPasswordResetConfirmGateway
    implements PasswordResetConfirmGateway {
  RepositoryPasswordResetConfirmGateway({
    required this.firebaseAdmin,
    required this.usersRepository,
    required this.passwordHistoryRepository,
    required this.auditRepository,
    required this.hibpScreener,
    required this.passwordHistoryHasher,
    this.failClosedOnHibpUnavailable = false,
  });

  final FirebaseAdminAuthClient firebaseAdmin;
  final UsersRepository usersRepository;
  final PasswordHistoryRepository passwordHistoryRepository;
  final AuthEventsAuditRepository auditRepository;
  final HibpPwnedPasswordScreener hibpScreener;
  final PasswordHistoryHasher passwordHistoryHasher;
  final bool failClosedOnHibpUnavailable;

  @override
  Future<PasswordResetConfirmCompleted> confirmPasswordReset(
    PasswordResetConfirmCommand command,
  ) async {
    final codeInfo = await firebaseAdmin.verifyPasswordResetCode(
      oobCode: command.oobCode,
    );
    final user = await usersRepository.findActiveAuthUserByEmail(
      email: codeInfo.email,
      adminReason: 'auth.password_reset_confirm_lookup',
    );
    if (user == null) {
      throw const PasswordChangeRejected(
        code: 'password_reset_user_not_found',
        message: 'Password reset could not be completed.',
        statusCode: 404,
      );
    }
    final expectedUid = user.firebaseUid ?? user.userId;
    final codeUid = codeInfo.uid;
    if (codeUid != null && codeUid != expectedUid) {
      throw const PasswordChangeRejected(
        code: 'password_reset_scope_mismatch',
        message: 'Password reset could not be completed.',
        statusCode: 403,
      );
    }

    final historyCheck = RepositoryPasswordHistoryCheck(
      repository: passwordHistoryRepository,
      hasher: passwordHistoryHasher,
      operatorId: user.operatorId,
      locationId: user.locationId,
    );
    final service = PasswordChangeService(
      hibpScreener: hibpScreener,
      historyCheck: historyCheck,
      failClosedOnHibpUnavailable: failClosedOnHibpUnavailable,
    );
    final outcome = await service.evaluate(
      userId: user.userId,
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
        user,
        eventType: 'auth.hibp_unavailable',
        payload: const <String, Object?>{'path': 'password_reset'},
      );
    }
    await firebaseAdmin.confirmPasswordReset(
      oobCode: command.oobCode,
      newPassword: command.newPassword,
    );
    await historyCheck.recordAndPrune(
      userId: user.userId,
      candidate: command.newPassword,
    );
    await usersRepository.markPasswordChanged(
      operatorId: user.operatorId,
      locationId: user.locationId,
      userId: user.userId,
    );
    await _audit(user, eventType: 'auth.password_reset_confirmed');
    return PasswordResetConfirmCompleted(
      hibpUnavailable:
          outcome.hibpResult == PwnedPasswordResult.screenerUnavailable,
    );
  }

  Future<void> _audit(
    UserAuthLookupRow user, {
    required String eventType,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return auditRepository.insertSystemEvent(
      operatorId: user.operatorId,
      locationId: user.locationId,
      actorKind: 'system',
      targetUserId: user.userId,
      eventType: eventType,
      payload: payload,
      adminReason: 'auth.password_reset_confirm',
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
    return 'password_reset_rejected';
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
    return 'Password reset was rejected. Please try another password.';
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
