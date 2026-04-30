// Phase 9 live-closeout B11 - Production MfaEnrollmentService.
//
// Composes the [FirebaseMfaClient] adapter, the only component that imports
// `firebase_auth`'s MultiFactor APIs, into the app/proxy enrollment seam.
// Recovery-code generation is intentionally not part of the launch enrollment
// flow: Firebase cannot accept local recovery codes for second-factor sign-in,
// so Forge & Flow uses delayed admin/self reset instead.

import 'firebase_mfa_client.dart';
import 'mfa_enrollment_service.dart';

class FirebaseMfaEnrollmentService implements MfaEnrollmentService {
  FirebaseMfaEnrollmentService({required FirebaseMfaClient client})
    : _client = client;

  final FirebaseMfaClient _client;

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment({
    String authorizationIdToken = '',
    required String userId,
    required String userEmail,
    required String issuerName,
  }) async {
    final payload = await _client.beginTotpEnrollment(
      authorizationIdToken: authorizationIdToken,
      userId: userId,
      userEmail: userEmail,
      issuerName: issuerName,
    );
    return TotpEnrollmentSetup(
      factorId: payload.factorId,
      secretBase32: payload.secretBase32,
      otpAuthUrl: payload.otpAuthUrl,
    );
  }

  @override
  Future<MfaEnrollmentConfirmResult> confirmTotpEnrollment({
    String authorizationIdToken = '',
    required String factorId,
    required String oneTimeCode,
    String issuerName = 'Forge & Flow',
  }) async {
    final outcome = await _client.confirmTotpEnrollment(
      authorizationIdToken: authorizationIdToken,
      factorId: factorId,
      oneTimeCode: oneTimeCode,
      issuerName: issuerName,
    );
    return switch (outcome) {
      FirebaseMfaConfirmSucceeded(:final factorMetadata) =>
        MfaEnrollmentConfirmSuccess(
          MfaEnrollmentCompleted(
            // Use the firebase_factor_uid from the metadata if the adapter
            // provided one; otherwise fall back to the session factorId. The
            // proxy replaces this with the mfa_factors.factor_id UUID.
            factorId:
                factorMetadata['firebase_factor_uid'] is String &&
                    (factorMetadata['firebase_factor_uid'] as String).isNotEmpty
                ? factorMetadata['firebase_factor_uid'] as String
                : factorId,
          ),
        ),
      FirebaseMfaConfirmFailed(:final code, :final message) =>
        MfaEnrollmentConfirmFailure(code: code, message: message),
    };
  }
}
