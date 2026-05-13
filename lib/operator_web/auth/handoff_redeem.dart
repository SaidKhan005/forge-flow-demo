// Lane B B11.1 — operator-web handoff redeem client.
//
// The mobile→web hand-off flow lands the browser at a URL of the
// shape `https://app.forgeflow.app/handoff?code=<opaque>`. The web
// app's router parses the `code` query parameter from THAT browser
// URL — that landing URL is the operator-web app's own contract, NOT
// a proxy contract. This client then immediately POSTs the code to
// `/v1/auth/handoff/redeem` in a JSON request BODY so the proxy can
// resolve it atomically.
//
// URL discipline (addendum A1 in
// `docs/_execution/lane_b_features/01_product_rule_and_ia.md`):
//
//   * The web app reads `code` from `window.location.search` (or the
//     equivalent in the Flutter Web router) and IMMEDIATELY posts it
//     to the proxy in a JSON body. The web client MUST NOT call the
//     proxy redeem endpoint with the code as a URL query parameter.
//   * The browser landing URL with `?code=…` lives outside the proxy
//     contract; this file's responsibility starts at "we hold a code
//     in memory and need to swap it for a session".
//   * Once the redeem call returns, the browser URL should be
//     immediately replaced (e.g. via the Flutter web router) so the
//     code does not linger in shareable URLs, browser history, or
//     analytics referrers. The caller is responsible for that scrub
//     — this client only handles the proxy round-trip.
//
// Authority:
//   * docs/_execution/lane_b_features/03_execution_slices.md
//     "B11.1 — handoff_codes table + endpoints"
//   * docs/_execution/lane_b_features/01_product_rule_and_ia.md
//     "Redemption-Code Handoff (B11)" + addendum A1
//   * tool/advisor_proxy/auth_handoff_routes.dart (the route the
//     proxy exposes; the response shape this client expects).

import 'dart:io';

import '../../services/auth/proxy_auth_operations_gateway.dart';

/// Result of a successful redeem. The web app reads [targetPath] and
/// navigates the user there post-redeem; the (user/operator/location)
/// triple is surfaced for parity with the mobile session the user
/// just bounced from.
class HandoffRedeemResult {
  const HandoffRedeemResult({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.targetPath,
  });

  final String userId;
  final String operatorId;
  final String locationId;

  /// The deep-link target the mobile client originally requested
  /// (e.g. `/operator-web/team`). Server-relative path; the web
  /// router navigates here once the new session is in place.
  final String targetPath;
}

/// Thrown by the gateway when the proxy refuses the redeem. Carries
/// the proxy's (statusCode, error code, message) so the web UI can
/// route to the right plain-English copy:
///
///   * `wrong_operator` (403): "This handoff code was created for a
///     different business…"
///   * `handoff_code_unusable` (410): "This handoff code has already
///     been used or has expired…"
///   * `invalid_code` / `missing_code` (400): malformed input
///   * `auth_handoff_unavailable` (503): proxy or DB outage
class HandoffRedeemRejected implements Exception {
  const HandoffRedeemRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() => 'HandoffRedeemRejected($statusCode $code): $message';
}

/// Web-side gateway. Wraps the proxy POST so the operator-web router
/// can call [redeemHandoffCode] without touching `dart:io` HTTP
/// plumbing.
class HandoffRedeemClient {
  HandoffRedeemClient({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyAuthOperationsHttpClient httpClient,
  })  : _proxyBaseUri = proxyBaseUri,
        _idTokenProvider = idTokenProvider,
        _httpClient = httpClient;

  /// Path the web build hits to redeem a handoff code. Mirror of
  /// `authHandoffRedeemPath` in `tool/advisor_proxy/auth_handoff_routes.dart`.
  static const String redeemPath = '/v1/auth/handoff/redeem';

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final ProxyAuthOperationsHttpClient _httpClient;

  /// Sends the [code] to the proxy in a JSON request BODY. Returns
  /// the resolved (user_id, operator_id, location_id, target_path)
  /// on success; throws [HandoffRedeemRejected] on every failure mode.
  ///
  /// The caller must hold a verified Bearer token; the proxy
  /// double-checks that the redeeming JWT's operator_id matches the
  /// operator the original mint was scoped to (returns 403 on
  /// mismatch).
  ///
  /// IMPORTANT: callers that read [code] from a browser URL must
  /// call this method synchronously and then immediately scrub the
  /// URL (e.g. via the Flutter web router's `pushReplacement`) so the
  /// raw code does not linger in browser history.
  Future<HandoffRedeemResult> redeemHandoffCode({
    required String code,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const HandoffRedeemRejected(
        code: 'no_id_token',
        message: 'You need to be signed in to complete the handoff.',
        statusCode: 401,
      );
    }
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve(redeemPath),
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
      },
      body: <String, Object?>{
        // Per addendum A1: code goes in the BODY, never as a URL
        // query parameter. The proxy reads `body['code']` and
        // ignores `request.uri.queryParameters`.
        'code': code,
      },
    );
    if (response.statusCode != 200) {
      throw HandoffRedeemRejected(
        code: _errorCode(response),
        message: _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
    final userId = response.body['user_id'];
    final operatorId = response.body['operator_id'];
    final locationId = response.body['location_id'];
    final targetPath = response.body['target_path'];
    if (userId is! String ||
        userId.isEmpty ||
        operatorId is! String ||
        operatorId.isEmpty ||
        locationId is! String ||
        locationId.isEmpty ||
        targetPath is! String ||
        targetPath.isEmpty) {
      throw const HandoffRedeemRejected(
        code: 'malformed_redeem_response',
        message:
            'The handoff service returned an unexpected response. '
            'Please sign in again.',
        statusCode: 502,
      );
    }
    return HandoffRedeemResult(
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      targetPath: targetPath,
    );
  }

  static String _errorCode(ProxyAuthOperationsResponse response) {
    final value = response.body['error'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return 'handoff_redeem_failed';
  }

  static String _errorMessage(ProxyAuthOperationsResponse response) {
    final value = response.body['message'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return 'Could not complete the handoff. Please sign in again.';
  }
}
