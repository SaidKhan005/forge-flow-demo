// HARD-C — request body size cap tests.
//
// Contract: every POST/PATCH/PUT must declare a Content-Length and
// stay under 1_000_000 bytes. Oversized or unannounced mutations
// short-circuit with 413 + body
// `{"error":"request_too_large","limit_bytes":1000000}` BEFORE any
// gateway runs. CORS headers were already applied for admin paths,
// so the browser still sees the echo on the 413 response.
//
// GET / OPTIONS are unaffected.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _adminOrigin = 'https://admin.forgeandflow.app';

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

Future<({HttpServer server, HttpClient client, Uri baseUri})> _spinUp() async {
  final guard = ProxyRequestGuard(
    verifier: const ScaffoldRejectingJwtVerifier(),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    try {
      await routeRequest(
        request,
        guard,
        adminCorsAllowList: const <String>[_adminOrigin],
        now: () => DateTime.utc(2026, 5, 2, 12),
      );
    } catch (_) {
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri);
}

Future<({int statusCode, HttpHeaders headers, String body})> _send({
  required HttpClient client,
  required Uri uri,
  required String method,
  int? contentLength,
  List<int>? body,
  Map<String, String>? headers,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  if (headers != null) {
    headers.forEach(request.headers.set);
  }
  if (contentLength != null) {
    request.contentLength = contentLength;
  }
  if (body != null) {
    request.add(body);
  }
  final response = await request.close();
  final bodyText = await response.transform(utf8.decoder).join();
  return (
    statusCode: response.statusCode,
    headers: response.headers,
    body: bodyText,
  );
}

void main() {
  group('routeRequest body cap — 413 on oversized POST', () {
    test('Content-Length above 1 MB → 413 with limit_bytes', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          // Dart's HttpClient validates that the bytes written match
          // the declared contentLength on close, so send a payload
          // exactly matching 1_000_001 bytes. The proxy still
          // short-circuits in the pre-handler before reading the
          // stream — the client-side validation is just to keep
          // Dart happy.
          final oversized = Uint8List(kAdminCorsRequestBodyLimitBytes + 1);
          final res = await _send(
            client: ctx.client,
            uri: ctx.baseUri.resolve(adminOperatorsPath),
            method: 'POST',
            contentLength: oversized.length,
            body: oversized,
            headers: <String, String>{
              'Origin': _adminOrigin,
              HttpHeaders.contentTypeHeader: 'application/json',
            },
          );

          expect(res.statusCode, equals(413));
          final decoded = jsonDecode(res.body) as Map<String, Object?>;
          expect(decoded['error'], equals('request_too_large'));
          expect(
            decoded['limit_bytes'],
            equals(kAdminCorsRequestBodyLimitBytes),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('413 path still echoes Allow-Origin for admin routes', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final oversized = Uint8List(kAdminCorsRequestBodyLimitBytes + 1);
          final res = await _send(
            client: ctx.client,
            uri: ctx.baseUri.resolve(adminOperatorsPath),
            method: 'POST',
            contentLength: oversized.length,
            body: oversized,
            headers: <String, String>{
              'Origin': _adminOrigin,
              HttpHeaders.contentTypeHeader: 'application/json',
            },
          );

          expect(res.statusCode, equals(413));
          // Admin routes pre-applied CORS before the body cap fired,
          // so the browser receives the echo on the 413.
          expect(
            res.headers.value('access-control-allow-origin'),
            equals(_adminOrigin),
          );
          expect(res.headers.value('vary'), equals('Origin'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('routeRequest body cap — missing Content-Length on POST', () {
    test('chunked POST with no Content-Length → 413', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          // Setting contentLength to -1 forces Dart's HttpClient to
          // use chunked transfer-encoding and omit the
          // Content-Length header. The proxy must reject these
          // because we cannot bound an unannounced body.
          final request = await ctx.client.postUrl(
            ctx.baseUri.resolve(adminOperatorsPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', _adminOrigin);
          request.headers.contentType = ContentType.json;
          request.contentLength = -1;
          request.add(utf8.encode('{}'));
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();

          expect(response.statusCode, equals(413));
          final decoded = jsonDecode(body) as Map<String, Object?>;
          expect(decoded['error'], equals('request_too_large'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('chunked PATCH and PUT also rejected', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          for (final method in const <String>['PATCH', 'PUT']) {
            final request = await ctx.client.openUrl(
              method,
              ctx.baseUri.resolve(adminOperatorsPath),
            );
            request.persistentConnection = false;
            request.headers.set('Origin', _adminOrigin);
            request.headers.contentType = ContentType.json;
            request.contentLength = -1;
            request.add(utf8.encode('{}'));
            final response = await request.close();
            final body = await response.transform(utf8.decoder).join();

            expect(
              response.statusCode,
              equals(413),
              reason: '$method should be rejected without Content-Length',
            );
            final decoded = jsonDecode(body) as Map<String, Object?>;
            expect(decoded['error'], equals('request_too_large'));
          }
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('routeRequest body cap — under-cap and non-body methods', () {
    test('POST under cap reaches the handler (not a 413)', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          // 32 KB body — well under the 1 MB cap. Without auth the
          // route returns 401, NOT 413. We just need to assert "did
          // not 413"; the handler internals are not the body-cap
          // test's concern.
          final encoded = utf8.encode('{"sample":"${'a' * 32000}"}');
          final res = await _send(
            client: ctx.client,
            uri: ctx.baseUri.resolve(adminOperatorsPath),
            method: 'POST',
            contentLength: encoded.length,
            body: encoded,
            headers: <String, String>{
              'Origin': _adminOrigin,
              HttpHeaders.contentTypeHeader: 'application/json',
            },
          );

          expect(res.statusCode, isNot(equals(413)));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('GET requests skip the body cap entirely', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final request = await ctx.client.getUrl(
            ctx.baseUri.resolve(adminOperatorsPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', _adminOrigin);
          // No Content-Length set on GET — must not trigger the cap.
          final response = await request.close();
          await response.drain<void>();

          expect(response.statusCode, isNot(equals(413)));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('OPTIONS preflight is unaffected by the body cap', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminOperatorsPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', _adminOrigin);
          request.headers.set('Access-Control-Request-Method', 'POST');
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();

          expect(response.statusCode, equals(HttpStatus.noContent));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('exactly-at-cap POST is allowed (1_000_000 bytes)', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          // Send exactly 1_000_000 bytes — the inclusive limit. The
          // proxy must NOT 413; downstream handlers run (and may
          // 401 for missing auth). We only assert "did not 413".
          final atCap = Uint8List(kAdminCorsRequestBodyLimitBytes);
          final res = await _send(
            client: ctx.client,
            uri: ctx.baseUri.resolve(adminOperatorsPath),
            method: 'POST',
            contentLength: atCap.length,
            body: atCap,
            headers: <String, String>{
              'Origin': _adminOrigin,
              HttpHeaders.contentTypeHeader: 'application/json',
            },
          );

          expect(res.statusCode, isNot(equals(413)));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}
