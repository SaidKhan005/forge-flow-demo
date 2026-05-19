// Phase 8 weekly-plan truth - proxy route tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';
const String _restaurantId = 'demo_restaurant';
const String _baseOperatorLocationPath =
    '/v1/operators/$_operatorId/locations/$_locationId';
const String _snapshotsPath =
    '$_baseOperatorLocationPath/$weeklyPlanSnapshotsResource';
const String _contextsPath =
    '$_baseOperatorLocationPath/$forecastContextsResource';

Map<String, Object?> _lockBody({
  String weekStartDate = '2026-05-04',
  int forecastCovers = 840,
}) {
  return <String, Object?>{
    'restaurant_id': _restaurantId,
    'week_start_date': weekStartDate,
    'week_end_date': '2026-05-10',
    'target_cycle_id': _targetCycleId,
    'forecast_context_id': _forecastContextId,
    'forecast_covers': forecastCovers,
    'forecast_sales': 35700.0,
    'required_foh_hours': 72,
    'required_boh_hours': 54,
    'theoretical_foh_labor_dollars': 1296.0,
    'theoretical_boh_labor_dollars': 1080.0,
    'covers_source': 'appDerivedFromHistoricalAverage',
    'sales_source': 'appDerivedFromCoversAndPpa',
    'day_rows': <Map<String, Object?>>[
      const <String, Object?>{
        'day': 'Monday',
        'business_date': '2026-05-04',
        'forecast_covers': 120,
        'forecast_sales': 5100.0,
        'required_foh_hours': 10,
        'required_boh_hours': 8,
      },
    ],
    'day_dayparts': <Map<String, Object?>>[
      const <String, Object?>{
        'business_date': '2026-05-04',
        'service_period_id': 'brunch',
        'forecast_covers': 72,
        'forecast_sales': 3060.0,
        'required_foh_hours': 6.5,
        'required_boh_hours': 5.25,
        'theoretical_foh_dollars': 117.0,
        'theoretical_boh_dollars': 105.0,
      },
    ],
    'wage_at_lock_time_json': const <String, Object?>{
      'foh_wage': 18.0,
      'boh_wage': 20.0,
      'blended_wage': 19.0,
    },
    'reason': 'manager locked current week',
    'metadata': const <String, Object?>{'device_id': 'ipad-1'},
  };
}

Map<String, Object?> _lockBodyWithEmbeddedForecastContext() {
  return <String, Object?>{
    ..._lockBody(),
    'forecast_context_id': null,
    'forecast_context': const <String, Object?>{
      'restaurant_id': _restaurantId,
      'anchor_business_date': '2026-05-03',
      'baseline_total_covers': 7200,
      'baseline_weekly_avg_covers': 840,
      'baseline_weeks_represented': 8.571,
      'recent_three_week_total_covers': 2640,
      'recent_three_week_weekly_avg_covers': 880,
      'recent_trend_delta_covers': 40,
      'resolved_weekly_forecast_covers': 860,
      'covers_source': 'appDerivedFromHistoricalAverage',
      'built_at': '2026-05-06T18:00:00Z',
    },
  };
}

void main() {
  tearDown(WeeklyPlanRouter.resetGlobalForTesting);

  group('weekly-plan proxy routes', () {
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
        _RecordingWeeklyPlanGateway gateway,
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
      final gateway = _RecordingWeeklyPlanGateway();
      final router = WeeklyPlanRouter(gateway: gateway);
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
            weeklyPlanRouter: router,
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
      'GET reads weekly-plan snapshots and forecast contexts for sync',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            ctx.gateway.snapshotRows = <WeeklyPlanSnapshotRow>[
              _snapshotRow(updatedAt: DateTime.utc(2026, 5, 6, 18, 1)),
            ];
            ctx.gateway.contextRows = <ForecastContextRow>[
              _forecastContextRow(updatedAt: DateTime.utc(2026, 5, 6, 18, 2)),
            ];

            final snapshotResponse = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '$_snapshotsPath?modified_since=2026-05-06T18:00:00Z'
                '&page_size=25',
              ),
            );
            final contextResponse = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '$_contextsPath?cursor=2026-05-06T18:00:00Z&page_size=30',
              ),
            );

            expect(snapshotResponse.statusCode, equals(200));
            expect(contextResponse.statusCode, equals(200));
            expect(ctx.permissionGuard.contexts, isEmpty);
            expect(ctx.gateway.snapshotCalls.single.limit, equals(25));
            expect(ctx.gateway.contextCalls.single.limit, equals(30));

            final snapshotBody =
                jsonDecode(snapshotResponse.body) as Map<String, Object?>;
            final snapshots =
                snapshotBody[weeklyPlanSnapshotsResource] as List<dynamic>;
            expect(snapshots, hasLength(1));
            expect(
              (snapshots.single as Map<String, Object?>)['target_cycle_id'],
              equals(_targetCycleId),
            );
            expect(
              (snapshots.single as Map<String, Object?>)['day_dayparts'],
              isNotEmpty,
            );
            expect(
              (snapshots.single
                  as Map<String, Object?>)['wage_at_lock_time_json'],
              equals(<String, Object?>{
                'foh_wage': 18.0,
                'boh_wage': 20.0,
                'blended_wage': 19.0,
              }),
            );
            expect(
              snapshotBody['next_cursor'],
              equals('2026-05-06T18:01:00.000Z'),
            );

            final contextBody =
                jsonDecode(contextResponse.body) as Map<String, Object?>;
            final contexts =
                contextBody[forecastContextsResource] as List<dynamic>;
            expect(contexts, hasLength(1));
            expect(
              (contexts.single
                  as Map<String, Object?>)['resolved_weekly_forecast_covers'],
              equals(860),
            );
            expect(
              contextBody['next_cursor'],
              equals('2026-05-06T18:02:00.000Z'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('POST lock writes a manager snapshot through gateway seam', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_snapshotsPath/lock'),
            method: 'POST',
            idempotencyKey: 'idem-lock-1',
            body: _lockBodyWithEmbeddedForecastContext(),
          );

          expect(response.statusCode, equals(200));
          expect(ctx.permissionGuard.contexts, hasLength(1));
          expect(
            ctx.permissionGuard.contexts.single.requestedPermissionKey,
            equals(weeklyPlanLockPermissionKey),
          );
          expect(ctx.gateway.locks, hasLength(1));
          final lock = ctx.gateway.locks.single;
          expect(lock.operatorId, equals(_operatorId));
          expect(lock.locationId, equals(_locationId));
          expect(lock.actorUserId, equals(_userId));
          expect(lock.actorKind, equals('operator_user'));
          expect(lock.idempotencyKey, equals('idem-lock-1'));
          expect(lock.requestHash, isNotEmpty);
          expect(lock.embeddedForecastContext, isNotNull);
          expect(lock.dayRows.single.businessDate, equals('2026-05-04'));
          expect(lock.dayDayparts.single.servicePeriodId, equals('brunch'));
          expect(lock.wageAtLockTimeJson!['foh_wage'], equals(18.0));

          final body = jsonDecode(response.body) as Map<String, Object?>;
          final snapshot = body['snapshot'] as Map<String, Object?>;
          expect(snapshot['request_hash'], equals(lock.requestHash));
          expect(snapshot['week_key'], equals('2026-05-04_2026-05-10'));
          expect(snapshot['day_dayparts'], isNotEmpty);
          final wageAtLock =
              snapshot['wage_at_lock_time_json'] as Map<String, dynamic>;
          expect(
            wageAtLock['blended_wage'],
            equals(19.0),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST lock denies without weekly-plan permission', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(allowPermission: false);
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_snapshotsPath/lock'),
            method: 'POST',
            idempotencyKey: 'idem-denied',
            body: _lockBody(),
          );

          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(ctx.gateway.locks, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST lock requires Idempotency-Key', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_snapshotsPath/lock'),
            method: 'POST',
            idempotencyKey: null,
            body: _lockBody(),
          );

          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_missing'));
          expect(ctx.gateway.locks, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'POST lock replays same idempotency key without duplicate write',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final first = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve('$_snapshotsPath/lock'),
              method: 'POST',
              idempotencyKey: 'idem-replay',
              body: _lockBody(),
            );
            final second = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve('$_snapshotsPath/lock'),
              method: 'POST',
              idempotencyKey: 'idem-replay',
              body: _lockBody(),
            );

            expect(first.statusCode, equals(200));
            expect(second.statusCode, equals(200));
            expect(second.body, equals(first.body));
            expect(ctx.gateway.locks, hasLength(1));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST lock rejects idempotency conflict for a different body',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            await _httpJson(
              ctx.client,
              ctx.baseUri.resolve('$_snapshotsPath/lock'),
              method: 'POST',
              idempotencyKey: 'idem-conflict',
              body: _lockBody(),
            );
            final response = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve('$_snapshotsPath/lock'),
              method: 'POST',
              idempotencyKey: 'idem-conflict',
              body: _lockBody(forecastCovers: 841),
            );

            expect(response.statusCode, equals(409));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('idempotency_key_conflict'));
            expect(ctx.gateway.locks, hasLength(1));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'GET returns honest-unavailable shape for an empty page (Theme H#3)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '$_snapshotsPath?modified_since=2026-05-06T18:00:00Z'
                '&page_size=25',
              ),
            );

            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            // Honest-unavailable shape (Theme H#3) — clients short-circuit
            // on `available:false` rather than treating zero rows as a
            // synced empty page.
            expect(body['available'], isFalse);
            expect(body['status'], equals('unavailable'));
            expect(body['unavailable_reason'], equals('no_projected_rows'));
            expect(body['reason'], equals('no_projected_rows'));
            expect(body[weeklyPlanSnapshotsResource], isEmpty);
            expect(body['next_cursor'], isNull);
            expect(body['has_more'], isFalse);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('GET rejects caller scope mismatch before gateway access', () async {
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
            ctx.baseUri.resolve(_snapshotsPath),
          );

          expect(response.statusCode, equals(403));
          expect(ctx.gateway.snapshotCalls, isEmpty);
          expect(ctx.gateway.contextCalls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('GET rejects malformed page size', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve('$_snapshotsPath?page_size=0'),
          );

          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_page_size'));
          expect(ctx.gateway.snapshotCalls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST lock rejects malformed dates', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_snapshotsPath/lock'),
            method: 'POST',
            idempotencyKey: 'idem-bad-date',
            body: _lockBody(weekStartDate: '2026-02-31'),
          );

          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_week_start_date'));
          expect(ctx.gateway.locks, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('operator user cannot set proxy-owned actor fields', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve('$_snapshotsPath/lock'),
            method: 'POST',
            idempotencyKey: 'idem-forged-actor',
            body: <String, Object?>{
              ..._lockBody(),
              'actor_kind': 'forge_admin',
            },
          );

          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('actor_kind_not_client_settable'));
          expect(ctx.gateway.locks, isEmpty);
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

class _RecordingWeeklyPlanGateway implements WeeklyPlanGateway {
  final List<WeeklyPlanLockRequest> locks = <WeeklyPlanLockRequest>[];
  List<WeeklyPlanSnapshotRow> snapshotRows = <WeeklyPlanSnapshotRow>[];
  List<ForecastContextRow> contextRows = <ForecastContextRow>[];
  final List<({DateTime updatedAfter, int limit})> snapshotCalls =
      <({DateTime updatedAfter, int limit})>[];
  final List<({DateTime updatedAfter, int limit})> contextCalls =
      <({DateTime updatedAfter, int limit})>[];

  @override
  Future<WeeklyPlanSnapshotRow> lockSnapshot({
    required WeeklyPlanLockRequest request,
  }) async {
    locks.add(request);
    return _snapshotRow(
      requestHash: request.requestHash,
      idempotencyKey: request.idempotencyKey,
      forecastCovers: request.forecastCovers,
      dayRows: request.dayRows,
      dayDayparts: request.dayDayparts,
      wageAtLockTimeJson: request.wageAtLockTimeJson,
      lockReason: request.reason,
    );
  }

  @override
  Future<List<WeeklyPlanSnapshotRow>> listWeeklyPlanSnapshotsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) async {
    snapshotCalls.add((updatedAfter: updatedAfter, limit: limit));
    return snapshotRows;
  }

  @override
  Future<List<ForecastContextRow>> listForecastContextsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) async {
    contextCalls.add((updatedAfter: updatedAfter, limit: limit));
    return contextRows;
  }
}

const String _snapshotId = '44444444-4444-4444-4444-444444444444';
const String _targetCycleId = '55555555-5555-5555-5555-555555555555';
const String _forecastContextId = '66666666-6666-6666-6666-666666666666';

WeeklyPlanSnapshotRow _snapshotRow({
  String requestHash = 'hash-existing',
  String idempotencyKey = 'idem-existing',
  int forecastCovers = 840,
  List<WeeklyPlanDayPayload>? dayRows,
  List<WeeklyPlanDayDaypartPayload>? dayDayparts,
  Map<String, Object?>? wageAtLockTimeJson,
  String lockReason = 'manager locked current week',
  DateTime? updatedAt,
}) {
  return WeeklyPlanSnapshotRow(
    snapshotId: _snapshotId,
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    weekStartDate: '2026-05-04',
    weekEndDate: '2026-05-10',
    targetCycleId: _targetCycleId,
    forecastContextId: _forecastContextId,
    forecastCovers: forecastCovers,
    forecastSales: 35700.0,
    requiredFohHours: 72,
    requiredBohHours: 54,
    theoreticalFohLaborDollars: 1296.0,
    theoreticalBohLaborDollars: 1080.0,
    coversSource: 'appDerivedFromHistoricalAverage',
    salesSource: 'appDerivedFromCoversAndPpa',
    dayRows:
        dayRows ??
        const <WeeklyPlanDayPayload>[
          WeeklyPlanDayPayload(
            day: 'Monday',
            businessDate: '2026-05-04',
            forecastCovers: 120,
            forecastSales: 5100.0,
            requiredFohHours: 10,
            requiredBohHours: 8,
          ),
        ],
    dayDayparts:
        dayDayparts ??
        const <WeeklyPlanDayDaypartPayload>[
          WeeklyPlanDayDaypartPayload(
            businessDate: '2026-05-04',
            servicePeriodId: 'brunch',
            forecastCovers: 72,
            forecastSales: 3060.0,
            requiredFohHours: 6.5,
            requiredBohHours: 5.25,
            theoreticalFohDollars: 117.0,
            theoreticalBohDollars: 105.0,
          ),
        ],
    wageAtLockTimeJson:
        wageAtLockTimeJson ??
        const <String, Object?>{
          'foh_wage': 18.0,
          'boh_wage': 20.0,
          'blended_wage': 19.0,
        },
    lockedAt: DateTime.utc(2026, 5, 6, 18),
    lockedByUserId: _userId,
    lockReason: lockReason,
    isActive: true,
    supersedesSnapshotId: null,
    idempotencyKey: idempotencyKey,
    requestHash: requestHash,
    metadata: const <String, Object?>{},
    createdAt: DateTime.utc(2026, 5, 6, 18),
    updatedAt: updatedAt ?? DateTime.utc(2026, 5, 6, 18),
    supersededAt: null,
  );
}

ForecastContextRow _forecastContextRow({DateTime? updatedAt}) {
  return ForecastContextRow(
    forecastContextId: _forecastContextId,
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    anchorBusinessDate: '2026-05-03',
    weekStartDate: '2026-05-04',
    weekEndDate: '2026-05-10',
    baselineTotalCovers: 7200,
    baselineWeeklyAvgCovers: 840,
    baselineWeeksRepresented: 8.571,
    recentThreeWeekTotalCovers: 2640,
    recentThreeWeekWeeklyAvgCovers: 880,
    recentTrendDeltaCovers: 40,
    resolvedWeeklyForecastCovers: 860,
    targetPpa: 42.5,
    forecastSales: 36550.0,
    requiredFohHours: 74,
    requiredBohHours: 55,
    theoreticalLaborDollars: 2432.0,
    coversSource: 'appDerivedFromHistoricalAverage',
    builtAt: DateTime.utc(2026, 5, 6, 18),
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
