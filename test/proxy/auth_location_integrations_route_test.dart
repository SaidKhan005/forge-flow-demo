// Phase 8 — operator-self-service vendor connections list (real
// projection wiring). Validates that
// `GET /v1/auth/locations/{location_id}/integrations` returns the
// connector_connection projection emitted by the bound projection
// closure (production wiring: ConnectorConnectionListRepository).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_connection_list_repository.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const _operatorOrigin = 'https://forge-flow-operator-web.test';

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

OperatorLocationIntegrationsProjection _projectionFor(
  ConnectorConnectionListBundle bundle,
) {
  return ({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    return buildOperatorLocationIntegrationsBundleJson(bundle);
  };
}

OperatorLocationIntegrationsProjection _failingProjection() {
  return ({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    // A3.3 (bb88f82b) narrowed the catch site at advisor_proxy.dart from
    // `catch (_)` to `on Exception catch (_)`. StateError extends Error so
    // escapes uncaught; use Exception to exercise the swallow-and-project-
    // false path (503 + integrations_projection_unavailable).
    throw Exception('boom');
  };
}

Future<({HttpServer server, HttpClient client, Uri baseUri})> _spinUp({
  bool allowIntegrations = true,
  OperatorLocationIntegrationsProjection? projection,
  ProxyJwtClaims claims = const ProxyJwtClaims(
    userId: 'user-1',
    operatorId: 'op-1',
    locationId: 'loc-1',
    roles: <String>['operator_admin'],
  ),
  bool unauthenticated = false,
}) async {
  final guard = unauthenticated
      ? ProxyRequestGuard(verifier: const _RejectingVerifier())
      : ProxyRequestGuard(verifier: _StaticVerifier(claims));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    await routeRequest(
      request,
      guard,
      permissionSnapshotResolver: _StaticPermissionResolver(
        allowIntegrations: allowIntegrations,
      ),
      operatorLocationIntegrationsProjection: projection,
      adminCorsAllowList: const <String>[_operatorOrigin],
      now: () => DateTime.utc(2026, 5, 7, 12),
    );
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri);
}

ConnectorConnectionListRow _row({
  required String connectionId,
  required String vendorId,
  required IntegrationCategory category,
  String status = 'connected',
  String? module,
  Map<String, Object?> metadata = const <String, Object?>{},
  DateTime? lastSyncAt,
  String? disconnectReason,
  FirstBackfillStatus? firstBackfillStatus,
  DateTime? firstBackfillStartedAt,
  DateTime? firstBackfillCompletedAt,
  String? firstBackfillFailureReason,
  int? firstBackfillProcessedDays,
  int? firstBackfillTotalDays,
}) {
  return ConnectorConnectionListRow(
    connectionId: connectionId,
    vendorId: vendorId,
    category: category,
    status: status,
    metadata: metadata,
    module: module,
    lastSyncAt: lastSyncAt ?? DateTime.utc(2026, 5, 7, 11, 30),
    disconnectReason: disconnectReason,
    webhookUrlProvisioned: status == 'connected',
    createdAt: DateTime.utc(2026, 5, 7, 9),
    updatedAt: DateTime.utc(2026, 5, 7, 11, 30),
    firstBackfillStatus: firstBackfillStatus,
    firstBackfillStartedAt: firstBackfillStartedAt,
    firstBackfillCompletedAt: firstBackfillCompletedAt,
    firstBackfillFailureReason: firstBackfillFailureReason,
    firstBackfillProcessedDays: firstBackfillProcessedDays,
    firstBackfillTotalDays: firstBackfillTotalDays,
  );
}

void main() {
  test('returns empty connections list and demo_flags=true when no rows '
      'exist for the operator', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp(
        projection: _projectionFor(
          const ConnectorConnectionListBundle(
            operatorId: 'op-1',
            locationId: 'loc-1',
            rows: <ConnectorConnectionListRow>[],
          ),
        ),
      );
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-1/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.headers.set('Origin', _operatorOrigin);
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.ok);
        expect(body['operator_id'], 'op-1');
        expect(body['location_id'], 'loc-1');
        expect(body['connections'], isEmpty);
        final demoFlags = body['demo_flags']! as Map<String, Object?>;
        expect(demoFlags['pos'], isTrue);
        expect(demoFlags['labor'], isTrue);
        expect(demoFlags['reservation'], isTrue);
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('returns one POS + one labor row with correct category mapping and '
      'demo_flags reflecting only-reservation-still-demo', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp(
        projection: _projectionFor(
          ConnectorConnectionListBundle(
            operatorId: 'op-1',
            locationId: 'loc-1',
            rows: <ConnectorConnectionListRow>[
              _row(
                connectionId: 'cnx-1',
                vendorId: 'toast',
                category: IntegrationCategory.pos,
              ),
              _row(
                connectionId: 'cnx-2',
                vendorId: '7shifts',
                category: IntegrationCategory.labor,
              ),
            ],
          ),
        ),
      );
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-1/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.ok);
        final connections = body['connections']! as List<Object?>;
        expect(connections, hasLength(2));
        final pos = connections.firstWhere(
          (c) => (c! as Map<String, Object?>)['vendor_id'] == 'toast',
        )! as Map<String, Object?>;
        expect(pos['category'], 'pos');
        expect(pos['status'], 'connected');
        expect(pos['connection_id'], 'cnx-1');
        final labor = connections.firstWhere(
          (c) => (c! as Map<String, Object?>)['vendor_id'] == '7shifts',
        )! as Map<String, Object?>;
        expect(labor['category'], 'labor');
        expect(labor['status'], 'connected');

        final demoFlags = body['demo_flags']! as Map<String, Object?>;
        expect(demoFlags['pos'], isFalse);
        expect(demoFlags['labor'], isFalse);
        expect(demoFlags['reservation'], isTrue);
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('disconnected/error rows do not flip demo_flags off for their '
      'category — only a connected row counts', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp(
        projection: _projectionFor(
          ConnectorConnectionListBundle(
            operatorId: 'op-1',
            locationId: 'loc-1',
            rows: <ConnectorConnectionListRow>[
              _row(
                connectionId: 'cnx-error',
                vendorId: 'square',
                category: IntegrationCategory.pos,
                status: 'error',
                disconnectReason: 'oauth_timeout',
              ),
              _row(
                connectionId: 'cnx-disc',
                vendorId: 'opentable',
                category: IntegrationCategory.reservation,
                status: 'disconnected',
                disconnectReason: 'operator_action',
              ),
            ],
          ),
        ),
      );
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-1/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.ok);
        final demoFlags = body['demo_flags']! as Map<String, Object?>;
        expect(demoFlags['pos'], isTrue);
        expect(demoFlags['labor'], isTrue);
        expect(demoFlags['reservation'], isTrue);
        final connections = body['connections']! as List<Object?>;
        expect(connections, hasLength(2));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('rejects another operator location with location_scope_mismatch '
      'BEFORE invoking the projection (RLS guard)', () {
    var projectionCalls = 0;
    Future<Map<String, Object?>> countingProjection({
      required String operatorId,
      required String locationId,
      required String actorUserId,
    }) async {
      projectionCalls++;
      return buildOperatorLocationIntegrationsBundleJson(
        const ConnectorConnectionListBundle(
          operatorId: 'op-1',
          locationId: 'loc-1',
          rows: <ConnectorConnectionListRow>[],
        ),
      );
    }
    return _withRealHttp(() async {
      final ctx = await _spinUp(projection: countingProjection);
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-other/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.forbidden);
        expect(body['error'], 'location_scope_mismatch');
        expect(
          projectionCalls,
          0,
          reason:
              'projection must not run when the URL location does not match '
              'the verified scope',
        );
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('returns 401 when the bearer token is missing or invalid', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp(
        projection: _projectionFor(
          const ConnectorConnectionListBundle(
            operatorId: 'op-1',
            locationId: 'loc-1',
            rows: <ConnectorConnectionListRow>[],
          ),
        ),
        unauthenticated: true,
      );
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-1/integrations'),
        );
        request.headers.set('Authorization', 'Bearer bad');
        request.contentLength = 0;
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.unauthorized);
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('emits first_backfill JSON object on rows with backfill state and '
      'omits the field on legacy rows without one', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp(
        projection: _projectionFor(
          ConnectorConnectionListBundle(
            operatorId: 'op-1',
            locationId: 'loc-1',
            rows: <ConnectorConnectionListRow>[
              _row(
                connectionId: 'cnx-running',
                vendorId: 'toast',
                category: IntegrationCategory.pos,
                firstBackfillStatus: FirstBackfillStatus.running,
                firstBackfillStartedAt: DateTime.utc(2026, 5, 7, 11),
                firstBackfillProcessedDays: 12,
                firstBackfillTotalDays: 60,
              ),
              _row(
                connectionId: 'cnx-done',
                vendorId: 'humanity',
                category: IntegrationCategory.labor,
                firstBackfillStatus: FirstBackfillStatus.succeeded,
                firstBackfillStartedAt: DateTime.utc(2026, 5, 6, 22),
                firstBackfillCompletedAt: DateTime.utc(2026, 5, 6, 22, 22),
              ),
              _row(
                connectionId: 'cnx-failed',
                vendorId: 'square',
                category: IntegrationCategory.pos,
                firstBackfillStatus: FirstBackfillStatus.failed,
                firstBackfillFailureReason: 'token revoked mid-pull',
              ),
              _row(
                connectionId: 'cnx-dl',
                vendorId: 'opentable',
                category: IntegrationCategory.reservation,
                firstBackfillStatus: FirstBackfillStatus.deadLettered,
                firstBackfillFailureReason: 'attempts exhausted',
              ),
              _row(
                connectionId: 'cnx-legacy',
                vendorId: '7shifts',
                category: IntegrationCategory.labor,
                // No firstBackfillStatus — legacy connection row
                // predating the queue. Wire JSON must omit
                // `first_backfill` entirely.
              ),
            ],
          ),
        ),
      );
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-1/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.ok);
        final connections = body['connections']! as List<Object?>;
        expect(connections, hasLength(5));

        final running = connections.firstWhere(
          (c) => (c! as Map<String, Object?>)['vendor_id'] == 'toast',
        )! as Map<String, Object?>;
        expect(running.containsKey('first_backfill'), isTrue);
        final runningBackfill =
            running['first_backfill']! as Map<String, Object?>;
        expect(runningBackfill['status'], 'running');
        expect(runningBackfill['started_at'], '2026-05-07T11:00:00.000Z');
        expect(runningBackfill['completed_at'], isNull);
        expect(runningBackfill['failure_reason'], isNull);
        expect(runningBackfill['processed_days'], 12);
        expect(runningBackfill['total_days'], 60);

        final done = connections.firstWhere(
          (c) => (c! as Map<String, Object?>)['vendor_id'] == 'humanity',
        )! as Map<String, Object?>;
        final doneBackfill =
            done['first_backfill']! as Map<String, Object?>;
        expect(doneBackfill['status'], 'succeeded');
        expect(doneBackfill['completed_at'], '2026-05-06T22:22:00.000Z');

        final failed = connections.firstWhere(
          (c) => (c! as Map<String, Object?>)['vendor_id'] == 'square',
        )! as Map<String, Object?>;
        final failedBackfill =
            failed['first_backfill']! as Map<String, Object?>;
        expect(failedBackfill['status'], 'failed');
        expect(failedBackfill['failure_reason'], 'token revoked mid-pull');

        final dl = connections.firstWhere(
          (c) => (c! as Map<String, Object?>)['vendor_id'] == 'opentable',
        )! as Map<String, Object?>;
        final dlBackfill =
            dl['first_backfill']! as Map<String, Object?>;
        expect(dlBackfill['status'], 'dead_lettered');
        expect(dlBackfill['failure_reason'], 'attempts exhausted');

        final legacy = connections.firstWhere(
          (c) => (c! as Map<String, Object?>)['vendor_id'] == '7shifts',
        )! as Map<String, Object?>;
        expect(
          legacy.containsKey('first_backfill'),
          isFalse,
          reason: 'legacy rows without a job row must not emit '
              'first_backfill so the operator-web client renders no '
              'progress UI for them',
        );
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('returns 503 with integrations_projection_unavailable when the '
      'projection throws', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp(projection: _failingProjection());
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-1/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.serviceUnavailable);
        expect(body['error'], 'integrations_projection_unavailable');
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });
}

class _StaticVerifier implements ProxyJwtVerifier {
  const _StaticVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _RejectingVerifier implements ProxyJwtVerifier {
  const _RejectingVerifier();

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    throw ProxyAuthError('bad_token', statusCode: 401);
  }
}

class _StaticPermissionResolver implements ProxyPermissionSnapshotResolver {
  const _StaticPermissionResolver({required this.allowIntegrations});

  final bool allowIntegrations;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async {
    return ProxyPermissionSnapshot(
      userId: scope.userId,
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      rolesVersion: 1,
      evaluatedAt: DateTime.utc(2026, 5, 7, 12),
      permissions: <String, PermissionEffect>{
        PermissionKeys.integrationToastView: allowIntegrations
            ? PermissionEffect.allow
            : PermissionEffect.deny,
      },
    );
  }
}
