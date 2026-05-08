import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/mfa_freshness_redirect_listener.dart';

const Duration kAdminHttpRequestTimeout = Duration(seconds: 30);
const Duration kAdminHealthHttpRequestTimeout = Duration(seconds: 60);

class AdminHttpTimeoutException implements Exception {
  const AdminHttpTimeoutException({
    required this.method,
    required this.uri,
    required this.timeout,
  });

  final String method;
  final Uri uri;
  final Duration timeout;

  @override
  String toString() =>
      'AdminHttpTimeoutException($method $uri after ${timeout.inSeconds}s)';
}

/// CODE_OPS_DEBT carry-over #1 — process-wide listener for the admin
/// HTTP layer's `mfa_freshness_required` 403 detection.
///
/// All admin gateways funnel their HTTP through [sendAdminHttpRequest];
/// that helper inspects every response body for the proxy's freshness
/// redirect contract (parsed via [MfaFreshnessRedirectPayload.tryParse])
/// and dispatches to [AdminHttpFreshnessRedirectDispatcher.listener]
/// before returning. The admin shell registers its
/// [AdminAuthSource] on bootstrap so the sign-out + state-emit
/// handshake runs as a side-effect of the gateway call.
///
/// This is process-global (rather than threaded through every
/// gateway constructor) because the listener is an app-shell-wide
/// concern — there is one admin-shell auth source per process, and
/// every gateway routes through `sendAdminHttpRequest`. Tests can
/// install a recording listener in `setUp` and reset to
/// [NoopMfaFreshnessRedirectListener] in `tearDown`.
class AdminHttpFreshnessRedirectDispatcher {
  AdminHttpFreshnessRedirectDispatcher._();

  static MfaFreshnessRedirectListener listener =
      const NoopMfaFreshnessRedirectListener();

  /// Reset to the default no-op listener. Call from `tearDown` so
  /// test pollution does not leak into the next test.
  static void resetForTesting() {
    listener = const NoopMfaFreshnessRedirectListener();
  }
}

Future<http.Response> sendAdminHttpRequest(
  http.Client client,
  http.BaseRequest request, {
  Duration timeout = kAdminHttpRequestTimeout,
}) async {
  final http.Response response;
  try {
    response = await (() async {
      final streamed = await client.send(request);
      return http.Response.fromStream(streamed);
    })().timeout(timeout);
  } on TimeoutException {
    throw AdminHttpTimeoutException(
      method: request.method,
      uri: request.url,
      timeout: timeout,
    );
  }
  // CODE_OPS_DEBT carry-over #1 — intercept the proxy
  // `mfa_freshness_required` 403 here so every admin gateway gets
  // the redirect-to-login behaviour without each gateway repeating
  // the parse. The dispatched call drives sign-out + the
  // post-sign-out info banner; the gateway's own status-code branch
  // still fires below so existing error UI stays intact.
  if (response.statusCode == 403) {
    final body = response.body;
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final payload = MfaFreshnessRedirectPayload.tryParse(
            statusCode: response.statusCode,
            body: decoded.cast<String, Object?>(),
          );
          if (payload != null) {
            AdminHttpFreshnessRedirectDispatcher.listener
                .onMfaFreshnessRedirect(payload);
          }
        }
      } on FormatException {
        // Malformed JSON body — fall through to the gateway's own
        // 403 path. The redirect contract requires a JSON body, so
        // a parse error here is itself a signal that this is not
        // the freshness 403.
      }
    }
  }
  return response;
}
