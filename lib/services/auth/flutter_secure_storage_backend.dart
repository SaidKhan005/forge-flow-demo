// Phase 9 live-closeout - flutter_secure_storage backend.
//
// This is the only runtime file that imports the real secure-storage plugin.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'platform_secure_session_storage.dart';

/// Production [PlatformSecureStorageBackend] over
/// `package:flutter_secure_storage`.
///
/// The key/value shape is owned by [PlatformSecureSessionStorage]; this class
/// only delegates to the platform plugin and keeps token-bearing values out of
/// logs and exceptions.
class FlutterSecureStorageBackend implements PlatformSecureStorageBackend {
  const FlutterSecureStorageBackend({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) {
    return _storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) {
    return _storage.delete(key: key);
  }
}
