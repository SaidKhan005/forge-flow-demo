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

  test('auth team preflight exposes self-service write methods', () async {
    await _withRealHttp(() async {
      final ctx = await _spinUp();
      try {
        final request = await ctx.client.openUrl(
          'OPTIONS',
          ctx.baseUri.resolve('/v1/auth/team/locations/loc_1/org-unit'),
        );
        request.headers.set('Origin', _operatorWebOrigin);
        request.headers.set('Access-Control-Request-Method', 'PATCH');
        request.headers.set(
          'Access-Control-Request-Headers',
          'authorization,content-type,idempotency-key',
        );
        request.contentLength = 0;
        final response = await request.close();
        expect(response.statusCode, equals(HttpStatus.noContent));
        final methods =
            response.headers.value('access-control-allow-methods') ?? '';
        expect(methods, contains('PATCH'));
        expect(methods, contains('DELETE'));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('operator self-service preflight admits operator web origin', () async {
    await _withRealHttp(() async {
      final ctx = await _spinUp();
      try {
        final cases = <({String path, String method})>[
          (path: '/v1/operator/account', method: 'PATCH'),
          (path: '/v1/operator/business-timing-profiles', method: 'POST'),
          (path: '/v1/operator/notification-preferences', method: 'PUT'),
          (path: '/v1/auth/mobile/push-token/register', method: 'POST'),
        ];
        for (final entry in cases) {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(entry.path),
          );
          request.headers.set('Origin', _operatorWebOrigin);
          request.headers.set('Access-Control-Request-Method', entry.method);
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type,idempotency-key',
          );
          request.contentLength = 0;
          final response = await request.close();
          expect(
            response.statusCode,
            equals(HttpStatus.noContent),
            reason: entry.path,
          );
          expect(
            response.headers.value('access-control-allow-origin'),
            equals(_operatorWebOrigin),
            reason: entry.path,
          );
          expect(
            response.headers.value('access-control-allow-methods') ?? '',
            contains(entry.method),
            reason: entry.path,
          );
        }
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
