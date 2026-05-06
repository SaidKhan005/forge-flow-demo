import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
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

    expect(open.snapshots.single.daypart, 'lunch');
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
    expect(requests, hasLength(5));

    // BUG 3 (MEDIUM): non-root proxyBaseUri prefix MUST be preserved.
    // The previous implementation called `proxyBaseUri.resolve` against
    // an absolute path that wiped any prefix on the base URI; here we
    // assert the full URL contains the `/base/` segment AND the
    // composed `/v1/operators/...` tail.
    for (final url in fullUrls) {
      expect(
        url,
        startsWith('https://proxy.example/base/v1/operators/op/locations/loc/'),
        reason:
            'every request URL must preserve the configured /base/ prefix',
      );
    }
  });

  test('non-root proxyBaseUri without trailing slash also keeps the prefix',
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
    expect(requestTokens, <String>[
      'Bearer stale-token',
      'Bearer fresh-token',
    ]);
    expect(page.records, isEmpty);
  });

  test('does not retry past one refresh attempt; surfaces 401 on retry too',
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
  });

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
