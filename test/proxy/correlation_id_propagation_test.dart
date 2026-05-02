// HARD-G observability — X-Correlation-Id round-trip.
//
// Verifies that `routeRequest`:
//   1. Reads a well-formed inbound `X-Correlation-Id` (UUID v4) and
//      echoes it back on the response header.
//   2. Generates a fresh UUID v4 when the header is absent.
//   3. Generates a fresh UUID v4 when the header is malformed (not
//      UUID v4) and does NOT echo the malformed value.
//
// The test spins up a real localhost HttpServer wired to
// `routeRequest` and hits it through `HttpClient`. It uses the
// `/healthz` route because that is unauthenticated and round-trips
// without any of the optional bindings.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

class _NoopVerifier implements ProxyJwtVerifier {
  @override
  Future<ProxyJwtClaims> verify(String bearerToken) {
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

Future<HttpServer> _bindProxy() async {
  final guard = ProxyRequestGuard(verifier: _NoopVerifier());
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    try {
      await routeRequest(request, guard);
    } catch (_) {
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {
        /* ignore */
      }
    }
  });
  return server;
}

Future<HttpClientResponse> _getHealth(
  HttpClient client,
  HttpServer server, {
  String? correlationIdHeaderValue,
}) async {
  final uri =
      Uri.parse('http://${server.address.host}:${server.port}/healthz');
  final request = await client.getUrl(uri);
  request.persistentConnection = false;
  if (correlationIdHeaderValue != null) {
    request.headers.set(
      correlationIdHeaderName,
      correlationIdHeaderValue,
    );
  }
  return request.close();
}

void main() {
  test('inbound X-Correlation-Id (UUID v4) is echoed on response',
      () async {
    await _withRealHttp(() async {
      final server = await _bindProxy();
      final client = HttpClient();
      try {
        const inbound = '11111111-1111-4111-8111-111111111111';
        final response = await _getHealth(
          client,
          server,
          correlationIdHeaderValue: inbound,
        );
        await response.drain<void>();
        expect(response.statusCode, equals(200));
        expect(
          response.headers.value(correlationIdHeaderName),
          equals(inbound),
          reason: 'well-formed inbound id must round-trip unchanged',
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    });
  });

  test('absent X-Correlation-Id generates a fresh UUID v4', () async {
    await _withRealHttp(() async {
      final server = await _bindProxy();
      final client = HttpClient();
      try {
        final response = await _getHealth(client, server);
        await response.drain<void>();
        expect(response.statusCode, equals(200));
        final emitted = response.headers.value(correlationIdHeaderName);
        expect(emitted, isNotNull);
        expect(
          isValidUuidV4(emitted!),
          isTrue,
          reason: 'generated id must be UUID v4: $emitted',
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    });
  });

  test('malformed X-Correlation-Id is replaced with a generated UUID v4',
      () async {
    await _withRealHttp(() async {
      final server = await _bindProxy();
      final client = HttpClient();
      try {
        const malformed = 'not-a-uuid-at-all';
        final response = await _getHealth(
          client,
          server,
          correlationIdHeaderValue: malformed,
        );
        await response.drain<void>();
        expect(response.statusCode, equals(200));
        final emitted = response.headers.value(correlationIdHeaderName);
        expect(emitted, isNotNull);
        expect(
          emitted,
          isNot(equals(malformed)),
          reason: 'malformed value must be discarded, not echoed',
        );
        expect(isValidUuidV4(emitted!), isTrue);
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    });
  });
}
