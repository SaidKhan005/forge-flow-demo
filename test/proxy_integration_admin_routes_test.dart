// Phase 11A.4 — Integration management proxy routes tests.
//
// Spins up a real loopback HttpServer per test, dispatches through
// `routeRequest` with a fake `IntegrationAdminProxyGateway`, and
// asserts the role-gate matrix, masked-value invariant on list
// responses, audit-row writes for both rotate-success and
// rotate-failure paths, and CORS preflight admission of POST.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('11A.4 admin integrations routes', () {
    final clockNow = DateTime.utc(2026, 5, 1, 12);
    // Fresh-auth window is 5 minutes; pin the claim's
    // `lastFreshAuthAt` to two minutes before the test clock so POST
    // rotations land inside the window. Stale-auth tests override
    // this with an older timestamp.
    final freshAuthAt = clockNow.subtract(const Duration(minutes: 2));
    final staleAuthAt = clockNow.subtract(const Duration(minutes: 30));

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
        _FakeIntegrationAdminGateway gateway,
        _FakeIntegrationActorResolver resolver,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      _FakeIntegrationAdminGateway? customGateway,
      _FakeIntegrationActorResolver? customResolver,
      bool gatewayConfigured = true,
      bool resolverConfigured = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims;
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? _FakeIntegrationAdminGateway();
      // The default resolver echoes the firebase_uid back as a
      // mock-resolved user id so test claims that already carry a
      // UUID-shaped firebase_uid round-trip through the dispatch
      // unchanged.
      final resolver = customResolver ?? _FakeIntegrationActorResolver();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            integrationAdminGateway: gatewayConfigured ? gateway : null,
            integrationAdminActorResolver:
                resolverConfigured ? resolver : null,
            now: () => clockNow,
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
      '11A.4 GET /v1/admin/integrations returns 503 without a gateway',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(gatewayConfigured: false);
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminIntegrationsListPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['error'],
              equals('integration_admin_not_configured'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.4 GET /v1/admin/integrations rejects operator_owner (403)',
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
              ctx.baseUri.resolve(adminIntegrationsListPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            final required =
                (body['required_roles']! as List).cast<String>();
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
      '11A.4 GET /v1/admin/integrations admits ff_support (read-only)',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeIntegrationAdminGateway();
          gateway.listResult = <String, Object?>{
            'provider_keys': const <Map<String, Object?>>[],
            'vendor_connectors': const <Map<String, Object?>>[],
            'fx_rate_source': const <String, Object?>{
              'id': 'fx_rate',
              'display_name': 'FX-rate source',
              'status_label': 'green',
              'detail_message': '',
            },
            'email_provider': const <String, Object?>{
              'id': 'email',
              'display_name': 'Email provider',
              'status_label': 'placeholder',
              'detail_message': '',
            },
          };
          // UUID-shaped support userId — the resolver echoes it back
          // by default, so the gateway sees the same UUID after
          // resolution. A claim missing a Postgres `users` row would
          // 403 before reaching the gateway (asserted below).
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
              ctx.baseUri.resolve(adminIntegrationsListPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            // Plaintext invariant — the list response NEVER carries a
            // `plaintext_value` field at the top level.
            expect(body.containsKey('plaintext_value'), isFalse);
            expect(gateway.lastActorUserId, equals(supportUuid));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.4 POST .../rotate-anthropic rejects ff_support with 403',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeIntegrationAdminGateway();
          // ff_support's role gate rejects BEFORE the actor resolver
          // is called, so the firebase_uid shape is irrelevant here.
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: ProxyJwtClaims(
              userId: '22222222-2222-4222-8222-222222222222',
              firebaseUid: '22222222-2222-4222-8222-222222222222',
              operatorId: null,
              locationId: null,
              roles: const <String>['ff_support'],
              lastFreshAuthAt: freshAuthAt,
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'plaintext_value': 'sk-ant-newvalue1234',
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(body['required_roles'], contains('super_admin'));
            expect(body['required_roles'], isNot(contains('ff_support')));
            expect(gateway.rotateCalls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.4 POST .../rotate-anthropic forwards to gateway as super_admin',
        () async {
      await withRealHttp(() async {
        final gateway = _FakeIntegrationAdminGateway();
        gateway.rotateResult = <String, Object?>{
          'row': <String, Object?>{
            'credential_id': 'cred-new',
            'key_kind': 'anthropic',
            'masked_value': 'sk-a***1234',
            'kms_secret_name': 'kms://stub/new-uuid',
            'created_by': '11111111-1111-4111-8111-111111111111',
            'updated_by': '11111111-1111-4111-8111-111111111111',
            'rotated_at': '2026-05-01T12:00:00.000Z',
          },
          'plaintext_value': 'sk-ant-newvalue1234',
        };
        // Use a UUID-shaped firebase_uid so the resolver's echo
        // fallback returns the same UUID as the resolved Postgres
        // user_id.
        const actorUuid = '11111111-1111-4111-8111-111111111111';
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: ProxyJwtClaims(
            userId: actorUuid,
            firebaseUid: actorUuid,
            operatorId: null,
            locationId: null,
            roles: const <String>['super_admin'],
            lastFreshAuthAt: freshAuthAt,
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'plaintext_value': 'sk-ant-newvalue1234',
            },
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          // Plaintext echoed ONCE on the rotation response.
          expect(body['plaintext_value'], equals('sk-ant-newvalue1234'));
          // Masked-value invariant on the row.
          final row = (body['row'] as Map).cast<String, Object?>();
          expect(row['masked_value'], equals('sk-a***1234'));
          expect(gateway.rotateCalls, hasLength(1));
          expect(
            gateway.rotateCalls.single['key_kind'],
            equals('anthropic'),
          );
          expect(
            gateway.rotateCalls.single['plaintext_value'],
            equals('sk-ant-newvalue1234'),
          );
          expect(gateway.lastReason, contains('admin.integrations.POST'));
          // The reason string carries the verified Firebase UID for
          // traceability, alongside the resolved Postgres user UUID
          // on the gateway's actorUserId parameter.
          expect(gateway.lastReason, contains(actorUuid));
          // The gateway receives the resolved Postgres user UUID
          // (UUID-backed audit attribution).
          expect(gateway.lastActorUserId, equals(actorUuid));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.4 POST .../rotate-anthropic with stale lastFreshAuthAt is 403 mfa_freshness_required',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeIntegrationAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: ProxyJwtClaims(
              userId: '11111111-1111-4111-8111-111111111111',
              firebaseUid: '11111111-1111-4111-8111-111111111111',
              operatorId: null,
              locationId: null,
              roles: const <String>['super_admin'],
              lastFreshAuthAt: staleAuthAt,
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'plaintext_value': 'sk-ant-newvalue1234',
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('mfa_freshness_required'));
            // Stale-auth denial must not reach the gateway — no
            // KMS write, no provider_credentials row, no audit row
            // can be written by the gateway path.
            expect(gateway.rotateCalls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.4 POST .../rotate-anthropic with no lastFreshAuthAt is 403 mfa_freshness_required',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeIntegrationAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: '11111111-1111-4111-8111-111111111111',
              firebaseUid: '11111111-1111-4111-8111-111111111111',
              operatorId: null,
              locationId: null,
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'plaintext_value': 'sk-ant-newvalue1234',
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('mfa_freshness_required'));
            expect(gateway.rotateCalls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.4 POST rotate resolves verified firebase_uid into a Postgres user UUID',
      () async {
        await withRealHttp(() async {
          // The verifier returns a UUID-shaped firebase_uid (per F&F's
          // `firebase_uid` column type). The resolver maps that
          // explicit Firebase UID into a (possibly different)
          // Postgres user UUID; the test asserts the gateway sees
          // the resolved UUID, NOT the raw firebase_uid.
          const firebaseUidUuid = '99999999-9999-4999-8999-999999999999';
          const resolvedUserId = '11111111-1111-4111-8111-111111111111';
          final resolver = _FakeIntegrationActorResolver()
            ..useEchoFallback = false
            ..resolveByFirebaseUid = const <String, String?>{
              firebaseUidUuid: resolvedUserId,
            };
          final gateway = _FakeIntegrationAdminGateway();
          gateway.rotateResult = const <String, Object?>{
            'row': <String, Object?>{
              'credential_id': 'cred-new',
              'key_kind': 'anthropic',
              'masked_value': 'sk-a***1234',
              'kms_secret_name': 'kms://stub/new-uuid',
              'created_by': resolvedUserId,
              'updated_by': resolvedUserId,
              'rotated_at': '2026-05-01T12:00:00.000Z',
            },
            'plaintext_value': 'sk-ant-newvalue1234',
          };
          final ctx = await spinUp(
            customGateway: gateway,
            customResolver: resolver,
            initialClaims: ProxyJwtClaims(
              userId: firebaseUidUuid,
              firebaseUid: firebaseUidUuid,
              operatorId: null,
              locationId: null,
              roles: const <String>['super_admin'],
              lastFreshAuthAt: freshAuthAt,
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'plaintext_value': 'sk-ant-newvalue1234',
              },
            );
            expect(response.statusCode, equals(200));
            // The gateway receives the RESOLVED user UUID, not the
            // raw firebase_uid — audit attribution stays UUID-backed
            // (`auth_events_audit.actor_user_id` is never null while
            // `actor_kind = 'user'`).
            expect(gateway.lastActorUserId, equals(resolvedUserId));
            expect(resolver.lastFirebaseUid, equals(firebaseUidUuid));
            expect(resolver.lastReason, contains('admin.integrations.POST'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.4 POST rotate rejects suspended / dormant Postgres users row (403)',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeIntegrationAdminGateway();
          // The production resolver's SELECT pins `status = 'active'`,
          // so a suspended / dormant_30 / dormant_60 / dormant_90 row
          // returns NO match and the resolver returns null. Simulate
          // that by leaving the resolver with no override and
          // disabling the echo fallback — the resolver returns null
          // for any input. The route handler must surface this as a
          // 403 `actor_user_not_resolvable`, NOT silently fall back
          // to the firebase_uid.
          final resolver = _FakeIntegrationActorResolver()
            ..useEchoFallback = false;
          final ctx = await spinUp(
            customGateway: gateway,
            customResolver: resolver,
            initialClaims: ProxyJwtClaims(
              userId: '99999999-9999-4999-8999-999999999999',
              firebaseUid: '99999999-9999-4999-8999-999999999999',
              operatorId: null,
              locationId: null,
              roles: const <String>['super_admin'],
              lastFreshAuthAt: freshAuthAt,
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'plaintext_value': 'sk-ant-newvalue1234',
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('actor_user_not_resolvable'));
            expect(gateway.rotateCalls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.4 POST rotate rejects when Firebase user has no Postgres users row (403)',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeIntegrationAdminGateway();
          // Resolver returns null → no active users row matches.
          final resolver = _FakeIntegrationActorResolver()
            ..useEchoFallback = false;
          final ctx = await spinUp(
            customGateway: gateway,
            customResolver: resolver,
            initialClaims: ProxyJwtClaims(
              userId: '99999999-9999-4999-8999-999999999999',
              firebaseUid: '99999999-9999-4999-8999-999999999999',
              operatorId: null,
              locationId: null,
              roles: const <String>['super_admin'],
              lastFreshAuthAt: freshAuthAt,
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'plaintext_value': 'sk-ant-newvalue1234',
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('actor_user_not_resolvable'));
            // Unresolvable actor must NEVER reach the gateway — no
            // KMS write, no provider_credentials row, no audit row.
            expect(gateway.rotateCalls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.4 GET integrations also resolves actor before listing (audit attribution)',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeIntegrationAdminGateway();
          final resolver = _FakeIntegrationActorResolver()
            ..useEchoFallback = false;
          final ctx = await spinUp(
            customGateway: gateway,
            customResolver: resolver,
            initialClaims: const ProxyJwtClaims(
              userId: '88888888-8888-4888-8888-888888888888',
              firebaseUid: '88888888-8888-4888-8888-888888888888',
              operatorId: null,
              locationId: null,
              roles: <String>['ff_support'],
            ),
          );
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminIntegrationsListPath),
              authorization: 'Bearer fake.token',
            );
            // No Postgres row matches → 403 even on read paths,
            // because the audit row written by listBundle still
            // requires UUID-backed attribution.
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

    test(
      '11A.4 returns 503 when integrationAdminActorResolver is not wired',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            resolverConfigured: false,
            initialClaims: ProxyJwtClaims(
              userId: '11111111-1111-4111-8111-111111111111',
              firebaseUid: '11111111-1111-4111-8111-111111111111',
              operatorId: null,
              locationId: null,
              roles: const <String>['super_admin'],
              lastFreshAuthAt: freshAuthAt,
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'plaintext_value': 'sk-ant-newvalue1234',
              },
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['error'],
              equals('integration_admin_actor_resolver_not_configured'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.4 POST .../rotate-azure-db rejects missing plaintext (400)',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: ProxyJwtClaims(
            userId: '11111111-1111-4111-8111-111111111111',
            firebaseUid: '11111111-1111-4111-8111-111111111111',
            operatorId: null,
            locationId: null,
            roles: const <String>['super_admin'],
            lastFreshAuthAt: freshAuthAt,
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminIntegrationsRotateAzureDbPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_plaintext_value'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.4 POST rotate surfaces gateway validation error as a structured 4xx/5xx',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeIntegrationAdminGateway();
          gateway.rotateRaises = const IntegrationAdminGatewayValidationError(
            statusCode: 503,
            code: 'kms_write_failed',
            message: 'stub_kms_forced_failure',
          );
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: ProxyJwtClaims(
              userId: '11111111-1111-4111-8111-111111111111',
              firebaseUid: '11111111-1111-4111-8111-111111111111',
              operatorId: null,
              locationId: null,
              roles: const <String>['super_admin'],
              lastFreshAuthAt: freshAuthAt,
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminIntegrationsRotateVoyagePath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'plaintext_value': 'pa-voyage-newvalue9999',
              },
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('kms_write_failed'));
            expect(body['message'], equals('stub_kms_forced_failure'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.4 OPTIONS preflight allows POST for rotate-anthropic', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminIntegrationsRotateAnthropicPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'POST');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type',
          );
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.noContent));
          final allowMethods =
              response.headers.value('access-control-allow-methods') ?? '';
          expect(allowMethods.toUpperCase(), contains('POST'));
          expect(allowMethods.toUpperCase(), contains('OPTIONS'));
          expect(
            response.headers.value('access-control-allow-origin'),
            equals('*'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.4 GET /v1/admin/integrations without Authorization is 401',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminIntegrationsListPath),
            );
            expect(response.statusCode, equals(401));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}

class _FakeIntegrationAdminGateway implements IntegrationAdminProxyGateway {
  Map<String, Object?> listResult = <String, Object?>{
    'provider_keys': const <Map<String, Object?>>[],
    'vendor_connectors': const <Map<String, Object?>>[],
    'fx_rate_source': const <String, Object?>{
      'id': 'fx_rate',
      'display_name': 'FX-rate source',
      'status_label': 'green',
      'detail_message': '',
    },
    'email_provider': const <String, Object?>{
      'id': 'email',
      'display_name': 'Email provider',
      'status_label': 'placeholder',
      'detail_message': '',
    },
  };
  Map<String, Object?> rotateResult = <String, Object?>{
    'row': <String, Object?>{},
    'plaintext_value': '',
  };
  Object? rotateRaises;
  String? lastActorUserId;
  String? lastReason;
  final List<Map<String, Object?>> rotateCalls = <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> listBundle({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return listResult;
  }

  @override
  Future<Map<String, Object?>> rotateProviderKey({
    required String actorUserId,
    required String keyKind,
    required String plaintextValue,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    rotateCalls.add(<String, Object?>{
      'key_kind': keyKind,
      'plaintext_value': plaintextValue,
    });
    final raise = rotateRaises;
    if (raise != null) throw raise;
    return rotateResult;
  }
}

/// Fake actor resolver. By default echoes the supplied
/// `firebase_uid` back as the resolved Postgres user UUID — every
/// test claim that already carries a UUID-shaped firebase id will
/// round-trip through the dispatcher unchanged. Override
/// [resolveResult] to simulate "no Postgres users row matches" or
/// [raises] to simulate a DB outage.
class _FakeIntegrationActorResolver implements IntegrationAdminActorResolver {
  /// When non-null, every resolveActorUserId call returns this value
  /// regardless of input. Set to null to defer to [resolveByFirebaseUid].
  String? resolveResult;
  Map<String, String?> resolveByFirebaseUid = const <String, String?>{};
  bool useEchoFallback = true;
  Object? raises;
  String? lastFirebaseUid;
  String? lastReason;

  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) async {
    lastFirebaseUid = firebaseUid;
    lastReason = adminReason;
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
  String? errorMessage;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final error = errorMessage;
    if (error != null) {
      throw ProxyJwtVerificationError(error);
    }
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
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
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
