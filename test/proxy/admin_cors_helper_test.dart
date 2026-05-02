// HARD-C — unit tests for respondAdminCorsPreflight, the single
// origin-decision site for admin CORS.
//
// Covers the contract surface in
// docs/contracts/hardening_admin_cors_and_limits_contract.md:
//   * allowed origin → 204 with exact-origin echo (never `*`)
//   * disallowed origin → 403 with `cors_origin_not_allowed`
//     and NO Access-Control-Allow-Origin header
//   * missing Origin → 403 same as disallowed
//   * Vary: Origin set on every response (allowed and rejected)
//   * Allow-Headers includes Idempotency-Key
//   * Max-Age 600
//   * `:*` allow-list entries match any port on the same scheme/host
//
// The helper takes a real HttpRequest, so we drive it through a
// loopback HttpServer that hands every request directly into the
// helper. No routeRequest, no auth, no JWT — just the helper itself.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

/// Flutter's test environment installs a global HttpOverrides that
/// returns 400 for any real HTTP call. Temporarily clear it for each
/// test so we can exercise the helper end-to-end against a localhost
/// server. Restored after the test body.
Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

Future<({HttpServer server, HttpClient client, Uri baseUri})> _spinUp({
  required List<String> allowList,
  required List<String> allowedMethods,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    try {
      respondAdminCorsPreflight(
        request,
        allowList,
        allowedMethods: allowedMethods,
      );
      await request.response.close();
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

Future<({int statusCode, HttpHeaders headers, String body})> _options(
  HttpClient client,
  Uri uri, {
  String? origin,
}) async {
  final request = await client.openUrl('OPTIONS', uri);
  request.persistentConnection = false;
  if (origin != null) request.headers.set('Origin', origin);
  request.headers.set('Access-Control-Request-Method', 'POST');
  request.headers.set(
    'Access-Control-Request-Headers',
    'authorization,content-type',
  );
  request.contentLength = 0;
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return (
    statusCode: response.statusCode,
    headers: response.headers,
    body: body,
  );
}

void main() {
  group('respondAdminCorsPreflight — allowed origin', () {
    test('echoes the exact origin and never wildcards', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['https://admin.forgeandflow.app'],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'https://admin.forgeandflow.app',
          );

          expect(res.statusCode, equals(HttpStatus.noContent));
          expect(
            res.headers.value('access-control-allow-origin'),
            equals('https://admin.forgeandflow.app'),
          );
          expect(
            res.headers.value('access-control-allow-origin'),
            isNot(equals('*')),
          );
          expect(res.body, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('sets Vary: Origin, Allow-Methods, Allow-Headers, Max-Age', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['https://admin.forgeandflow.app'],
          allowedMethods: const <String>['GET', 'POST', 'PATCH', 'OPTIONS'],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'https://admin.forgeandflow.app',
          );

          expect(res.headers.value('vary'), equals('Origin'));
          final methods =
              res.headers.value('access-control-allow-methods') ?? '';
          expect(methods.toUpperCase(), contains('GET'));
          expect(methods.toUpperCase(), contains('POST'));
          expect(methods.toUpperCase(), contains('PATCH'));
          expect(methods.toUpperCase(), contains('OPTIONS'));
          final allowedHeaders =
              res.headers.value('access-control-allow-headers') ?? '';
          expect(allowedHeaders.toLowerCase(), contains('authorization'));
          expect(allowedHeaders.toLowerCase(), contains('content-type'));
          expect(allowedHeaders.toLowerCase(), contains('idempotency-key'));
          expect(res.headers.value('access-control-max-age'), equals('600'));
          // Bearer-token admin auth — Allow-Credentials must NOT be set.
          expect(
            res.headers.value('access-control-allow-credentials'),
            isNull,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'Allow-Headers exactly matches the contract value (P3)',
      () async {
        // Contract: Authorization, Content-Type, Idempotency-Key
        // (with single space after each comma; no `Accept`).
        await _withRealHttp(() async {
          final ctx = await _spinUp(
            allowList: const <String>['https://admin.forgeandflow.app'],
            allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
          );
          try {
            final res = await _options(
              ctx.client,
              ctx.baseUri,
              origin: 'https://admin.forgeandflow.app',
            );

            expect(
              res.headers.value('access-control-allow-headers'),
              equals('Authorization, Content-Type, Idempotency-Key'),
            );
            // `Accept` is not required by any admin route; the
            // contract excludes it from Allow-Headers.
            expect(
              res.headers
                  .value('access-control-allow-headers')!
                  .toLowerCase(),
              isNot(contains('accept')),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('case-sensitive matching — origins must match exactly', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['https://admin.forgeandflow.app'],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          // Capitalised host: not in the allow-list, should be rejected.
          final res = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'https://ADMIN.forgeandflow.app',
          );
          expect(res.statusCode, equals(HttpStatus.forbidden));
          expect(
            res.headers.value('access-control-allow-origin'),
            isNull,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('respondAdminCorsPreflight — disallowed origin', () {
    test('returns 403 with cors_origin_not_allowed body', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['https://admin.forgeandflow.app'],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'https://attacker.example',
          );

          expect(res.statusCode, equals(HttpStatus.forbidden));
          final decoded = jsonDecode(res.body) as Map<String, Object?>;
          expect(decoded['error'], equals('cors_origin_not_allowed'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('never echoes the disallowed origin in any header', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['https://admin.forgeandflow.app'],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'https://attacker.example',
          );

          expect(
            res.headers.value('access-control-allow-origin'),
            isNull,
          );
          expect(
            res.headers.value('access-control-allow-methods'),
            isNull,
          );
          expect(
            res.headers.value('access-control-allow-headers'),
            isNull,
          );
          // Vary: Origin is still set on rejections so a CDN does not
          // serve a single cached 403 to every origin.
          expect(res.headers.value('vary'), equals('Origin'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('missing Origin header returns 403 with no echo', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['https://admin.forgeandflow.app'],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          final res = await _options(ctx.client, ctx.baseUri);

          expect(res.statusCode, equals(HttpStatus.forbidden));
          expect(
            res.headers.value('access-control-allow-origin'),
            isNull,
          );
          expect(res.headers.value('vary'), equals('Origin'));
          final decoded = jsonDecode(res.body) as Map<String, Object?>;
          expect(decoded['error'], equals('cors_origin_not_allowed'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('empty allow-list rejects every origin', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>[],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'https://admin.forgeandflow.app',
          );

          expect(res.statusCode, equals(HttpStatus.forbidden));
          expect(
            res.headers.value('access-control-allow-origin'),
            isNull,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('respondAdminCorsPreflight — wildcard port matching', () {
    test('matches `http://localhost:*` against any numeric port', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['http://localhost:*'],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          final res5173 = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'http://localhost:5173',
          );
          expect(res5173.statusCode, equals(HttpStatus.noContent));
          expect(
            res5173.headers.value('access-control-allow-origin'),
            equals('http://localhost:5173'),
          );

          final res8080 = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'http://localhost:8080',
          );
          expect(res8080.statusCode, equals(HttpStatus.noContent));
          expect(
            res8080.headers.value('access-control-allow-origin'),
            equals('http://localhost:8080'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('rejects non-numeric port suffix in `:*` match', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['http://localhost:*'],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          // `localhost.evil.example` is NOT `localhost`, and the port
          // suffix `5173.evil` is non-numeric — both fail the wildcard.
          final res = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'http://localhost.evil.example',
          );
          expect(res.statusCode, equals(HttpStatus.forbidden));
          expect(
            res.headers.value('access-control-allow-origin'),
            isNull,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('does NOT treat exact origins as wildcards', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>['https://admin.forgeandflow.app'],
          allowedMethods: const <String>['GET', 'POST', 'OPTIONS'],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri,
            origin: 'https://admin.forgeandflow.app:8443',
          );
          expect(res.statusCode, equals(HttpStatus.forbidden));
          expect(
            res.headers.value('access-control-allow-origin'),
            isNull,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}
