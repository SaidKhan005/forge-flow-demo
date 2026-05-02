// Forge & Flow — KMS provider interface.
//
// Phase 11A.4c. Extracted from `kms_stub_provider.dart` so production
// implementations (`GcpSecretManagerKmsProvider`, KmsLaneRouter) can
// take a stable dependency on the contract without bringing in the
// stub's `dart:math` import on the client build.
//
// The contract is intentionally write-only: every implementation
// persists [plaintext] under [logicalKeyKind] and returns a stable
// pointer plus a masked display string. Reads do NOT happen through
// this interface — runtime API key resolution still flows through
// Cloud Run env vars (Hard Promise #7 in CLAUDE.md). The pointer
// returned by `writeSecret` lands in
// `provider_credentials.kms_secret_name` for audit + disaster-recovery.

class KmsWriteResult {
  const KmsWriteResult({
    required this.secretName,
    required this.maskedDisplay,
  });

  /// Opaque KMS pointer the proxy persists in
  /// `provider_credentials.kms_secret_name`. Format depends on the
  /// implementation:
  ///  - `KmsStubProvider`              -> `kms://stub/<uuid>`
  ///  - `GcpSecretManagerKmsProvider`  -> `kms://gcp-secret-manager/<full version name>`
  final String secretName;

  /// Display string the admin console renders. Built from the first
  /// few + last few characters of the plaintext so an operator can
  /// recognise the rotated key without leaking it.
  final String maskedDisplay;
}

abstract class KmsProvider {
  /// Persist [plaintext] under [logicalKeyKind] and return an opaque
  /// pointer plus a masked display string. Implementations must NOT
  /// log [plaintext] — failing closed is preferable to leaking the
  /// secret.
  Future<KmsWriteResult> writeSecret({
    required String logicalKeyKind,
    required String plaintext,
  });
}

class KmsWriteFailure implements Exception {
  const KmsWriteFailure(this.message);
  final String message;
  @override
  String toString() => 'KmsWriteFailure: $message';
}
