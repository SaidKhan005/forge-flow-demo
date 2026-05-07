// A7 — POST /v1/auth/magic-link/redeem proxy route tests.
//
// Covers:
//   1. Route returns 503 when no MagicLinkRedeemGateway is wired
//      (scaffold / test environment without Postgres).
//   2. Route validates body fields (token + idempotency_key required).
//   3. Happy path: gateway succeeds → 200 with firebase_custom_token.
//   4. 4xx from gateway → 410 with calm operator-facing message.
//   5. Security headers: Referrer-Policy: no-referrer and
//      Cache-Control: no-store, no-cache on every response.
//   6. GET to the same path → 404 (GET form not implemented;
//      deprecated in favour of POST).
//   7. CORS preflight admits operator-web origin for the POST path.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import '../../tool/advisor_proxy/advisor_proxy.dart';

// ─── Helpers ────────────────────────────────────────────────────────────────

const String _origin = 'https://forge-flow-operator-web.test';

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

class _OkGateway implements MagicLinkRedeemGateway {
  @override
  Future<MagicLinkRedeemed> redeem(MagicLinkRedeemCommand command) async {
    return const MagicLinkRedeemed(firebaseCustomToken: 'firebase-ct-abc');
  }
}

class _ExpiredGateway implements MagicLinkRedeemGateway {
  @override
  Future<MagicLinkRedeemed> redeem(MagicLinkRedeemCommand command) async {
    throw const MagicLinkTokenInvalid(
      code: 'token_expired',
      message: 'This link has expired or been used.',
      statusCode: 410,
    );
  }
}

Future<({HttpServer server, HttpClient client, Uri baseUri})> _spinUp({
  MagicLinkRedeemGateway? gateway,
}) async {
  final guard = ProxyRequestGuard(
    verifier: const ScaffoldRejectingJwtVerifier(),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    await routeRequest(
      request,
      guard,
      magicLinkRedeemGateway: gateway,
      adminCorsAllowList: const <String>[_origin],
      now: () => DateTime.utc(2026, 5, 7, 10),
    );
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri);
}

Future<HttpClientResponse> _post(
  HttpClient client,
  Uri url,
  Map<String, Object?> body,
) async {
  final request = await client.postUrl(url);
  request.headers.contentType = ContentType.json;
  request.headers.add('Content-Length', utf8.encode(jsonEncode(body)).length);
  request.write(jsonEncode(body));
  return request.close();
}

// ─── Tests ──────────────────────────────────────────────────────────────────

void main() {
  group('POST /v1/auth/magic-link/redeem', () {
    test('returns 503 when gateway not wired', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: null);
        try {
          final response = await _post(
            ctx.client,
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
            <String, Object?>{
              'token': 'some-token',
              'idempotency_key': 'ik-1',
            },
          );
          expect(response.statusCode, equals(503));
          final body =
              jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;
          expect(body['error'], equals('magic_link_redeem_not_configured'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns 400 when token is missing from body', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _OkGateway());
        try {
          final response = await _post(
            ctx.client,
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
            <String, Object?>{'idempotency_key': 'ik-2'},
          );
          expect(response.statusCode, equals(400));
          final body =
              jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;
          expect(body['error'], equals('missing_token'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns 400 when idempotency_key is missing from body', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _OkGateway());
        try {
          final response = await _post(
            ctx.client,
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
            <String, Object?>{'token': 'tok'},
          );
          expect(response.statusCode, equals(400));
          final body =
              jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;
          expect(body['error'], equals('missing_idempotency_key'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns 200 with firebase_custom_token on success', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _OkGateway());
        try {
          final response = await _post(
            ctx.client,
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
            <String, Object?>{
              'token': 'valid-invite-token',
              'idempotency_key': 'ik-3',
            },
          );
          expect(response.statusCode, equals(200));
          final body =
              jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;
          expect(body['ok'], isTrue);
          expect(body['firebase_custom_token'], equals('firebase-ct-abc'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('maps MagicLinkTokenInvalid(410) to calm operator-facing message',
        () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _ExpiredGateway());
        try {
          final response = await _post(
            ctx.client,
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
            <String, Object?>{
              'token': 'expired-token',
              'idempotency_key': 'ik-4',
            },
          );
          expect(response.statusCode, equals(410));
          final body =
              jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;
          expect(body['error'], equals('token_expired'));
          // Message is operator-facing, not engineering shorthand.
          final message = body['message'] as String? ?? '';
          expect(message, contains('expired or been used'));
          expect(message, contains('invite-sender'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('sets Referrer-Policy: no-referrer on success', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _OkGateway());
        try {
          final response = await _post(
            ctx.client,
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
            <String, Object?>{
              'token': 'tok',
              'idempotency_key': 'ik-5',
            },
          );
          // Drain response.
          await response.drain<void>();
          expect(
            response.headers.value('referrer-policy'),
            equals('no-referrer'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('sets Cache-Control: no-store, no-cache on success', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _OkGateway());
        try {
          final response = await _post(
            ctx.client,
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
            <String, Object?>{
              'token': 'tok',
              'idempotency_key': 'ik-6',
            },
          );
          await response.drain<void>();
          final cacheControl = response.headers.value('cache-control') ?? '';
          expect(cacheControl, contains('no-store'));
          expect(cacheControl, contains('no-cache'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('sets security headers on 4xx response too', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _ExpiredGateway());
        try {
          final response = await _post(
            ctx.client,
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
            <String, Object?>{
              'token': 'expired',
              'idempotency_key': 'ik-7',
            },
          );
          await response.drain<void>();
          expect(
            response.headers.value('referrer-policy'),
            equals('no-referrer'),
          );
          final cacheControl = response.headers.value('cache-control') ?? '';
          expect(cacheControl, contains('no-store'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('GET to same path returns 404 (GET form not implemented)', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _OkGateway());
        try {
          final request = await ctx.client.getUrl(
            ctx.baseUri.resolve(
              '$authMagicLinkRedeemPath?token=tok',
            ),
          );
          final response = await request.close();
          await response.drain<void>();
          // GET is not an implemented handler; proxy returns 404.
          expect(response.statusCode, equals(404));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('CORS preflight admits operator-web origin', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(gateway: _OkGateway());
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(authMagicLinkRedeemPath),
          );
          request.headers.set('Origin', _origin);
          request.headers.set('Access-Control-Request-Method', 'POST');
          request.headers.set(
            'Access-Control-Request-Headers',
            'content-type',
          );
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.noContent));
          expect(
            response.headers.value('access-control-allow-origin'),
            equals(_origin),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}
