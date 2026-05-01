// Phase 9.UX.7 - self-serve password reset gateway seam.
//
// Splits the email-link reset flow into the two app-side calls the new
// reset screens need:
//   - [requestReset]  — POST /v1/auth/password/reset/request, fire and
//                       forget. Privacy-preserving by contract: the
//                       app shows the same confirmation copy whether
//                       the email exists or not.
//   - [confirmReset]  — POST /v1/auth/password/reset/confirm, the
//                       Firebase action page deep-link target. Surfaces
//                       proxy policy rejections (HIBP, last-5 history)
//                       so the operator can pick another password.
//
// Backend ownership lives with B48; this seam is a pure UX consumer.

import '../../auth/password_policy.dart';

class PasswordResetRequestCommand {
  const PasswordResetRequestCommand({required this.email, this.idempotencyKey});

  final String email;

  /// Optional caller-supplied idempotency key. When non-null the
  /// gateway forwards it as the `Idempotency-Key` header so a
  /// network retry of the same submission replays the proxy's
  /// cached response instead of issuing a second reset email.
  /// When null the gateway generates a fresh key per call (matches
  /// the pre-9.UX.7 behavior).
  final String? idempotencyKey;
}

class PasswordResetRequested {
  const PasswordResetRequested();
}

class PasswordResetConfirmRequest {
  const PasswordResetConfirmRequest({
    required this.oobCode,
    required this.newPassword,
    this.idempotencyKey,
  });

  final String oobCode;
  final String newPassword;

  /// Optional caller-supplied idempotency key. Critical for confirm
  /// retries: oobCode is single-use, so a retry without dedupe
  /// surfaces `password_reset_expired` even when the server already
  /// completed the original submit. The screen owns this key and
  /// reuses it across retries of the same (oobCode, password)
  /// attempt, regenerating only when the operator changes inputs
  /// (e.g., picks a different password after a HIBP rejection).
  final String? idempotencyKey;
}

class PasswordResetConfirmed {
  const PasswordResetConfirmed({this.hibpUnavailable = false});

  final bool hibpUnavailable;
}

class PasswordResetRejected implements Exception {
  const PasswordResetRejected({
    required this.code,
    required this.message,
    this.statusCode = 422,
    this.rejections = const <String>[],
  });

  /// Stable machine-readable code (`invalid_email`, `rate_limited`,
  /// `password_policy_failed`, `password_pwned`, `password_reused`,
  /// `password_reset_expired`, `network_error`, ...).
  final String code;

  /// Human-readable message safe to render in the UI banner. Must
  /// never carry the password attempt or token contents.
  final String message;

  final int statusCode;

  /// Rejection key list returned by the proxy when policy / HIBP /
  /// history checks reject the candidate password.
  final List<String> rejections;

  @override
  String toString() =>
      'PasswordResetRejected(code: $code, status: $statusCode)';
}

abstract class PasswordResetGateway {
  /// Requests an email-link password reset. Always returns success
  /// from the operator's perspective (privacy-preserving). Network /
  /// rate-limit failures throw [PasswordResetRejected] so the UI can
  /// distinguish "we didn't get to ask" from the silent success copy.
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  );

  /// Confirms the new password for the supplied Firebase oobCode.
  /// On success returns [PasswordResetConfirmed]; on policy / HIBP /
  /// history rejection throws [PasswordResetRejected] with the proxy
  /// rejection codes preserved.
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  );
}

/// Default fail-closed implementation. Every call throws so a
/// production deploy without a wired backend surfaces a clear
/// "no auth backend wired" error instead of silently succeeding.
class ScaffoldFailingPasswordResetGateway implements PasswordResetGateway {
  const ScaffoldFailingPasswordResetGateway();

  @override
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    throw const PasswordResetRejected(
      code: 'password_reset_not_configured',
      message: 'Password reset is unavailable in this build.',
      statusCode: 503,
    );
  }

  @override
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  ) async {
    throw const PasswordResetRejected(
      code: 'password_reset_not_configured',
      message: 'Password reset is unavailable in this build.',
      statusCode: 503,
    );
  }
}

/// Demo gateway that supports the `kDemoMode = true` walkthrough
/// without a live proxy. Accepts any well-formed email; rejects
/// candidate passwords shorter than [minPasswordLength] with a
/// `password_policy_failed` error so operators can see the
/// rejection copy path.
class DemoPasswordResetGateway implements PasswordResetGateway {
  const DemoPasswordResetGateway({
    this.minPasswordLength = PasswordPolicy.minLength,
  });

  final int minPasswordLength;

  @override
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    return const PasswordResetRequested();
  }

  @override
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  ) async {
    final candidate = request.newPassword;
    if (candidate.length < minPasswordLength) {
      throw const PasswordResetRejected(
        code: 'password_policy_failed',
        message: 'Choose a password that meets the password policy.',
        rejections: <String>['violates_policy'],
      );
    }
    return const PasswordResetConfirmed();
  }
}
