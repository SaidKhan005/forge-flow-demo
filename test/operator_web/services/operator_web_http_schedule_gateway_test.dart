// Phase 8 W5.B - HTTP schedule gateway tests.
//
// Coverage:
//   * GET round-trip parses the proxy `weekly_plan_snapshots` +
//     `forecast_contexts` response shape, picks the active snapshot,
//     and pairs it with the matching forecast context.
//   * 4xx surfaces a plain-English message via
//     OperatorWebScheduleGatewayException.
//   * Missing token short-circuits before any HTTP call.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/operator_web_schedule_gateway.dart';

void main() {
  group('OperatorWebHttpScheduleGateway', () {
    Map<String, Object?> snapshotPayload({
      String snapshotId = 'snap-1',
      String weekStart = '2026-05-04',
      String weekEnd = '2026-05-10',
      bool isActive = true,
      DateTime? lockedAt,
    }) {
      final lock = lockedAt ?? DateTime.utc(2026, 5, 3, 12);
      return <String, Object?>{
        'snapshot_id': snapshotId,
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'restaurant_id': 'rest-1',
        'week_start_date': weekStart,
        'week_end_date': weekEnd,
        'target_cycle_id': 'cycle-1',
        'forecast_context_id': 'ctx-1',
        'forecast_covers': 1230,
        'forecast_sales': 46740.0,
        'required_foh_hours': 260,
        'required_boh_hours': 188,
        'theoretical_foh_labor_dollars': 4810.0,
        'theoretical_boh_labor_dollars': 3055.0,
        'covers_source': 'app_derived_from_historical_average',
        'sales_source': 'app_derived_from_historical_average',
        'day_rows': <Map<String, Object?>>[
          for (var i = 0; i < 7; i++)
            <String, Object?>{
              'day': const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i],
              'business_date':
                  '2026-05-${(4 + i).toString().padLeft(2, '0')}',
              'forecast_covers': 175,
              'forecast_sales': 6675.0,
              'required_foh_hours': 36,
              'required_boh_hours': 28,
            },
        ],
        'locked_at': lock.toIso8601String(),
        'locked_by_user_id': 'user-1',
        'lock_reason': 'auto',
        'is_active': isActive,
        'idempotency_key': 'idem-1',
        'request_hash': 'hash-1',
        'metadata': <String, Object?>{},
        'created_at': lock.toIso8601String(),
        'updated_at': lock.toIso8601String(),
      };
    }

    Map<String, Object?> contextPayload({
      String forecastContextId = 'ctx-1',
      String weekStart = '2026-05-04',
      String weekEnd = '2026-05-10',
      String coversSource = 'app_derived_from_historical_average',
      int? baselineWeeklyAvgCovers = 1180,
      int? baselineTotalCovers = 10110,
      double baselineWeeksRepresented = 60 / 7,
    }) {
      return <String, Object?>{
        'forecast_context_id': forecastContextId,
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'restaurant_id': 'rest-1',
        'anchor_business_date': '2026-05-03',
        'week_start_date': weekStart,
        'week_end_date': weekEnd,
        'baseline_total_covers': baselineTotalCovers,
        'baseline_weekly_avg_covers': baselineWeeklyAvgCovers,
        'baseline_weeks_represented': baselineWeeksRepresented,
        'recent_three_week_total_covers': 3540,
        'recent_three_week_weekly_avg_covers': 1180,
        'recent_trend_delta_covers': 0,
        'resolved_weekly_forecast_covers': 1230,
        'target_ppa': 38.0,
        'forecast_sales': 46740.0,
        'required_foh_hours': 260,
        'required_boh_hours': 188,
        'theoretical_labor_dollars': 7865.0,
        'covers_source': coversSource,
        'built_at': '2026-05-03T12:00:00Z',
        'created_at': '2026-05-03T12:00:00Z',
        'updated_at': '2026-05-03T12:00:00Z',
      };
    }

    test(
      'fetchCurrent fans out to snapshots + contexts and pairs by week range',
      () async {
        final captured = <http.Request>[];
        final mock = MockClient((request) async {
          captured.add(request);
          if (request.url.path.endsWith('/weekly_plan_snapshots')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'weekly_plan_snapshots': <Map<String, Object?>>[
                  snapshotPayload(
                    snapshotId: 'older',
                    weekStart: '2026-04-27',
                    weekEnd: '2026-05-03',
                    lockedAt: DateTime.utc(2026, 4, 26, 12),
                  ),
                  snapshotPayload(),
                ],
                'next_cursor': null,
                'has_more': false,
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          if (request.url.path.endsWith('/forecast_contexts')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'forecast_contexts': <Map<String, Object?>>[contextPayload()],
                'next_cursor': null,
                'has_more': false,
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response('{}', 404);
        });
        final gateway = OperatorWebHttpScheduleGateway(
          proxyBaseUri: Uri.parse('https://proxy.test/'),
          idTokenProvider: () async => 'demo-id-token',
          client: mock,
        );

        final snapshot = await gateway.fetchCurrent(
          operatorId: 'op-1',
          locationId: 'loc-1',
        );
        expect(snapshot, isNotNull);
        expect(snapshot!.snapshotId, 'snap-1');
        expect(snapshot.weekStartDate, '2026-05-04');
        expect(snapshot.dayRows, hasLength(7));
        expect(snapshot.forecastContext, isNotNull);
        expect(snapshot.forecastContext!.targetPpa, 38.0);
        expect(snapshot.forecastContext!.hasBaseline, isTrue);
        expect(captured, hasLength(2));
        for (final request in captured) {
          expect(request.method, 'GET');
          expect(request.headers['authorization'], 'Bearer demo-id-token');
        }
      },
    );

    test('fetchCurrent surfaces a plain-English message on 4xx', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'forbidden',
            'message': "You don't have permission to view this schedule.",
          }),
          403,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = OperatorWebHttpScheduleGateway(
        proxyBaseUri: Uri.parse('https://proxy.test/'),
        idTokenProvider: () async => 'demo-id-token',
        client: mock,
      );
      await expectLater(
        gateway.fetchCurrent(operatorId: 'op-1', locationId: 'loc-1'),
        throwsA(
          isA<OperatorWebScheduleGatewayException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', contains('permission')),
        ),
      );
    });

    test('fetchCurrent throws when the id token is missing', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return http.Response('{}', 200);
      });
      final gateway = OperatorWebHttpScheduleGateway(
        proxyBaseUri: Uri.parse('https://proxy.test/'),
        idTokenProvider: () async => null,
        client: mock,
      );
      await expectLater(
        gateway.fetchCurrent(operatorId: 'op-1', locationId: 'loc-1'),
        throwsA(
          isA<OperatorWebScheduleGatewayException>()
              .having((e) => e.code, 'code', 'unauthenticated'),
        ),
      );
      expect(calls, 0);
    });

    test('fetchCurrent returns null when the proxy returns no snapshots',
        () async {
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/weekly_plan_snapshots')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'operator_id': 'op-1',
              'location_id': 'loc-1',
              'weekly_plan_snapshots': <Map<String, Object?>>[],
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }
        return http.Response('{}', 200);
      });
      final gateway = OperatorWebHttpScheduleGateway(
        proxyBaseUri: Uri.parse('https://proxy.test/'),
        idTokenProvider: () async => 'demo-id-token',
        client: mock,
      );
      final snapshot = await gateway.fetchCurrent(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      expect(snapshot, isNull);
    });

    test(
      'fetchCurrent flags thin-history when the forecast context is unavailable',
      () async {
        final mock = MockClient((request) async {
          if (request.url.path.endsWith('/weekly_plan_snapshots')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'weekly_plan_snapshots': <Map<String, Object?>>[
                  snapshotPayload(),
                ],
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          if (request.url.path.endsWith('/forecast_contexts')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'forecast_contexts': <Map<String, Object?>>[
                  contextPayload(
                    coversSource: 'unavailable',
                    baselineWeeklyAvgCovers: null,
                    baselineTotalCovers: null,
                    baselineWeeksRepresented: 29 / 7,
                  ),
                ],
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response('{}', 404);
        });
        final gateway = OperatorWebHttpScheduleGateway(
          proxyBaseUri: Uri.parse('https://proxy.test/'),
          idTokenProvider: () async => 'demo-id-token',
          client: mock,
        );
        final snapshot = await gateway.fetchCurrent(
          operatorId: 'op-1',
          locationId: 'loc-1',
        );
        expect(snapshot, isNotNull);
        expect(snapshot!.forecastContext, isNotNull);
        expect(snapshot.forecastContext!.hasBaseline, isFalse);
        expect(snapshot.forecastContext!.historyDays, 29);
      },
    );
  });
}
