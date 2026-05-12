// HARD-C — admin route CORS tests.
//
// Verifies all five admin path families route their preflight
// through the centralized respondAdminCorsPreflight helper:
//   * /v1/admin/operators       (operator/location admin)
//   * /v1/admin/pricing/...     (pricing tier admin)
//   * /v1/admin/corpus/...      (corpus admin — Idempotency-Key)
//   * /v1/admin/integrations    (integration admin)
//   * /v1/admin/feature-flags   (feature flags admin — Idempotency-Key)
//
// Allowed origin: 204, exact-origin echo, never `*`.
// Disallowed origin: 403, no Allow-Origin header.
//
// The contract acceptance bullet "no remaining
// `Access-Control-Allow-Origin: *` on admin paths" is enforced via a
// source-grep test that fails if anyone reintroduces a bare `*` in
// the proxy source.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _adminOrigin = 'https://admin.forgeandflow.app';
const String _firebaseActionOrigin =
    'https://forge-flow-staging.firebaseapp.com';
const String _attackerOrigin = 'https://attacker.example';

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
  List<String> allowList = const <String>[_adminOrigin],
}) async {
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
        adminCorsAllowList: allowList,
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

Future<({int statusCode, HttpHeaders headers, String body})> _options(
  HttpClient client,
  Uri uri, {
  required String requestMethod,
  String? origin,
}) async {
  final request = await client.openUrl('OPTIONS', uri);
  request.persistentConnection = false;
  if (origin != null) request.headers.set('Origin', origin);
  request.headers.set('Access-Control-Request-Method', requestMethod);
  request.headers.set(
    'Access-Control-Request-Headers',
    'authorization,content-type,idempotency-key',
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

Future<({int statusCode, HttpHeaders headers, String body})> _get(
  HttpClient client,
  Uri uri, {
  String? origin,
}) async {
  final request = await client.openUrl('GET', uri);
  request.persistentConnection = false;
  if (origin != null) request.headers.set('Origin', origin);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return (
    statusCode: response.statusCode,
    headers: response.headers,
    body: body,
  );
}

void _expectAllowed(
  ({int statusCode, HttpHeaders headers, String body}) res, {
  String origin = _adminOrigin,
}) {
  expect(res.statusCode, equals(HttpStatus.noContent));
  expect(res.headers.value('access-control-allow-origin'), equals(origin));
  expect(res.headers.value('access-control-allow-origin'), isNot(equals('*')));
  expect(res.headers.value('vary'), equals('Origin'));
  expect(res.headers.value('access-control-max-age'), equals('600'));
}

void _expectDisallowed(
  ({int statusCode, HttpHeaders headers, String body}) res,
) {
  expect(res.statusCode, equals(HttpStatus.forbidden));
  expect(res.headers.value('access-control-allow-origin'), isNull);
  expect(res.headers.value('vary'), equals('Origin'));
}

void main() {
  group('admin route CORS — operator/location', () {
    test('OPTIONS allowed origin → 204 with exact-origin echo', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminOperatorsPath),
            requestMethod: 'POST',
            origin: _adminOrigin,
          );
          _expectAllowed(res);
          final methods =
              res.headers.value('access-control-allow-methods') ?? '';
          expect(methods.toUpperCase(), contains('PATCH'));
          expect(methods.toUpperCase(), contains('DELETE'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('OPTIONS disallowed origin → 403 with no echo', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminOperatorsPath),
            requestMethod: 'POST',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
          final decoded = jsonDecode(res.body) as Map<String, Object?>;
          expect(decoded['error'], equals('cors_origin_not_allowed'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS — pricing', () {
    test('OPTIONS allowed origin echoes origin and announces PUT', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminPricingUsageCapsPath),
            requestMethod: 'PUT',
            origin: _adminOrigin,
          );
          _expectAllowed(res);
          final methods =
              res.headers.value('access-control-allow-methods') ?? '';
          expect(methods.toUpperCase(), contains('PUT'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('OPTIONS disallowed origin → 403 on pricing path', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminPricingOperatorsPath),
            requestMethod: 'GET',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS — corpus', () {
    test(
      'OPTIONS allowed origin echoes origin and includes Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final ctx = await _spinUp();
          try {
            final res = await _options(
              ctx.client,
              ctx.baseUri.resolve(adminCorpusCommitPath),
              requestMethod: 'POST',
              origin: _adminOrigin,
            );
            _expectAllowed(res);
            final allowedHeaders =
                res.headers.value('access-control-allow-headers') ?? '';
            expect(allowedHeaders.toLowerCase(), contains('idempotency-key'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('OPTIONS disallowed origin → 403 on corpus path', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminCorpusPreviewDiffPath),
            requestMethod: 'POST',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS — integrations', () {
    test('OPTIONS allowed origin echoes origin', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminIntegrationsListPath),
            requestMethod: 'POST',
            origin: _adminOrigin,
          );
          _expectAllowed(res);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('OPTIONS disallowed origin → 403 on integrations path', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminIntegrationsListPath),
            requestMethod: 'POST',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS — feature flags', () {
    test(
      'OPTIONS allowed origin echoes origin and includes Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final ctx = await _spinUp();
          try {
            final res = await _options(
              ctx.client,
              ctx.baseUri.resolve(adminFeatureFlagsListPath),
              requestMethod: 'POST',
              origin: _adminOrigin,
            );
            _expectAllowed(res);
            final allowedHeaders =
                res.headers.value('access-control-allow-headers') ?? '';
            expect(allowedHeaders.toLowerCase(), contains('idempotency-key'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('OPTIONS disallowed origin → 403 on feature-flags path', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminFeatureFlagsListPath),
            requestMethod: 'POST',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS — debug console', () {
    test('OPTIONS allowed origin echoes origin and announces GET', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminDebugRequestsPath),
            requestMethod: 'GET',
            origin: _adminOrigin,
          );
          _expectAllowed(res);
          final methods =
              res.headers.value('access-control-allow-methods') ?? '';
          expect(methods.toUpperCase(), contains('GET'));
          expect(methods.toUpperCase(), contains('OPTIONS'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('OPTIONS disallowed origin → 403 on debug-console path', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminDebugFullContentOptInsPath),
            requestMethod: 'GET',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS — observability', () {
    test('OPTIONS allowed origin echoes origin and announces GET', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminObservabilityPath),
            requestMethod: 'GET',
            origin: _adminOrigin,
          );
          _expectAllowed(res);
          final methods =
              res.headers.value('access-control-allow-methods') ?? '';
          expect(methods.toUpperCase(), contains('GET'));
          expect(methods.toUpperCase(), contains('OPTIONS'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('OPTIONS disallowed origin → 403 on observability path', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminObservabilityPath),
            requestMethod: 'GET',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS - admin auth', () {
    test('OPTIONS allowed origin echoes origin for members routes', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminAuthUsersPath),
            requestMethod: 'GET',
            origin: _adminOrigin,
          );
          _expectAllowed(res);
          final methods =
              res.headers.value('access-control-allow-methods') ?? '';
          expect(methods.toUpperCase(), contains('GET'));
          expect(methods.toUpperCase(), contains('POST'));
          expect(methods.toUpperCase(), contains('OPTIONS'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'OPTIONS allowed origin echoes origin for role hierarchy routes',
      () async {
        await _withRealHttp(() async {
          final ctx = await _spinUp();
          try {
            final res = await _options(
              ctx.client,
              ctx.baseUri.resolve(adminAuthRolesPath),
              requestMethod: 'GET',
              origin: _adminOrigin,
            );
            _expectAllowed(res);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('OPTIONS disallowed origin -> 403 on admin auth paths', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(adminAuthUsersPath),
            requestMethod: 'GET',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS - deep health', () {
    test('OPTIONS allowed origin echoes origin and announces GET', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(deepHealthPath),
            requestMethod: 'GET',
            origin: _adminOrigin,
          );
          _expectAllowed(res);
          final methods =
              res.headers.value('access-control-allow-methods') ?? '';
          expect(methods.toUpperCase(), contains('GET'));
          expect(methods.toUpperCase(), contains('OPTIONS'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('GET degraded response echoes allowed origin', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp();
        try {
          final res = await _get(
            ctx.client,
            ctx.baseUri.resolve(deepHealthPath),
            origin: _adminOrigin,
          );
          expect(res.statusCode, equals(HttpStatus.serviceUnavailable));
          expect(
            res.headers.value('access-control-allow-origin'),
            equals(_adminOrigin),
          );
          expect(res.headers.value('vary'), equals('Origin'));
          final decoded = jsonDecode(res.body) as Map<String, Object?>;
          expect(decoded['error'], equals('health_check_not_configured'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('auth password reset CORS', () {
    test('request preflight allows the operator web origin', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>[
            _adminOrigin,
            'https://forge-flow-operator-web-rf7nosnoka-pd.a.run.app',
          ],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(authPasswordResetRequestPath),
            requestMethod: 'POST',
            origin: 'https://forge-flow-operator-web-rf7nosnoka-pd.a.run.app',
          );
          _expectAllowed(
            res,
            origin: 'https://forge-flow-operator-web-rf7nosnoka-pd.a.run.app',
          );
          final methods =
              res.headers.value('access-control-allow-methods') ?? '';
          expect(methods.toUpperCase(), contains('POST'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('confirm preflight allows the Firebase action page origin', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>[_adminOrigin, _firebaseActionOrigin],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(authPasswordResetConfirmPath),
            requestMethod: 'POST',
            origin: _firebaseActionOrigin,
          );
          _expectAllowed(res, origin: _firebaseActionOrigin);
          final allowedHeaders =
              res.headers.value('access-control-allow-headers') ?? '';
          expect(allowedHeaders.toLowerCase(), contains('idempotency-key'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('confirm preflight rejects an unlisted origin', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(
          allowList: const <String>[_adminOrigin, _firebaseActionOrigin],
        );
        try {
          final res = await _options(
            ctx.client,
            ctx.baseUri.resolve(authPasswordResetConfirmPath),
            requestMethod: 'POST',
            origin: _attackerOrigin,
          );
          _expectDisallowed(res);
          final decoded = jsonDecode(res.body) as Map<String, Object?>;
          expect(decoded['error'], equals('cors_origin_not_allowed'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('admin route CORS — source grep guard', () {
    test('no Dart code sets Access-Control-Allow-Origin to a wildcard', () {
      // Contract acceptance: HARD-C deletes every `*` echo on
      // admin paths. Catch reintroductions before they ship.
      // Search only for the Dart code form (quoted header name +
      // quoted `*` value) — doc comments mentioning the legacy
      // wildcard for context are allowed.
      final source = File(
        'tool/advisor_proxy/advisor_proxy.dart',
      ).readAsStringSync();
      // Tolerate any whitespace between the header name and `'*'`.
      final wildcardCallSite = RegExp(
        r"""'Access-Control-Allow-Origin'\s*,\s*'\*'""",
      );
      expect(
        wildcardCallSite.hasMatch(source),
        isFalse,
        reason:
            'admin CORS regression — a Dart call site echoes '
            "`Access-Control-Allow-Origin: '*'`. Replace with "
            'respondAdminCorsPreflight in advisor_proxy.dart.',
      );
    });
  });
}
