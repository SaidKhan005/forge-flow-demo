// Phase 11A.4 — KMS stub provider.
//
// Provider abstraction for "write a plaintext credential to KMS,
// receive an opaque pointer in return". The launch admin flow runs
// against the stub: it generates a deterministic
// `kms://stub/<uuid>` reference, logs nothing about plaintext (the
// stub never echoes the secret), and lets the proxy persist the
// pointer + masked-display string in `provider_credentials`.
//
// Production swaps in a real implementation that writes to Cloud Run
// KMS / Azure Key Vault and returns the live secret reference. The
// admin path stays identical — only the binding changes.
//
// The stub also models a forced-failure mode (`failNextWrite`) so the
// rotate route's audit-on-failure path can be exercised end-to-end
// without touching a real KMS.

import 'dart:math';

class KmsWriteResult {
  const KmsWriteResult({
    required this.secretName,
    required this.maskedDisplay,
  });

  /// Opaque KMS pointer the proxy persists in
  /// `provider_credentials.kms_secret_name`. Format depends on the
  /// implementation; the stub uses `kms://stub/<uuid>`.
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

/// Stub provider used by the launch demo + widget tests + the
/// pre-production proxy binding. Returns a deterministic
/// `kms://stub/<uuid>` pointer keyed off [idGenerator] so callers
/// can rebuild a stable expected value in tests.
class KmsStubProvider implements KmsProvider {
  KmsStubProvider({String Function()? idGenerator, this.failNextWrite = false})
    : _idGenerator = idGenerator ?? _defaultId;

  final String Function() _idGenerator;

  /// When true, the next call to [writeSecret] throws
  /// [KmsWriteFailure] and resets the flag. Lets the rotate route's
  /// audit-on-failure path get exercised without a real KMS.
  bool failNextWrite;

  @override
  Future<KmsWriteResult> writeSecret({
    required String logicalKeyKind,
    required String plaintext,
  }) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw const KmsWriteFailure('stub_kms_forced_failure');
    }
    final id = _idGenerator();
    return KmsWriteResult(
      secretName: 'kms://stub/$id',
      maskedDisplay: maskCredentialForDisplay(plaintext),
    );
  }

  static final _rng = Random.secure();
  static String _defaultId() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

/// Mask a plaintext credential for display: show the first four and
/// last four characters joined by `***`. Strings shorter than nine
/// characters fall back to a fully redacted display so we never echo
/// the entire value.
String maskCredentialForDisplay(String plaintext) {
  final trimmed = plaintext.trim();
  if (trimmed.length < 9) return '***';
  final head = trimmed.substring(0, 4);
  final tail = trimmed.substring(trimmed.length - 4);
  return '$head***$tail';
}
