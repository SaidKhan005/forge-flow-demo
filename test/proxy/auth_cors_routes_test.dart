// Operator-web auth CORS coverage.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _operatorWebOrigin = 'https://forge-flow-operator-web.test';

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
    await routeRequest(
      request,
      guard,
      adminCorsAllowList: const <String>[_operatorWebOrigin],
      now: () => DateTime.utc(2026, 5, 5, 12),
    );
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri);
}

void main() {
  test('auth preflight admits operator web origin', () async {
    await _withRealHttp(() async {
      final ctx = await _spinUp();
      try {
        final request = await ctx.client.openUrl(
          'OPTIONS',
          ctx.baseUri.resolve(authSessionLoginPath),
        );
        request.headers.set('Origin', _operatorWebOrigin);
        request.headers.set('Access-Control-Request-Method', 'POST');
        request.headers.set(
          'Access-Control-Request-Headers',
          'authorization,content-type,idempotency-key',
        );
        request.contentLength = 0;
        final response = await request.close();
        expect(response.statusCode, equals(HttpStatus.noContent));
        expect(
          response.headers.value('access-control-allow-origin'),
          equals(_operatorWebOrigin),
        );
        expect(
          response.headers.value('access-control-allow-methods') ?? '',
          contains('POST'),
        );
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('auth rejection still echoes allowed operator web origin', () async {
    await _withRealHttp(() async {
      final ctx = await _spinUp();
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve(authAccountInfoPath),
        );
        request.headers.set('Origin', _operatorWebOrigin);
        request.contentLength = 0;
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, equals(HttpStatus.serviceUnavailable));
        expect(
          response.headers.value('access-control-allow-origin'),
          equals(_operatorWebOrigin),
        );
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });
}
