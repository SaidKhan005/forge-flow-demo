import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:forge_and_flow/services/star_target_selection_write_service.dart';
import 'package:forge_and_flow/services/sync/http_sync_proxy_client.dart';

void main() {
  test('fetchShiftRecords calls scoped proxy path with bearer token', () async {
    late http.Request seen;
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example'),
      idTokenProvider: () async => 'token-1',
      httpClient: http_testing.MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'records': <Object?>[_shiftRow()],
            'next_cursor': 'cursor-2',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final page = await client.fetchShiftRecords(
      operatorId: 'op-1',
      locationId: 'loc-1',
      cursor: 'cursor-1',
      pageSize: 50,
    );

    expect(seen.method, 'GET');
    expect(seen.url.path, '/v1/operators/op-1/locations/loc-1/shift_records');
    expect(seen.url.queryParameters['modified_since'], 'cursor-1');
    expect(seen.url.queryParameters['page_size'], '50');
    expect(seen.headers['authorization'], 'Bearer token-1');
    expect(page.records.single.weekId, '2026-W18');
    expect(page.nextCursor, 'cursor-2');
  });

  test(
    'submitSelectedStarDecision posts scoped body with idempotency key',
    () async {
      late http.Request seen;
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example/base/'),
        idTokenProvider: () async => 'token-1',
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'decision': <String, Object?>{'decision_id': 'decision-1'},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      await client.submitSelectedStarDecision(
        operatorId: 'op',
        locationId: 'loc',
        action: StarTargetSelectionWriteAction.select,
        idempotencyKey: 'idem-1',
        body: const <String, Object?>{
          'restaurant_id': 'restaurant-1',
          'record_key': '2026-W19|Wed|dinner',
          'week_id': '2026-W19',
          'day_label': 'Wed',
          'daypart': 'dinner',
          'business_date': '2026-05-06',
        },
      );

      expect(seen.method, 'POST');
      expect(
        seen.url.path,
        '/base/v1/operators/op/locations/loc/'
        'selected_star_shift_decisions/select',
      );
      expect(seen.headers['authorization'], 'Bearer token-1');
      expect(seen.headers['idempotency-key'], 'idem-1');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['record_key'], '2026-W19|Wed|dinner');
    },
  );

  test('parses open snapshots, timing config, and aux snapshots', () async {
    final requests = <String>[];
    final fullUrls = <String>[];
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example/base/'),
      idTokenProvider: () async => 'token-1',
      httpClient: http_testing.MockClient((request) async {
        requests.add(request.url.path);
        fullUrls.add(request.url.toString());
        final body = switch (request.url.path) {
          '/base/v1/operators/op/locations/loc/open_shift_snapshots' =>
            <String, Object?>{
              'open_shift_snapshots': <Object?>[_openSnapshotRow()],
            },
          '/base/v1/operators/op/locations/loc/timing/resolved' =>
            <String, Object?>{
              'timing_config': <String, Object?>{
                'restaurant_id': 'loc',
                'location_timezone': 'America/St_Johns',
                'business_day_start_local_time': '05:00:00',
                'week_start_day': 1,
                'close_authority': 'vendor_finalization',
                'service_period_definitions_json': jsonEncode(<Object?>[
                  <String, Object?>{
                    'service_period_key': 'brunch',
                    'label': 'Brunch',
                    'short_label': 'B',
                    'sort_order': 1,
                    'start_local_time': '09:00:00',
                    'end_local_time': '13:00:00',
                    'rolls_past_midnight': false,
                    'applicable_weekdays': <int>[6, 7],
                  },
                ]),
              },
            },
          '/base/v1/operators/op/locations/loc/demo_mode_states' =>
            <String, Object?>{
              'demo_mode_states': <Object?>[
                <String, Object?>{
                  'operator_id': 'op',
                  'location_id': 'loc',
                  'category': 'pos',
                  'is_demo': false,
                },
              ],
            },
          '/base/v1/operators/op/locations/loc/data_accuracy_settings' =>
            <String, Object?>{
              'data': <String, Object?>{
                'operator_id': 'op',
                'location_id': 'loc',
                'covers_source_lunch': 'vendor',
                'covers_source_dinner': 'manual',
                'covers_source_late_night': 'forecast',
                'covers_manual_entries': <String, Object?>{
                  '2026-05-05': <String, Object?>{'dinner': 120},
                },
                'wage_source': 'manual_mix',
                'updated_at': '2026-05-06T12:00:00Z',
              },
            },
          '/base/v1/operators/op/locations/loc/polling_tier_assignment' =>
            <String, Object?>{
              'assignment': <String, Object?>{
                'operator_id': 'op',
                'location_id': 'loc',
                'tier_key': 'premium',
                'polling_cadence_per_vendor_seconds': <String, Object?>{
                  'toast': 300,
                },
                'monthly_price_cents': 9900,
                'effective_at': '2026-05-06T12:00:00Z',
              },
            },
          '/base/v1/operators/op/locations/loc/first_backfill_status' =>
            <String, Object?>{
              'first_backfill_status': <String, Object?>{
                'job_id': 'job-1',
                'operator_id': 'op',
                'location_id': 'loc',
                'connection_id': 'conn-1',
                'vendor_id': 'toast',
                'category': 'pos',
                'status': 'running',
                'window_start': '2026-03-07T00:00:00Z',
                'window_end': '2026-05-06T00:00:00Z',
                'created_at': '2026-05-06T12:00:00Z',
                'updated_at': '2026-05-06T12:05:00Z',
              },
            },
          _ => <String, Object?>{},
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );

    final open = await client.fetchOpenShiftSnapshots(
      operatorId: 'op',
      locationId: 'loc',
      cursor: null,
      pageSize: 25,
    );
    final timing = await client.fetchResolvedTimingConfig(
      operatorId: 'op',
      locationId: 'loc',
      restaurantId: 'loc',
    );
    final demo = await client.fetchDemoModeStates(
      operatorId: 'op',
      locationId: 'loc',
    );
    final accuracy = await client.fetchDataAccuracySettings(
      operatorId: 'op',
      locationId: 'loc',
    );
    final tier = await client.fetchForgeFlowPollingTierAssignment(
      operatorId: 'op',
      locationId: 'loc',
    );
    final backfill = await client.fetchFirstBackfillStatus(
      operatorId: 'op',
      locationId: 'loc',
    );

    expect(open.snapshots.single.daypart, 'lunch');
    expect(open.snapshots.single.businessTimingProfileId, 'profile-1');
    expect(open.snapshots.single.businessTimingProfileVersionId, 'profile-1');
    expect(open.snapshots.single.servicePeriodKey, 'lunch');
    expect(timing!.businessDayStartLocalTime, '05:00');
    expect(timing.businessTimezone, 'America/St_Johns');
    expect(timing.servicePeriodDefinitions.single.id, 'brunch');
    expect(timing.servicePeriodDefinitions.single.startLocalTime, '09:00');
    expect(timing.servicePeriodDefinitions.single.applicableDays, <int>[6, 7]);
    expect(demo.single.isDemo, isFalse);
    expect(accuracy!.coversSourceDinner, 'manual');
    expect(accuracy.coversManualEntries['2026-05-05']!['dinner'], 120);
    expect(tier!.tierKey, 'premium');
    expect(tier.pollingCadencePerVendorSeconds['toast'], 300);
    expect(backfill!.status, 'running');
    expect(backfill.vendorId, 'toast');
    expect(backfill.isRunning, isTrue);
    expect(requests, hasLength(6));

    // BUG 3 (MEDIUM): non-root proxyBaseUri prefix MUST be preserved.
    // The previous implementation called `proxyBaseUri.resolve` against
    // an absolute path that wiped any prefix on the base URI; here we
    // assert the full URL contains the `/base/` segment AND the
    // composed `/v1/operators/...` tail.
    for (final url in fullUrls) {
      expect(
        url,
        startsWith('https://proxy.example/base/v1/operators/op/locations/loc/'),
        reason: 'every request URL must preserve the configured /base/ prefix',
      );
    }
  });

  test('missing first backfill status payload remains compatible', () async {
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example'),
      idTokenProvider: () async => 'token-1',
      httpClient: http_testing.MockClient((request) async {
        expect(
          request.url.path,
          '/v1/operators/op/locations/loc/first_backfill_status',
        );
        return http.Response(jsonEncode(<String, Object?>{}), 200);
      }),
    );

    final status = await client.fetchFirstBackfillStatus(
      operatorId: 'op',
      locationId: 'loc',
    );

    expect(status, isNull);
  });

  test(
    'legacy proxy without first backfill status route returns null',
    () async {
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example'),
        idTokenProvider: () async => 'token-1',
        httpClient: http_testing.MockClient((_) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'mobile_sync_route_not_found',
            }),
            404,
          );
        }),
      );

      final status = await client.fetchFirstBackfillStatus(
        operatorId: 'op',
        locationId: 'loc',
      );

      expect(status, isNull);
    },
  );

  test(
    'legacy open snapshot row without timing provenance still parses',
    () async {
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example'),
        idTokenProvider: () async => 'token-1',
        httpClient: http_testing.MockClient((_) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'open_shift_snapshots': <Object?>[_legacyOpenSnapshotRow()],
            }),
            200,
          );
        }),
      );

      final page = await client.fetchOpenShiftSnapshots(
        operatorId: 'op',
        locationId: 'loc',
        cursor: null,
        pageSize: 25,
      );

      final snapshot = page.snapshots.single;
      expect(snapshot.daypart, 'lunch');
      expect(snapshot.businessTimingProfileId, isNull);
      expect(snapshot.businessTimingProfileVersionId, isNull);
      expect(snapshot.servicePeriodKey, 'lunch');
    },
  );

  test(
    'non-root proxyBaseUri without trailing slash also keeps the prefix',
    () async {
      late http.Request seen;
      final client = HttpSyncProxyClient(
        // Note: no trailing slash on the base URI.
        proxyBaseUri: Uri.parse('https://proxy.example/api'),
        idTokenProvider: () async => 'tok',
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': const <Object?>[],
              'next_cursor': null,
            }),
            200,
          );
        }),
      );

      await client.fetchShiftRecords(
        operatorId: 'op',
        locationId: 'loc',
        cursor: null,
        pageSize: 10,
      );

      expect(
        seen.url.toString(),
        startsWith(
          'https://proxy.example/api/v1/operators/op/locations/loc/shift_records',
        ),
        reason:
            'BUG 3: prefix path on proxyBaseUri must be preserved even when '
            'the base URI is supplied without a trailing slash',
      );
    },
  );

  test('parses star-target sync resources and unavailable setup state', () async {
    final requests = <Uri>[];
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example/base/'),
      idTokenProvider: () async => 'token-1',
      httpClient: http_testing.MockClient((request) async {
        requests.add(request.url);
        final body = switch (request.url.path) {
          '/base/v1/operators/op/locations/loc/selected_star_shift_decisions' =>
            <String, Object?>{
              'decisions': <Object?>[
                <String, Object?>{
                  'operator_id': 'op',
                  'location_id': 'loc',
                  'restaurant_id': 'loc',
                  'record_key': '2026-W18|Mon|lunch',
                  'decision_type': 'manager_selected',
                  'updated_at': '2026-05-06T12:00:00Z',
                },
              ],
              'next_cursor': 'selected-next',
            },
          '/base/v1/operators/op/locations/loc/target_cycles' =>
            <String, Object?>{
              'target_cycles': <Object?>[_targetCycleRow()],
              'next_cursor': 'cycle-next',
            },
          '/base/v1/operators/op/locations/loc/active_target_profiles' =>
            <String, Object?>{
              'active_target_profiles': <Object?>[_activeProfileRow()],
            },
          '/base/v1/operators/op/locations/loc/target_profile_versions' =>
            <String, Object?>{
              'status': 'setup_required',
              'setup_reason': 'target_profile_versions_not_projected',
            },
          _ => <String, Object?>{},
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );

    final selected = await client.fetchSelectedStarShiftDecisions(
      operatorId: 'op',
      locationId: 'loc',
      cursor: 'selected-cursor',
      pageSize: 25,
    );
    final cycles = await client.fetchTargetCycles(
      operatorId: 'op',
      locationId: 'loc',
      cursor: null,
      pageSize: 25,
    );
    final profiles = await client.fetchActiveTargetProfiles(
      operatorId: 'op',
      locationId: 'loc',
      cursor: null,
      pageSize: 25,
    );
    final versions = await client.fetchTargetProfileVersions(
      operatorId: 'op',
      locationId: 'loc',
      cursor: null,
      pageSize: 25,
    );

    expect(selected.decisions.single.recordKey, '2026-W18|Mon|lunch');
    expect(selected.decisions.single.isSelected, isTrue);
    expect(selected.nextCursor, 'selected-next');
    expect(cycles.cycles.single.cycle.cycleId, 'cycle-1');
    expect(cycles.cycles.single.cycle.managerOverrideUsed, isTrue);
    expect(cycles.nextCursor, 'cycle-next');
    expect(profiles.profiles.single.profile.targetProfileId, 'profile-1');
    expect(versions.isUnavailable, isTrue);
    expect(versions.unavailableReason, 'target_profile_versions_not_projected');
    expect(requests.first.queryParameters['modified_since'], 'selected-cursor');
    expect(requests.first.queryParameters['page_size'], '25');
  });

  test('missing star-target proxy route reports unavailable page', () async {
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example'),
      idTokenProvider: () async => 'token-1',
      httpClient: http_testing.MockClient((_) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'not_found'}),
          404,
        );
      }),
    );

    final page = await client.fetchTargetCycles(
      operatorId: 'op',
      locationId: 'loc',
      cursor: null,
      pageSize: 25,
    );

    expect(page.isUnavailable, isTrue);
    expect(page.unavailableReason, 'star_target_proxy_route_not_found');
  });

  test(
    'parses weekly-plan sync resources and forecast context payloads',
    () async {
      final requests = <Uri>[];
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example/base/'),
        idTokenProvider: () async => 'token-1',
        httpClient: http_testing.MockClient((request) async {
          requests.add(request.url);
          final body = switch (request.url.path) {
            '/base/v1/operators/op/locations/loc/weekly_plan_snapshots' =>
              <String, Object?>{
                'snapshots': <Object?>[_weeklyPlanRow()],
                'nextCursor': 'weekly-next',
              },
            '/base/v1/operators/op/locations/loc/forecast_contexts' =>
              <String, Object?>{
                'forecast_context': _forecastContextRow(),
                'next_cursor': 'forecast-next',
              },
            _ => <String, Object?>{},
          };
          return http.Response(jsonEncode(body), 200);
        }),
      );

      final snapshots = await client.fetchWeeklyPlanSnapshots(
        operatorId: 'op',
        locationId: 'loc',
        cursor: 'weekly-cursor',
        pageSize: 25,
      );
      final contexts = await client.fetchForecastContexts(
        operatorId: 'op',
        locationId: 'loc',
        cursor: null,
        pageSize: 25,
      );

      expect(snapshots.snapshots.single.snapshot.snapshotId, 'wps-1');
      expect(
        snapshots.snapshots.single.snapshot.weekKey,
        '2026-05-04_2026-05-10',
      );
      expect(snapshots.snapshots.single.snapshot.dayRows.single.day, 'Mon');
      expect(snapshots.nextCursor, 'weekly-next');
      expect(contexts.contexts.single.context.baselineTotalCovers, 1200);
      expect(
        contexts.contexts.single.context.resolvedWeeklyForecastCovers,
        148,
      );
      expect(contexts.nextCursor, 'forecast-next');
      expect(requests.first.queryParameters['modified_since'], 'weekly-cursor');
      expect(requests.first.queryParameters['page_size'], '25');
    },
  );

  test('missing weekly-plan proxy route reports unavailable page', () async {
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example'),
      idTokenProvider: () async => 'token-1',
      httpClient: http_testing.MockClient((_) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'not_found'}),
          404,
        );
      }),
    );

    final page = await client.fetchWeeklyPlanSnapshots(
      operatorId: 'op',
      locationId: 'loc',
      cursor: null,
      pageSize: 25,
    );

    expect(page.isUnavailable, isTrue);
    expect(page.unavailableReason, 'weekly_plan_proxy_route_not_found');
  });

  test('retries once after a 401 by force-refreshing the id token', () async {
    final tokens = <String>['stale-token', 'fresh-token'];
    var refreshCount = 0;
    final requestTokens = <String>[];
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example'),
      idTokenProvider: () async => tokens.first,
      refreshIdToken: () async {
        refreshCount++;
        // Rotate the token so the retry sends the fresh one.
        if (tokens.length > 1) tokens.removeAt(0);
      },
      httpClient: http_testing.MockClient((request) async {
        requestTokens.add(request.headers['authorization'] ?? '');
        if (requestTokens.length == 1) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'unauthorized',
              'message': 'token expired',
            }),
            401,
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'records': const <Object?>[],
            'next_cursor': null,
          }),
          200,
        );
      }),
    );

    final page = await client.fetchShiftRecords(
      operatorId: 'op',
      locationId: 'loc',
      cursor: null,
      pageSize: 10,
    );

    expect(refreshCount, 1, reason: 'refresh hook is invoked exactly once');
    expect(requestTokens, <String>['Bearer stale-token', 'Bearer fresh-token']);
    expect(page.records, isEmpty);
  });

  test(
    'does not retry past one refresh attempt; surfaces 401 on retry too',
    () async {
      var refreshCount = 0;
      var requestCount = 0;
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example'),
        idTokenProvider: () async => 'still-stale',
        refreshIdToken: () async {
          refreshCount++;
        },
        httpClient: http_testing.MockClient((_) async {
          requestCount++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'unauthorized',
              'message': 'token expired',
            }),
            401,
          );
        }),
      );

      await expectLater(
        client.fetchShiftRecords(
          operatorId: 'op',
          locationId: 'loc',
          cursor: null,
          pageSize: 10,
        ),
        throwsA(
          isA<SyncProxyClientException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(requestCount, 2, reason: 'one initial + one retry, no more');
      expect(refreshCount, 1);
    },
  );

  test('throws a diagnostic-safe error when token is absent', () async {
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example'),
      idTokenProvider: () async => null,
      httpClient: http_testing.MockClient((_) async {
        fail('request should not be sent without a token');
      }),
    );

    expect(
      () => client.fetchShiftRecords(
        operatorId: 'op',
        locationId: 'loc',
        cursor: null,
        pageSize: 10,
      ),
      throwsA(isA<SyncProxyClientException>()),
    );
  });
}

Map<String, Object?> _shiftRow() => <String, Object?>{
  'restaurant_id': 'loc-1',
  'week_id': '2026-W18',
  'day_label': 'Mon',
  'daypart': 'lunch',
  'status': 'closed',
  'covers': 100,
  'forecast_covers': 90,
  'ppa': 35.0,
  'cplh': 14.0,
  'splh': 120.0,
  'foh_hours': 7,
  'boh_hours': 5,
  'theoretical_labor_pct': 30.0,
  'primary_lever': 'ON_MODEL',
};

Map<String, Object?> _openSnapshotRow() => <String, Object?>{
  'restaurant_id': 'loc',
  'week_id': '2026-W18',
  'day_label': 'Tue',
  'daypart': 'lunch',
  'status': 'open',
  'business_date': '2026-05-05',
  'business_timing_profile_id': 'profile-1',
  'business_timing_profile_version_id': 'profile-1',
  'service_period_key': 'lunch',
  'forecast_covers': 100,
  'current_covers': 40,
  'scheduled_foh_hours': 6,
  'scheduled_boh_hours': 4,
  'current_ppa': 32.5,
  'current_cplh': 12.0,
  'current_splh': 140.0,
  'blended_wage': 22.0,
  'updated_at': '2026-05-06T12:00:00Z',
};

Map<String, Object?> _legacyOpenSnapshotRow() {
  final row = Map<String, Object?>.from(_openSnapshotRow());
  row.remove('business_timing_profile_id');
  row.remove('business_timing_profile_version_id');
  row.remove('service_period_key');
  return row;
}

Map<String, Object?> _targetCycleRow() => <String, Object?>{
  'cycle_id': 'cycle-1',
  'operator_id': 'op',
  'location_id': 'loc',
  'restaurant_id': 'loc',
  'source': 'manager_override',
  'effective_start': '2026-05-01',
  'effective_end': '2026-06-30',
  'calibration_window_start': '2026-03-01',
  'calibration_window_end': '2026-04-30',
  'target_cplh': '5.2',
  'target_splh': 181.0,
  'target_ppa': 44.0,
  'foh_wage': 18.0,
  'boh_wage': 23.0,
  'opz_floor_cplh': 3.5,
  'opz_ceiling_cplh': 7.0,
  'manager_override_used': true,
  'manager_override_at': '2026-05-06T12:00:00Z',
  'created_at': '2026-05-06T12:00:00Z',
  'updated_at': '2026-05-06T12:00:00Z',
};

Map<String, Object?> _activeProfileRow() => <String, Object?>{
  'target_profile_id': 'profile-1',
  'operator_id': 'op',
  'location_id': 'loc',
  'restaurant_id': 'loc',
  'target_cycle_id': 'cycle-1',
  'target_profile_version_id': 'tpv-1',
  'source_type': 'cycle_manager_override',
  'target_cplh': 5.2,
  'target_splh': 181.0,
  'target_ppa': 44.0,
  'foh_wage': 18.0,
  'boh_wage': 23.0,
  'opz_floor_cplh': 3.5,
  'opz_ceiling_cplh': 7.0,
  'theoretical_foh_labor_pct': 7.87,
  'theoretical_boh_labor_pct': 12.7,
  'theoretical_labor_pct': 20.57,
  'built_at': '2026-05-06T12:00:00Z',
  'updated_at': '2026-05-06T12:00:00Z',
};

Map<String, Object?> _weeklyPlanRow() => <String, Object?>{
  'operator_id': 'op',
  'location_id': 'loc',
  'snapshot_id': 'wps-1',
  'restaurant_id': 'loc',
  'week_start_date': '2026-05-04',
  'week_end_date': '2026-05-10',
  'target_cycle_id': 'cycle-1',
  'forecast_covers': 148,
  'forecast_sales': 6512.0,
  'required_foh_hours': 32,
  'required_boh_hours': 28,
  'theoretical_foh_labor_dollars': 576.0,
  'theoretical_boh_labor_dollars': 644.0,
  'covers_source': 'historical_average',
  'sales_source': 'covers_and_ppa',
  'generated_at': '2026-05-06T12:00:00Z',
  'locked_at': '2026-05-06T12:01:00Z',
  'day_rows_json': jsonEncode(<Object?>[
    <String, Object?>{
      'day_label': 'Mon',
      'business_date': '2026-05-04',
      'covers': 22,
      'sales': 968.0,
      'foh_hours': 5,
      'boh_hours': 4,
    },
  ]),
};

Map<String, Object?> _forecastContextRow() => <String, Object?>{
  'operator_id': 'op',
  'location_id': 'loc',
  'restaurant_id': 'loc',
  'business_date': '2026-05-04',
  'baseline_total_covers': 1200,
  'baseline_weekly_avg_covers': 140,
  'baseline_weeks_represented': 8.571,
  'recent_21_day_total_covers': 468,
  'recent_21_day_weekly_average_covers': 156,
  'recent_trend_delta_covers': 16,
  'resolved_weekly_forecast_covers': 148,
  'covers_source': 'historical_average',
  'built_at': '2026-05-06T12:00:00Z',
};
