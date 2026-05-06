// Phase 8 star/target truth - selected-star proxy route tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/selected_star_shift_repository.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';
const String _restaurantId = 'demo_restaurant';
const String _basePath =
    '/v1/operators/$_operatorId/locations/$_locationId/'
    '$selectedStarShiftDecisionsResource';

Map<String, Object?> _selectBody({
  String recordKey = '2026-W19|Wednesday|dinner',
  int covers = 120,
}) {
  return <String, Object?>{
    'restaurant_id': _restaurantId,
    'record_key': recordKey,
    'week_id': '2026-W19',
    'day_label': 'Wednesday',
    'daypart': 'dinner',
    'business_date': '2026-05-06',
    'service_period_key': 'dinner',
    'source_system': 'pos',
    'source_shift_id': 'shift-1',
    'source_shift_record_id': 'record-1',
    'covers': covers,
    'cplh': 12.4,
    'splh': 152.0,
    'ppa': 42.5,
    'primary_lever_id': 'labor',
    'actual_labor_pct': 21.4,
    'has_actual_labor_pct_truth': true,
    'recommendation_reference_id': 'rec-123',
    'candidate_snapshot': const <String, Object?>{
      'source': 'closed_shift_history',
      'actual_labor_pct': 21.4,
    },
    'reason': 'manager selected star',
  };
}

Map<String, Object?> _clearBody() {
  return const <String, Object?>{
    'restaurant_id': _restaurantId,
    'record_key': '2026-W19|Wednesday|dinner',
    'week_id': '2026-W19',
    'day_label': 'Wednesday',
    'daypart': 'dinner',
    'business_date': '2026-05-06',
    'service_period_key': 'dinner',
    'reason': 'manager cleared star',
  };
}

void main() {
  tearDown(SelectedStarTargetRouter.resetGlobalForTesting);

  group('selected-star target proxy routes', () {
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
        _RecordingSelectedStarGateway gateway,
        _RecordingPermissionGuard permissionGuard,
        _SettableVerifier verifier,
      })
    >
    spinUp({bool allowPermission = true, ProxyJwtClaims? claims}) async {
      final verifier = _SettableVerifier();
      verifier.claims =
          claims ??
          const ProxyJwtClaims(
            userId: _userId,
            operatorId: _operatorId,
            locationId: _locationId,
            roles: <String>['operator_manager'],
          );
      final gateway = _RecordingSelectedStarGateway();
      final router = SelectedStarTargetRouter(gateway: gateway);
      final permissionGuard = _RecordingPermissionGuard(
        decision: allowPermission
            ? const ProxyAdminAllowed()
            : const ProxyAdminDeniedDefault(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            ProxyRequestGuard(verifier: verifier),
            adminPermissionGuard: permissionGuard,
            selectedStarTargetRouter: router,
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
        permissionGuard: permissionGuard,
        verifier: verifier,
      );
    }

    test(
      'POST select records a manager decision through repository seam',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve('$_basePath/select'),
              method: 'POST',
              idempotencyKey: 'idem-select-1',
              body: _selectBody(),
            );

            expect(response.statusCode, equals(200));
            expect(ctx.permissionGuard.contexts, hasLength(1));
            expect(
              ctx.permissionGuard.contexts.single.requestedPermissionKey,
              equals(selectedStarWritePermissionKey),
            );
            expect(ctx.gateway.writes, hasLength(1));
            final write = ctx.gateway.writes.single;
            expect(write.decisionType, equals('manager_selected'));
            expect(write.decisionSource, equals('manager'));
            expect(write.idempotencyKey, equals('idem-select-1'));
            expect(write.recommendationReferenceId, equals('rec-123'));
            expect(
              write.candidateSnapshot['source'],
              equals('closed_shift_history'),
            );

            final json = jsonDecode(response.body) as Map<String, Object?>;
            final decision = json['decision'] as Map<String, Object?>;
            expect(decision['decision_type'], equals('manager_selected'));
            expect(decision['recommendation_reference_id'], equals('rec-123'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST clear records a clear decision without candidate fabrication',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve('$_basePath/clear'),
              method: 'POST',
              idempotencyKey: 'idem-clear-1',
              body: _clearBody(),
            );

            expect(response.statusCode, equals(200));
            expect(ctx.gateway.writes, hasLength(1));
            final write = ctx.gateway.writes.single;
            expect(write.decisionType, equals('manager_cleared'));
            expect(write.recommendationReferenceId, isNull);
            expect(write.candidateSnapshot, isEmpty);
            final json = jsonDecode(response.body) as Map<String, Object?>;
            final decision = json['decision'] as Map<String, Object?>;
            expect(decision['decision_type'], equals('manager_cleared'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('write requires Idempotency-Key', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_basePath/select'),
            method: 'POST',
            idempotencyKey: null,
            body: _selectBody(),
          );

          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_missing'));
          expect(ctx.gateway.writes, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('write denies without baseline override permission', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(allowPermission: false);
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_basePath/select'),
            method: 'POST',
            idempotencyKey: 'idem-denied',
            body: _selectBody(),
          );

          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(ctx.gateway.writes, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'operator user cannot forge an admin selected-star decision',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve('$_basePath/select'),
              method: 'POST',
              idempotencyKey: 'idem-admin-forged',
              body: <String, Object?>{
                ..._selectBody(),
                'decision_source': 'admin',
              },
            );

            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('admin_decision_source_forbidden'));
            expect(ctx.gateway.writes, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('idempotency replay does not call repository twice', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final first = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_basePath/select'),
            method: 'POST',
            idempotencyKey: 'idem-replay',
            body: _selectBody(),
          );
          final second = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_basePath/select'),
            method: 'POST',
            idempotencyKey: 'idem-replay',
            body: _selectBody(),
          );

          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          expect(second.body, equals(first.body));
          expect(ctx.gateway.writes, hasLength(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('idempotency conflict rejects same key with different body', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_basePath/select'),
            method: 'POST',
            idempotencyKey: 'idem-conflict',
            body: _selectBody(),
          );
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_basePath/select'),
            method: 'POST',
            idempotencyKey: 'idem-conflict',
            body: _selectBody(covers: 121),
          );

          expect(response.statusCode, equals(409));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_conflict'));
          expect(ctx.gateway.writes, hasLength(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('read returns selected-star decisions for sync', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.updatedRows = <SelectedStarShiftDecisionRow>[
            _row(
              decisionType: 'manager_selected',
              requestHash: 'hash-existing',
              idempotencyKey: 'idem-existing',
              updatedAt: DateTime.utc(2026, 5, 6, 18, 1),
            ),
          ];
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$_basePath?modified_since=2026-05-06T18:00:00Z&page_size=25',
            ),
          );

          expect(response.statusCode, equals(200));
          expect(ctx.gateway.updatedSinceCalls, hasLength(1));
          expect(ctx.gateway.updatedSinceCalls.single.limit, equals(25));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final rows = body['selected_star_shift_decisions'] as List<dynamic>;
          expect(rows, hasLength(1));
          expect(
            (rows.single as Map<String, Object?>)['decision_type'],
            equals('manager_selected'),
          );
          expect(body['next_cursor'], equals('2026-05-06T18:01:00.000Z'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('read rejects caller scope mismatch', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          claims: const ProxyJwtClaims(
            userId: _userId,
            operatorId: _operatorId,
            locationId: '99999999-9999-9999-9999-999999999999',
            roles: <String>['operator_manager'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(_basePath),
          );

          expect(response.statusCode, equals(403));
          expect(ctx.gateway.updatedSinceCalls, isEmpty);
          expect(ctx.gateway.currentSelectionCalls, isEmpty);
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

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final c = claims;
    if (c == null) throw ProxyJwtVerificationError('no claims');
    return c;
  }
}

class _RecordingPermissionGuard implements ProxyAdminPermissionGuard {
  _RecordingPermissionGuard({required this.decision});

  final ProxyAdminGuardDecision decision;
  final List<ProxyAdminGuardContext> contexts = <ProxyAdminGuardContext>[];

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    contexts.add(context);
    return decision;
  }
}

class _RecordingSelectedStarGateway implements SelectedStarTargetGateway {
  final List<SelectedStarShiftDecisionWrite> writes =
      <SelectedStarShiftDecisionWrite>[];
  final List<String> actorKinds = <String>[];
  List<SelectedStarShiftDecisionRow> updatedRows =
      <SelectedStarShiftDecisionRow>[];
  List<SelectedStarShiftDecisionRow> currentRows =
      <SelectedStarShiftDecisionRow>[];
  final List<({DateTime updatedAfter, int limit})> updatedSinceCalls =
      <({DateTime updatedAfter, int limit})>[];
  final List<({String restaurantId, int limit})> currentSelectionCalls =
      <({String restaurantId, int limit})>[];

  @override
  Future<SelectedStarShiftDecisionRow> recordDecision({
    required SelectedStarShiftDecisionWrite decision,
    required String actorKind,
  }) async {
    writes.add(decision);
    actorKinds.add(actorKind);
    return _row(
      decisionType: decision.decisionType,
      requestHash: decision.requestHash,
      idempotencyKey: decision.idempotencyKey,
      recommendationReferenceId: decision.recommendationReferenceId,
      candidateSnapshot: decision.candidateSnapshot,
      recordKey: decision.recordKey,
      reason: decision.reason,
    );
  }

  @override
  Future<List<SelectedStarShiftDecisionRow>> listUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) async {
    updatedSinceCalls.add((updatedAfter: updatedAfter, limit: limit));
    return updatedRows;
  }

  @override
  Future<List<SelectedStarShiftDecisionRow>> listCurrentSelections({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
    int limit = 250,
  }) async {
    currentSelectionCalls.add((restaurantId: restaurantId, limit: limit));
    return currentRows;
  }
}

SelectedStarShiftDecisionRow _row({
  required String decisionType,
  required String requestHash,
  required String idempotencyKey,
  String? recommendationReferenceId = 'rec-123',
  Map<String, Object?> candidateSnapshot = const <String, Object?>{
    'source': 'closed_shift_history',
  },
  String recordKey = '2026-W19|Wednesday|dinner',
  String? reason = 'manager selected star',
  DateTime? updatedAt,
}) {
  final isClear = decisionType.endsWith('_cleared');
  final source = decisionType.startsWith('admin_') ? 'admin' : 'manager';
  return SelectedStarShiftDecisionRow(
    decisionId: '44444444-4444-4444-4444-444444444444',
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    recordKey: recordKey,
    weekId: '2026-W19',
    dayLabel: 'Wednesday',
    daypart: 'dinner',
    businessDate: '2026-05-06',
    servicePeriodKey: 'dinner',
    targetCycleId: null,
    decisionType: decisionType,
    decisionSource: source,
    actorUserId: _userId,
    decidedAt: DateTime.utc(2026, 5, 6, 18),
    sourceSystem: isClear ? null : 'pos',
    sourceShiftId: isClear ? null : 'shift-1',
    sourceShiftRecordId: isClear ? null : 'record-1',
    covers: isClear ? null : 120,
    cplh: isClear ? null : 12.4,
    splh: isClear ? null : 152.0,
    ppa: isClear ? null : 42.5,
    primaryLeverId: isClear ? null : 'labor',
    actualLaborPct: isClear ? null : 21.4,
    hasActualLaborPctTruth: !isClear,
    recommendationReferenceId: isClear ? null : recommendationReferenceId,
    candidateSnapshot: isClear ? const <String, Object?>{} : candidateSnapshot,
    reason: reason,
    idempotencyKey: idempotencyKey,
    requestHash: requestHash,
    metadata: const <String, Object?>{},
    createdAt: DateTime.utc(2026, 5, 6, 18),
    updatedAt: updatedAt ?? DateTime.utc(2026, 5, 6, 18),
  );
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpJson(
  HttpClient client,
  Uri uri, {
  required String method,
  required String? idempotencyKey,
  required Map<String, Object?> body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  request.headers.contentType = ContentType.json;
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  final encoded = utf8.encode(jsonEncode(body));
  request.contentLength = encoded.length;
  request.add(encoded);
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}

Future<_HttpResponseSnapshot> _httpGet(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
