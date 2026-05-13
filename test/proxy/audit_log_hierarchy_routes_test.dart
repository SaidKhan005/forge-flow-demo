// Lane B B8 — audit_log_hierarchy_routes proxy tests.
//
// Pins the contract for:
//
//   GET /v1/admin/auth/audit-log/hierarchy
//
// Covers:
//   * 401 on missing / unverified bearer token.
//   * 403 on insufficient role (operator_owner is NOT a global admin).
//   * 400 on missing admin_reason header.
//   * 400 on bad time formats / missing scope ids / malformed uuids.
//   * 200 on operator_wide / org_unit / location scope branches.
//   * Cross-tenant isolation: the gateway sees only the JWT operator.
//   * 503 envelope when the gateway throws.
//   * Latency recorder hook fires on 2xx with the distinct-location
//     count from the result page.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';

import '../../tool/advisor_proxy/audit_log_hierarchy_routes.dart';

void main() {
  group('AuditLogHierarchyRouter.tryHandle', () {
    test('returns false for unrelated path', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/admin/health',
      );
      expect(result.handled, isFalse);
    });

    test('401 when auth resolver returns null', () async {
      final result = await _captureRequest(
        router: AuditLogHierarchyRouter(
          gateway: _RecordingGateway(),
          authResolver: (_) async => null,
        ),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 401);
      expect(result.bodyJson['error'], 'unauthorized');
    });

    test('401 when auth resolver throws', () async {
      final result = await _captureRequest(
        router: AuditLogHierarchyRouter(
          gateway: _RecordingGateway(),
          authResolver: (_) async => throw StateError('boom'),
        ),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 401);
    });

    test('403 when actor lacks {super_admin, ff_support}', () async {
      final result = await _captureRequest(
        router: _buildRouter(roles: <String>{'operator_owner'}),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy',
        headers: <String, String>{'admin_reason': 'support-ticket-1'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 403);
      expect(result.bodyJson['error'], 'permission_denied');
    });

    test('400 when admin_reason header missing', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy',
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'missing_admin_reason');
    });

    test('400 when scope=org_unit but org_unit_id missing', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?scope_type=org_unit',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'missing_org_unit_id');
    });

    test('400 when scope=location but location_filter missing', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?scope_type=location',
        headers: <String, String>{'admin_reason': 'audit-x'},
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
            '/v1/admin/auth/audit-log/hierarchy?scope_type=org_unit&org_unit_id=not-a-uuid',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_org_unit_id');
    });

    test('400 when from is not parseable', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy?from=not-a-date',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_from');
    });

    test('400 when to is not parseable', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy?to=not-a-date',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_to');
    });

    test('400 when from > to', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?from=2026-05-13T00:00:00Z&to=2026-05-12T00:00:00Z',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_range');
    });

    test('400 when limit is non-numeric', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy?limit=abc',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_limit');
    });

    test('400 when action exceeds 200 chars', () async {
      final longAction = 'a' * 201;
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?action=$longAction',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_action');
    });

    test('400 when actor_user_id is malformed', () async {
      final result = await _captureRequest(
        router: _buildRouter(),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?actor_user_id=not-a-uuid',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_actor_user_id');
    });

    test('200 on operator_wide happy path', () async {
      final gateway = _RecordingGateway()
        ..seedRows(<AuditLogRow>[
          _makeRow(id: '42', operatorId: 'op-1', locationId: 'loc-1'),
        ]);
      final result = await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy',
        headers: <String, String>{'admin_reason': 'support-ticket-1'},
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 200);
      final body = result.bodyJson;
      expect((body['rows'] as List).length, 1);
      expect((body['rows'] as List).first, isA<Map<String, Object?>>());
      expect(gateway.calls.length, 1);
      expect(gateway.calls.first.operatorId, 'op-1');
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
            '/v1/admin/auth/audit-log/hierarchy?scope_type=org_unit&org_unit_id=$orgUnitId',
        headers: <String, String>{'admin_reason': 'audit-x'},
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
            '/v1/admin/auth/audit-log/hierarchy?scope_type=location&location_filter=$locationFilter',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.statusCode, 200);
      expect(gateway.calls.first.scopeType,
          AuditLogHierarchyScope.location);
      expect(gateway.calls.first.locationFilter, locationFilter);
    });

    test('cross-tenant: gateway only sees the JWT operator', () async {
      final gateway = _RecordingGateway();
      // Caller crafts an operator_id query param hoping to read op-2.
      // The JWT scope is op-1; the route ignores the param and the
      // gateway sees only op-1.
      final result = await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?operator_id=11111111-1111-1111-1111-111111111111',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'operator_id_mismatch');
      expect(gateway.calls, isEmpty);
    });

    test('global-admin caller with scope-less JWT supplies operator_id',
        () async {
      final operatorId = '33333333-3333-3333-3333-333333333333';
      final locationId = '44444444-4444-4444-4444-444444444444';
      final gateway = _RecordingGateway();
      final result = await _captureRequest(
        router: _buildRouter(
          gateway: gateway,
          operatorId: '',
          locationId: '',
        ),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?operator_id=$operatorId&location_id=$locationId',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.statusCode, 200);
      expect(gateway.calls.first.operatorId, operatorId);
      expect(gateway.calls.first.locationId, locationId);
    });

    test('400 when scope-less JWT lacks operator_id query param',
        () async {
      final result = await _captureRequest(
        router: _buildRouter(operatorId: '', locationId: ''),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'missing_operator_id');
    });

    test('400 when scope-less JWT lacks location_id query param',
        () async {
      final operatorId = '55555555-5555-5555-5555-555555555555';
      final result = await _captureRequest(
        router: _buildRouter(operatorId: '', locationId: ''),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?operator_id=$operatorId',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'missing_location_id');
    });

    test('503 when gateway throws', () async {
      final gateway = _RecordingGateway()..failNext = StateError('db down');
      final result = await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy',
        headers: <String, String>{'admin_reason': 'audit-x'},
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
      final router = AuditLogHierarchyRouter(
        gateway: gateway,
        authResolver: (_) async => const AuditLogHierarchyActor(
          actorUserId: 'user-1',
          actorRoles: <String>{'super_admin'},
          actorOperatorId: 'op-1',
          actorLocationId: 'loc-1',
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
        path: '/v1/admin/auth/audit-log/hierarchy',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(result.statusCode, 200);
      expect(samples, hasLength(1));
      expect(samples.first['operator_id'], 'op-1');
      // 2 distinct locations in the page: loc-a, loc-b.
      expect(samples.first['location_count'], 2);
    });

    test('limit clamps to 200', () async {
      final gateway = _RecordingGateway();
      await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path:
            '/v1/admin/auth/audit-log/hierarchy?limit=1000',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(gateway.calls.first.limit, AuditLogsReader.maxLimit);
    });

    test('before_id is forwarded to the gateway', () async {
      final gateway = _RecordingGateway();
      await _captureRequest(
        router: _buildRouter(gateway: gateway),
        method: 'GET',
        path: '/v1/admin/auth/audit-log/hierarchy?before_id=42',
        headers: <String, String>{'admin_reason': 'audit-x'},
      );
      expect(gateway.calls.first.beforeId, 42);
    });
  });
}

// ───────────────────────────────────────────────────────────────────
// Test scaffolding.
// ───────────────────────────────────────────────────────────────────

AuditLogHierarchyRouter _buildRouter({
  AuditLogHierarchyGateway? gateway,
  Set<String>? roles,
  String operatorId = 'op-1',
  String locationId = 'loc-1',
}) {
  return AuditLogHierarchyRouter(
    gateway: gateway ?? _RecordingGateway(),
    authResolver: (_) async => AuditLogHierarchyActor(
      actorUserId: 'user-1',
      actorRoles: roles ?? <String>{'super_admin'},
      actorOperatorId: operatorId,
      actorLocationId: locationId,
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
}

class _RecordingGateway implements AuditLogHierarchyGateway {
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
    actorKind: 'user',
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
  required AuditLogHierarchyRouter router,
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
