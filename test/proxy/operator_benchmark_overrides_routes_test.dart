import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/operator_benchmark_overrides_routes.dart';

void main() {
  const operatorId = '22222222-2222-4222-8222-222222222222';
  const locationId = '33333333-3333-4333-8333-333333333333';
  const orgUnitId = '44444444-4444-4444-8444-444444444444';
  const actorUserId = '11111111-1111-4111-8111-111111111111';

  group('OperatorBenchmarkOverridesRouter', () {
    test('matches read and write routes only', () {
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          '/v1/operator/benchmarks/overrides',
          'GET',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          '/v1/operator/benchmarks/overrides',
          'POST',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          '/v1/operator/benchmarks/overrides/override-a',
          'DELETE',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          '/v1/operator/benchmarks/overrides',
          'DELETE',
        ),
        isFalse,
      );
    });

    test('GET lists current overrides without touching idempotency', () async {
      final gateway = _FakeGateway();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: _RecordingAuditSink(),
      );

      final result = await router.handle(
        method: 'GET',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: '',
        body: const <String, Object?>{},
      );

      expect(result.statusCode, 200);
      expect(result.body['overrides'], isA<List<Object?>>());
      expect(gateway.listCalls, 1);
    });

    test('POST sets override, emits audit, and replays same idem key',
        () async {
      final gateway = _FakeGateway();
      gateway.rows.add(_row(value: 10));
      final audit = _RecordingAuditSink();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: audit,
        idempotencyCache: OperatorWriteIdempotencyCache(),
        now: () => DateTime.utc(2026, 5, 13, 17),
      );
      final body = <String, Object?>{
        'scope_type': 'org_unit',
        'org_unit_id': orgUnitId,
        'metric_key': 'target_cplh',
        'override_value': 12.25,
      };

      final first = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-1',
        body: body,
      );
      final second = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-1',
        body: Map<String, Object?>.from(body),
      );

      expect(first.statusCode, 201);
      expect(second.statusCode, 201);
      expect(gateway.setCalls, 1);
      expect(audit.events, hasLength(1));
      expect(audit.events.single['eventKind'], 'benchmark.override.set');
      expect(audit.events.single['occurredAt'], DateTime.utc(2026, 5, 13, 17));
      final payload = audit.events.single['payload'] as Map<String, Object?>;
      expect(payload['scope_type'], 'org_unit');
      expect(payload['target_id'], orgUnitId);
      expect(payload['metric_key'], 'target_cplh');
      expect(payload['prev_value'], 10);
      expect(payload['new_value'], 12.25);
    });

    test('POST idem key conflict returns 409 before second write', () async {
      final gateway = _FakeGateway();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: _RecordingAuditSink(),
      );

      await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-1',
        body: const <String, Object?>{
          'scope_type': 'operator_wide',
          'metric_key': 'target_splh',
          'override_value': 10,
        },
      );
      final conflict = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-1',
        body: const <String, Object?>{
          'scope_type': 'operator_wide',
          'metric_key': 'target_splh',
          'override_value': 11,
        },
      );

      expect(conflict.statusCode, 409);
      expect(conflict.body['error'], 'idempotency_key_conflict');
      expect(gateway.setCalls, 1);
    });

    test('DELETE clears override and emits clear audit event', () async {
      final gateway = _FakeGateway();
      gateway.rows.add(_row(value: 12.25));
      final audit = _RecordingAuditSink();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: audit,
      );

      final result = await router.handle(
        method: 'DELETE',
        path:
            '$operatorBenchmarkOverridesPrefix'
            '55555555-5555-4555-8555-555555555555',
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'delete-1',
        body: const <String, Object?>{},
      );

      expect(result.statusCode, 200);
      expect(gateway.clearCalls, 1);
      expect(audit.events.single['eventKind'], 'benchmark.override.clear');
      final payload = audit.events.single['payload'] as Map<String, Object?>;
      expect(payload['target_id'], orgUnitId);
      expect(payload['metric_key'], 'target_cplh');
      expect(payload['prev_value'], 12.25);
      expect(payload['new_value'], isNull);
      expect(payload['cleared'], isTrue);
    });

    test('invalid body is rejected before gateway write', () async {
      final gateway = _FakeGateway();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: _RecordingAuditSink(),
      );

      final result = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'bad-1',
        body: const <String, Object?>{
          'scope_type': 'org_unit',
          'metric_key': 'unknown',
          'override_value': 12,
        },
      );

      expect(result.statusCode, 400);
      expect(result.body['error'], 'invalid_metric_key');
      expect(gateway.setCalls, 0);
    });
  });

  group('RP-15 manager-once cap', () {
    test('manager-tier user is blocked on second POST in same month',
        () async {
      final gateway = _FakeGateway();
      final audit = _RecordingAuditSink();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: audit,
        now: () => DateTime.utc(2026, 5, 13, 17),
      );

      final firstBody = <String, Object?>{
        'scope_type': 'location',
        'location_id': locationId,
        'metric_key': 'target_cplh',
        'override_value': 12.5,
      };
      final first = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        actorRoles: const <String>{'location_manager'},
        idempotencyKey: 'mgr-first',
        body: firstBody,
      );
      expect(first.statusCode, 201);

      // The fake gateway's setOverride seeds a row with createdBy =
      // the test actor and effective_from = the router's fixed now,
      // so the second attempt's cap evaluator now sees one row in
      // the same month — capped.
      final second = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        actorRoles: const <String>{'location_manager'},
        idempotencyKey: 'mgr-second',
        body: <String, Object?>{
          'scope_type': 'location',
          'location_id': locationId,
          'metric_key': 'target_splh',
          'override_value': 4.2,
        },
      );

      expect(second.statusCode, 409);
      expect(second.body['error'], 'manager_override_cap_reached');
      final cap = second.body['cap'] as Map<String, Object?>;
      expect(cap['tier'], 'manager');
      expect(cap['remaining'], 0);
      expect(gateway.setCalls, 1);
    });

    test('admin-tier user is uncapped — third POST still passes', () async {
      final gateway = _FakeGateway();
      final audit = _RecordingAuditSink();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: audit,
        now: () => DateTime.utc(2026, 5, 13, 17),
      );

      for (var i = 0; i < 3; i += 1) {
        final result = await router.handle(
          method: 'POST',
          path: operatorBenchmarkOverridesPath,
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: actorUserId,
          actorKind: 'operator_user',
          actorRoles: const <String>{'operator_owner'},
          idempotencyKey: 'admin-$i',
          body: <String, Object?>{
            'scope_type': 'operator_wide',
            'metric_key': 'target_cplh',
            'override_value': 10.0 + i,
          },
        );
        expect(result.statusCode, 201);
      }
      expect(gateway.setCalls, 3);
    });

    test('cap resets across calendar months', () async {
      final gateway = _FakeGateway();
      // Seed a manager-set row from April.
      gateway.history.add(
        BenchmarkOverrideCandidate(
          overrideId: 'apr-row',
          operatorId: operatorId,
          scopeType: BenchmarkOverrideScopeType.location,
          orgUnitId: null,
          locationId: locationId,
          metricKey: 'target_cplh',
          value: 11,
          effectiveFrom: DateTime.utc(2026, 4, 30, 17),
          effectiveUntil: DateTime.utc(2026, 5, 1, 6),
          createdBy: actorUserId,
        ),
      );
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: _RecordingAuditSink(),
        now: () => DateTime.utc(2026, 5, 13, 17),
      );

      // April's row sits outside May; manager should still have the
      // full budget.
      final result = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        actorRoles: const <String>{'location_manager'},
        idempotencyKey: 'new-month',
        body: <String, Object?>{
          'scope_type': 'location',
          'location_id': locationId,
          'metric_key': 'target_cplh',
          'override_value': 12.0,
        },
      );

      expect(result.statusCode, 201);
      expect(gateway.setCalls, 1);
    });

    test('cap-status GET reports remaining for managers', () async {
      final gateway = _FakeGateway();
      gateway.rows.add(
        BenchmarkOverrideCandidate(
          overrideId: 'may-row',
          operatorId: operatorId,
          scopeType: BenchmarkOverrideScopeType.location,
          orgUnitId: null,
          locationId: locationId,
          metricKey: 'target_cplh',
          value: 12,
          effectiveFrom: DateTime.utc(2026, 5, 5, 17),
          effectiveUntil: null,
          createdBy: actorUserId,
        ),
      );
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: _RecordingAuditSink(),
        now: () => DateTime.utc(2026, 5, 13, 17),
      );

      final result = await router.handle(
        method: 'GET',
        path: operatorBenchmarkOverrideCapStatusPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        actorRoles: const <String>{'location_manager'},
        idempotencyKey: '',
        body: const <String, Object?>{},
      );

      expect(result.statusCode, 200);
      final cap = result.body['cap'] as Map<String, Object?>;
      expect(cap['tier'], 'manager');
      expect(cap['used'], 1);
      expect(cap['remaining'], 0);
    });

    test('admin-undo writes admin.benchmark_override_undone audit row',
        () async {
      final gateway = _FakeGateway();
      const managerOriginalId = '55555555-5555-4555-8555-555555555555';
      gateway.rows.add(
        BenchmarkOverrideCandidate(
          overrideId: managerOriginalId,
          operatorId: operatorId,
          scopeType: BenchmarkOverrideScopeType.location,
          orgUnitId: null,
          locationId: locationId,
          metricKey: 'target_cplh',
          value: 12,
          effectiveFrom: DateTime.utc(2026, 5, 5, 17),
          effectiveUntil: null,
          createdBy: 'manager-007',
        ),
      );
      final audit = _RecordingAuditSink();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: audit,
        now: () => DateTime.utc(2026, 5, 13, 18),
      );

      final result = await router.handle(
        method: 'DELETE',
        path:
            '$operatorBenchmarkOverridesPrefix$managerOriginalId'
            '$operatorBenchmarkOverrideAdminUndoSuffix',
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: 'admin-001',
        actorKind: 'operator_user',
        actorRoles: const <String>{'operator_owner'},
        idempotencyKey: 'undo-1',
        body: const <String, Object?>{
          'undo_reason': 'Replaced with new benchmark for May rollout.',
        },
      );

      expect(result.statusCode, 200);
      expect(gateway.clearCalls, 1);
      expect(audit.events, hasLength(1));
      expect(
        audit.events.single['eventKind'],
        'admin.benchmark_override_undone',
      );
      final payload = audit.events.single['payload'] as Map<String, Object?>;
      expect(payload['undone_by_admin_id'], 'admin-001');
      expect(payload['original_override_id'], managerOriginalId);
      expect(payload['original_manager_id'], 'manager-007');
      expect(
        payload['undo_reason'],
        'Replaced with new benchmark for May rollout.',
      );
    });

    test('admin-undo refuses manager-tier callers', () async {
      final gateway = _FakeGateway();
      gateway.rows.add(_row());
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: _RecordingAuditSink(),
      );

      final result = await router.handle(
        method: 'DELETE',
        path:
            '$operatorBenchmarkOverridesPrefix'
            '55555555-5555-4555-8555-555555555555'
            '$operatorBenchmarkOverrideAdminUndoSuffix',
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        actorRoles: const <String>{'location_manager'},
        idempotencyKey: 'no-undo',
        body: const <String, Object?>{},
      );

      expect(result.statusCode, 403);
      expect(result.body['error'], 'admin_role_required');
      expect(gateway.clearCalls, 0);
    });
  });

  group('HTTP permission gate', () {
    test('POST requires forgeflow.baseline.override permission', () async {
      await _withRealHttp(() async {
        final ctx = await _spinUp(allowBaselineOverride: false);
        try {
          final response = await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBenchmarkOverridesPath),
            <String, Object?>{
              'scope_type': 'operator_wide',
              'metric_key': 'target_cplh',
              'override_value': 10,
            },
          );
          expect(response.statusCode, HttpStatus.forbidden);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            body['permission_key'],
            PermissionKeys.forgeflowBaselineOverride,
          );
          expect(ctx.gateway.setCalls, 0);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

class _FakeGateway implements OperatorBenchmarkOverridesGateway {
  final List<BenchmarkOverrideCandidate> rows = <BenchmarkOverrideCandidate>[];
  final List<BenchmarkOverrideCandidate> history =
      <BenchmarkOverrideCandidate>[];
  int listCalls = 0;
  int monthCalls = 0;
  int setCalls = 0;
  int patchCalls = 0;
  int clearCalls = 0;

  @override
  Future<List<BenchmarkOverrideCandidate>> listCurrent({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    listCalls += 1;
    return rows.toList(growable: false);
  }

  @override
  Future<List<BenchmarkOverrideCandidate>> listOverridesByUserInMonth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime referenceTime,
  }) async {
    monthCalls += 1;
    final ref = referenceTime.toUtc();
    final corpus = <BenchmarkOverrideCandidate>[...rows, ...history];
    return corpus.where((row) {
      if (row.createdBy != actorUserId) return false;
      final ef = row.effectiveFrom.toUtc();
      return ef.year == ref.year && ef.month == ref.month;
    }).toList(growable: false);
  }

  @override
  Future<BenchmarkOverrideCandidate> setOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required BenchmarkOverrideScopeType scopeType,
    required String? orgUnitId,
    required String? targetLocationId,
    required String metricKey,
    required double overrideValue,
    DateTime? effectiveFrom,
  }) async {
    setCalls += 1;
    final row = _row(
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: targetLocationId,
      metricKey: metricKey,
      value: overrideValue,
    );
    rows.add(row);
    return row;
  }

  @override
  Future<BenchmarkOverrideCandidate?> patchOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
    required double overrideValue,
  }) async {
    patchCalls += 1;
    return _row(value: overrideValue);
  }

  @override
  Future<BenchmarkOverrideCandidate?> clearOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
  }) async {
    clearCalls += 1;
    return _row(overrideId: overrideId);
  }
}

class _RecordingAuditSink implements OperatorWriteAuditSink {
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];

  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    events.add(<String, Object?>{
      'operatorId': operatorId,
      'actorUserId': actorUserId,
      'actorKind': actorKind,
      'eventKind': eventKind,
      'payload': payload,
      'occurredAt': occurredAt,
    });
  }
}

BenchmarkOverrideCandidate _row({
  String overrideId = '55555555-5555-4555-8555-555555555555',
  BenchmarkOverrideScopeType scopeType = BenchmarkOverrideScopeType.orgUnit,
  String? orgUnitId = '44444444-4444-4444-8444-444444444444',
  String? locationId,
  String metricKey = 'target_cplh',
  double value = 12.25,
}) {
  return BenchmarkOverrideCandidate(
    overrideId: overrideId,
    operatorId: '22222222-2222-4222-8222-222222222222',
    scopeType: scopeType,
    orgUnitId: orgUnitId,
    locationId: locationId,
    metricKey: metricKey,
    value: value,
    effectiveFrom: DateTime.utc(2026, 5, 13, 17),
    effectiveUntil: null,
    createdBy: '11111111-1111-4111-8111-111111111111',
    sourceLabel: 'Org unit',
  );
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

Future<({
  HttpServer server,
  HttpClient client,
  Uri baseUri,
  _FakeGateway gateway,
})> _spinUp({required bool allowBaselineOverride}) async {
  final gateway = _FakeGateway();
  final guard = ProxyRequestGuard(
    verifier: const _StaticVerifier(
      ProxyJwtClaims(
        userId: '11111111-1111-4111-8111-111111111111',
        operatorId: '22222222-2222-4222-8222-222222222222',
        locationId: '33333333-3333-4333-8333-333333333333',
        roles: <String>['operator_admin'],
      ),
    ),
  );
  final permissionResolver = _StaticPermissionResolver(
    allowBaselineOverride: allowBaselineOverride,
  );
  // Construct the router with the same closure-bound auth + permission
  // bridges that `main.dart` builds in production. Tests then mount it
  // via `tryHandle` ahead of `routeRequest` (sibling-file pre-check
  // pattern shared with C-1 SendGrid + B8 audit-log-hierarchy).
  final router = OperatorBenchmarkOverridesRouter(
    gateway: gateway,
    auditSink: _RecordingAuditSink(),
    authResolver: (request) async {
      try {
        final scope = await guard.requireOperatorContext(
          authorizationHeader: request.headers.value(
            HttpHeaders.authorizationHeader,
          ),
        );
        return OperatorBenchmarkOverridesActor(
          userId: scope.userId,
          operatorId: scope.operatorId,
          locationId: scope.locationId,
          roles: scope.roles.toSet(),
          actorKind: scope.actorKind,
        );
      } on ProxyAuthError {
        return null;
      }
    },
    permissionGate: (actor) async {
      try {
        final snapshot = await permissionResolver.load(
          OperatorContext(
            userId: actor.userId,
            operatorId: actor.operatorId,
            locationId: actor.locationId,
            roles: actor.roles.toList(),
            actorKind: actor.actorKind,
          ),
        );
        final effect =
            snapshot.permissions[PermissionKeys.forgeflowBaselineOverride];
        return effect == PermissionEffect.allow
            ? OperatorBenchmarkOverridesPermissionEffect.allow
            : OperatorBenchmarkOverridesPermissionEffect.deny;
      } on Exception {
        return OperatorBenchmarkOverridesPermissionEffect.unavailable;
      }
    },
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    if (await router.tryHandle(request)) {
      return;
    }
    await routeRequest(request, guard);
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri, gateway: gateway);
}

Future<({int statusCode, String body})> _httpPost(
  HttpClient client,
  Uri uri,
  Map<String, Object?> body,
) async {
  final request = await client.postUrl(uri);
  final encoded = utf8.encode(jsonEncode(body));
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer token');
  request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  request.headers.set('Idempotency-Key', 'http-test-idem');
  request.headers.contentLength = encoded.length;
  request.add(encoded);
  final response = await request.close();
  return (
    statusCode: response.statusCode,
    body: await utf8.decoder.bind(response).join(),
  );
}

class _StaticVerifier implements ProxyJwtVerifier {
  const _StaticVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _StaticPermissionResolver implements ProxyPermissionSnapshotResolver {
  const _StaticPermissionResolver({required this.allowBaselineOverride});

  final bool allowBaselineOverride;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async {
    return ProxyPermissionSnapshot(
      userId: scope.userId,
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      rolesVersion: 1,
      evaluatedAt: DateTime.utc(2026, 5, 13, 18),
      permissions: <String, PermissionEffect>{
        PermissionKeys.forgeflowBaselineOverride: allowBaselineOverride
            ? PermissionEffect.allow
            : PermissionEffect.deny,
      },
    );
  }
}
