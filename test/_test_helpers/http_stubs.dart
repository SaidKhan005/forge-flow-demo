// Shared `dart:io` HTTP stubs for advisor_proxy route tests.
//
// Bucket 4a of the 2026-05-20 test-suite tightening audit consolidated
// five copies of these stubs (~500 LOC duplicated across
// `test/tool/advisor_proxy/`) into this single helper. The canonical
// shape is the one previously in
// `admin_integrations_response_sanitization_test.dart`, which is the
// only copy that implemented `HttpHeaders.forEach` against the real
// `dart:io` typedef — `void Function(String name, List<String> values)`.
//
// Why that detail matters: when a stub routes `forEach` through
// `noSuchMethod`, Dart accepts the missing override at analyze time
// but the SDK's structured-log breadcrumb path (which iterates
// request headers) throws `NoSuchMethodError` at run time once the
// closure-signature check fires. That mismatch quarantined
// `admin_integrations_response_sanitization_test.dart` for weeks
// (see PR #1089). New shared shape preserves the real typedef.
//
// All members are public and constructable so the five callers can
// import this file and drop their local `_StubHttp*` copies entirely.
//
// Anything not used by the current five callers falls through to
// `noSuchMethod`; if a future caller needs more surface, add it here
// rather than re-introducing per-file duplicates.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// In-memory `HttpRequest` stand-in.
///
/// Supports both:
///   * Stream-bodied callers (idempotency / sanitization / oauth /
///     worker-heartbeats) — `listen` replays the encoded `bodyJson` (or
///     an empty `Uint8List` when omitted) exactly once.
///   * Header-only callers (phase_8 production binder) — pass only
///     `headers`; `response` is still constructed but unused.
class StubHttpRequest extends Stream<Uint8List> implements HttpRequest {
  StubHttpRequest({
    this.method = 'GET',
    Uri? uri,
    Map<String, Object?>? bodyJson,
    Map<String, String> headers = const <String, String>{},
  })  : _uri = uri ?? Uri.parse('https://localhost/'),
        _headers = StubHttpHeaders(headers),
        _body = bodyJson == null
            ? Uint8List(0)
            : Uint8List.fromList(utf8.encode(jsonEncode(bodyJson))),
        response = StubHttpResponse();

  final Uri _uri;
  final StubHttpHeaders _headers;
  final Uint8List _body;

  @override
  final String method;

  @override
  final StubHttpResponse response;

  @override
  HttpHeaders get headers => _headers;

  @override
  Uri get uri => _uri;

  @override
  Uri get requestedUri => _uri;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<Uint8List>.value(_body).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory `HttpHeaders` stand-in.
///
/// `forEach` is implemented against the real `dart:io` typedef so
/// the dispatch wrapper's structured-log breadcrumb path
/// (`request.headers.forEach((name, values) { ... })`) survives. Any
/// other member (`add`, `removeAll`, etc.) falls through to
/// `noSuchMethod`.
class StubHttpHeaders implements HttpHeaders {
  StubHttpHeaders([Map<String, String>? values])
      : _values = <String, String>{...?values};

  final Map<String, String> _values;

  /// Test-side mutator. Lets callers set a header without reaching
  /// into the private map.
  void setRaw(String name, String value) {
    _values[name] = value;
  }

  @override
  String? value(String name) {
    final lower = name.toLowerCase();
    for (final entry in _values.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// Mirrors `dart:io` `HttpHeaders.forEach((String, List<String>) => void)`.
  /// MUST match the real typedef exactly (regression-fixed in PR #1089).
  @override
  void forEach(void Function(String name, List<String> values) action) {
    for (final entry in _values.entries) {
      action(entry.key.toLowerCase(), <String>[entry.value]);
    }
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory `HttpResponse` stand-in. Captures the response body
/// (via `write`) and headers (via the attached `StubResponseHeaders`)
/// so tests can assert on the wire shape without binding a real socket.
class StubHttpResponse implements HttpResponse {
  @override
  int statusCode = 200;

  final StringBuffer _body = StringBuffer();
  final StubResponseHeaders _headers = StubResponseHeaders();

  /// Convenience accessor for tests. The accumulated text written via
  /// `write` calls.
  String get bodyText => _body.toString();

  @override
  void write(Object? object) {
    _body.write(object);
  }

  @override
  Future<void> close() async {}

  @override
  HttpHeaders get headers => _headers;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory `HttpHeaders` stand-in for the response side. Tracks the
/// content type and any name/value pairs the handler sets.
class StubResponseHeaders implements HttpHeaders {
  final Map<String, String> _values = <String, String>{};
  ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) {
    _contentType = value;
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
