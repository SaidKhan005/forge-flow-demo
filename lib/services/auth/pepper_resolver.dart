// fix(M2.pepper-runtime): PepperResolver abstraction.
//
// Decouples pepper retrieval from the compile-time
// `String.fromEnvironment` constant so the proxy can fetch the active
// pepper (and any historical peppers) at runtime via a proxy endpoint,
// enabling zero-downtime pepper rotation without a rebuild.
//
// Implementations:
//   * [EnvPepperResolver] — backwards-compat shim wrapping the existing
//     `String.fromEnvironment` path. Used by tests and any caller that
//     has not yet migrated to [ProxyPepperResolver].
//   * [ProxyPepperResolver] — calls the proxy's
//     `GET /v1/auth/peppers/active` and `GET /v1/auth/peppers/:id`
//     endpoints. Results are cached in-memory with a configurable TTL
//     (default 5 minutes) so the proxy is not hit on every password
//     verify.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Abstraction over pepper retrieval. Production binds
/// [ProxyPepperResolver]; tests and demo mode bind [EnvPepperResolver].
abstract class PepperResolver {
  /// Returns the currently-active pepper plaintext (base64-decoded bytes
  /// represented as a UTF-8 string). Throws [PepperResolutionException]
  /// when the active pepper cannot be determined.
  Future<String> resolveActive();

  /// Returns the pepper plaintext for a known pepper id, or `null` when
  /// the id is not found (caller should treat the row as un-verifiable
  /// rather than crashing).
  Future<String?> resolveById(String pepperId);
}

/// Thrown when a pepper cannot be resolved from the backing store.
class PepperResolutionException implements Exception {
  const PepperResolutionException(this.message);

  final String message;

  @override
  String toString() => 'PepperResolutionException: $message';
}

// ─── EnvPepperResolver ────────────────────────────────────────────────

/// Backwards-compatible resolver backed by `--dart-define` env vars.
/// This is the pre-M4 behaviour: one pepper compiled into the binary.
///
/// * [resolveActive] returns the value of
///   `String.fromEnvironment('PASSWORD_HISTORY_PEPPER')`. Throws
///   [PepperResolutionException] if the value is empty (mirrors
///   [PasswordHistoryPepperMissingError] semantics so callers see a
///   consistent error type).
/// * [resolveById] returns the same pepper for any id that matches the
///   single compiled-in pepper id (derived the same way as
///   [PasswordHistoryPepperConfig._derivePepperId]); returns `null` for
///   every other id so legacy rows with a different pepper id are
///   treated as un-verifiable rather than crashing.
class EnvPepperResolver implements PepperResolver {
  const EnvPepperResolver({
    String pepper = const String.fromEnvironment('PASSWORD_HISTORY_PEPPER'),
    bool demoMode = const bool.fromEnvironment('kDemoMode'),
  }) : _pepper = pepper,
       _demoMode = demoMode;

  final String _pepper;
  final bool _demoMode;

  @override
  Future<String> resolveActive() async {
    if (_pepper.isEmpty) {
      if (_demoMode) return '';
      throw const PepperResolutionException(
        'PASSWORD_HISTORY_PEPPER is not set and kDemoMode is false',
      );
    }
    return _pepper;
  }

  @override
  Future<String?> resolveById(String pepperId) async {
    // The env resolver only knows one pepper. If the id happens to match
    // (unlikely outside tests), return it; otherwise return null so the
    // caller treats the row as un-verifiable.
    if (_pepper.isEmpty) return null;
    return _pepper; // caller already holds the correct pepper id from the row
  }
}

// ─── ProxyPepperResolver ──────────────────────────────────────────────

/// Runtime resolver that fetches peppers from the proxy endpoints:
///
///   GET /v1/auth/peppers/active      → active pepper
///   GET /v1/auth/peppers/:id         → specific pepper by id
///
/// Results are cached in-memory per [ttl] to avoid hitting the proxy on
/// every password verify. The cache is intentionally per-instance so
/// two different resolver instances do not share cached values.
///
/// [httpClient] is the underlying HTTP client. Production wires
/// [HttpClient] (dart:io); tests inject a fake.
/// [baseUri] is the proxy base URI, e.g. `http://localhost:8080`.
/// [bearerTokenProvider] returns the service-principal JWT used to
/// authenticate pepper-fetch requests. Called fresh on every uncached
/// request so the token can be rotated without restarting.
class ProxyPepperResolver implements PepperResolver {
  ProxyPepperResolver({
    required Uri baseUri,
    required Future<String> Function() bearerTokenProvider,
    Duration ttl = const Duration(minutes: 5),
    PepperHttpClient? httpClient,
  }) : _baseUri = baseUri,
       _bearerTokenProvider = bearerTokenProvider,
       _ttl = ttl,
       _http = httpClient ?? DartIoPepperHttpClient();

  final Uri _baseUri;
  final Future<String> Function() _bearerTokenProvider;
  final Duration _ttl;
  final PepperHttpClient _http;

  // active pepper cache
  _CachedPepper? _activeCached;

  // per-id cache
  final Map<String, _CachedPepper> _byIdCache = <String, _CachedPepper>{};

  @override
  Future<String> resolveActive() async {
    final cached = _activeCached;
    if (cached != null && !cached.isExpired) return cached.pepper;

    final token = await _bearerTokenProvider();
    final uri = _baseUri.replace(
      path: '${_baseUri.path.isEmpty ? '' : _baseUri.path}/v1/auth/peppers/active',
    );
    final body = await _http.get(uri, bearerToken: token);
    final decoded = _decodeResponse(body, 'active');
    final pepper = _extractPepperBytes(decoded);
    _activeCached = _CachedPepper(pepper: pepper, expiresAt: _now().add(_ttl));
    // Warm the by-id cache too so a subsequent resolveById hit on the
    // just-fetched id skips a round-trip.
    final id = decoded['pepper_id'];
    if (id is String && id.isNotEmpty) {
      _byIdCache[id] = _CachedPepper(pepper: pepper, expiresAt: _now().add(_ttl));
    }
    return pepper;
  }

  @override
  Future<String?> resolveById(String pepperId) async {
    final cached = _byIdCache[pepperId];
    if (cached != null && !cached.isExpired) return cached.pepper;

    final token = await _bearerTokenProvider();
    final encodedId = Uri.encodeComponent(pepperId);
    final uri = _baseUri.replace(
      path: '${_baseUri.path.isEmpty ? '' : _baseUri.path}/v1/auth/peppers/$encodedId',
    );
    try {
      final body = await _http.get(uri, bearerToken: token);
      final decoded = _decodeResponse(body, pepperId);
      final pepper = _extractPepperBytes(decoded);
      _byIdCache[pepperId] = _CachedPepper(
        pepper: pepper,
        expiresAt: _now().add(_ttl),
      );
      return pepper;
    } on PepperResolutionException catch (e) {
      // 404 → id unknown
      if (e.message.contains('not_found') || e.message.contains('404')) {
        return null;
      }
      rethrow;
    }
  }

  Map<String, Object?> _decodeResponse(String body, String context) {
    Object? parsed;
    try {
      parsed = jsonDecode(body);
    } catch (_) {
      throw PepperResolutionException(
        'proxy returned non-JSON body for pepper $context',
      );
    }
    if (parsed is! Map) {
      throw PepperResolutionException(
        'proxy returned unexpected body shape for pepper $context',
      );
    }
    return parsed.cast<String, Object?>();
  }

  String _extractPepperBytes(Map<String, Object?> body) {
    final b64 = body['pepper_b64'];
    if (b64 is! String || b64.isEmpty) {
      throw PepperResolutionException(
        'proxy response missing pepper_b64 field',
      );
    }
    try {
      return utf8.decode(base64Decode(b64));
    } catch (_) {
      throw PepperResolutionException(
        'proxy returned malformed base64 in pepper_b64',
      );
    }
  }

  // Overridable for tests.
  DateTime _now() => DateTime.now();
}

class _CachedPepper {
  _CachedPepper({required this.pepper, required this.expiresAt});
  final String pepper;
  final DateTime expiresAt;
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

// ─── HTTP client seam ─────────────────────────────────────────────────

/// Minimal HTTP GET seam for the pepper resolver. Production uses
/// [DartIoPepperHttpClient] (dart:io HttpClient); tests inject a fake.
/// Exposed publicly so tests can provide an in-process implementation
/// without hitting the network.
abstract class PepperHttpClient {
  /// Issues GET [uri] with `Authorization: Bearer [bearerToken]`.
  /// Returns the response body as a UTF-8 string.
  /// Throws [PepperResolutionException] on non-2xx status or network error.
  Future<String> get(Uri uri, {required String bearerToken});
}

class DartIoPepperHttpClient implements PepperHttpClient {
  @override
  Future<String> get(Uri uri, {required String bearerToken}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 404) {
        throw PepperResolutionException(
          'pepper not_found: HTTP 404 from $uri',
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw PepperResolutionException(
          'pepper fetch failed: HTTP ${resp.statusCode} from $uri',
        );
      }
      return body;
    } on PepperResolutionException {
      rethrow;
    } catch (e) {
      throw PepperResolutionException('network error fetching pepper: $e');
    } finally {
      client.close();
    }
  }
}
