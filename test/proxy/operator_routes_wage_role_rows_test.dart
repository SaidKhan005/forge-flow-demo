// Phase 8 W5.A.1 — HTTP-level tests for the wage role rows write
// routes:
//
//   POST   /v1/operator/wage-role-rows
//   DELETE /v1/operator/wage-role-rows/:wage_role_row_id
//
// Coverage:
//   * 401 when bearer token is rejected.
//   * 403 when the actor lacks an operator-write role.
//   * 400 when Idempotency-Key is missing.
//   * 200 round-trip on POST + DELETE; gateway sees JWT-resolved
//     operator + location, never values from the URL or body.
//   * 200 idempotent replay (same key, same body) — gateway sees the
//     write exactly once.
//   * 409 idempotency_key_conflict (same key, different body).
//   * Cross-tenant: gateway always sees the JWT operator id.
//   * 400 on malformed body (invalid labor_bucket).
//   * 503 when the router is not configured.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/wage_role_row_record.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kLoc = '33333333-3333-3333-3333-333333333333';
const String _kUserA = '44444444-4444-4444-4444-444444444444';
const String _kUserB = '55555555-5555-5555-5555-555555555555';
const String _kRowId = '66666666-6666-6666-6666-666666666666';

void main() {
  group('wage role rows routes', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<({
      HttpServer server,
      HttpClient client,
      Uri baseUri,
      _RecordingWageGateway gateway,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
      bool routerConfigured = true,
      List<String> roles = const <String>['operator_owner'],
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims ??
          ProxyJwtClaims(
            userId: _kUserA,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: roles,
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = _RecordingWageGateway();
      final router = WageRoleRowsRouter(gateway: gateway);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            wageRoleRowsRouter: routerConfigured ? router : null,
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
        gateway: gateway,
      );
    }

    test('POST 401 when bearer token is rejected', () async {
      await withRealHttp(() async {
        final verifier = _SettableVerifier();
        verifier.error = ProxyJwtVerificationError('rejected');
        final guard = ProxyRequestGuard(verifier: verifier);
        final gateway = _RecordingWageGateway();
        final router = WageRoleRowsRouter(gateway: gateway);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        // ignore: unawaited_futures
        server.listen((request) async {
          await routeRequest(request, guard, wageRoleRowsRouter: router);
        });
        final client = HttpClient();
        try {
          final response = await _http(
            client,
            Uri.parse('http://${server.address.host}:${server.port}')
                .resolve(wageRoleRowsPath),
            method: 'POST',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-401',
            body: const <String, Object?>{
              'restaurant_id': 'rest-1',
              'role_name': 'Server',
              'labor_bucket': 'foh',
              'hourly_rate': 18.5,
              'weighted_hours': 30.0,
            },
          );
          expect(response.statusCode, anyOf(401, 403));
        } finally {
          client.close(force: true);
          await server.close(force: true);
        }
      });
    });

    test(
      'POST 403 when actor lacks operator-write role (e.g., manager '
      'without owner / admin)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(roles: const <String>['operator_member']);
          try {
            final response = await _http(
              ctx.client,
              ctx.baseUri.resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-403',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
              },
            );
            expect(response.statusCode, equals(403));
            expect(ctx.gateway.upsertCalls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('POST 400 when Idempotency-Key is missing', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(wageRoleRowsPath),
            method: 'POST',
            authorization: 'Bearer fake.token',
            idempotencyKey: null,
            body: const <String, Object?>{
              'restaurant_id': 'rest-1',
              'role_name': 'Server',
              'labor_bucket': 'foh',
              'hourly_rate': 18.5,
              'weighted_hours': 30.0,
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_missing'));
          expect(ctx.gateway.upsertCalls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'POST round-trips and forwards JWT operator + location to the '
      'gateway (not URL / body)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _http(
              ctx.client,
              ctx.baseUri.resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-001',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
                'source': 'operator_manual',
              },
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['server_id'], equals(_kRowId));
            expect(body['restaurant_id'], equals('rest-1'));
            expect(body['role_name'], equals('Server'));
            expect(body['labor_bucket'], equals('foh'));
            expect(body['source'], equals('operator_manual'));
            expect(ctx.gateway.upsertCalls, hasLength(1));
            expect(
              ctx.gateway.upsertCalls.single['operatorId'],
              equals(_kOpA),
            );
            expect(
              ctx.gateway.upsertCalls.single['locationId'],
              equals(_kLoc),
            );
            expect(
              ctx.gateway.upsertCalls.single['actorUserId'],
              equals(_kUserA),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST idempotent replay returns the cached response — gateway '
      'saw the call exactly once',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final first = await _http(
              ctx.client,
              ctx.baseUri.resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-replay',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
              },
            );
            final second = await _http(
              ctx.client,
              ctx.baseUri.resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-replay',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
              },
            );
            expect(first.statusCode, equals(200));
            expect(second.statusCode, equals(200));
            expect(first.body, equals(second.body));
            expect(ctx.gateway.upsertCalls, hasLength(1));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST 409 idempotency_key_conflict when same key + different body',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            await _http(
              ctx.client,
              ctx.baseUri.resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-collide',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
              },
            );
            final second = await _http(
              ctx.client,
              ctx.baseUri.resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-collide',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'boh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
              },
            );
            expect(second.statusCode, equals(409));
            final body = jsonDecode(second.body) as Map<String, Object?>;
            expect(body['error'], equals('idempotency_key_conflict'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'cross-tenant: gateway always sees the JWT operator id, never '
      'a value smuggled in via URL or body',
      () async {
        await withRealHttp(() async {
          final verifier = _SettableVerifier();
          final gateway = _RecordingWageGateway();
          final guard = ProxyRequestGuard(verifier: verifier);
          final router = WageRoleRowsRouter(gateway: gateway);
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          // ignore: unawaited_futures
          server.listen((request) async {
            await routeRequest(request, guard, wageRoleRowsRouter: router);
          });
          final client = HttpClient();
          try {
            // Operator A.
            verifier.claims = const ProxyJwtClaims(
              userId: _kUserA,
              operatorId: _kOpA,
              locationId: _kLoc,
              roles: <String>['operator_owner'],
            );
            await _http(
              client,
              Uri.parse('http://${server.address.host}:${server.port}')
                  .resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-a',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
                // Hostile payload claiming to be operator B — must be
                // ignored, the JWT wins.
                'operator_id': _kOpB,
              },
            );
            // Operator B.
            verifier.claims = const ProxyJwtClaims(
              userId: _kUserB,
              operatorId: _kOpB,
              locationId: _kLoc,
              roles: <String>['operator_owner'],
            );
            await _http(
              client,
              Uri.parse('http://${server.address.host}:${server.port}')
                  .resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-b',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
              },
            );
            expect(gateway.upsertCalls, hasLength(2));
            expect(gateway.upsertCalls[0]['operatorId'], equals(_kOpA));
            expect(gateway.upsertCalls[0]['actorUserId'], equals(_kUserA));
            expect(gateway.upsertCalls[1]['operatorId'], equals(_kOpB));
            expect(gateway.upsertCalls[1]['actorUserId'], equals(_kUserB));
          } finally {
            client.close(force: true);
            await server.close(force: true);
          }
        });
      },
    );

    test('POST 400 invalid_labor_bucket on unsupported bucket', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(wageRoleRowsPath),
            method: 'POST',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-bad-bucket',
            body: const <String, Object?>{
              'restaurant_id': 'rest-1',
              'role_name': 'Server',
              'labor_bucket': 'mascot',
              'hourly_rate': 18.5,
              'weighted_hours': 30.0,
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_labor_bucket'));
          expect(ctx.gateway.upsertCalls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'POST 400 missing_restaurant_id when required field is absent',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _http(
              ctx.client,
              ctx.baseUri.resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-missing',
              body: const <String, Object?>{
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('missing_restaurant_id'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'DELETE soft-deletes by UUID and returns removed=true; gateway '
      'sees JWT operator + location',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            ctx.gateway.softDeleteAffected = true;
            final response = await _http(
              ctx.client,
              ctx.baseUri.resolve('$wageRoleRowsPrefix$_kRowId'),
              method: 'DELETE',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-del',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['removed'], isTrue);
            expect(body['wage_role_row_id'], equals(_kRowId));
            expect(ctx.gateway.softDeleteCalls, hasLength(1));
            expect(
              ctx.gateway.softDeleteCalls.single['operatorId'],
              equals(_kOpA),
            );
            expect(
              ctx.gateway.softDeleteCalls.single['locationId'],
              equals(_kLoc),
            );
            expect(
              ctx.gateway.softDeleteCalls.single['wageRoleRowId'],
              equals(_kRowId),
            );
            expect(
              ctx.gateway.softDeleteCalls.single['actorUserId'],
              equals(_kUserA),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('DELETE 400 invalid_wage_role_row_id when path is not a UUID',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve('${wageRoleRowsPrefix}not-a-uuid'),
            method: 'DELETE',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-bad-id',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_wage_role_row_id'));
          expect(ctx.gateway.softDeleteCalls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when router is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(routerConfigured: false);
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(wageRoleRowsPath),
            method: 'POST',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-503',
            body: const <String, Object?>{
              'restaurant_id': 'rest-1',
              'role_name': 'Server',
              'labor_bucket': 'foh',
              'hourly_rate': 18.5,
              'weighted_hours': 30.0,
            },
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            body['error'],
            equals('wage_role_rows_router_not_configured'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;
  Object? error;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final err = error;
    if (err != null) throw err;
    final c = claims;
    if (c == null) {
      throw ProxyJwtVerificationError('no claims set');
    }
    return c;
  }
}

class _RecordingWageGateway implements WageRoleRowsGateway {
  bool softDeleteAffected = true;
  final List<Map<String, Object?>> upsertCalls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> softDeleteCalls = <Map<String, Object?>>[];

  @override
  Future<WageRoleRowRecord> upsert({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String roleName,
    required String laborBucket,
    required double hourlyRate,
    required double weightedHours,
    String? jobCode,
    String? vendorId,
    String? vendorRoleId,
    WageRoleRowSource source = WageRoleRowSource.operatorManual,
    bool isActive = true,
    Map<String, Object?> metadata = const <String, Object?>{},
    String? actorUserId,
  }) async {
    upsertCalls.add(<String, Object?>{
      'operatorId': operatorId,
      'locationId': locationId,
      'restaurantId': restaurantId,
      'roleName': roleName,
      'laborBucket': laborBucket,
      'hourlyRate': hourlyRate,
      'weightedHours': weightedHours,
      'jobCode': jobCode,
      'vendorId': vendorId,
      'vendorRoleId': vendorRoleId,
      'source': source.wire,
      'isActive': isActive,
      'metadata': metadata,
      'actorUserId': actorUserId,
    });
    return WageRoleRowRecord(
      wageRoleRowId: _kRowId,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      roleName: roleName,
      laborBucket: laborBucket,
      hourlyRate: hourlyRate,
      weightedHours: weightedHours,
      jobCode: jobCode,
      vendorId: vendorId,
      vendorRoleId: vendorRoleId,
      source: source,
      isActive: isActive,
      effectiveAt: DateTime.utc(2026, 5, 7, 12),
      metadata: metadata,
      createdAt: DateTime.utc(2026, 5, 7, 12),
      updatedAt: DateTime.utc(2026, 5, 7, 12),
      updatedBy: actorUserId,
    );
  }

  @override
  Future<bool> softDelete({
    required String operatorId,
    required String locationId,
    required String wageRoleRowId,
    String? actorUserId,
  }) async {
    softDeleteCalls.add(<String, Object?>{
      'operatorId': operatorId,
      'locationId': locationId,
      'wageRoleRowId': wageRoleRowId,
      'actorUserId': actorUserId,
    });
    return softDeleteAffected;
  }
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _http(
  HttpClient client,
  Uri uri, {
  required String method,
  required String authorization,
  String? idempotencyKey,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
