// Phase 11A.7 — Feature flags admin proxy routes tests.
//
// Spins up a real loopback HttpServer per test, dispatches through
// `routeRequest` with a fake `FeatureFlagsAdminProxyGateway`, and
// asserts the role-gate matrix, idempotency-key requirement on POST,
// actor-resolver gate on toggle, and 404 surfacing on unknown_flag.
//
// The gateway returns a placeholder row JSON; the real toggle audit
// row is exercised by `proxy_feature_flags_audit_test.dart`-style
// unit coverage on `RepositoryFeatureFlagsAdminProxyGateway`. The
// fake here records the actor + idempotency-key the dispatcher
// passed through so the test can assert the proxy plumbing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('11A.7 admin feature flags routes', () {
    final clockNow = DateTime.utc(2026, 5, 2, 12);

    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<
      ({
        HttpServer server,
        HttpClient client,
        Uri baseUri,
        _SettableVerifier verifier,
        _FakeFeatureFlagsAdminGateway gateway,
        _FakeActorResolver resolver,
      })
    > spinUp({
      ProxyJwtClaims? initialClaims,
      _FakeFeatureFlagsAdminGateway? customGateway,
      _FakeActorResolver? customResolver,
      bool gatewayConfigured = true,
      bool resolverConfigured = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims;
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? _FakeFeatureFlagsAdminGateway();
      final resolver = customResolver ?? _FakeActorResolver();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            featureFlagsAdminGateway:
                gatewayConfigured ? gateway : null,
            integrationAdminActorResolver:
                resolverConfigured ? resolver : null,
            now: () => clockNow,
            adminCorsAllowList: const <String>[
              'https://admin.forgeflow.app',
            ],
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {}
        }
      });
      final client = HttpClient();
      final baseUri =
          Uri.parse('http://${server.address.host}:${server.port}');
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        verifier: verifier,
        gateway: gateway,
        resolver: resolver,
      );
    }

    test(
      'GET /v1/admin/feature-flags returns 503 without a gateway',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(gatewayConfigured: false);
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminFeatureFlagsListPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('feature_flags_admin_not_configured'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'GET /v1/admin/feature-flags rejects operator_owner (403)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_x',
              locationId: 'loc_x',
              roles: <String>['operator_owner'],
            ),
          );
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminFeatureFlagsListPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            final required = (body['required_roles']! as List).cast<String>();
            expect(required, contains('super_admin'));
            expect(required, contains('ff_support'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'GET /v1/admin/feature-flags admits ff_support (read-only)',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeFeatureFlagsAdminGateway();
          gateway.listResult = <Map<String, Object?>>[
            <String, Object?>{
              'flag_id': 'flag-1',
              'flag_name': 'advisor_enabled',
              'operator_id': null,
              'location_id': null,
              'enabled': true,
              'kind': 'standard',
              'description': null,
              'updated_by': null,
              'created_at': clockNow.toIso8601String(),
              'updated_at': clockNow.toIso8601String(),
            },
          ];
          const supportUuid = '22222222-2222-4222-8222-222222222222';
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: supportUuid,
              firebaseUid: supportUuid,
              operatorId: null,
              locationId: null,
              roles: <String>['ff_support'],
            ),
          );
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminFeatureFlagsListPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final flags =
                (body['flags']! as List).cast<Map<String, Object?>>();
            expect(flags, hasLength(1));
            expect(flags.first['flag_name'], equals('advisor_enabled'));
            // Reads skip resolver, so the gateway sees the raw user id.
            expect(gateway.lastListActorUserId, equals(supportUuid));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST /v1/admin/feature-flags/toggle rejects ff_support (write)',
      () async {
        await withRealHttp(() async {
          const supportUuid = '22222222-2222-4222-8222-222222222222';
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: supportUuid,
              firebaseUid: supportUuid,
              operatorId: null,
              locationId: null,
              roles: <String>['ff_support'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-1',
              body: const <String, Object?>{
                'flag_id': 'flag-1',
                'enabled': true,
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            final required =
                (body['required_roles']! as List).cast<String>();
            expect(required, equals(<String>['super_admin']));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST /v1/admin/feature-flags/toggle requires Idempotency-Key',
      () async {
        await withRealHttp(() async {
          const adminUuid = '11111111-1111-4111-8111-111111111111';
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: adminUuid,
              firebaseUid: adminUuid,
              operatorId: null,
              locationId: null,
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'flag_id': 'flag-1',
                'enabled': true,
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            // HARD-D — code aligned with
            // docs/contracts/hardening_feature_flag_idempotency_contract.md.
            expect(body['error'], equals('idempotency_key_missing'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST toggle resolves Firebase UID through the actor resolver',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeFeatureFlagsAdminGateway();
          gateway.toggleResult = <String, Object?>{
            'flag_id': 'flag-1',
            'flag_name': 'advisor_enabled',
            'operator_id': null,
            'location_id': null,
            'enabled': true,
            'kind': 'standard',
            'description': null,
            'updated_by': '11111111-1111-4111-8111-111111111111',
            'created_at': clockNow.toIso8601String(),
            'updated_at': clockNow.toIso8601String(),
          };
          // Firebase UID does NOT echo as a UUID; resolver maps it to
          // the Postgres user UUID.
          final resolver = _FakeActorResolver()
            ..resolveByFirebaseUid = <String, String?>{
              'firebase-admin-uid':
                  '11111111-1111-4111-8111-111111111111',
            }
            ..useEchoFallback = false;
          final ctx = await spinUp(
            customGateway: gateway,
            customResolver: resolver,
            initialClaims: const ProxyJwtClaims(
              userId: 'firebase-admin-uid',
              firebaseUid: 'firebase-admin-uid',
              operatorId: null,
              locationId: null,
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-1',
              body: const <String, Object?>{
                'flag_id': 'flag-1',
                'enabled': true,
              },
            );
            expect(response.statusCode, equals(200));
            // Toggle reached the gateway with the resolved Postgres
            // UUID, not the raw Firebase UID.
            expect(
              gateway.lastToggleActorUserId,
              equals('11111111-1111-4111-8111-111111111111'),
            );
            // Idempotency-Key plumbed through.
            expect(gateway.lastToggleIdempotencyKey, equals('idem-1'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST toggle returns 403 actor_user_not_resolvable when no '
      'matching Postgres users row',
      () async {
        await withRealHttp(() async {
          final resolver = _FakeActorResolver()
            ..useEchoFallback = false
            ..resolveResult = null;
          final ctx = await spinUp(
            customResolver: resolver,
            initialClaims: const ProxyJwtClaims(
              userId: 'firebase-admin-uid',
              firebaseUid: 'firebase-admin-uid',
              operatorId: null,
              locationId: null,
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-1',
              body: const <String, Object?>{
                'flag_id': 'flag-1',
                'enabled': true,
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('actor_user_not_resolvable'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('POST toggle returns 404 when gateway returns null', () async {
      await withRealHttp(() async {
        final gateway = _FakeFeatureFlagsAdminGateway();
        gateway.toggleResult = null;
        const adminUuid = '11111111-1111-4111-8111-111111111111';
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: adminUuid,
            firebaseUid: adminUuid,
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-2',
            body: const <String, Object?>{
              'flag_id': 'flag-missing',
              'enabled': true,
            },
          );
          expect(response.statusCode, equals(404));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('unknown_flag'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('OPTIONS preflight allows POST + Idempotency-Key header', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'POST');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type,idempotency-key',
          );
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.noContent));
          final allowMethods =
              response.headers.value('access-control-allow-methods') ?? '';
          expect(allowMethods.toUpperCase(), contains('POST'));
          expect(allowMethods.toUpperCase(), contains('OPTIONS'));
          final allowHeaders =
              response.headers.value('access-control-allow-headers') ?? '';
          expect(allowHeaders, contains('Idempotency-Key'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

class _FakeFeatureFlagsAdminGateway implements FeatureFlagsAdminProxyGateway {
  List<Map<String, Object?>> listResult = const <Map<String, Object?>>[];
  Map<String, Object?>? toggleResult = <String, Object?>{};
  String? lastListActorUserId;
  String? lastToggleActorUserId;
  String? lastToggleIdempotencyKey;
  String? lastToggleFlagId;
  bool? lastToggleEnabled;

  @override
  Future<List<Map<String, Object?>>> listFlags({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastListActorUserId = actorUserId;
    return listResult;
  }

  @override
  Future<Map<String, Object?>?> toggleFlag({
    required String actorUserId,
    required String flagId,
    required bool enabled,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    lastToggleActorUserId = actorUserId;
    lastToggleIdempotencyKey = idempotencyKey;
    lastToggleFlagId = flagId;
    lastToggleEnabled = enabled;
    return toggleResult;
  }
}

class _FakeActorResolver implements IntegrationAdminActorResolver {
  String? resolveResult;
  Map<String, String?> resolveByFirebaseUid = const <String, String?>{};
  bool useEchoFallback = true;
  Object? raises;

  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) async {
    final raise = raises;
    if (raise != null) throw raise;
    if (resolveByFirebaseUid.containsKey(firebaseUid)) {
      return resolveByFirebaseUid[firebaseUid];
    }
    if (resolveResult != null) return resolveResult;
    if (useEchoFallback) return firebaseUid;
    return null;
  }
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final value = claims;
    if (value != null) return value;
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

class _HttpResponseSnapshot {
  _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpGet(
  HttpClient client,
  Uri uri, {
  String? authorization,
}) async {
  final request = await client.getUrl(uri);
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(statusCode: response.statusCode, body: body);
}

Future<_HttpResponseSnapshot> _httpJson(
  HttpClient client,
  String method,
  Uri uri, {
  String? authorization,
  String? idempotencyKey,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  } else {
    request.contentLength = 0;
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
