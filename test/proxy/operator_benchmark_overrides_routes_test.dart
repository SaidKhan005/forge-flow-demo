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
  const actorUserId = '11111111-1111-4111-8111-111111111111';
  const overrideId = '55555555-5555-4555-8555-555555555555';

  group('OperatorBenchmarkOverridesRouter', () {
    test('matches read routes and legacy write tombstones', () {
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          operatorBenchmarkOverridesPath,
          'GET',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          operatorBenchmarkOverrideCapStatusPath,
          'GET',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          operatorBenchmarkOverridesPath,
          'POST',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          '$operatorBenchmarkOverridesPrefix$overrideId',
          'PATCH',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          '$operatorBenchmarkOverridesPrefix$overrideId',
          'DELETE',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          '$operatorBenchmarkOverridesPrefix$overrideId'
              '$operatorBenchmarkOverrideAdminUndoSuffix',
          'DELETE',
        ),
        isTrue,
      );
      expect(
        OperatorBenchmarkOverridesRouter.matches(
          operatorBenchmarkOverridesPath,
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
      expect(gateway.monthCalls, 0);
    });

    test('legacy write verbs return gone without gateway or audit', () async {
      final gateway = _FakeGateway();
      gateway.rows.add(_row(value: 10));
      final audit = _RecordingAuditSink();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: audit,
        now: () => DateTime.utc(2026, 5, 13, 17),
      );

      final cases = <({String method, String path, Map<String, Object?> body})>[
        (
          method: 'POST',
          path: operatorBenchmarkOverridesPath,
          body: const <String, Object?>{
            'scope_type': 'org_unit',
            'metric_key': 'target_cplh',
            'override_value': 12.25,
          },
        ),
        (
          method: 'PATCH',
          path: '$operatorBenchmarkOverridesPrefix$overrideId',
          body: const <String, Object?>{'override_value': 13},
        ),
        (
          method: 'DELETE',
          path: '$operatorBenchmarkOverridesPrefix$overrideId',
          body: const <String, Object?>{},
        ),
        (
          method: 'DELETE',
          path:
              '$operatorBenchmarkOverridesPrefix$overrideId'
              '$operatorBenchmarkOverrideAdminUndoSuffix',
          body: const <String, Object?>{
            'undo_reason': 'Legacy admin undo is disabled too.',
          },
        ),
      ];

      for (final c in cases) {
        final result = await router.handle(
          method: c.method,
          path: c.path,
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: actorUserId,
          actorKind: 'operator_user',
          actorRoles: const <String>{'operator_owner'},
          idempotencyKey: 'same-idem-key',
          body: c.body,
        );

        _expectLegacyWriteDisabled(result);
      }

      expect(gateway.listCalls, 0);
      expect(gateway.monthCalls, 0);
      expect(audit.events, isEmpty);
    });

    test('legacy POST is disabled before validation and replay', () async {
      final gateway = _FakeGateway();
      final audit = _RecordingAuditSink();
      final router = OperatorBenchmarkOverridesRouter(
        gateway: gateway,
        auditSink: audit,
      );

      final first = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: '',
        body: const <String, Object?>{
          'scope_type': 'org_unit',
          'metric_key': 'unknown',
          'override_value': -1,
        },
      );
      final second = await router.handle(
        method: 'POST',
        path: operatorBenchmarkOverridesPath,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: '',
        body: const <String, Object?>{
          'scope_type': 'operator_wide',
          'metric_key': 'target_splh',
          'override_value': 11,
        },
      );

      _expectLegacyWriteDisabled(first);
      _expectLegacyWriteDisabled(second);
      expect(gateway.listCalls, 0);
      expect(gateway.monthCalls, 0);
      expect(audit.events, isEmpty);
    });
  });

  group('legacy cap-status read', () {
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
      expect(gateway.monthCalls, 1);
    });

    test(
      'cap-status GET reports admins as uncapped without month load',
      () async {
        final gateway = _FakeGateway();
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
          actorRoles: const <String>{'operator_owner'},
          idempotencyKey: '',
          body: const <String, Object?>{},
        );

        expect(result.statusCode, 200);
        final cap = result.body['cap'] as Map<String, Object?>;
        expect(cap['tier'], 'admin');
        expect(cap['remaining'], -1);
        expect(gateway.monthCalls, 0);
      },
    );
  });

  group('HTTP mount behavior', () {
    test(
      'POST legacy write returns gone before permission or gateway',
      () async {
        await _withRealHttp(() async {
          final ctx = await _spinUp(allowBaselineOverride: false);
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(operatorBenchmarkOverridesPath),
              body: const <String, Object?>{
                'scope_type': 'operator_wide',
                'metric_key': 'unknown',
                'override_value': -1,
              },
            );

            expect(
              response.statusCode,
              operatorBenchmarkOverrideWriteDisabledStatus,
            );
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], operatorBenchmarkOverrideWriteDisabledError);
            expect(
              body['replacement'],
              'mobile_baseline_manager_selected_star',
            );
            expect(ctx.permissionResolver.loadCalls, 0);
            expect(ctx.gateway.listCalls, 0);
            expect(ctx.gateway.monthCalls, 0);
            expect(ctx.auditSink.events, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'GET read-only route still requires baseline override permission',
      () async {
        await _withRealHttp(() async {
          final ctx = await _spinUp(allowBaselineOverride: false);
          try {
            final response = await _httpJson(
              ctx.client,
              'GET',
              ctx.baseUri.resolve(operatorBenchmarkOverridesPath),
            );

            expect(response.statusCode, HttpStatus.forbidden);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['permission_key'],
              PermissionKeys.forgeflowBaselineOverride,
            );
            expect(ctx.permissionResolver.loadCalls, 1);
            expect(ctx.gateway.listCalls, 0);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}

void _expectLegacyWriteDisabled(
  ({int statusCode, Map<String, Object?> body}) result,
) {
  expect(result.statusCode, operatorBenchmarkOverrideWriteDisabledStatus);
  expect(result.body['error'], operatorBenchmarkOverrideWriteDisabledError);
  expect(result.body['message'], operatorBenchmarkOverrideWriteDisabledMessage);
  expect(result.body['replacement'], 'mobile_baseline_manager_selected_star');
}

class _FakeGateway implements OperatorBenchmarkOverridesGateway {
  final List<BenchmarkOverrideCandidate> rows = <BenchmarkOverrideCandidate>[];
  final List<BenchmarkOverrideCandidate> history =
      <BenchmarkOverrideCandidate>[];
  int listCalls = 0;
  int monthCalls = 0;

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
    return corpus
        .where((row) {
          if (row.createdBy != actorUserId) return false;
          final ef = row.effectiveFrom.toUtc();
          return ef.year == ref.year && ef.month == ref.month;
        })
        .toList(growable: false);
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
  String id = '55555555-5555-4555-8555-555555555555',
  BenchmarkOverrideScopeType scopeType = BenchmarkOverrideScopeType.orgUnit,
  String? orgUnitId = '44444444-4444-4444-8444-444444444444',
  String? rowLocationId,
  String metricKey = 'target_cplh',
  double value = 12.25,
}) {
  return BenchmarkOverrideCandidate(
    overrideId: id,
    operatorId: '22222222-2222-4222-8222-222222222222',
    scopeType: scopeType,
    orgUnitId: orgUnitId,
    locationId: rowLocationId,
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

Future<
  ({
    HttpServer server,
    HttpClient client,
    Uri baseUri,
    _FakeGateway gateway,
    _RecordingAuditSink auditSink,
    _StaticPermissionResolver permissionResolver,
  })
>
_spinUp({required bool allowBaselineOverride}) async {
  final gateway = _FakeGateway();
  final auditSink = _RecordingAuditSink();
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
  final router = OperatorBenchmarkOverridesRouter(
    gateway: gateway,
    auditSink: auditSink,
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
  return (
    server: server,
    client: client,
    baseUri: baseUri,
    gateway: gateway,
    auditSink: auditSink,
    permissionResolver: permissionResolver,
  );
}

Future<({int statusCode, String body})> _httpJson(
  HttpClient client,
  String method,
  Uri uri, {
  Map<String, Object?>? body,
  String? idempotencyKey,
}) async {
  final request = await client.openUrl(method, uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer token');
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body != null) {
    final encoded = utf8.encode(jsonEncode(body));
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.contentLength = encoded.length;
    request.add(encoded);
  }
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
  _StaticPermissionResolver({required this.allowBaselineOverride});

  final bool allowBaselineOverride;
  int loadCalls = 0;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async {
    loadCalls += 1;
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
