// fix(M2.pepper-runtime): KMS pepper store.
//
// V1 implementation: reads pepper bytes from process environment variables
// of the form `FORGE_PEPPER_<id>` where `<id>` matches the
// `password_hash_pepper_id` stored per row.
//
// The active pepper id is identified by the env var `FORGE_PEPPER_ACTIVE_ID`.
// When KMS lands, swap only this file's implementation — the proxy route
// and the PepperResolver interface remain unchanged.
//
// Env var shape:
//   FORGE_PEPPER_ACTIVE_ID=sha256:abc123          — which id is active
//   FORGE_PEPPER_sha256:abc123=<base64-bytes>     — active pepper bytes (b64)
//   FORGE_PEPPER_sha256:old456=<base64-bytes>     — a retired pepper still
//                                                   needed to verify old rows
//
// The `<id>` portion of the env var name may contain colons (as in the
// sha256-prefix format). Platform env var names that contain `:` are
// not portable to all shells, so callers may substitute `:` with `_COLON_`
// in the env var name; the store normalises both forms when looking up.

import 'dart:convert';
import 'dart:io';

/// V1 pepper store backed by process environment variables.
///
/// Production: set `FORGE_PEPPER_ACTIVE_ID` + one or more
/// `FORGE_PEPPER_<id>` vars in the Cloud Run service env. When KMS
/// lands, replace this class with a GCP Secret Manager / Azure Key
/// Vault implementation; the route layer stays the same.
class EnvKmsPepperStore {
  EnvKmsPepperStore({Map<String, String>? environment})
    : _env = environment ?? Platform.environment;

  final Map<String, String> _env;

  static const String _activeIdVar = 'FORGE_PEPPER_ACTIVE_ID';
  static const String _varPrefix = 'FORGE_PEPPER_';

  /// Returns the active pepper id. Throws [KmsPepperStoreException] when
  /// `FORGE_PEPPER_ACTIVE_ID` is missing or empty.
  String get activeId {
    final id = (_env[_activeIdVar] ?? '').trim();
    if (id.isEmpty) {
      throw const KmsPepperStoreException(
        'FORGE_PEPPER_ACTIVE_ID is not set. Set it to the active pepper id '
        '(e.g. sha256:abc123) and provide the corresponding '
        'FORGE_PEPPER_sha256:abc123 env var.',
      );
    }
    return id;
  }

  /// Returns the base64-encoded pepper bytes for [pepperId], or `null`
  /// when no env var exists for that id. Callers should treat `null` as
  /// "pepper unknown — row un-verifiable".
  String? pepperB64ForId(String pepperId) {
    // Normalise id → env var name. Allow either raw `:` or `_COLON_`
    // substitution in the env var name so operators can use shells that
    // disallow `:` in env names.
    final rawKey = '$_varPrefix$pepperId';
    final colonKey = '$_varPrefix${pepperId.replaceAll(':', '_COLON_')}';
    return _env[rawKey] ?? _env[colonKey];
  }

  /// Returns the base64-encoded bytes for the active pepper.
  /// Throws [KmsPepperStoreException] when the active id or its bytes
  /// are missing.
  String activePepperB64() {
    final id = activeId;
    final b64 = pepperB64ForId(id);
    if (b64 == null || b64.trim().isEmpty) {
      throw KmsPepperStoreException(
        'Active pepper id is "$id" but no env var found for it. '
        'Expected FORGE_PEPPER_$id (or FORGE_PEPPER_${id.replaceAll(':', '_COLON_')}) '
        'to contain base64-encoded pepper bytes.',
      );
    }
    return b64.trim();
  }

  /// Validates that the active id + active bytes are set, and that
  /// every value in the store is valid base64. Returns a list of
  /// validation errors; empty list = valid.
  List<String> validate() {
    final errors = <String>[];
    String id;
    try {
      id = activeId;
    } on KmsPepperStoreException catch (e) {
      errors.add(e.message);
      return errors; // can't continue without an active id
    }
    try {
      activePepperB64();
    } on KmsPepperStoreException catch (e) {
      errors.add(e.message);
    }
    // Check that any FORGE_PEPPER_ vars (other than ACTIVE_ID) decode as
    // valid base64.
    for (final entry in _env.entries) {
      if (!entry.key.startsWith(_varPrefix)) continue;
      if (entry.key == _activeIdVar) continue;
      try {
        base64Decode(entry.value.trim());
      } catch (_) {
        errors.add(
          'env var ${entry.key} is not valid base64',
        );
      }
    }
    // Ensure the active id pepper decodes cleanly.
    final b64 = pepperB64ForId(id);
    if (b64 != null && b64.trim().isNotEmpty) {
      try {
        base64Decode(b64.trim());
      } catch (_) {
        errors.add('active pepper bytes for id "$id" are not valid base64');
      }
    }
    return errors;
  }
}

/// Thrown when pepper store configuration is invalid.
class KmsPepperStoreException implements Exception {
  const KmsPepperStoreException(this.message);

  final String message;

  @override
  String toString() => 'KmsPepperStoreException: $message';
}
