// Lane B B11.1 — mobile-side handoff code client.
//
// Mobile asks the proxy for a one-time short-TTL opaque code
// (POST /v1/auth/handoff/codes). The returned code is embedded in the
// browser landing URL the mobile app opens (e.g.
// `https://app.forgeflow.app/handoff?code=<opaque>`); the web client
// then immediately POSTs the code in a JSON BODY to
// `/v1/auth/handoff/redeem` to mint a fresh web session.
//
// URL discipline (addendum A1 in
// `docs/_execution/lane_b_features/01_product_rule_and_ia.md`):
//
//   * The proxy contract is "code in body only". This client receives
//     the code in the response body and surfaces it in
//     [HandoffCodeMintResult.code]. Callers that build the browser
//     landing URL from this code MUST treat the URL pattern as the
//     web-app's own client-app contract — the proxy never sees the
//     URL.
//   * The original Decision #5 token-in-URL pattern is SUPERSEDED by
//     this surface. No JWT or other long-lived credential ever travels
//     in the URL.
//
// Idempotency:
//   * Every mint carries a freshly generated CSPRNG `Idempotency-Key`
//     so a flaky-network double-submit returns the same code instead
//     of burning two slots in the per-user 10/hour rate limit.
//
// Authority:
//   * docs/_execution/lane_b_features/03_execution_slices.md
//     "B11.1 — handoff_codes table + endpoints"
//   * docs/_execution/lane_b_features/01_product_rule_and_ia.md
//     "Redemption-Code Handoff (B11)" + addendum A1
//   * tool/advisor_proxy/auth_handoff_routes.dart (the route the
//     proxy exposes; the response shape this client expects).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'proxy_auth_operations_gateway.dart';

/// Result of a successful mint. The web is expected to receive [code]
/// (via deep-link or QR scan) and immediately POST it to the proxy's
/// `/v1/auth/handoff/redeem` endpoint within [expiresIn].
class HandoffCodeMintResult {
  const HandoffCodeMintResult({
    required this.code,
    required this.expiresIn,
  });

  /// Opaque short-TTL code. Server-generated via
  /// `gen_random_bytes(16)` (pgcrypto); 22-char base64-url body. The
  /// raw code MUST NOT be logged, persisted, or shared beyond the
  /// browser landing URL the mobile app is about to open.
  final String code;

  /// Time-to-live the proxy promised. Currently 60 seconds; surface
  /// this so a future contract bump (e.g. 30s) does not require a
  /// mobile client release.
  final Duration expiresIn;
}

/// Thrown by the gateway when the proxy refuses the mint. Carries
/// the proxy's (statusCode, error code, message) so the calling UI
/// can route to the right plain-English copy.
class HandoffCodeMintRejected implements Exception {
  const HandoffCodeMintRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  /// Proxy error code (e.g. `rate_limit_exceeded`, `invalid_target_path`).
  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() =>
      'HandoffCodeMintRejected($statusCode $code): $message';
}

/// Mobile-side gateway. Wraps the proxy POST so screens can call
/// [mintHandoffCode] without touching `dart:io` HTTP plumbing.
class HandoffCodeClient {
  HandoffCodeClient({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyAuthOperationsHttpClient httpClient,
    String Function()? idempotencyKeyFactory,
  })  : _proxyBaseUri = proxyBaseUri,
        _idTokenProvider = idTokenProvider,
        _httpClient = httpClient,
        _idempotencyKeyFactory =
            idempotencyKeyFactory ?? _defaultIdempotencyKey;

  /// Path the mobile build hits to mint a handoff code. Mirror of
  /// `authHandoffCodesMintPath` in `tool/advisor_proxy/auth_handoff_routes.dart`.
  static const String mintPath = '/v1/auth/handoff/codes';

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final ProxyAuthOperationsHttpClient _httpClient;
  final String Function() _idempotencyKeyFactory;

  /// POSTs to the proxy mint endpoint. The opaque code is read from
  /// the response body — never from a URL — and returned for the
  /// caller to embed in the browser landing URL it is about to open.
  ///
  /// [targetPath] must be a server-relative path (begins with `/`)
  /// that the web client will navigate to after redeem. The proxy
  /// rejects absolute / protocol-relative URLs as a small open-
  /// redirect defense.
  Future<HandoffCodeMintResult> mintHandoffCode({
    required String targetPath,
    String? sourceDeviceFingerprint,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const HandoffCodeMintRejected(
        code: 'no_id_token',
        message: 'There is no live authenticated session.',
        statusCode: 401,
      );
    }
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve(mintPath),
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
        'Idempotency-Key': _idempotencyKeyFactory(),
      },
      body: <String, Object?>{
        'target_path': targetPath,
        if (sourceDeviceFingerprint != null)
          'source_device_fingerprint': sourceDeviceFingerprint,
      },
    );
    if (response.statusCode != 200) {
      throw HandoffCodeMintRejected(
        code: _errorCode(response),
        message: _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
    final code = response.body['code'];
    final ttlRaw = response.body['expires_in_seconds'];
    if (code is! String || code.isEmpty) {
      throw const HandoffCodeMintRejected(
        code: 'malformed_mint_response',
        message: 'Handoff code service returned an unexpected response.',
        statusCode: 502,
      );
    }
    final ttl = ttlRaw is int && ttlRaw > 0
        ? Duration(seconds: ttlRaw)
        : const Duration(seconds: 60);
    return HandoffCodeMintResult(code: code, expiresIn: ttl);
  }

  static String _errorCode(ProxyAuthOperationsResponse response) {
    final value = response.body['error'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return 'handoff_code_mint_failed';
  }

  static String _errorMessage(ProxyAuthOperationsResponse response) {
    final value = response.body['message'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return 'Could not start the handoff. Please try again in a moment.';
  }

  /// 16 bytes of CSPRNG entropy → hex (32 chars). Mirrors the shape
  /// `proxy_password_change_gateway.dart` uses for its idempotency
  /// key so the proxy's per-route caches see consistent shapes
  /// across auth surfaces.
  static String _defaultIdempotencyKey() {
    final random = math.Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
