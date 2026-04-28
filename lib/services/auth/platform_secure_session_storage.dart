// Phase 9 live-closeout B5 - Platform secure storage backend +
// production SecureSessionStorage binding.
//
// The production [SecureSessionStorage] binds platform-secure storage
// (Keychain on iOS / Android Keystore on Android / IndexedDB-backed
// session storage on web). To keep the binding unit-testable + to defer
// pulling `flutter_secure_storage` into pubspec until iOS Xcode +
// Android Gradle wiring (B7) lands, we route the underlying read/
// write/delete through the [PlatformSecureStorageBackend] adapter.
//
// Hard rules:
//
//   * No file outside this directory may import the real
//     `package:flutter_secure_storage/flutter_secure_storage.dart`.
//     The SDK adapter that does is a B7 follow-up.
//   * Tokens never appear in `toString()`, debug prints, or error
//     messages emitted from this layer.
//   * The default binding is [ScaffoldFailingPlatformSecureStorageBackend]
//     so a misconfigured deploy surfaces a "no secure storage wired"
//     error rather than silently dropping persistence.

import '../secure_session_storage.dart';

/// Backend abstraction over the platform secure-storage SDK
/// (`flutter_secure_storage` in production). Tests inject fakes;
/// production wires a thin adapter that delegates to the SDK.
abstract class PlatformSecureStorageBackend {
  /// Returns the value stored under [key], or null when absent.
  Future<String?> read(String key);

  /// Writes [value] under [key]. Implementations MUST use the
  /// platform secure-storage primitives (Keychain / Android Keystore
  /// / web IndexedDB) — never plain `SharedPreferences`.
  Future<void> write(String key, String value);

  /// Deletes the value stored under [key]. No-op when absent.
  Future<void> delete(String key);
}

/// Hard-fail-closed default. Every method throws so a production
/// deploy that wires [PlatformSecureSessionStorage] but forgets the
/// real backend surfaces a clear "no platform secure storage wired"
/// error rather than silently dropping persistence.
class ScaffoldFailingPlatformSecureStorageBackend
    implements PlatformSecureStorageBackend {
  const ScaffoldFailingPlatformSecureStorageBackend();

  @override
  Future<String?> read(String key) async {
    throw StateError(_message);
  }

  @override
  Future<void> write(String key, String value) async {
    throw StateError(_message);
  }

  @override
  Future<void> delete(String key) async {
    throw StateError(_message);
  }

  static const String _message =
      'B5 scaffold: real PlatformSecureStorageBackend is not wired — '
      'bind `flutter_secure_storage` (Keychain / Android Keystore / web '
      'IndexedDB) in the app bootstrap before serving authenticated '
      'traffic.';
}

/// In-memory backend for tests + previewer harnesses. Functionally
/// equivalent to [InMemorySecureSessionStorage] but at the backend
/// layer so tests of [PlatformSecureSessionStorage] can exercise
/// the indirection.
class InMemoryPlatformSecureStorageBackend
    implements PlatformSecureStorageBackend {
  final Map<String, String> _store = <String, String>{};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }
}

/// Production [SecureSessionStorage] binding. Persists the AuthSession
/// JSON under a single namespaced key in the platform-secure backend.
/// The key is versioned so a future migration (e.g. switching the
/// AuthSession JSON shape) can read the old key, rewrite under a new
/// key, and delete the old one without leaving stale data.
class PlatformSecureSessionStorage extends SecureSessionStorage {
  PlatformSecureSessionStorage({
    required PlatformSecureStorageBackend backend,
    String storageKey = defaultSessionKey,
  }) : _backend = backend,
       _storageKey = storageKey;

  /// Default namespaced key. Bumped per AuthSession JSON shape
  /// version so a future migration can disambiguate.
  static const String defaultSessionKey = 'forge_flow.auth.session_v1';

  final PlatformSecureStorageBackend _backend;
  final String _storageKey;

  @override
  Future<String?> readSessionJson() {
    return _backend.read(_storageKey);
  }

  @override
  Future<void> writeSessionJson(String json) {
    return _backend.write(_storageKey, json);
  }

  @override
  Future<void> clear() {
    return _backend.delete(_storageKey);
  }
}
