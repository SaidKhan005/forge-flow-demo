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

/// G71 (cross-surface parity §0b) — admin parallel of the mobile/op-web
/// G61 "401 → force-refresh-ID-token → retry-once" recovery.
///
/// Before this slice, a clock-skewed device or a mid-rotation Firebase
/// ID token surfaced as a hard 401 on every admin gateway because the
/// admin HTTP path (unlike mobile `http_sync_proxy_client.dart` and the
/// op-web proxy client) never refreshed-and-retried. Destructive admin
/// actions hard-failed on a transient token problem the other surfaces
/// silently recover from.
///
/// This dispatcher is process-global for the SAME reason
/// [AdminHttpFreshnessRedirectDispatcher] is: there is exactly one
/// admin-shell auth source per process and every admin gateway funnels
/// through [sendAdminHttpRequest]. The admin shell registers the live
/// Firebase auth client's force-refresh on bootstrap; demo / share-
/// preview / tests leave it [unset] (the no-op) so the first 401 throws
/// exactly as it did before this slice (no behaviour change off the
/// 401-recovery path).
///
/// The contract `sendAdminHttpRequest` honours:
///   * 401 with NO hook wired           → return the 401 (pre-slice).
///   * 401 with hook → refresh succeeds → rebuild the IDENTICAL request
///     (same method/URL/body and every header, including the caller-
///     stable `Idempotency-Key`, verbatim) swapping ONLY the bearer to
///     the freshly minted token, send once, return whatever comes back
///     (success OR a second 401 — no further retry, no loop).
///   * 401 with hook → refresh throws / returns null → return the
///     original 401 (treat as a genuine auth failure, pre-slice path).
class AdminHttpTokenRefreshDispatcher {
  AdminHttpTokenRefreshDispatcher._();

  /// Process-wide force-refresh hook. Returns the freshly minted ID
  /// token on success, or `null` when the user is signed out / the
  /// refresh failed (caller then surfaces the original 401 unchanged).
  /// Production wires this to the live admin `FirebaseAuthClient`'s
  /// `refreshIdToken()` → `currentIdToken()`. When null (demo / share-
  /// preview / tests) the chokepoint does NOT retry.
  static Future<String?> Function()? refreshIdToken;

  /// Reset to the unset (no-retry) state. Call from `tearDown` so test
  /// pollution does not leak into the next test.
  static void resetForTesting() {
    refreshIdToken = null;
  }
}

Future<http.Response> sendAdminHttpRequest(
  http.Client client,
  http.BaseRequest request, {
  Duration timeout = kAdminHttpRequestTimeout,
}) async {
  // G71 — snapshot the request BEFORE the first send so a 401 can be
  // retried with a refreshed bearer. `http.BaseRequest` is single-use
  // (a sent request cannot be re-sent), so the retry needs a verbatim
  // rebuild: same method/URL/body and EVERY header preserved, including
  // the caller-stable `Idempotency-Key` (re-minting it would be the
  // G60/G70 idempotency bug class). Only the `authorization` header is
  // re-stamped, and only after a successful refresh.
  final _AdminRequestSnapshot? snapshot = _snapshotForRetry(request);

  http.Response response = await _sendOnce(
    client,
    request,
    timeout: timeout,
  );

  // G71 — single 401 → force-refresh → retry-once. No hook wired
  // (demo / share-preview / tests), an unsnapshottable request, or a
  // non-401 status all fall straight through to the pre-slice return.
  final refreshHook = AdminHttpTokenRefreshDispatcher.refreshIdToken;
  if (response.statusCode == 401 &&
      refreshHook != null &&
      snapshot != null) {
    String? freshToken;
    try {
      freshToken = await refreshHook();
    } catch (_) {
      // Refresh failed (signed out / network) — treat as a genuine
      // auth failure and surface the original 401 unchanged. No retry.
      freshToken = null;
    }
    if (freshToken != null && freshToken.isNotEmpty) {
      // Rebuild the IDENTICAL request, swapping ONLY the bearer.
      response = await _sendOnce(
        client,
        snapshot.rebuildWithBearer(freshToken),
        timeout: timeout,
      );
      // Whatever the retry returns — success OR a second 401 — is the
      // final answer. Exactly one retry; no loop.
    }
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

/// One send + timeout. Extracted so the G71 first-attempt and the
/// post-refresh retry share IDENTICAL transport semantics (the timeout
/// envelope and the [AdminHttpTimeoutException] mapping are byte-for-
/// byte the pre-slice behaviour).
Future<http.Response> _sendOnce(
  http.Client client,
  http.BaseRequest request, {
  required Duration timeout,
}) async {
  try {
    return await (() async {
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
}

/// Verbatim snapshot of a retry-able admin request. Only `http.Request`
/// (the single type every admin gateway funnels — buffered `bodyBytes`,
/// no streamed/multipart body) is snapshot-able; anything else returns
/// null from [_snapshotForRetry] so the chokepoint silently skips the
/// retry and behaves exactly as before this slice.
class _AdminRequestSnapshot {
  _AdminRequestSnapshot({
    required this.method,
    required this.url,
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required this.encoding,
    required this.followRedirects,
    required this.maxRedirects,
    required this.persistentConnection,
  })  : _headers = Map<String, String>.from(headers),
        _bodyBytes = List<int>.unmodifiable(bodyBytes);

  final String method;
  final Uri url;
  final Map<String, String> _headers;
  final List<int> _bodyBytes;
  final Encoding encoding;
  final bool followRedirects;
  final int maxRedirects;
  final bool persistentConnection;

  /// Rebuilds the IDENTICAL request — same method/URL/body, EVERY
  /// header preserved verbatim (the caller-stable `Idempotency-Key`
  /// included; it is NOT re-minted) — swapping ONLY the `authorization`
  /// bearer to the freshly refreshed token. The header lookup is
  /// case-insensitive so the original casing (gateways use lowercase
  /// `authorization`) is overwritten in place rather than duplicated.
  http.Request rebuildWithBearer(String freshToken) {
    final rebuilt = http.Request(method, url)
      ..encoding = encoding
      ..followRedirects = followRedirects
      ..maxRedirects = maxRedirects
      ..persistentConnection = persistentConnection
      ..bodyBytes = _bodyBytes;
    var swapped = false;
    _headers.forEach((key, value) {
      if (key.toLowerCase() == 'authorization') {
        rebuilt.headers[key] = 'Bearer $freshToken';
        swapped = true;
      } else {
        rebuilt.headers[key] = value;
      }
    });
    // Defensive: if the original carried no auth header at all (no
    // admin gateway does today, but the chokepoint is generic) still
    // attach the fresh bearer so the retry is authenticated.
    if (!swapped) {
      rebuilt.headers['authorization'] = 'Bearer $freshToken';
    }
    return rebuilt;
  }
}

_AdminRequestSnapshot? _snapshotForRetry(http.BaseRequest request) {
  if (request is! http.Request) {
    // Streamed / multipart bodies cannot be replayed verbatim; skip
    // the retry rather than risk re-sending a half-consumed body.
    return null;
  }
  return _AdminRequestSnapshot(
    method: request.method,
    url: request.url,
    headers: request.headers,
    bodyBytes: request.bodyBytes,
    encoding: request.encoding,
    followRedirects: request.followRedirects,
    maxRedirects: request.maxRedirects,
    persistentConnection: request.persistentConnection,
  );
}
