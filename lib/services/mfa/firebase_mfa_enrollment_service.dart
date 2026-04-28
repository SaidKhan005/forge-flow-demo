// Phase 9 live-closeout B11 - Production MfaEnrollmentService.
//
// Composes the [FirebaseMfaClient] adapter (the only component that
// imports `firebase_auth`'s MultiFactor APIs) with the F&F
// [RecoveryCodeGenerator] + [RecoveryCodeHasher] so the higher-
// level [MfaEnrollmentCompleted] bundle the UI consumes is built in
// one place.
//
// The service does NOT persist `mfa_factors` rows — that lives in
// [MfaFactorsRepository] (B12). The proxy orchestrator chains the
// two:
//
//   1. service.beginTotpEnrollment → adapter call → return setup
//   2. UI renders QR, user scans, types the first OTP
//   3. service.confirmTotpEnrollment → adapter call → on success
//      generate codes + hashes → return [MfaEnrollmentCompleted]
//   4. proxy persists the TOTP factor row + N recovery-code rows
//      via [MfaFactorsRepository]
//   5. proxy returns plaintext codes to the UI for the display-once
//      surface (the only time the user ever sees them)

import 'dart:math';
import 'dart:typed_data';

import 'firebase_mfa_client.dart';
import 'mfa_enrollment_service.dart';
import 'recovery_code_generator.dart';
import 'recovery_code_hasher.dart';

/// Source of cryptographically-strong random bytes for the
/// per-user recovery-code salt. Tests inject deterministic
/// implementations.
abstract class RecoveryCodeSaltSource {
  Uint8List nextSalt();
}

/// Production salt source: 16 bytes from `Random.secure`. Per the
/// `recovery_code_hasher.dart` design, salt is per-user (not
/// per-code) so all 10 codes for a single enrollment share it.
class SecureRandomRecoveryCodeSaltSource implements RecoveryCodeSaltSource {
  SecureRandomRecoveryCodeSaltSource({Random? random})
    : _random = random ?? Random.secure();

  final Random _random;

  @override
  Uint8List nextSalt() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }
}

class FirebaseMfaEnrollmentService implements MfaEnrollmentService {
  FirebaseMfaEnrollmentService({
    required FirebaseMfaClient client,
    required RecoveryCodeGenerator codeGenerator,
    required RecoveryCodeHasher codeHasher,
    required RecoveryCodeSaltSource saltSource,
    int recoveryCodeCount = RecoveryCodeGenerator.defaultCodeCount,
  }) : _client = client,
       _codeGenerator = codeGenerator,
       _codeHasher = codeHasher,
       _saltSource = saltSource,
       _recoveryCodeCount = recoveryCodeCount;

  final FirebaseMfaClient _client;
  final RecoveryCodeGenerator _codeGenerator;
  final RecoveryCodeHasher _codeHasher;
  final RecoveryCodeSaltSource _saltSource;
  final int _recoveryCodeCount;

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
      FirebaseMfaConfirmSucceeded(:final factorMetadata) => _buildSuccess(
        factorId: factorId,
        factorMetadata: factorMetadata,
      ),
      FirebaseMfaConfirmFailed(:final code, :final message) =>
        MfaEnrollmentConfirmFailure(code: code, message: message),
    };
  }

  MfaEnrollmentConfirmSuccess _buildSuccess({
    required String factorId,
    required Map<String, Object?> factorMetadata,
  }) {
    // Same per-user salt is used for every code so the 10 codes
    // share salt-storage on the user row (the proxy persists salt +
    // hash per `mfa_factors` row but also exposes the salt to the
    // verification path so a single store lookup can decide).
    final salt = _saltSource.nextSalt();
    final plaintext = _codeGenerator.generate(count: _recoveryCodeCount);
    final hashed = <HashedRecoveryCode>[];
    for (final raw in plaintext) {
      final normalized = RecoveryCodeGenerator.normalize(raw);
      if (normalized == null) {
        throw StateError(
          'RecoveryCodeGenerator produced a code outside its own '
          'alphabet — refusing to enroll',
        );
      }
      hashed.add(_codeHasher.hash(normalizedCode: normalized, saltBytes: salt));
    }
    return MfaEnrollmentConfirmSuccess(
      MfaEnrollmentCompleted(
        // Use the firebase_factor_uid from the metadata if the
        // adapter provided one; otherwise fall back to the session
        // factorId. The proxy will replace this with the
        // mfa_factors.factor_id UUID at persist time.
        factorId:
            factorMetadata['firebase_factor_uid'] is String &&
                (factorMetadata['firebase_factor_uid'] as String).isNotEmpty
            ? factorMetadata['firebase_factor_uid'] as String
            : factorId,
        recoveryCodesPlaintext: List<String>.unmodifiable(plaintext),
        hashedRecoveryCodes: List<HashedRecoveryCode>.unmodifiable(hashed),
      ),
    );
  }
}
