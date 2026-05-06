import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('mobile operational sync proxy routes', () {
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
        _FakeMobileOperationalSyncGateway gateway,
      })
    >
    spinUp({ProxyJwtClaims? claims, bool gatewayConfigured = true}) async {
      final verifier = _SettableVerifier(
        claims ??
            const ProxyJwtClaims(
              userId: 'user-1',
              operatorId: 'op-1',
              locationId: 'loc-1',
              roles: <String>['operator_owner'],
            ),
      );
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = _FakeMobileOperationalSyncGateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            mobileOperationalSyncGateway: gatewayConfigured ? gateway : null,
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
      );
    }

    test('GET endpoints route through token-matched operator scope', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final shift = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/shift_records'
              '?modified_since=2026-05-06T12:00:00Z&page_size=2',
            ),
          );
          expect(shift.statusCode, 200);
          expect(
            (jsonDecode(shift.body) as Map<String, Object?>)['next_cursor'],
            '2026-05-06T12:30:00.000Z',
          );
          // V1.A regression guard: closed shift_records payloads must
          // carry the timing-provenance triplet so mobile renders
          // history with stable boundaries.
          expect(shift.body, contains('business_timing_profile_id'));
          expect(shift.body, contains('business_timing_profile_version_id'));
          expect(shift.body, contains('service_period_key'));

          final open = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/open_shift_snapshots',
            ),
          );
          expect(open.statusCode, 200);
          expect(open.body, contains('open_shift_snapshots'));
          expect(open.body, contains('business_timing_profile_id'));
          expect(open.body, contains('business_timing_profile_version_id'));
          expect(open.body, contains('service_period_key'));

          final timing = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/timing/resolved'
              '?business_date=2026-05-06',
            ),
          );
          expect(timing.statusCode, 200);
          expect(timing.body, contains('timing_config'));

          final demo = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/demo_mode_states',
            ),
          );
          expect(demo.statusCode, 200);
          expect(demo.body, contains('demo_mode_states'));

          final accuracy = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
            ),
          );
          expect(accuracy.statusCode, 200);
          expect(accuracy.body, contains('covers_source_lunch'));

          final tier = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/polling_tier_assignment',
            ),
          );
          expect(tier.statusCode, 200);
          expect(tier.body, contains('polling_cadence_per_vendor_seconds'));

          final backfill = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/first_backfill_status',
            ),
          );
          expect(backfill.statusCode, 200);
          expect(backfill.body, contains('first_backfill_status'));
          expect(backfill.body, contains('running'));

          expect(ctx.gateway.calls, <String>[
            'shift_records:op-1:loc-1:2026-05-06T12:00:00Z:2',
            'open_shift_snapshots:op-1:loc-1:null:200',
            'timing/resolved:op-1:loc-1:2026-05-06',
            'demo_mode_states:op-1:loc-1',
            'data_accuracy_settings:op-1:loc-1',
            'polling_tier_assignment:op-1:loc-1',
            'first_backfill_status:op-1:loc-1',
          ]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns 503 when production gateway is not installed', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(gatewayConfigured: false);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/shift_records',
            ),
          );
          expect(response.statusCode, 503);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'mobile_operational_sync_not_configured');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('rejects URL scope that differs from bearer scope', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-2/locations/loc-1/shift_records',
            ),
          );
          expect(response.statusCode, 403);
          expect(ctx.gateway.calls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'upstream gateway throw surfaces a 503 wrapper to the client',
      () async {
        // BUG 4 (MEDIUM) supporting test: confirm the proxy wraps an
        // upstream exception (5xx-class fault inside the gateway) into a
        // 503 envelope with the documented `mobile_operational_sync_unavailable`
        // code. The client's 401-retry path does not need this code path,
        // but verifying the wrapper here keeps the route's failure mode
        // honest for the mobile runtime's pull loop.
        await withRealHttp(() async {
          final ctx = await spinUp();
          ctx.gateway.throwOnNextShift = StateError('upstream fault');
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/shift_records',
              ),
            );
            expect(response.statusCode, 503);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], 'mobile_operational_sync_unavailable');
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('validates page size and cursor before gateway dispatch', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final badPage = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/shift_records?page_size=0',
            ),
          );
          expect(badPage.statusCode, 400);
          expect(
            (jsonDecode(badPage.body) as Map<String, Object?>)['error'],
            'invalid_page_size',
          );

          final badCursor = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/shift_records'
              '?modified_since=not-a-date',
            ),
          );
          expect(badCursor.statusCode, 400);
          expect(
            (jsonDecode(badCursor.body) as Map<String, Object?>)['error'],
            'invalid_modified_since',
          );
          expect(ctx.gateway.calls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  _SettableVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _FakeMobileOperationalSyncGateway
    implements MobileOperationalSyncProxyGateway {
  final List<String> calls = <String>[];
  Object? throwOnNextShift;

  @override
  Future<Map<String, Object?>> fetchShiftRecords({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) async {
    final thrown = throwOnNextShift;
    if (thrown != null) {
      throwOnNextShift = null;
      throw thrown;
    }
    calls.add('shift_records:$operatorId:$locationId:$modifiedSince:$pageSize');
    return const <String, Object?>{
      'shift_records': <Map<String, Object?>>[
        <String, Object?>{
          'restaurant_id': 'loc-1',
          'week_id': '2026-W18',
          'day_label': 'Tue',
          'daypart': 'dinner',
          'status': 'closed',
          'business_date': '2026-05-05',
          // V1.A: closed shift_records carry the same timing triplet
          // as open snapshots so mobile's ClosedTimingLabelResolver
          // never falls back to mutable `daypart` when the operator
          // changes service-period boundaries later.
          'business_timing_profile_id': '11111111-1111-1111-1111-111111111111',
          'business_timing_profile_version_id':
              '11111111-1111-1111-1111-111111111111',
          'service_period_key': 'dinner',
          'covers': 120,
          'forecast_covers': 110,
          'ppa': 42.0,
          'cplh': 13.5,
          'splh': 160.0,
          'foh_hours': 8,
          'boh_hours': 5,
          'theoretical_labor_pct': 24.0,
          'primary_lever': 'ON_MODEL',
        },
      ],
      'next_cursor': '2026-05-06T12:30:00.000Z',
    };
  }

  @override
  Future<Map<String, Object?>> fetchOpenShiftSnapshots({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) async {
    calls.add(
      'open_shift_snapshots:$operatorId:$locationId:$modifiedSince:$pageSize',
    );
    return const <String, Object?>{
      'open_shift_snapshots': <Map<String, Object?>>[
        <String, Object?>{
          'restaurant_id': 'loc-1',
          'week_id': '2026-W18',
          'day_label': 'Tue',
          'daypart': 'lunch',
          'status': 'open',
          'business_date': '2026-05-06',
          'business_timing_profile_id': '11111111-1111-1111-1111-111111111111',
          'business_timing_profile_version_id':
              '11111111-1111-1111-1111-111111111111',
          'service_period_key': 'lunch',
        },
      ],
      'next_cursor': null,
    };
  }

  @override
  Future<Map<String, Object?>> fetchResolvedTimingConfig({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? businessDate,
  }) async {
    calls.add('timing/resolved:$operatorId:$locationId:$businessDate');
    return const <String, Object?>{
      'timing_config': <String, Object?>{
        'restaurant_id': 'loc-1',
        'business_timezone': 'America/St_Johns',
        'business_day_start_local_time': '04:00',
        'week_start_day': 1,
        'shift_close_authority': 'vendor_finalization',
        'service_period_definitions': <Map<String, Object?>>[],
      },
    };
  }

  @override
  Future<Map<String, Object?>> fetchDemoModeStates({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('demo_mode_states:$operatorId:$locationId');
    return const <String, Object?>{
      'demo_mode_states': <Map<String, Object?>>[
        <String, Object?>{
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'category': 'pos',
          'is_demo': false,
        },
      ],
    };
  }

  @override
  Future<Map<String, Object?>> fetchDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('data_accuracy_settings:$operatorId:$locationId');
    return const <String, Object?>{
      'data': <String, Object?>{
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'manual',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': <String, Object?>{},
        'wage_source': 'manual_mix',
        'updated_at': '2026-05-06T12:00:00Z',
      },
    };
  }

  @override
  Future<Map<String, Object?>> fetchPollingTierAssignment({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('polling_tier_assignment:$operatorId:$locationId');
    return const <String, Object?>{
      'assignment': <String, Object?>{
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'tier_key': 'premium',
        'polling_cadence_per_vendor_seconds': <String, Object?>{'toast': 300},
        'monthly_price_cents': 9900,
        'effective_at': '2026-05-06T12:00:00Z',
      },
    };
  }

  @override
  Future<Map<String, Object?>> fetchFirstBackfillStatus({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('first_backfill_status:$operatorId:$locationId');
    return const <String, Object?>{
      'first_backfill_status': <String, Object?>{
        'job_id': 'job-1',
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'connection_id': 'conn-1',
        'vendor_id': 'toast',
        'category': 'pos',
        'status': 'running',
        'window_start': '2026-03-07T00:00:00Z',
        'window_end': '2026-05-06T00:00:00Z',
        'created_at': '2026-05-06T12:00:00Z',
        'updated_at': '2026-05-06T12:01:00Z',
      },
    };
  }
}

Future<_HttpResult> _httpGet(
  HttpClient client,
  Uri uri, {
  String authorization = 'Bearer token',
}) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  final response = await request.close();
  final body = await utf8.decodeStream(response);
  return _HttpResult(response.statusCode, body);
}

class _HttpResult {
  const _HttpResult(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
