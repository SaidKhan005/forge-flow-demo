import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/services/star_target_selection_write_service.dart';
import 'package:forge_and_flow/services/sync/http_sync_proxy_client.dart';

void main() {
  test('fetchAccessibleBusinessScopes calls user-scoped route', () async {
    late http.Request seen;
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example/base/'),
      idTokenProvider: () async => 'token-1',
      httpClient: http_testing.MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'scopes': <Object?>[
              <String, Object?>{
                'scope_id': 'loc-2',
                'scope_type': 'location',
                'operator_id': 'op-1',
                'location_id': 'loc-2',
                'label': 'Mercado',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final scopes = await client.fetchAccessibleBusinessScopes(userId: 'user-1');

    expect(seen.method, 'GET');
    expect(seen.url.path, '/base/v1/users/user-1/business_scopes');
    expect(seen.headers['authorization'], 'Bearer token-1');
    expect(scopes.single.locationId, 'loc-2');
    expect(scopes.single.label, 'Mercado');
  });

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

  test(
    'submitSelectedStarTargetProjection posts scoped projection body',
    () async {
      late http.Request seen;
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example/base/'),
        idTokenProvider: () async => 'token-1',
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'target_cycle': <String, Object?>{'cycle_id': 'cycle-1'},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      await client.submitSelectedStarTargetProjection(
        operatorId: 'op',
        locationId: 'loc',
        idempotencyKey: 'projection-idem-1',
        body: const <String, Object?>{
          'restaurant_id': 'restaurant-1',
          'effective_start': '2026-05-06',
          'effective_end': '2026-07-04',
          'calibration_window_start': '2026-03-08',
          'calibration_window_end': '2026-05-06',
          'standards': <String, Object?>{'target_cplh': 12.4},
        },
      );

      expect(seen.method, 'POST');
      expect(
        seen.url.path,
        '/base/v1/operators/op/locations/loc/'
        'target_cycles/project_manager_override',
      );
      expect(seen.headers['authorization'], 'Bearer token-1');
      expect(seen.headers['idempotency-key'], 'projection-idem-1');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['restaurant_id'], 'restaurant-1');
    },
  );

  test('submitManualCovers patches scoped canonical covers route', () async {
    late http.Request seen;
    final client = HttpSyncProxyClient(
      proxyBaseUri: Uri.parse('https://proxy.example/base/'),
      idTokenProvider: () async => 'token-1',
      httpClient: http_testing.MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': <String, Object?>{'setting_id': 'setting-1'},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    await client.submitManualCovers(
      operatorId: 'op',
      locationId: 'loc',
      restaurantId: 'restaurant-1',
      businessDate: '2026-05-10',
      servicePeriodKey: 'brunch',
      covers: 84,
      recordedAt: '2026-05-10T18:00:00Z',
      idempotencyKey: 'manual-covers-idem-1',
    );

    expect(seen.method, 'PATCH');
    expect(
      seen.url.path,
      '/base/v1/operators/op/locations/loc/'
      'data_accuracy_settings/manual_covers',
    );
    expect(seen.headers['authorization'], 'Bearer token-1');
    expect(seen.headers['idempotency-key'], 'manual-covers-idem-1');
    final body = jsonDecode(seen.body) as Map<String, Object?>;
    expect(body, <String, Object?>{
      'restaurant_id': 'restaurant-1',
      'business_date': '2026-05-10',
      'service_period_key': 'brunch',
      'covers': 84,
      'recorded_at': '2026-05-10T18:00:00Z',
    });
  });

  test(
    'switchDemoModeToLive posts scoped route with idempotency key',
    () async {
      late http.Request seen;
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example/base/'),
        idTokenProvider: () async => 'token-1',
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'demo_mode_states': <Object?>[
                <String, Object?>{
                  'operator_id': 'op',
                  'location_id': 'loc',
                  'category': 'pos',
                  'is_demo': false,
                  'flipped_to_live_at': '2026-05-13T12:00:00Z',
                },
              ],
              'flipped_count': 1,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final states = await client.switchDemoModeToLive(
        operatorId: 'op',
        locationId: 'loc',
        idempotencyKey: 'idem-demo-live',
      );

      expect(seen.method, 'POST');
      expect(
        seen.url.path,
        '/base/v1/operators/op/locations/loc/demo-mode-master-switch',
      );
      expect(seen.headers['authorization'], 'Bearer token-1');
      expect(seen.headers['idempotency-key'], 'idem-demo-live');
      expect(jsonDecode(seen.body), <String, Object?>{'target_mode': 'live'});
      expect(states.single.isDemo, isFalse);
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
                'selected_scope_type': 'location',
                'selected_scope_id': 'loc',
                'source_scope_type': 'org_unit',
                'source_scope_id': 'district-1',
                'source_scope_label': 'Metro District',
                'inherited_from_ancestor': true,
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
                'wage_source_source': <String, Object?>{
                  'scope_type': 'business',
                  'source_kind': 'scoped_override',
                  'override_id': 'ovr-wage',
                },
                'walk_in_handling_mode': 'walk_ins_added_to_reservations',
                'walk_in_handling_mode_source': <String, Object?>{
                  'scope_type': 'location',
                  'source_kind': 'base_setting',
                  'setting_id': 'setting-1',
                },
                'covers_source_per_service_period_source': <String, Object?>{
                  'dinner': <String, Object?>{
                    'scope_type': 'org_unit',
                    'source_kind': 'scoped_override',
                    'override_id': 'ovr-dinner',
                  },
                },
                'walk_in_manual_entries': <String, Object?>{'2026-05-05': 14},
                'updated_at': '2026-05-06T12:00:00Z',
              },
            },
          '/base/v1/operators/op/locations/loc/data_accuracy_service_period_settings' =>
            <String, Object?>{
              'service_period_settings': <Object?>[
                <String, Object?>{
                  'id': 'setting-1',
                  'operator_id': 'op',
                  'location_id': 'loc',
                  'service_period_key': 'brunch',
                  'covers_source': 'reservation_plus_walkin',
                  'wage_source': 'manual_mix',
                  'effective_at_business_date': '2026-05-04',
                  'created_at': '2026-05-06T12:00:00Z',
                  'updated_at': '2026-05-06T12:05:00Z',
                  'updated_by': 'admin-1',
                },
              ],
            },
          '/base/v1/operators/op/locations/loc/wage_role_rows' =>
            request.url.queryParameters['modified_since'] == null
                ? <String, Object?>{
                    'wage_role_rows': <Object?>[
                      <String, Object?>{
                        // Theme H#4 / H#5 — proxy emits the full server
                        // payload; the mobile client must consume every
                        // field below, not just the legacy 4.
                        'server_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1',
                        'role_name': 'Line Cook',
                        'labor_bucket': 'boh',
                        'hourly_rate': '18.25',
                        'weighted_hours': 40,
                        'job_code': 'JC-LINE',
                        'vendor_id': 'seven_shifts',
                        'vendor_role_id': 'vendor-line-1',
                        'source': 'vendor_seven_shifts',
                        'is_active': true,
                        'effective_at': '2026-05-04T00:00:00Z',
                        'metadata': <String, Object?>{'origin': 'mock'},
                        'updated_by': 'admin-1',
                      },
                    ],
                    'next_cursor': '2026-05-06T12:00:00.000Z',
                  }
                : <String, Object?>{
                    'wage_role_rows': <Object?>[
                      <String, Object?>{
                        'roleName': 'Server',
                        'laborBucket': 'foh',
                        'hourlyRate': 16.5,
                        'weightedHours': '32',
                      },
                    ],
                    'next_cursor': null,
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
      businessDate: '2026-05-04',
    );
    final demo = await client.fetchDemoModeStates(
      operatorId: 'op',
      locationId: 'loc',
    );
    final accuracy = await client.fetchDataAccuracySettings(
      operatorId: 'op',
      locationId: 'loc',
    );
    final keyedAccuracy = await client.fetchDataAccuracyServicePeriodSettings(
      operatorId: 'op',
      locationId: 'loc',
    );
    final wageRows = await client.fetchWageRoleRows(
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
    expect(timing.selectedScopeType, 'location');
    expect(timing.selectedScopeId, 'loc');
    expect(timing.sourceScopeType, 'org_unit');
    expect(timing.sourceScopeId, 'district-1');
    expect(timing.sourceScopeLabel, 'Metro District');
    expect(timing.inheritedFromAncestor, isTrue);
    expect(timing.servicePeriodDefinitions.single.id, 'brunch');
    expect(timing.servicePeriodDefinitions.single.startLocalTime, '09:00');
    expect(timing.servicePeriodDefinitions.single.applicableDays, <int>[6, 7]);
    expect(demo.single.isDemo, isFalse);
    // R7c: the vestigial covers_source_{lunch,dinner,late_night}
    // snapshot fields were removed (no downstream resolver consumed
    // them). Any such keys still present in the wire payload are
    // ignored on parse. Per-period covers source flows via the keyed
    // service-period settings, asserted below as `keyedAccuracy`.
    expect(accuracy!.coversManualEntries['2026-05-05']!['dinner'], 120);
    expect(
      accuracy.coversSourcePerServicePeriodSources['dinner']!['scope_type'],
      'org_unit',
    );
    expect(accuracy.wageSourceSource!['scope_type'], 'business');
    expect(accuracy.walkInHandlingMode, 'walk_ins_added_to_reservations');
    expect(accuracy.walkInHandlingModeSource!['source_kind'], 'base_setting');
    expect(accuracy.walkInManualEntries['2026-05-05'], 14);
    expect(keyedAccuracy.single.servicePeriodKey, 'brunch');
    expect(keyedAccuracy.single.coversSource.wire, 'reservation_plus_walkin');
    expect(keyedAccuracy.single.wageSource.wire, 'manual_mix');
    expect(keyedAccuracy.single.updatedBy, 'admin-1');
    expect(wageRows.map((row) => row.roleName), <String>[
      'Line Cook',
      'Server',
    ]);
    expect(wageRows.first.restaurantId, 'loc');
    expect(wageRows.first.laborBucket, 'boh');
    expect(wageRows.first.hourlyRate, 18.25);
    expect(wageRows.last.weightedHours, 32);
    // Theme H#4 / H#5 — full server payload consumed by the sync client.
    expect(wageRows.first.serverId, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1');
    expect(wageRows.first.jobCode, 'JC-LINE');
    expect(wageRows.first.vendorId, 'seven_shifts');
    expect(wageRows.first.vendorRoleId, 'vendor-line-1');
    expect(wageRows.first.source, 'vendor_seven_shifts');
    expect(wageRows.first.isActive, isTrue);
    expect(wageRows.first.effectiveAt, '2026-05-04T00:00:00.000Z');
    expect(wageRows.first.metadata, isNotNull);
    expect(wageRows.first.metadata!['origin'], 'mock');
    expect(wageRows.first.updatedBy, 'admin-1');
    expect(tier!.tierKey, 'premium');
    expect(tier.pollingCadencePerVendorSeconds['toast'], 300);
    expect(backfill!.status, 'running');
    expect(backfill.vendorId, 'toast');
    expect(backfill.isRunning, isTrue);
    expect(requests, hasLength(9));
    expect(
      fullUrls.where((url) => url.contains('/timing/resolved')).single,
      Uri.parse(
            'https://proxy.example/base/v1/operators/op/locations/loc/'
            'timing/resolved',
          )
          .replace(
            queryParameters: <String, String>{
              'restaurant_id': 'loc',
              'business_date': '2026-05-04',
            },
          )
          .toString(),
    );
    final wageRoleUrl = Uri.parse(
      'https://proxy.example/base/v1/operators/op/locations/loc/'
      'wage_role_rows',
    );
    expect(
      fullUrls.where((url) => url.contains('/wage_role_rows')).toList(),
      <String>[
        wageRoleUrl
            .replace(queryParameters: <String, String>{'page_size': '500'})
            .toString(),
        wageRoleUrl
            .replace(
              queryParameters: <String, String>{
                'page_size': '500',
                'modified_since': '2026-05-06T12:00:00.000Z',
              },
            )
            .toString(),
      ],
    );

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
    expect(
      cycles.cycles.single.cycle.daypartFor('afternoon_tea')!.targetCPLH,
      0,
    );
    expect(cycles.cycles.single.cycle.daypartFor('supper_rush')!.targetPPA, 48);
    expect(cycles.cycles.single.cycle.daypartFor('legacy_lunch'), isNull);
    expect(cycles.nextCursor, 'cycle-next');
    expect(profiles.profiles.single.profile.targetProfileId, 'profile-1');
    expect(profiles.profiles.single.profile.targetCycleId, 'cycle-1');
    expect(profiles.profiles.single.profile.targetProfileVersionId, 'tpv-1');
    expect(
      profiles.profiles.single.profile
          .daypartFor('afternoon_tea')!
          .daypartTargetCPLH,
      0,
    );
    expect(
      profiles.profiles.single.profile
          .daypartFor('supper_rush')!
          .daypartTargetPPA,
      48,
    );
    expect(profiles.profiles.single.profile.daypartFor('legacy_lunch'), isNull);
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
      expect(snapshots.snapshots.single.snapshot.forecastContextId, 'fc-1');
      expect(
        snapshots.snapshots.single.snapshot.weekKey,
        '2026-05-04_2026-05-10',
      );
      expect(snapshots.snapshots.single.snapshot.dayRows.single.day, 'Mon');
      expect(
        snapshots.snapshots.single.snapshot.dayDayparts.single.servicePeriodId,
        'brunch',
      );
      expect(
        snapshots.snapshots.single.snapshot.wageAtLockTime!.blendedWage,
        20.0,
      );
      expect(snapshots.nextCursor, 'weekly-next');
      expect(contexts.contexts.single.forecastContextId, 'fc-1');
      expect(contexts.contexts.single.weekStartDate, '2026-05-04');
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
  'dayparts': <Object?>[
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
  ],
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
  'active_target_profile_dayparts': <Object?>[
    <String, Object?>{
      'service_period_id': 'afternoon_tea',
      'daypart_target_cplh': 0,
      'daypart_target_splh': 0,
      'daypart_target_ppa': 0,
      'daypart_opz_floor_cplh': 0,
      'daypart_opz_ceiling_cplh': 0,
    },
    <String, Object?>{
      'service_period_id': 'supper_rush',
      'target_cplh': 6.8,
      'target_splh': 190.0,
      'target_ppa': 48.0,
      'opz_floor_cplh': 5.4,
      'opz_ceiling_cplh': 8.2,
    },
  ],
};

Map<String, Object?> _weeklyPlanRow() => <String, Object?>{
  'operator_id': 'op',
  'location_id': 'loc',
  'snapshot_id': 'wps-1',
  'restaurant_id': 'loc',
  'week_start_date': '2026-05-04',
  'week_end_date': '2026-05-10',
  'target_cycle_id': 'cycle-1',
  'forecast_context_id': 'fc-1',
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
  'day_dayparts': <Object?>[
    <String, Object?>{
      'business_date': '2026-05-04',
      'service_period_id': 'brunch',
      'forecast_covers': 12,
      'forecast_sales': 528.0,
      'required_foh_hours': 2.5,
      'required_boh_hours': 2.0,
      'theoretical_foh_dollars': 45.0,
      'theoretical_boh_dollars': 44.0,
    },
  ],
  'wage_at_lock_time_json': <String, Object?>{
    'foh_wage': 18.0,
    'boh_wage': 22.0,
    'blended_wage': 20.0,
  },
};

Map<String, Object?> _forecastContextRow() => <String, Object?>{
  'operator_id': 'op',
  'location_id': 'loc',
  'forecast_context_id': 'fc-1',
  'restaurant_id': 'loc',
  'business_date': '2026-05-04',
  'week_start_date': '2026-05-04',
  'week_end_date': '2026-05-10',
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
