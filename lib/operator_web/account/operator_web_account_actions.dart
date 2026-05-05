// Phase 11W.live - web-safe account action seam.
//
// The Account screen is shared between demo and live mode. Demo mode keeps
// the local fixture behavior; live mode injects this seam so MFA enrollment
// and password rotation call the existing Phase 9 proxy routes without the UI
// importing a Firebase or HTTP implementation directly.

import '../auth/operator_web_auth_source.dart';

abstract class OperatorWebAccountActions {
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
  });

  Future<void> confirmAccountMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  });

  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  });
}
