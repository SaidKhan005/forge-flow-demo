// Shared outgoing-HTTP `http.Client` fake for vendor adapter / production
// API client tests.
//
// Bucket 4e of the 2026-05-20 test-suite tightening audit consolidated
// two near-duplicate `_FakeHttpClient` implementations (~100 LOC across
// two vendor production-client tests) into this single helper. A third
// caller — `test/services/auth/pepper_resolver_test.dart` — implements a
// different SUT-specific seam (`PepperHttpClient`, not `http.Client`) and
// is intentionally NOT migrated here; see the note at the bottom of this
// file.
//
// ─── How this differs from `http_stubs.dart` ─────────────────────────
//
// `http_stubs.dart` (Bucket 4a) stubs INCOMING route handling — it stands
// in for `dart:io` `HttpRequest` / `HttpResponse` so advisor_proxy route
// tests can drive route handlers without binding a real socket.
//
// THIS file stubs OUTGOING client calls — it stands in for a
// `package:http` `http.Client` so vendor-facing production API clients
// can be driven through their full request/response/retry/backoff paths
// without hitting a live vendor endpoint. The seam is different
// (`http.BaseClient.send` vs `HttpRequest`/`HttpResponse`), and so is the
// shape the call site needs (assert on what we SENT vs reply to what we
// RECEIVE). Don't try to share one class across both surfaces — the
// underlying `dart:io` vs `package:http` API split makes that a leaky
// abstraction.
//
// ─── Two ergonomic modes, one class ──────────────────────────────────
//
// The two migrated callers reach for two different shapes:
//
//   * Handler mode — `FakeHttpClient.handler((request) async { ... })`.
//     The handler inspects each outgoing request inline and returns a
//     synthesized response. Use when assertions about the request need to
//     happen in the same closure as the response choice (e.g. "if the
//     request has a `cursor=` query param, return page 2; otherwise
//     return page 1 with a `next_cursor`"). Humanity labor adapter tests
//     use this shape.
//
//   * Queue mode — `FakeHttpClient.queue([FakeHttpResponse(...), ...])`.
//     The fake serves canned responses in order. Inspect the captured
//     requests via `fake.requests` AFTER the call. Use when the test is
//     scripting a multi-step exchange (auth → list → revoke; or 429
//     followed by 200) and wants response-side and request-side
//     assertions cleanly separated. Lightspeed LSK production API client
//     tests use this shape.
//
//   * Timeout mode — `FakeHttpClient.alwaysTimesOut()`. `send` returns a
//     never-completing future so the caller's `.timeout(...)` raises a
//     `TimeoutException`. Still captures the request that triggered the
//     hang. Lightspeed timeout test uses this.
//
// All three modes populate the same `requests` list, so request-shape
// assertions look the same regardless of which mode the test chose.
//
// ─── Why this isn't the pepper resolver's fake too ───────────────────
//
// `pepper_resolver.dart` defines its own narrow seam,
// `abstract class PepperHttpClient { Future<String> get(Uri, { required
// String bearerToken }); }`, and the production implementation
// (`DartIoPepperHttpClient`) wraps `dart:io` `HttpClient` directly rather
// than going through `package:http`. The test's `_FakeHttpClient`
// implements that custom seam, not `http.Client`, and tracks per-endpoint
// hit counts (`activeGetCount`, `byIdGetCount`) — both of which a
// `http.Client`-shaped fake would have to reconstruct via URL pattern
// matching, which would make the test noisier rather than cleaner. Left
// in place as a deliberate divergence.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A canned response for [FakeHttpClient.queue]. Holds the status code,
/// body bytes, and any response headers the caller wants the SUT to see.
class FakeHttpResponse {
  FakeHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
    this.reasonPhrase,
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final String? reasonPhrase;
}

/// One outgoing request captured by [FakeHttpClient]. Tests assert on the
/// shape of what their SUT sent: method, URL, headers, body string.
class CapturedRequest {
  CapturedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// Request body as a UTF-8 string. Empty when the underlying request
  /// is not an `http.Request` (e.g. streamed multipart, which none of
  /// the migrated callers use).
  final String body;
}

/// In-memory fake for `package:http` `http.Client`. See the file-level
/// doc comment for the three modes (handler / queue / timeout) and the
/// rationale for the API shape.
class FakeHttpClient extends http.BaseClient {
  /// Handler mode: each outgoing request is passed to [handler], which
  /// returns the response to serve. The handler may inspect the request
  /// (method, URL, headers, body) before deciding what to return.
  FakeHttpClient.handler(
    Future<http.Response> Function(http.Request request) handler,
  )   : _handler = handler,
        _queue = null,
        _alwaysTimeout = false;

  /// Queue mode: serve [responses] in order. The Nth `send` returns the
  /// Nth element. Throws `StateError` if the SUT issues more requests
  /// than responses queued. Inspect the captured requests via
  /// [FakeHttpClient.requests] after the SUT call returns.
  FakeHttpClient.queue(List<FakeHttpResponse> responses)
      : _handler = null,
        _queue = List<FakeHttpResponse>.of(responses),
        _alwaysTimeout = false;

  /// Timeout mode: `send` returns a future that never completes, so the
  /// SUT's outer `.timeout(...)` fires a `TimeoutException`. Still
  /// captures the request that triggered the hang, so timeout tests can
  /// still assert on what was attempted.
  FakeHttpClient.alwaysTimesOut()
      : _handler = null,
        _queue = <FakeHttpResponse>[],
        _alwaysTimeout = true;

  final Future<http.Response> Function(http.Request request)? _handler;
  final List<FakeHttpResponse>? _queue;
  final bool _alwaysTimeout;

  /// Every outgoing request the SUT issued, in order. Populated for all
  /// three modes including timeout mode.
  final List<CapturedRequest> requests = <CapturedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    requests.add(CapturedRequest(
      method: request.method,
      url: request.url,
      headers: Map<String, String>.from(request.headers),
      body: body,
    ));

    if (_alwaysTimeout) {
      // Never completes — caller's `.timeout(...)` raises a
      // `TimeoutException`.
      return Completer<http.StreamedResponse>().future;
    }

    final handler = _handler;
    if (handler != null) {
      if (request is! http.Request) {
        throw StateError(
          'FakeHttpClient.handler only supports http.Request; got '
          '${request.runtimeType}',
        );
      }
      final response = await handler(request);
      return http.StreamedResponse(
        Stream<List<int>>.value(response.bodyBytes),
        response.statusCode,
        headers: response.headers,
        contentLength: response.bodyBytes.length,
        request: request,
        reasonPhrase: response.reasonPhrase,
      );
    }

    final queue = _queue!;
    if (queue.isEmpty) {
      throw StateError('FakeHttpClient.queue: no canned response remaining');
    }
    final canned = queue.removeAt(0);
    final stream = Stream<List<int>>.fromIterable(<List<int>>[
      utf8.encode(canned.body),
    ]);
    return http.StreamedResponse(
      stream,
      canned.statusCode,
      headers: canned.headers,
      reasonPhrase: canned.reasonPhrase,
      request: request,
    );
  }
}
