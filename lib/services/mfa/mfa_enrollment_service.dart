// Phase 9.4 - MFA enrollment service seam.
//
// Drives TOTP enrollment + recovery-code generation. The Flutter
// shell calls this service from the enrollment screen; production
// binds the real `firebase_auth` MFA APIs (TOTP enrollment uses
// `MultiFactor.beginEnrollment` + `TotpMultiFactorGenerator`). For
// tests we use a fake; the scaffold default fails closed.
//
// Recovery codes are NOT a Firebase-native concept — they're a F&F
// add-on stored in `mfa_factors` (Phase 9.0). The enrollment
// service therefore composes Firebase TOTP setup with the F&F
// recovery-code generator + hasher.

import 'recovery_code_hasher.dart';

/// QR-render data for a fresh TOTP secret. The raw secret is in
/// [secretBase32] for the OTP-app scan; the [otpAuthUrl] embeds the
/// secret + issuer + label in the standard `otpauth://` form so the
/// UI can render either a QR or a copy-paste fallback.
class TotpEnrollmentSetup {
  const TotpEnrollmentSetup({
    required this.factorId,
    required this.secretBase32,
    required this.otpAuthUrl,
  });

  final String factorId;
  final String secretBase32;
  final String otpAuthUrl;
}

/// Bundle returned after successful TOTP confirmation. The
/// [recoveryCodesPlaintext] are the only chance the user gets to
/// see them — the UI must render the display-once view immediately
/// and refuse to re-show them. The proxy persists the
/// [hashedRecoveryCodes] in `mfa_factors`.
class MfaEnrollmentCompleted {
  const MfaEnrollmentCompleted({
    required this.factorId,
    required this.recoveryCodesPlaintext,
    required this.hashedRecoveryCodes,
  });

  final String factorId;
  final List<String> recoveryCodesPlaintext;
  final List<HashedRecoveryCode> hashedRecoveryCodes;
}

/// Result of [MfaEnrollmentService.confirmTotpEnrollment]. Either
/// success (with the recovery-code bundle) or failure (with a
/// machine-readable code the UI maps to copy).
sealed class MfaEnrollmentConfirmResult {
  const MfaEnrollmentConfirmResult();
}

class MfaEnrollmentConfirmSuccess extends MfaEnrollmentConfirmResult {
  const MfaEnrollmentConfirmSuccess(this.payload);
  final MfaEnrollmentCompleted payload;
}

class MfaEnrollmentConfirmFailure extends MfaEnrollmentConfirmResult {
  const MfaEnrollmentConfirmFailure({
    required this.code,
    required this.message,
  });
  final String code;
  final String message;
}

abstract class MfaEnrollmentService {
  /// Begins TOTP enrollment: returns the secret + otpauth URL the
  /// UI shows in the "scan this QR" surface. The caller renders, the
  /// user scans, and then calls [confirmTotpEnrollment] with the
  /// first OTP the OTP app produces.
  Future<TotpEnrollmentSetup> beginTotpEnrollment({
    String authorizationIdToken = '',
    required String userId,
    required String userEmail,
    required String issuerName,
  });

  /// Confirms the enrollment with [oneTimeCode]. On success the
  /// service generates 10 recovery codes, hashes them via the
  /// injected hasher, persists the hashes via
  /// [mfa_factors] (server-side), and returns the plaintext +
  /// hashes for the display-once UI.
  Future<MfaEnrollmentConfirmResult> confirmTotpEnrollment({
    String authorizationIdToken = '',
    required String factorId,
    required String oneTimeCode,
    String issuerName = 'Forge & Flow',
  });
}

/// Hard-fail-closed default. Surfaces a clear error if a deploy
/// forgets to wire the real `firebase_auth` MFA backend.
class ScaffoldFailingMfaEnrollmentService implements MfaEnrollmentService {
  const ScaffoldFailingMfaEnrollmentService();

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment({
    String authorizationIdToken = '',
    required String userId,
    required String userEmail,
    required String issuerName,
  }) async {
    throw StateError(
      '9.4 scaffold: real MfaEnrollmentService is not wired — bind '
      '`firebase_auth` MFA APIs (TotpMultiFactorGenerator etc.) in '
      'the proxy / app bootstrap before exposing the enrollment surface.',
    );
  }

  @override
  Future<MfaEnrollmentConfirmResult> confirmTotpEnrollment({
    String authorizationIdToken = '',
    required String factorId,
    required String oneTimeCode,
    String issuerName = 'Forge & Flow',
  }) async {
    throw StateError('9.4 scaffold: real MfaEnrollmentService is not wired.');
  }
}
