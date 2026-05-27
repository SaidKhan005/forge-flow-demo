// Graph G5a -- Proxy POST /v1/admin/age/rebuild route tests.
//
// These tests are MOCKED ONLY. They inject a fake [AgeRebuildGateway]
// (no real Postgres, no real Apache AGE, no provider/LLM call, no paid
// AI) and exercise the route through `routeRequest` against a stub JWT
// verifier. The production projection is exercised separately at deploy
// time (OP-GATED); nothing here opens a database.
//
// Coverage (the slice contract):
//   * null gateway  -> the historical 501 not_implemented is preserved
//     byte-compatibly (existing tests must stay green).
//   * non-super_admin (ff_support) -> 403 permission_denied, gateway not
//     reached.
//   * missing Idempotency-Key -> 400 missing_idempotency_key.
//   * successful rebuild -> 200 with projection counts.
//   * HP#4 -> the gateway receives operator/location scope from the
//     VERIFIED JWT, never the request body (a body that names a
//     different operator is ignored).
//   * re-run convergence -> a replayed Idempotency-Key returns the same
//     payload and the (replay-aware) gateway projects once.
//   * un-scoped token -> 400 operator_scope_required (scope cannot come
//     from the body).
//
// Mirrors the harness in
// `test/services/proxy_graph_candidates_routes_test.dart`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
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
      _StubVerifier verifier,
      _FakeAgeRebuildGateway gateway,
    })
  > spinUp({
    ProxyJwtClaims? initialClaims,
    bool gatewayConfigured = true,
    _FakeAgeRebuildGateway? customGateway,
  }) async {
    final verifier = _StubVerifier();
    verifier.claims = initialClaims;
    final guard = ProxyRequestGuard(verifier: verifier);
    final gateway = customGateway ?? _FakeAgeRebuildGateway();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        await routeRequest(
          request,
          guard,
          ageRebuildGateway: gatewayConfigured ? gateway : null,
          now: () => DateTime.utc(2026, 5, 27, 12),
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
    return (
      server: server,
      client: client,
      baseUri: baseUri,
      verifier: verifier,
      gateway: gateway,
    );
  }

  test(
    'POST /v1/admin/age/rebuild with NO gateway preserves the historical '
    '501 not_implemented (byte-compatible)',
    () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          gatewayConfigured: false,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            operatorId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            locationId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-stub-1',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(501));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('not_implemented'));
          expect(body['message'], isA<String>());
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/age/rebuild as ff_support returns 403 permission_denied '
    'and never reaches the gateway',
    () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: 'user_support',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-403',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(body['required_roles'], contains('super_admin'));
          expect(
            ctx.gateway.invocationCount,
            equals(0),
            reason: 'role gate must short-circuit before the gateway call',
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/age/rebuild without Idempotency-Key returns 400',
    () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            operatorId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            locationId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            // intentionally omit Idempotency-Key
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_idempotency_key'));
          expect(ctx.gateway.invocationCount, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/age/rebuild as super_admin returns 200 with projection '
    'counts',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeAgeRebuildGateway();
        gateway.result = const AgeRebuildResult(
          nodesProjected: 7,
          edgesProjected: 4,
          nodesDeleted: 7,
          ageAvailable: true,
        );
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            operatorId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            locationId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-200',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['nodes_projected'], equals(7));
          expect(body['edges_projected'], equals(4));
          expect(body['nodes_deleted'], equals(7));
          expect(body['age_available'], isTrue);
          expect(body['graph_name'], equals('forgeflow'));
          // HP#9: the route states there is no AI cost to meter.
          expect(body['ai_cost_metered'], isFalse);
          expect(gateway.invocationCount, equals(1));
          expect(gateway.lastIdempotencyKey, equals('rebuild-200'));
          expect(gateway.lastActorUserId, equals('user_super'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'HP#4 -- the gateway receives operator/location scope from the VERIFIED '
    'JWT, never the request body',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeAgeRebuildGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            // Verified-claims scope is op_jwt / loc_jwt.
            operatorId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            locationId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-hp4',
            // A hostile body naming a DIFFERENT operator/location. The
            // route must ignore these and use the JWT scope.
            body: const <String, Object?>{
              'operator_id': 'cccccccc-cccc-cccc-cccc-cccccccccccc',
              'location_id': 'dddddddd-dddd-dddd-dddd-dddddddddddd',
              'target_operator_id': 'cccccccc-cccc-cccc-cccc-cccccccccccc',
            },
          );
          expect(response.statusCode, equals(200));
          expect(
            gateway.lastOperatorId,
            equals('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
            reason: 'operator scope must come from the verified JWT, not the '
                'request body',
          );
          expect(
            gateway.lastLocationId,
            equals('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
            reason: 'location scope must come from the verified JWT, not the '
                'request body',
          );
          expect(
            gateway.lastOperatorId,
            isNot(equals('cccccccc-cccc-cccc-cccc-cccccccccccc')),
            reason: 'the body operator_id must be ignored',
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/age/rebuild with an un-scoped super_admin token returns '
    '400 operator_scope_required (scope is never read from the body)',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeAgeRebuildGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            // No operator scope on the token.
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-unscoped',
            // Even with a body naming an operator, the route refuses.
            body: const <String, Object?>{
              'operator_id': 'cccccccc-cccc-cccc-cccc-cccccccccccc',
              'location_id': 'dddddddd-dddd-dddd-dddd-dddddddddddd',
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('operator_scope_required'));
          expect(
            gateway.invocationCount,
            equals(0),
            reason: 'an un-scoped token must be refused before the gateway, '
                'and scope must never be sourced from the body',
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/age/rebuild replayed with the same Idempotency-Key '
    'returns the same payload and projects once (convergence)',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeAgeRebuildGateway();
        gateway.replayCacheEnabled = true;
        gateway.result = const AgeRebuildResult(
          nodesProjected: 3,
          edgesProjected: 2,
          nodesDeleted: 3,
          ageAvailable: true,
        );
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            operatorId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            locationId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final first = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-replay',
            body: const <String, Object?>{},
          );
          final second = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-replay',
            body: const <String, Object?>{},
          );
          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          expect(
            second.body,
            equals(first.body),
            reason: 'a replayed Idempotency-Key must return the same payload '
                'byte-for-byte',
          );
          expect(
            gateway.invocationCount,
            equals(1),
            reason: 'a re-run with the same key must converge: project once, '
                'replay the cached result',
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/age/rebuild surfaces age_available=false when the '
    'projection reports AGE missing',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeAgeRebuildGateway();
        gateway.result = const AgeRebuildResult(
          nodesProjected: 0,
          edgesProjected: 0,
          nodesDeleted: 0,
          ageAvailable: false,
        );
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            operatorId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            locationId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-noage',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['age_available'], isFalse);
          expect(body['nodes_projected'], equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );
}

class _StubVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final value = claims;
    if (value != null) return value;
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

/// Fake [AgeRebuildGateway] that records call inputs for assertions and
/// (optionally) returns a cached result on Idempotency-Key reuse so the
/// convergence test can verify the contract without a real cache or DB.
class _FakeAgeRebuildGateway implements AgeRebuildGateway {
  AgeRebuildResult result = const AgeRebuildResult(
    nodesProjected: 0,
    edgesProjected: 0,
    nodesDeleted: 0,
    ageAvailable: true,
  );

  bool replayCacheEnabled = false;
  final Map<String, AgeRebuildResult> _replayCache =
      <String, AgeRebuildResult>{};

  int invocationCount = 0;
  String? lastActorUserId;
  String? lastOperatorId;
  String? lastLocationId;
  String? lastIdempotencyKey;
  String? lastAdminReason;

  @override
  Future<AgeRebuildResult> rebuild({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    if (replayCacheEnabled) {
      final cached = _replayCache[idempotencyKey];
      if (cached != null) return cached;
    }
    lastActorUserId = actorUserId;
    lastOperatorId = operatorId;
    lastLocationId = locationId;
    lastIdempotencyKey = idempotencyKey;
    lastAdminReason = adminReason;
    invocationCount += 1;
    if (replayCacheEnabled) {
      _replayCache[idempotencyKey] = result;
    }
    return result;
  }
}

class _HttpResponseSnapshot {
  _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
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
