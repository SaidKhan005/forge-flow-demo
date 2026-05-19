// Phase 8 star/target truth - selected-star proxy route tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/selected_star_shift_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/server_target_cycle_projection_service.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';
const String _restaurantId = 'demo_restaurant';
const String _baseOperatorLocationPath =
    '/v1/operators/$_operatorId/locations/$_locationId';
const String _basePath =
    '$_baseOperatorLocationPath/$selectedStarShiftDecisionsResource';

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

Map<String, Object?> _projectionBody({bool includeDayparts = false}) {
  final standards = <String, Object?>{
    'target_cplh': 12.4,
    'target_splh': 152.0,
    'target_ppa': 42.5,
    'foh_wage': 18.0,
    'boh_wage': 20.0,
    'opz_floor_cplh': 12.0,
    'opz_ceiling_cplh': 14.0,
  };
  if (includeDayparts) {
    standards['target_cycle_dayparts'] = <Object?>[
      <String, Object?>{
        'service_period_id': 'afternoon_tea',
        'target_cplh': 0,
        'target_splh': 0,
        'target_ppa': 0,
        'opz_floor_cplh': 0,
        'opz_ceiling_cplh': 0,
        'cover_count': 0,
      },
      <String, Object?>{
        'service_period_key': 'supper_rush',
        'target_cplh': 6.8,
        'target_splh': 190.0,
        'target_ppa': 48.0,
        'opz_floor_cplh': 5.4,
        'opz_ceiling_cplh': 8.2,
        'cover_count': 42,
      },
    ];
  }
  return <String, Object?>{
    'restaurant_id': _restaurantId,
    'effective_start': '2026-05-06',
    'effective_end': '2026-07-04',
    'calibration_window_start': '2026-03-08',
    'calibration_window_end': '2026-05-06',
    'standards': standards,
    'reason': 'manager selected star target on mobile',
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
            roles: <String>['operator_general_manager'],
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
      'POST select records a general-manager decision through repository seam',
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

    test(
      'POST manager projection writes target cycle and active profile',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            ctx.gateway.currentRows = <SelectedStarShiftDecisionRow>[
              _row(
                decisionType: 'manager_selected',
                requestHash: 'hash-existing',
                idempotencyKey: 'idem-existing',
              ),
            ];
            final response = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve(
                '$_baseOperatorLocationPath/$targetCyclesResource/'
                'project_manager_override',
              ),
              method: 'POST',
              idempotencyKey: 'projection-idem',
              body: _projectionBody(),
            );

            expect(response.statusCode, equals(200));
            expect(ctx.permissionGuard.contexts, hasLength(1));
            expect(ctx.gateway.projectionCommands, hasLength(1));
            final command = ctx.gateway.projectionCommands.single;
            expect(command.restaurantId, _restaurantId);
            expect(command.effectiveStart, '2026-05-06');
            expect(command.effectiveEnd, '2026-07-04');
            expect(command.standards.targetCplh, 12.4);
            expect(command.actorUserId, _userId);
            expect(command.idempotencyKey, 'projection-idem');

            final json = jsonDecode(response.body) as Map<String, Object?>;
            final cycle = json['target_cycle'] as Map<String, Object?>;
            final profile =
                json['active_target_profile'] as Map<String, Object?>;
            final summary =
                json['selected_star_summary'] as Map<String, Object?>;
            expect(cycle['source'], 'manager_override');
            expect(profile['source_type'], 'cycle_manager_override');
            expect(summary['selected_shift_count'], 1);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST manager projection accepts arbitrary service-period target rows',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            ctx.gateway.currentRows = <SelectedStarShiftDecisionRow>[
              _row(
                decisionType: 'manager_selected',
                requestHash: 'hash-existing',
                idempotencyKey: 'idem-existing',
              ),
            ];
            final response = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve(
                '$_baseOperatorLocationPath/$targetCyclesResource/'
                'project_manager_override',
              ),
              method: 'POST',
              idempotencyKey: 'projection-dayparts',
              body: _projectionBody(includeDayparts: true),
            );

            expect(response.statusCode, equals(200));
            final command = ctx.gateway.projectionCommands.single;
            expect(command.standards.dayparts, hasLength(2));
            expect(
              command.standards.dayparts.map((row) => row.servicePeriodId),
              <String>['afternoon_tea', 'supper_rush'],
            );
            expect(command.standards.dayparts.first.targetCplh, 0);
            expect(command.standards.dayparts.first.coverCount, 0);
            expect(command.standards.dayparts.last.targetPpa, 48);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('manager projection maps once-per-cycle denial to 409', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.denyProjection = true;
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(
              '$_baseOperatorLocationPath/$targetCyclesResource/'
              'project_manager_override',
            ),
            method: 'POST',
            idempotencyKey: 'projection-denied',
            body: _projectionBody(),
          );

          expect(response.statusCode, equals(409));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'manager_override_already_used');
          expect(body['active_cycle_id'], _cycleId);
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

    test('read returns target-cycle and profile mirrors for sync', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.targetCycleRows = <TargetCyclePostgresRow>[
            _targetCycleRow(
              updatedAt: DateTime.utc(2026, 5, 6, 18, 2),
              dayparts: _targetCycleDayparts(),
            ),
          ];
          ctx.gateway.activeProfileRows = <ActiveTargetProfilePostgresRow>[
            _activeProfileRow(
              updatedAt: DateTime.utc(2026, 5, 6, 18, 3),
              dayparts: _activeProfileDayparts(),
            ),
          ];
          ctx.gateway.targetProfileVersionRows =
              <TargetProfileVersionPostgresRow>[
                _targetProfileVersionRow(
                  updatedAt: DateTime.utc(2026, 5, 6, 18, 4),
                ),
              ];

          final cycleResponse = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$_baseOperatorLocationPath/$targetCyclesResource'
              '?modified_since=2026-05-06T18:00:00Z&page_size=10',
            ),
          );
          final profileResponse = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$_baseOperatorLocationPath/$activeTargetProfilesResource'
              '?modified_since=2026-05-06T18:00:00Z&page_size=11',
            ),
          );
          final versionResponse = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$_baseOperatorLocationPath/$targetProfileVersionsResource'
              '?modified_since=2026-05-06T18:00:00Z&page_size=12',
            ),
          );

          expect(cycleResponse.statusCode, equals(200));
          expect(profileResponse.statusCode, equals(200));
          expect(versionResponse.statusCode, equals(200));
          expect(ctx.permissionGuard.contexts, isEmpty);
          expect(ctx.gateway.targetCycleCalls.single.limit, equals(10));
          expect(ctx.gateway.activeProfileCalls.single.limit, equals(11));
          expect(
            ctx.gateway.targetProfileVersionCalls.single.limit,
            equals(12),
          );

          final cycleBody =
              jsonDecode(cycleResponse.body) as Map<String, Object?>;
          final cycles = cycleBody[targetCyclesResource] as List<dynamic>;
          final cycleJson = cycles.single as Map<String, Object?>;
          expect(cycleJson['cycle_id'], _cycleId);
          final cycleDayparts = cycleJson['dayparts'] as List<dynamic>;
          expect(cycleDayparts, hasLength(2));
          expect(
            (cycleDayparts.first as Map<String, Object?>)['service_period_id'],
            'afternoon_tea',
          );
          expect(
            (cycleDayparts.first as Map<String, Object?>)['target_cplh'],
            0,
          );
          expect(
            (cycleJson['target_cycle_dayparts'] as List<dynamic>),
            hasLength(2),
          );
          expect(cycleBody['next_cursor'], equals('2026-05-06T18:02:00.000Z'));

          final profileBody =
              jsonDecode(profileResponse.body) as Map<String, Object?>;
          final profiles =
              profileBody[activeTargetProfilesResource] as List<dynamic>;
          final profileJson = profiles.single as Map<String, Object?>;
          expect(profileJson['target_cycle_id'], _cycleId);
          final profileDayparts = profileJson['dayparts'] as List<dynamic>;
          expect(profileDayparts, hasLength(2));
          expect(
            (profileDayparts.last
                as Map<String, Object?>)['daypart_target_ppa'],
            48,
          );
          expect(
            (profileJson['active_target_profile_dayparts'] as List<dynamic>),
            hasLength(2),
          );
          expect(
            profileBody['next_cursor'],
            equals('2026-05-06T18:03:00.000Z'),
          );

          final versionBody =
              jsonDecode(versionResponse.body) as Map<String, Object?>;
          final versions =
              versionBody[targetProfileVersionsResource] as List<dynamic>;
          expect(
            (versions.single as Map<String, Object?>)['target_profile_id'],
            _targetProfileId,
          );
          expect(
            versionBody['next_cursor'],
            equals('2026-05-06T18:04:00.000Z'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('read returns honest-unavailable shape when projection is empty '
        '(Theme H#3)', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$_basePath?modified_since=2026-05-06T18:00:00Z&page_size=25',
            ),
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          // The new honest-unavailable shape — sync clients short-circuit
          // on `available:false` instead of treating zero rows as a synced
          // empty page.
          expect(body['available'], isFalse);
          expect(body['status'], equals('unavailable'));
          expect(body['unavailable_reason'], equals('no_projected_rows'));
          expect(body['reason'], equals('no_projected_rows'));
          expect(body['selected_star_shift_decisions'], isEmpty);
          expect(body['next_cursor'], isNull);
          expect(body['has_more'], isFalse);
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
            roles: <String>['operator_general_manager'],
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
  List<TargetCyclePostgresRow> targetCycleRows = <TargetCyclePostgresRow>[];
  List<ActiveTargetProfilePostgresRow> activeProfileRows =
      <ActiveTargetProfilePostgresRow>[];
  List<TargetProfileVersionPostgresRow> targetProfileVersionRows =
      <TargetProfileVersionPostgresRow>[];
  final List<ServerTargetCycleProjectionCommand> projectionCommands =
      <ServerTargetCycleProjectionCommand>[];
  bool denyProjection = false;
  final List<({DateTime updatedAfter, int limit})> updatedSinceCalls =
      <({DateTime updatedAfter, int limit})>[];
  final List<({String restaurantId, int limit})> currentSelectionCalls =
      <({String restaurantId, int limit})>[];
  final List<({DateTime updatedAfter, int limit})> targetCycleCalls =
      <({DateTime updatedAfter, int limit})>[];
  final List<({DateTime updatedAfter, int limit})> activeProfileCalls =
      <({DateTime updatedAfter, int limit})>[];
  final List<({DateTime updatedAfter, int limit})> targetProfileVersionCalls =
      <({DateTime updatedAfter, int limit})>[];

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
  Future<ServerTargetCycleProjectionResult>
  projectManagerOverrideFromCurrentServerSelections({
    required ServerTargetCycleProjectionCommand command,
  }) async {
    projectionCommands.add(command);
    if (denyProjection) {
      throw const TargetCycleManagerOverrideAlreadyUsed(
        _cycleId,
        _restaurantId,
      );
    }
    return ServerTargetCycleProjectionResult(
      cycle: _targetCycleRow(
        source: 'manager_override',
        managerOverrideUsed: true,
      ),
      activeProfile: _activeProfileRow(sourceType: 'cycle_manager_override'),
      selectedStarSummary: const ServerSelectedStarSummary(
        selectedShiftCount: 1,
        recordKeys: <String>['2026-W19|Wednesday|dinner'],
        decisionIds: <String>['44444444-4444-4444-4444-444444444444'],
      ),
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

  @override
  Future<List<TargetCyclePostgresRow>> listTargetCyclesUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) async {
    targetCycleCalls.add((updatedAfter: updatedAfter, limit: limit));
    return targetCycleRows;
  }

  @override
  Future<List<ActiveTargetProfilePostgresRow>>
  listActiveTargetProfilesUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) async {
    activeProfileCalls.add((updatedAfter: updatedAfter, limit: limit));
    return activeProfileRows;
  }

  @override
  Future<List<TargetProfileVersionPostgresRow>>
  listTargetProfileVersionsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) async {
    targetProfileVersionCalls.add((updatedAfter: updatedAfter, limit: limit));
    return targetProfileVersionRows;
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

const String _cycleId = '55555555-5555-5555-5555-555555555555';
const String _targetProfileId = '66666666-6666-6666-6666-666666666666';
const String _targetProfileVersionId = '77777777-7777-7777-7777-777777777777';

TargetCyclePostgresRow _targetCycleRow({
  DateTime? updatedAt,
  String source = 'recommended',
  bool managerOverrideUsed = false,
  List<TargetCyclePostgresDaypartRow> dayparts =
      const <TargetCyclePostgresDaypartRow>[],
}) {
  return TargetCyclePostgresRow(
    cycleId: _cycleId,
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    source: source,
    effectiveStart: '2026-05-04',
    effectiveEnd: '2026-05-10',
    calibrationWindowStart: '2026-04-20',
    calibrationWindowEnd: '2026-05-03',
    targetCplh: 12.0,
    targetSplh: 152.0,
    targetPpa: 42.5,
    fohWage: 18.0,
    bohWage: 20.0,
    opzFloorCplh: 10.0,
    opzCeilingCplh: 14.0,
    managerOverrideUsed: managerOverrideUsed,
    managerOverrideAt: managerOverrideUsed
        ? DateTime.utc(2026, 5, 6, 18)
        : null,
    managerOverrideByUserId: managerOverrideUsed ? _userId : null,
    adminReplacedAt: null,
    adminReplacedByUserId: null,
    supersedesCycleId: null,
    selectedShiftCount: 1,
    selectedRecordKeys: const <String>['2026-W19|Wednesday|dinner'],
    selectionDecisionIds: const <String>[
      '44444444-4444-4444-4444-444444444444',
    ],
    replacementReason: null,
    idempotencyKey: 'cycle-idem',
    requestHash: 'cycle-hash',
    createdBy: _userId,
    createdAt: DateTime.utc(2026, 5, 6, 18),
    updatedAt: updatedAt ?? DateTime.utc(2026, 5, 6, 18),
    deactivatedAt: null,
    dayparts: dayparts,
  );
}

ActiveTargetProfilePostgresRow _activeProfileRow({
  DateTime? updatedAt,
  String sourceType = 'cycle_recommended',
  List<ActiveTargetProfileDaypartRow> dayparts =
      const <ActiveTargetProfileDaypartRow>[],
}) {
  return ActiveTargetProfilePostgresRow(
    targetProfileId: _targetProfileId,
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    targetCycleId: _cycleId,
    targetProfileVersionId: _targetProfileVersionId,
    sourceType: sourceType,
    targetCplh: 12.0,
    targetSplh: 152.0,
    targetPpa: 42.5,
    fohWage: 18.0,
    bohWage: 20.0,
    opzFloorCplh: 10.0,
    opzCeilingCplh: 14.0,
    theoreticalFohLaborPct: 18.5,
    theoreticalBohLaborPct: 8.25,
    theoreticalLaborPct: 26.75,
    builtAt: DateTime.utc(2026, 5, 6, 18, 1),
    projectionSource: 'server_target_cycle_projection_service',
    createdAt: DateTime.utc(2026, 5, 6, 18),
    updatedAt: updatedAt ?? DateTime.utc(2026, 5, 6, 18),
    dayparts: dayparts,
  );
}

List<TargetCyclePostgresDaypartRow> _targetCycleDayparts() =>
    <TargetCyclePostgresDaypartRow>[
      TargetCyclePostgresDaypartRow(
        cycleId: _cycleId,
        operatorId: _operatorId,
        locationId: _locationId,
        servicePeriodId: 'afternoon_tea',
        targetCplh: 0,
        targetSplh: 0,
        targetPpa: 0,
        opzFloorCplh: 0,
        opzCeilingCplh: 0,
        coverCount: 0,
        verdict: null,
        verdictReason: null,
        createdAt: DateTime.utc(2026, 5, 6, 18),
        updatedAt: DateTime.utc(2026, 5, 6, 18),
      ),
      TargetCyclePostgresDaypartRow(
        cycleId: _cycleId,
        operatorId: _operatorId,
        locationId: _locationId,
        servicePeriodId: 'supper_rush',
        targetCplh: 6.8,
        targetSplh: 190,
        targetPpa: 48,
        opzFloorCplh: 5.4,
        opzCeilingCplh: 8.2,
        coverCount: 42,
        verdict: 'teachable',
        verdictReason: 'period has stable selected evidence',
        createdAt: DateTime.utc(2026, 5, 6, 18),
        updatedAt: DateTime.utc(2026, 5, 6, 18),
      ),
    ];

List<ActiveTargetProfileDaypartRow> _activeProfileDayparts() =>
    const <ActiveTargetProfileDaypartRow>[
      ActiveTargetProfileDaypartRow(
        servicePeriodId: 'afternoon_tea',
        daypartTargetCplh: 0,
        daypartTargetSplh: 0,
        daypartTargetPpa: 0,
        daypartOpzFloorCplh: 0,
        daypartOpzCeilingCplh: 0,
      ),
      ActiveTargetProfileDaypartRow(
        servicePeriodId: 'supper_rush',
        daypartTargetCplh: 6.8,
        daypartTargetSplh: 190,
        daypartTargetPpa: 48,
        daypartOpzFloorCplh: 5.4,
        daypartOpzCeilingCplh: 8.2,
        verdict: 'teachable',
        verdictReason: 'period has stable selected evidence',
      ),
    ];

TargetProfileVersionPostgresRow _targetProfileVersionRow({
  DateTime? updatedAt,
}) {
  return TargetProfileVersionPostgresRow(
    targetProfileVersionId: _targetProfileVersionId,
    operatorId: _operatorId,
    locationId: _locationId,
    targetProfileId: _targetProfileId,
    restaurantId: _restaurantId,
    targetCycleId: _cycleId,
    sourceType: 'cycle_recommended',
    targetCplh: 12.0,
    targetSplh: 152.0,
    targetPpa: 42.5,
    fohWage: 18.0,
    bohWage: 20.0,
    opzFloorCplh: 10.0,
    opzCeilingCplh: 14.0,
    theoreticalFohLaborPct: 18.5,
    theoreticalBohLaborPct: 8.25,
    theoreticalLaborPct: 26.75,
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
