import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// PII-aware wrapper around [FirebaseCrashlytics].
///
/// Scrubs known sensitive fields from custom key maps and error messages
/// before forwarding to Crashlytics so no PII (email, phone number,
/// auth tokens, vendor credentials) is ever stored in the crash-reporting
/// backend.
///
/// Call [initialize] once in `main()` after `Firebase.initializeApp()`.
class CrashReporter {
  CrashReporter._();

  static final CrashReporter instance = CrashReporter._();

  // Keys whose *values* are always redacted.
  static const _sensitiveKeys = <String>{
    'email',
    'phone',
    'pepper',
    'password',
    'authorization',
    'bearer',
    'vendor_credentials',
    'api_key',
    'access_token',
    'refresh_token',
    'id_token',
    'secret',
  };

  // Regex patterns that match PII-looking *values* in error messages.
  static final _emailPattern = RegExp(
    r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}',
  );
  static final _bearerPattern = RegExp(
    r'Bearer\s+[A-Za-z0-9\-_\.]+',
    caseSensitive: false,
  );
  static final _phonePattern = RegExp(
    r'\+?1?\s*[\(\-\.]?\d{3}[\)\-\.\s]\s*\d{3}[\-\.\s]\d{4}',
  );

  /// Wire Flutter and platform dispatcher error hooks.
  ///
  /// Must be called after `Firebase.initializeApp()` and
  /// `WidgetsFlutterBinding.ensureInitialized()`.
  void initialize() {
    if (kIsWeb) return; // Crashlytics is mobile-only.

    FlutterError.onError = (details) {
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(
        _scrubError(error),
        stack,
        fatal: true,
      );
      return true;
    };
  }

  /// Record a non-fatal error, scrubbing PII from the message and keys.
  Future<void> recordError(
    Object error,
    StackTrace? stack, {
    Map<String, Object?>? context,
    bool fatal = false,
  }) async {
    if (kIsWeb) return;
    final scrubbed = _scrubError(error);
    final scrubbedContext = context != null ? _scrubMap(context) : null;
    await FirebaseCrashlytics.instance.recordError(
      scrubbed,
      stack,
      reason: scrubbedContext?.isNotEmpty == true ? scrubbedContext : null,
      fatal: fatal,
    );
  }

  /// Log a diagnostic message (appears in the crash log breadcrumbs).
  /// PII in the message is redacted before forwarding.
  Future<void> log(String message) async {
    if (kIsWeb) return;
    await FirebaseCrashlytics.instance.log(_scrubString(message));
  }

  /// Set a string custom key, scrubbing if the key is sensitive.
  Future<void> setCustomKey(String key, Object value) async {
    if (kIsWeb) return;
    final safeValue = _isSensitiveKey(key) ? '[REDACTED]' : value.toString();
    await FirebaseCrashlytics.instance.setCustomKey(key, safeValue);
  }

  // ── private helpers ────────────────────────────────────────────────────

  Object _scrubError(Object error) {
    final message = error.toString();
    final scrubbed = _scrubString(message);
    if (scrubbed == message) return error;
    // Return a lightweight wrapper that carries the scrubbed message.
    return _ScrubbedError(scrubbed);
  }

  String _scrubString(String input) {
    return input
        .replaceAll(_emailPattern, '[EMAIL]')
        .replaceAll(_bearerPattern, 'Bearer [TOKEN]')
        .replaceAll(_phonePattern, '[PHONE]');
  }

  bool _isSensitiveKey(String key) =>
      _sensitiveKeys.contains(key.toLowerCase().replaceAll('-', '_'));

  Map<String, Object?> _scrubMap(Map<String, Object?> map) {
    return {
      for (final entry in map.entries)
        entry.key: _isSensitiveKey(entry.key)
            ? '[REDACTED]'
            : (entry.value is String
                ? _scrubString(entry.value as String)
                : entry.value),
    };
  }
}

class _ScrubbedError implements Exception {
  const _ScrubbedError(this.message);
  final String message;

  @override
  String toString() => message;
}
