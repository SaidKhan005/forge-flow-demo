// Lane B B8.b — operator_web_audit_log_hierarchy_routes proxy tests.
//
// Pins the contract for:
//
//   GET /v1/auth/audit-log/hierarchy
//
// Covers:
//   * 401 on missing / unverified bearer token (auth resolver returns
//     `unauthorized`).
//   * 401 when the auth resolver throws unexpectedly.
//   * 403 on missing `team.audit_log.view` permission.
//   * 503 when the permission snapshot read fails.
//   * 400 on `operator_id` / `location_id` query param injection
//     attempts (the JWT pins tenant scope; route refuses overrides).
//   * 400 on missing scope ids / malformed uuids / bad time formats /
//     limit / action / actor_user_id shape.
//   * 200 on operator_wide / org_unit / location scope branches.
//   * Tenant scope: the gateway is called with operator_id /
//     location_id from the verified JWT.
//   * 503 envelope when the gateway throws.
//   * Latency recorder hook fires on 2xx with the distinct-location
//     count from the result page.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';

import '../../tool/advisor_proxy/operator_web_audit_log_hierarchy_routes.dart';

void main() {
  group('OperatorWebAuditLogHierarchyRouter.tryHandle', () {
    test('returns false for unrelated path', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/admin/health',
      );
      expect(result.handled, isFalse);
    });

    test('returns false for non-GET method on matching path', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'POST',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.handled, isFalse);
    });

    test('401 when auth resolver returns unauthorized', () async {
      final result = await _captureRequest(
        router: OperatorWebAuditLogHierarchyRouter(
          gateway: _RecordingGateway(),
          authResolver: (_) async =>
              const OperatorWebAuditLogHierarchyAuthResult.unauthorized(),
        ),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 401);
      expect(result.bodyJson['error'], 'unauthorized');
    });

    test('401 when auth resolver throws', () async {
      final result = await _captureRequest(
        router: OperatorWebAuditLogHierarchyRouter(
          gateway: _RecordingGateway(),
          authResolver: (_) async => throw StateError('boom'),
        ),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 401);
      expect(result.bodyJson['error'], 'unauthorized');
    });

    test('403 when permission gate denies', () async {
      final result = await _captureRequest(
        router: OperatorWebAuditLogHierarchyRouter(
          gateway: _RecordingGateway(),
          authResolver: (_) async =>
              const OperatorWebAuditLogHierarchyAuthResult.forbidden(),
        ),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 403);
      expect(result.bodyJson['error'], 'permission_denied');
    });

    test('503 when permission snapshot read fails', () async {
      final result = await _captureRequest(
        router: OperatorWebAuditLogHierarchyRouter(
          gateway: _RecordingGateway(),
          authResolver: (_) async =>
              const OperatorWebAuditLogHierarchyAuthResult.unavailable(),
        ),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 503);
      expect(result.bodyJson['error'], 'permission_snapshot_unavailable');
    });

    test('400 when client supplies operator_id query param', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/auth/audit-log/hierarchy?operator_id=11111111-1111-1111-1111-111111111111',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'scope_param_forbidden');
    });

    test('400 when client supplies location_id query param', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/auth/audit-log/hierarchy?location_id=11111111-1111-1111-1111-111111111111',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'scope_param_forbidden');
    });

    test('400 when scope=org_unit but org_unit_id missing', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?scope_type=org_unit',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'missing_org_unit_id');
    });

    test('400 when scope=location but location_filter missing', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?scope_type=location',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'missing_location_filter');
    });

    test('400 when org_unit_id is not a uuid', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/auth/audit-log/hierarchy?scope_type=org_unit&org_unit_id=not-a-uuid',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_org_unit_id');
    });

    test('400 when location_filter is not a uuid', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/auth/audit-log/hierarchy?scope_type=location&location_filter=bad',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_location_filter');
    });

    test('400 when from is not parseable', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?from=not-a-date',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_from');
    });

    test('400 when to is not parseable', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?to=not-a-date',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_to');
    });

    test('400 when from > to', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/auth/audit-log/hierarchy?from=2026-05-13T00:00:00Z&to=2026-05-12T00:00:00Z',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_range');
    });

    test('400 when limit is non-numeric', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?limit=abc',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_limit');
    });

    test('400 when action exceeds 200 chars', () async {
      final longAction = 'a' * 201;
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?action=$longAction',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_action');
    });

    test('400 when actor_user_id is malformed', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?actor_user_id=not-a-uuid',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_actor_user_id');
    });

    test('400 when before_id is negative', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?before_id=-1',
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_before_id');
    });

    test('200 on operator_wide happy path', () async {
      final gateway = _RecordingGateway()
        ..seedRows(<AuditLogRow>[
          _makeRow(id: '42', operatorId: 'op-1', locationId: 'loc-1'),
        ]);
      final result = await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 200);
      final body = result.bodyJson;
      expect((body['rows'] as List).length, 1);
      expect(gateway.calls.length, 1);
      expect(gateway.calls.first.operatorId, 'op-1');
      expect(gateway.calls.first.locationId, 'loc-1');
      expect(gateway.calls.first.scopeType,
          AuditLogHierarchyScope.operatorWide);
    });

    test('200 on org_unit scope branch', () async {
      final orgUnitId = '11111111-1111-1111-1111-111111111111';
      final gateway = _RecordingGateway();
      final result = await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path:
            '/v1/auth/audit-log/hierarchy?scope_type=org_unit&org_unit_id=$orgUnitId',
      );
      expect(result.statusCode, 200);
      expect(gateway.calls.first.scopeType,
          AuditLogHierarchyScope.orgUnit);
      expect(gateway.calls.first.orgUnitId, orgUnitId);
    });

    test('200 on location scope branch', () async {
      final locationFilter = '22222222-2222-2222-2222-222222222222';
      final gateway = _RecordingGateway();
      final result = await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path:
            '/v1/auth/audit-log/hierarchy?scope_type=location&location_filter=$locationFilter',
      );
      expect(result.statusCode, 200);
      expect(gateway.calls.first.scopeType,
          AuditLogHierarchyScope.location);
      expect(gateway.calls.first.locationFilter, locationFilter);
    });

    test('tenant scope: gateway sees JWT operator/location', () async {
      final gateway = _RecordingGateway();
      await _captureRequest(
        router: _buildRouter(
          gateway: gateway,
          operatorId: 'op-from-jwt',
          locationId: 'loc-from-jwt',
        ),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(gateway.calls.first.operatorId, 'op-from-jwt');
      expect(gateway.calls.first.locationId, 'loc-from-jwt');
    });

    test('503 when gateway throws', () async {
      final gateway = _RecordingGateway()..failNext = StateError('db down');
      final result = await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.statusCode, 503);
      expect(result.bodyJson['error'], 'audit_log_hierarchy_unavailable');
    });

    test('latency recorder fires with distinct-location count', () async {
      final samples = <Map<String, Object?>>[];
      final gateway = _RecordingGateway()
        ..seedRows(<AuditLogRow>[
          _makeRow(id: '1', operatorId: 'op-1', locationId: 'loc-a'),
          _makeRow(id: '2', operatorId: 'op-1', locationId: 'loc-b'),
          _makeRow(id: '3', operatorId: 'op-1', locationId: 'loc-a'),
        ]);
      final router = OperatorWebAuditLogHierarchyRouter(
        gateway: gateway,
        authResolver: (_) async =>
            OperatorWebAuditLogHierarchyAuthResult.allow(
          const OperatorWebAuditLogHierarchyActor(
            actorUserId: 'user-1',
            actorOperatorId: 'op-1',
            actorLocationId: 'loc-1',
          ),
        ),
        latencyRecorder: ({
          required String operatorId,
          required int locationCount,
          required Duration elapsed,
        }) {
          samples.add(<String, Object?>{
            'operator_id': operatorId,
            'location_count': locationCount,
          });
        },
      );
      final result = await _captureRequest(
        router: router,
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.statusCode, 200);
      expect(samples, hasLength(1));
      expect(samples.first['operator_id'], 'op-1');
      expect(samples.first['location_count'], 2);
    });

    test('limit clamps to 200', () async {
      final gateway = _RecordingGateway();
      await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?limit=1000',
      );
      expect(gateway.calls.first.limit, AuditLogsReader.maxLimit);
    });

    test('before_id is forwarded to the gateway', () async {
      final gateway = _RecordingGateway();
      await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy?before_id=42',
      );
      expect(gateway.calls.first.beforeId, 42);
    });

    test('user_id is set to JWT actor on gateway call', () async {
      final gateway = _RecordingGateway();
      await _captureRequest(
        router: _buildRouter(
          gateway: gateway,
          actorUserId: 'verified-user-1',
        ),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(gateway.calls.first.userId, 'verified-user-1');
    });

    test(
        'response envelope carries scope echo with operator + location ids '
        'from JWT', () async {
      final result = await _captureRequest(
        router: _buildRouter(
          operatorId: 'op-echo',
          locationId: 'loc-echo',
        ),
        method: 'GET',
        path: '/v1/auth/audit-log/hierarchy',
      );
      expect(result.statusCode, 200);
      final scope = result.bodyJson['scope'] as Map<String, Object?>;
      expect(scope['operator_id'], 'op-echo');
      expect(scope['location_id'], 'loc-echo');
      expect(scope['scope_type'], 'operator_wide');
    });
  });
}

// ───────────────────────────────────────────────────────────────────
// Test scaffolding.
// ───────────────────────────────────────────────────────────────────

OperatorWebAuditLogHierarchyRouter _buildRouter({
  OperatorWebAuditLogHierarchyGateway? gateway,
  String operatorId = 'op-1',
  String locationId = 'loc-1',
  String actorUserId = 'user-1',
}) {
  return OperatorWebAuditLogHierarchyRouter(
    gateway: gateway ?? _RecordingGateway(),
    authResolver: (_) async =>
        OperatorWebAuditLogHierarchyAuthResult.allow(
      OperatorWebAuditLogHierarchyActor(
        actorUserId: actorUserId,
        actorOperatorId: operatorId,
        actorLocationId: locationId,
      ),
    ),
  );
}

class _RecordedCall {
  _RecordedCall({
    required this.operatorId,
    required this.locationId,
    required this.scopeType,
    this.orgUnitId,
    this.locationFilter,
    required this.from,
    required this.to,
    this.actorUserId,
    this.action,
    this.limit,
    this.beforeId,
    this.userId,
  });

  final String operatorId;
  final String locationId;
  final AuditLogHierarchyScope scopeType;
  final String? orgUnitId;
  final String? locationFilter;
  final DateTime from;
  final DateTime to;
  final String? actorUserId;
  final String? action;
  final int? limit;
  final int? beforeId;
  final String? userId;
}

class _RecordingGateway implements OperatorWebAuditLogHierarchyGateway {
  List<AuditLogRow> _rows = const <AuditLogRow>[];
  Object? failNext;
  final List<_RecordedCall> calls = <_RecordedCall>[];

  void seedRows(List<AuditLogRow> rows) {
    _rows = List<AuditLogRow>.unmodifiable(rows);
  }

  @override
  Future<List<AuditLogRow>> listByHierarchy({
    required String operatorId,
    required String locationId,
    required AuditLogHierarchyScope scopeType,
    String? orgUnitId,
    String? locationFilter,
    required DateTime from,
    required DateTime to,
    String? actorUserId,
    String? action,
    int? limit,
    int? beforeId,
    String? userId,
  }) async {
    calls.add(_RecordedCall(
      operatorId: operatorId,
      locationId: locationId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationFilter: locationFilter,
      from: from,
      to: to,
      actorUserId: actorUserId,
      action: action,
      limit: limit,
      beforeId: beforeId,
      userId: userId,
    ));
    if (failNext != null) {
      final err = failNext!;
      failNext = null;
      throw err;
    }
    return _rows;
  }
}

AuditLogRow _makeRow({
  required String id,
  required String operatorId,
  String? locationId,
}) {
  return AuditLogRow(
    id: id,
    operatorId: operatorId,
    locationId: locationId,
    occurredAt: DateTime.utc(2026, 5, 13, 12),
    actorKind: 'team_member',
    actorUserId: 'user-1',
    action: 'auth.password_changed',
    payload: const <String, Object?>{'demo': true},
  );
}

class _CapturedResult {
  _CapturedResult({
    required this.handled,
    required this.statusCode,
    required this.bodyText,
  });

  final bool handled;
  final int statusCode;
  final String bodyText;

  Map<String, Object?> get bodyJson {
    if (bodyText.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(bodyText);
    if (decoded is Map) return decoded.cast<String, Object?>();
    return const <String, Object?>{};
  }
}

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

Future<_CapturedResult> _captureRequest({
  required OperatorWebAuditLogHierarchyRouter router,
  required String method,
  required String path,
  Map<String, String> headers = const <String, String>{},
}) async {
  return _withRealHttp(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handledCompleter = Completer<bool>();
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        final handled = await router.tryHandle(request);
        if (!handledCompleter.isCompleted) {
          handledCompleter.complete(handled);
        }
        if (!handled) {
          request.response.statusCode = 404;
          await request.response.close();
        }
      } catch (_) {
        if (!handledCompleter.isCompleted) {
          handledCompleter.complete(false);
        }
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });

    final client = HttpClient();
    try {
      final clientRequest = await client.openUrl(
        method,
        Uri.parse('http://${server.address.host}:${server.port}$path'),
      );
      clientRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer test-token',
      );
      headers.forEach(clientRequest.headers.set);
      final response = await clientRequest.close();
      final body = await utf8.decodeStream(response);
      final handled = await handledCompleter.future;
      return _CapturedResult(
        handled: handled,
        statusCode: response.statusCode,
        bodyText: body,
      );
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });
}
