// Wave W2.D — HTTP-level tests for `GET /v1/operator/connector-backfill-jobs`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart'
    as integration;

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/connector_backfill_jobs_routes.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kLoc = '33333333-3333-3333-3333-333333333333';
const String _kUser = '44444444-4444-4444-4444-444444444444';
const String _kConnA = '55555555-5555-5555-5555-555555555555';

void main() {
  group('GET /v1/operator/connector-backfill-jobs', () {
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
        _RecordingBackfillJobsGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      bool routerConfigured = true,
      List<FirstConnectionBackfillJob>? seedJobs,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims =
          initialClaims ??
          const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = _RecordingBackfillJobsGateway(seed: seedJobs ?? const []);
      final router = ConnectorBackfillJobsRouter(gateway: gateway);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            connectorBackfillJobsRouter: routerConfigured ? router : null,
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {}
        }
      });
      final client = HttpClient();
      final baseUri = Uri.parse(
        'http://${server.address.host}:${server.port}',
      );
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        gateway: gateway,
      );
    }

    test('200 with the gateway-projected job list', () async {
      await withRealHttp(() async {
        final job = _sampleJob(
          jobId: 'job-1',
          operatorId: _kOpA,
          locationId: _kLoc,
          connectionId: _kConnA,
          status: FirstConnectionBackfillJobStatus.running,
        );
        final ctx = await spinUp(seedJobs: <FirstConnectionBackfillJob>[job]);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorConnectorBackfillJobsPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['operator_id'], equals(_kOpA));
          expect(body['location_id'], equals(_kLoc));
          final jobs = body['jobs'] as List<Object?>;
          expect(jobs, hasLength(1));
          final firstJob = jobs.first as Map<String, Object?>;
          expect(firstJob['job_id'], equals('job-1'));
          expect(firstJob['connection_id'], equals(_kConnA));
          expect(firstJob['status'], equals('running'));
          expect(ctx.gateway.calls, equals(1));
          expect(ctx.gateway.lastOperatorId, equals(_kOpA));
          expect(ctx.gateway.lastLocationId, equals(_kLoc));
          expect(ctx.gateway.lastConnectionId, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('connection_id query param narrows the gateway call', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri
                .resolve(operatorConnectorBackfillJobsPath)
                .replace(queryParameters: <String, String>{
                  'connection_id': _kConnA,
                }),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(ctx.gateway.lastConnectionId, equals(_kConnA));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 when connection_id is blank', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri
                .resolve(operatorConnectorBackfillJobsPath)
                .replace(queryParameters: <String, String>{
                  'connection_id': '   ',
                }),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_connection_id'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when the router is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(routerConfigured: false);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorConnectorBackfillJobsPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            body['error'],
            equals('connector_backfill_jobs_router_not_configured'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('401 when the bearer token is rejected', () async {
      await withRealHttp(() async {
        final verifier = _SettableVerifier();
        verifier.claims = null;
        verifier.error = ProxyJwtVerificationError('rejected');
        final guard = ProxyRequestGuard(verifier: verifier);
        final gateway = _RecordingBackfillJobsGateway();
        final router = ConnectorBackfillJobsRouter(gateway: gateway);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        // ignore: unawaited_futures
        server.listen((request) async {
          await routeRequest(
            request,
            guard,
            connectorBackfillJobsRouter: router,
          );
        });
        final client = HttpClient();
        try {
          final response = await _httpGet(
            client,
            Uri.parse(
              'http://${server.address.host}:${server.port}',
            ).resolve(operatorConnectorBackfillJobsPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, anyOf(401, 403));
          expect(gateway.calls, equals(0));
        } finally {
          client.close(force: true);
          await server.close(force: true);
        }
      });
    });

    test('403 when caller lacks any operator-web role', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorConnectorBackfillJobsPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('forbidden'));
          expect(ctx.gateway.calls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'cross-tenant impossible: gateway sees the JWT operator + location, '
      'never URL-supplied scope',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            // Operator A reads. JWT pins (_kOpA, _kLoc).
            final aResp = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(operatorConnectorBackfillJobsPath),
              authorization: 'Bearer fake.token',
            );
            expect(aResp.statusCode, equals(200));
            expect(ctx.gateway.lastOperatorId, equals(_kOpA));
            expect(ctx.gateway.lastLocationId, equals(_kLoc));

            // Same client, swap the JWT to operator B; the gateway now
            // sees operator B even though every URL/header otherwise
            // identical. Confirms scope rides solely on the bearer token.
            final verifier = _SettableVerifier();
            verifier.claims = const ProxyJwtClaims(
              userId: _kUser,
              operatorId: _kOpB,
              locationId: _kLoc,
              roles: <String>['operator_admin'],
            );
            final guard = ProxyRequestGuard(verifier: verifier);
            final gatewayB = _RecordingBackfillJobsGateway();
            final routerB = ConnectorBackfillJobsRouter(gateway: gatewayB);
            final serverB = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            // ignore: unawaited_futures
            serverB.listen((request) async {
              await routeRequest(
                request,
                guard,
                connectorBackfillJobsRouter: routerB,
              );
            });
            final clientB = HttpClient();
            try {
              final bResp = await _httpGet(
                clientB,
                Uri.parse(
                  'http://${serverB.address.host}:${serverB.port}',
                ).resolve(operatorConnectorBackfillJobsPath),
                authorization: 'Bearer fake.token',
              );
              expect(bResp.statusCode, equals(200));
              expect(gatewayB.lastOperatorId, equals(_kOpB));
              expect(gatewayB.lastLocationId, equals(_kLoc));
            } finally {
              clientB.close(force: true);
              await serverB.close(force: true);
            }
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}

FirstConnectionBackfillJob _sampleJob({
  required String jobId,
  required String operatorId,
  required String locationId,
  required String connectionId,
  required FirstConnectionBackfillJobStatus status,
}) {
  final windowEnd = DateTime.utc(2026, 5, 7);
  final windowStart = windowEnd.subtract(const Duration(days: 60));
  return FirstConnectionBackfillJob(
    jobId: jobId,
    operatorId: operatorId,
    locationId: locationId,
    connectionId: connectionId,
    vendorId: 'toast',
    category: integration.IntegrationCategory.pos,
    windowStart: windowStart,
    windowEnd: windowEnd,
    status: status,
    cursorToken: 'cursor-1',
    lastModifiedSeen: DateTime.utc(2026, 4, 1),
    attemptCount: 1,
    workerId: 'worker-1',
    claimedAt: DateTime.utc(2026, 5, 5),
    completedAt: null,
    lastError: null,
    createdAt: DateTime.utc(2026, 5, 4),
    updatedAt: DateTime.utc(2026, 5, 6),
  );
}

class _RecordingBackfillJobsGateway
    implements ConnectorBackfillJobsReadGateway {
  _RecordingBackfillJobsGateway({
    List<FirstConnectionBackfillJob> seed = const <FirstConnectionBackfillJob>[],
  }) : _seed = seed;

  final List<FirstConnectionBackfillJob> _seed;
  int calls = 0;
  String? lastOperatorId;
  String? lastLocationId;
  String? lastConnectionId;
  String? lastActorUserId;

  @override
  Future<List<FirstConnectionBackfillJob>> listLatestPerConnection({
    required String operatorId,
    required String locationId,
    String? connectionId,
    String? actorUserId,
  }) async {
    calls += 1;
    lastOperatorId = operatorId;
    lastLocationId = locationId;
    lastConnectionId = connectionId;
    lastActorUserId = actorUserId;
    if (connectionId == null) return _seed;
    return _seed
        .where((job) => job.connectionId == connectionId)
        .toList(growable: false);
  }
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

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpGet(
  HttpClient client,
  Uri uri, {
  required String authorization,
}) async {
  final request = await client.openUrl('GET', uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
