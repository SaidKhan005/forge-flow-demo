import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

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
        _FakeDemoModeMasterSwitchGateway demoSwitchGateway,
        _FakeAdminRequestIdempotencyStore idempotencyStore,
      })
    >
    spinUp({
      ProxyJwtClaims? claims,
      bool gatewayConfigured = true,
      bool demoSwitchConfigured = true,
      _FakeDemoModeMasterSwitchGateway? demoSwitchGateway,
      _FakeAdminRequestIdempotencyStore? idempotencyStore,
    }) async {
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
      final switchGateway =
          demoSwitchGateway ?? _FakeDemoModeMasterSwitchGateway();
      final adminIdempotencyStore =
          idempotencyStore ?? _FakeAdminRequestIdempotencyStore();
      final demoSwitchRouter = DemoModeMasterSwitchRouter(
        gateway: switchGateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            mobileOperationalSyncGateway: gatewayConfigured ? gateway : null,
            demoModeMasterSwitchRouter: demoSwitchConfigured
                ? demoSwitchRouter
                : null,
            adminRequestIdempotencyStore: adminIdempotencyStore,
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
        demoSwitchGateway: switchGateway,
        idempotencyStore: adminIdempotencyStore,
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
          expect(accuracy.body, contains('walk_in_handling_mode'));

          final periodAccuracy = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/'
              'data_accuracy_service_period_settings',
            ),
          );
          expect(periodAccuracy.statusCode, 200);
          final periodBody =
              jsonDecode(periodAccuracy.body) as Map<String, Object?>;
          final periodRows =
              periodBody['data_accuracy_service_period_settings']
                  as List<Object?>;
          expect(periodRows, hasLength(1));
          final periodRow = periodRows.single as Map<String, Object?>;
          expect(periodRow['service_period_key'], 'dinner');
          expect(periodRow['effective_at_business_date'], '2026-05-06');
          expect(periodRow['covers_source'], 'manual');
          expect(periodRow['wage_source'], 'manual_mix');

          final wageRows = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/wage_role_rows'
              '?modified_since=2026-05-06T12:00:00Z&page_size=1',
            ),
          );
          expect(wageRows.statusCode, 200);
          final wageBody = jsonDecode(wageRows.body) as Map<String, Object?>;
          expect(wageBody['next_cursor'], '2026-05-06T12:30:00.000Z');
          final rows = wageBody['wage_role_rows'] as List<Object?>;
          expect(rows, hasLength(1));
          final wageRow = rows.single as Map<String, Object?>;
          expect(wageRow['server_id'], 'wage-row-1');
          expect(wageRow.containsKey('id'), isFalse);
          expect(wageRow['role_name'], 'Server');
          expect(wageRow['labor_bucket'], 'foh');
          expect(wageRow['hourly_rate'], 22.5);
          expect(wageRow['weighted_hours'], 32.0);
          expect(wageRow['job_code'], '5001');
          expect(wageRow['source'], 'operator_manual');

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
            'data_accuracy_service_period_settings:op-1:loc-1',
            'wage_role_rows:op-1:loc-1:2026-05-06T12:00:00Z:1',
            'polling_tier_assignment:op-1:loc-1',
            'first_backfill_status:op-1:loc-1',
          ]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period settings writes through owner scope', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/'
            'data_accuracy_service_period_settings',
          );
          final post = await _httpRequest(ctx.client, 'POST', uri);
          expect(post.statusCode, 404);
          final patch = await _httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: const <String, Object?>{
              'service_period_key': 'breakfast',
              'covers_source': 'reservation_plus_walkin',
              'wage_source': 'target_substitution',
              'effective_at_business_date': '2026-05-07',
            },
            idempotencyKey: 'service-period-key-1',
          );
          expect(patch.statusCode, 200);
          final body = jsonDecode(patch.body) as Map<String, Object?>;
          final data = body['data'] as Map<String, Object?>;
          expect(data['service_period_key'], 'breakfast');
          expect(data['covers_source'], 'reservation_plus_walkin');
          expect(data['wage_source'], 'target_substitution');
          expect(data['effective_at_business_date'], '2026-05-07');
          final expectedCall =
              'data_accuracy_service_period_settings_write:op-1:loc-1:'
              'breakfast:reservation_plus_walkin:target_substitution:'
              '2026-05-07';
          expect(ctx.gateway.calls, <String>[expectedCall]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH service-period settings rejects missing Idempotency-Key',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/'
                'data_accuracy_service_period_settings',
              ),
              body: const <String, Object?>{
                'service_period_key': 'breakfast',
                'covers_source': 'manual',
                'wage_source': 'manual_mix',
                'effective_at_business_date': '2026-05-07',
              },
            );
            expect(response.statusCode, 400);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], 'idempotency_key_missing');
            expect(ctx.gateway.calls, isEmpty);
            expect(ctx.idempotencyStore.reserveCalls, 0);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PATCH service-period settings replays same key and body', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/'
            'data_accuracy_service_period_settings',
          );
          const body = <String, Object?>{
            'service_period_key': 'breakfast',
            'covers_source': 'reservation_plus_walkin',
            'wage_source': 'target_substitution',
            'effective_at_business_date': '2026-05-07',
          };
          final first = await _httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: body,
            idempotencyKey: 'service-period-replay-key',
          );
          final replay = await _httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: body,
            idempotencyKey: 'service-period-replay-key',
          );
          expect(first.statusCode, 200);
          expect(replay.statusCode, 200);
          expect(jsonDecode(replay.body), jsonDecode(first.body));
          final expectedCall =
              'data_accuracy_service_period_settings_write:op-1:loc-1:'
              'breakfast:reservation_plus_walkin:target_substitution:'
              '2026-05-07';
          expect(ctx.gateway.calls, <String>[expectedCall]);
          expect(ctx.idempotencyStore.reserveCalls, 1);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH service-period settings rejects same key with different body',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final uri = ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/'
              'data_accuracy_service_period_settings',
            );
            final first = await _httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'service_period_key': 'breakfast',
                'covers_source': 'manual',
                'wage_source': 'manual_mix',
                'effective_at_business_date': '2026-05-07',
              },
              idempotencyKey: 'service-period-conflict-key',
            );
            final conflict = await _httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'service_period_key': 'breakfast',
                'covers_source': 'vendor',
                'wage_source': 'manual_mix',
                'effective_at_business_date': '2026-05-07',
              },
              idempotencyKey: 'service-period-conflict-key',
            );
            expect(first.statusCode, 200);
            expect(conflict.statusCode, 409);
            final body = jsonDecode(conflict.body) as Map<String, Object?>;
            expect(body['error'], 'idempotency_key_conflict');
            final expectedCall =
                'data_accuracy_service_period_settings_write:op-1:loc-1:'
                'breakfast:manual:manual_mix:2026-05-07';
            expect(ctx.gateway.calls, <String>[expectedCall]);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PATCH service-period settings rejects location manager', () async {
      // Doc 1 keyed-data-accuracy-write — defence in depth on the
      // operator-web keyed write path. The role gate already covers the
      // legacy data_accuracy_settings PATCH; pin it for the keyed path
      // too so a future role refactor cannot quietly let a location
      // manager edit per-period covers/wage source.
      await withRealHttp(() async {
        final ctx = await spinUp(
          claims: const ProxyJwtClaims(
            userId: 'user-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
            roles: <String>['location_manager'],
          ),
        );
        try {
          final response = await _httpRequest(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/'
              'data_accuracy_service_period_settings',
            ),
            body: const <String, Object?>{
              'service_period_key': 'breakfast',
              'covers_source': 'manual',
              'wage_source': 'manual_mix',
              'effective_at_business_date': '2026-05-07',
            },
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
      'PATCH service-period settings rejects phantom operator_admin',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            claims: const ProxyJwtClaims(
              userId: 'user-1',
              operatorId: 'op-1',
              locationId: 'loc-1',
              roles: <String>['operator_admin'],
            ),
          );
          try {
            final response = await _httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/'
                'data_accuracy_service_period_settings',
              ),
              body: const <String, Object?>{
                'service_period_key': 'breakfast',
                'covers_source': 'manual',
                'wage_source': 'manual_mix',
                'effective_at_business_date': '2026-05-07',
              },
            );
            expect(response.statusCode, 403);
            expect(ctx.gateway.calls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PATCH service-period settings rejects invalid key', () async {
      // Doc 1 keyed-data-accuracy-write — invalid `service_period_key`
      // (not lowercase / not [a-z][a-z0-9_]+) must round-trip a 400 from
      // the proxy validator before any gateway call so a typo in the
      // operator-web client cannot create a malformed row.
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpRequest(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/'
              'data_accuracy_service_period_settings',
            ),
            body: const <String, Object?>{
              'service_period_key': 'Breakfast Brunch',
              'covers_source': 'vendor',
              'wage_source': 'vendor_per_employee',
              'effective_at_business_date': '2026-05-07',
            },
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'invalid_service_period_key');
          expect(ctx.gateway.calls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH service-period settings rejects malformed business date',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/'
                'data_accuracy_service_period_settings',
              ),
              body: const <String, Object?>{
                'service_period_key': 'breakfast',
                'covers_source': 'vendor',
                'wage_source': 'vendor_per_employee',
                'effective_at_business_date': 'May 7 2026',
              },
            );
            expect(response.statusCode, 400);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], 'invalid_effective_at_business_date');
            expect(ctx.gateway.calls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'PATCH service-period settings rejects impossible business date',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/'
                'data_accuracy_service_period_settings',
              ),
              body: const <String, Object?>{
                'service_period_key': 'breakfast',
                'covers_source': 'vendor',
                'wage_source': 'vendor_per_employee',
                'effective_at_business_date': '2026-02-31',
              },
              idempotencyKey: 'period-impossible-date-key',
            );
            expect(response.statusCode, 400);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], 'invalid_effective_at_business_date');
            expect(ctx.gateway.calls, isEmpty);
            expect(ctx.idempotencyStore.reserveCalls, 0);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'PATCH service-period settings rejects URL scope different from bearer',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-2/locations/loc-1/'
                'data_accuracy_service_period_settings',
              ),
              body: const <String, Object?>{
                'service_period_key': 'breakfast',
                'covers_source': 'vendor',
                'wage_source': 'vendor_per_employee',
                'effective_at_business_date': '2026-05-07',
              },
            );
            expect(response.statusCode, 403);
            expect(ctx.gateway.calls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PATCH data accuracy settings writes through owner scope', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpRequest(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
            ),
            body: const <String, Object?>{
              'covers_source_lunch': 'manual',
              'covers_source_dinner': 'vendor',
              'covers_source_late_night': 'forecast',
              'covers_manual_entries': <String, Object?>{
                '2026-05-06': <String, Object?>{'lunch': 42},
              },
              'wage_source': 'manual_mix',
              'walk_in_handling_mode': 'walk_ins_added_to_reservations',
              'walk_in_manual_entries': <String, Object?>{'2026-05-06': 8},
            },
            idempotencyKey: 'data-accuracy-settings-key-1',
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final data = body['data'] as Map<String, Object?>;
          expect(data['covers_source_lunch'], 'manual');
          expect(data['wage_source'], 'manual_mix');
          expect(ctx.gateway.calls, <String>[
            'data_accuracy_settings_write:op-1:loc-1:manual:manual_mix',
          ]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH data accuracy settings rejects missing Idempotency-Key',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
              ),
              body: const <String, Object?>{
                'covers_source_lunch': 'manual',
                'wage_source': 'manual_mix',
              },
            );
            expect(response.statusCode, 400);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], 'idempotency_key_missing');
            expect(ctx.gateway.calls, isEmpty);
            expect(ctx.idempotencyStore.reserveCalls, 0);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PATCH data accuracy settings replays same key and body', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
          );
          const body = <String, Object?>{
            'covers_source_lunch': 'manual',
            'wage_source': 'manual_mix',
          };
          final first = await _httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: body,
            idempotencyKey: 'data-accuracy-settings-replay-key',
          );
          final replay = await _httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: body,
            idempotencyKey: 'data-accuracy-settings-replay-key',
          );
          expect(first.statusCode, 200);
          expect(replay.statusCode, 200);
          expect(jsonDecode(replay.body), jsonDecode(first.body));
          expect(ctx.gateway.calls, <String>[
            'data_accuracy_settings_write:op-1:loc-1:manual:manual_mix',
          ]);
          expect(ctx.idempotencyStore.reserveCalls, 1);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH data accuracy settings rejects same key with different body',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final uri = ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
            );
            final first = await _httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'covers_source_lunch': 'manual',
                'wage_source': 'manual_mix',
              },
              idempotencyKey: 'data-accuracy-settings-conflict-key',
            );
            final conflict = await _httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'covers_source_lunch': 'vendor',
                'wage_source': 'manual_mix',
              },
              idempotencyKey: 'data-accuracy-settings-conflict-key',
            );
            expect(first.statusCode, 200);
            expect(conflict.statusCode, 409);
            final body = jsonDecode(conflict.body) as Map<String, Object?>;
            expect(body['error'], 'idempotency_key_conflict');
            expect(ctx.gateway.calls, <String>[
              'data_accuracy_settings_write:op-1:loc-1:manual:manual_mix',
            ]);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PATCH manual covers rejects missing Idempotency-Key', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpRequest(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/'
              'data_accuracy_settings/manual_covers',
            ),
            body: const <String, Object?>{
              'restaurant_id': 'loc-1',
              'business_date': '2026-05-06',
              'service_period_key': 'dinner',
              'covers': 84,
            },
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'idempotency_key_missing');
          expect(ctx.gateway.calls, isEmpty);
          expect(ctx.idempotencyStore.reserveCalls, 0);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH manual covers rejects impossible business date', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpRequest(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/'
              'data_accuracy_settings/manual_covers',
            ),
            body: const <String, Object?>{
              'restaurant_id': 'loc-1',
              'business_date': '2026-02-31',
              'service_period_key': 'dinner',
              'covers': 84,
            },
            idempotencyKey: 'manual-cover-impossible-date-key',
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'invalid_business_date');
          expect(ctx.gateway.calls, isEmpty);
          expect(ctx.idempotencyStore.reserveCalls, 0);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH manual covers merges one canonical cover entry', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpRequest(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/'
              'data_accuracy_settings/manual_covers',
            ),
            body: const <String, Object?>{
              'restaurant_id': 'loc-1',
              'business_date': '2026-05-06',
              'service_period_key': 'dinner',
              'covers': 84,
            },
            idempotencyKey: 'manual-cover-key-1',
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final data = body['data'] as Map<String, Object?>;
          final entries = data['covers_manual_entries'] as Map<String, Object?>;
          expect(entries['2026-05-06'], <String, Object?>{'dinner': 84});
          expect(ctx.gateway.calls, <String>[
            'manual_covers_write:op-1:loc-1:2026-05-06:dinner:84',
          ]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH manual covers replays same key and body without a second write',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final uri = ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/'
              'data_accuracy_settings/manual_covers',
            );
            const body = <String, Object?>{
              'restaurant_id': 'loc-1',
              'business_date': '2026-05-06',
              'service_period_key': 'dinner',
              'covers': 84,
            };
            final first = await _httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: body,
              idempotencyKey: 'manual-cover-replay-key',
            );
            final replay = await _httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: body,
              idempotencyKey: 'manual-cover-replay-key',
            );
            expect(first.statusCode, 200);
            expect(replay.statusCode, 200);
            expect(jsonDecode(replay.body), jsonDecode(first.body));
            expect(ctx.gateway.calls, <String>[
              'manual_covers_write:op-1:loc-1:2026-05-06:dinner:84',
            ]);
            expect(ctx.idempotencyStore.reserveCalls, 1);
            expect(ctx.idempotencyStore.reserveActorUserIds, <String?>[
              'user-1',
            ]);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PATCH manual covers rejects same key with different body', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/'
            'data_accuracy_settings/manual_covers',
          );
          final first = await _httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: const <String, Object?>{
              'restaurant_id': 'loc-1',
              'business_date': '2026-05-06',
              'service_period_key': 'dinner',
              'covers': 84,
            },
            idempotencyKey: 'manual-cover-conflict-key',
          );
          final conflict = await _httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: const <String, Object?>{
              'restaurant_id': 'loc-1',
              'business_date': '2026-05-06',
              'service_period_key': 'dinner',
              'covers': 85,
            },
            idempotencyKey: 'manual-cover-conflict-key',
          );
          expect(first.statusCode, 200);
          expect(conflict.statusCode, 409);
          final body = jsonDecode(conflict.body) as Map<String, Object?>;
          expect(body['error'], 'idempotency_key_conflict');
          expect(ctx.gateway.calls, <String>[
            'manual_covers_write:op-1:loc-1:2026-05-06:dinner:84',
          ]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH data accuracy settings rejects location manager', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          claims: const ProxyJwtClaims(
            userId: 'user-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
            roles: <String>['location_manager'],
          ),
        );
        try {
          final response = await _httpRequest(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
            ),
            body: const <String, Object?>{'wage_source': 'manual_mix'},
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
      'PATCH data accuracy settings rejects phantom operator_admin',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            claims: const ProxyJwtClaims(
              userId: 'user-1',
              operatorId: 'op-1',
              locationId: 'loc-1',
              roles: <String>['operator_admin'],
            ),
          );
          try {
            final response = await _httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
              ),
              body: const <String, Object?>{'wage_source': 'manual_mix'},
            );
            expect(response.statusCode, 403);
            expect(ctx.gateway.calls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('does not accept writes for wage role rows', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/wage_role_rows',
          );
          final post = await _httpRequest(ctx.client, 'POST', uri);
          expect(post.statusCode, 404);
          final patch = await _httpRequest(ctx.client, 'PATCH', uri);
          expect(patch.statusCode, 404);
          expect(ctx.gateway.calls, isEmpty);
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

    test(
      'rejects invalid timing business date before gateway dispatch',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/timing/resolved'
                '?business_date=2026-02-31',
              ),
            );
            expect(response.statusCode, 400);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], 'invalid_business_date');
            expect(ctx.gateway.calls, isEmpty);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST demo master switch flips demo rows and replays durable idem key',
      () async {
        await withRealHttp(() async {
          final demoSwitchGateway = _FakeDemoModeMasterSwitchGateway();
          final ctx = await spinUp(demoSwitchGateway: demoSwitchGateway);
          try {
            final uri = ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
            );
            final first = await _httpRequest(
              ctx.client,
              'POST',
              uri,
              idempotencyKey: 'idem-demo-live',
              body: const <String, Object?>{'target_mode': 'live'},
            );
            expect(first.statusCode, 200);
            final body = jsonDecode(first.body) as Map<String, Object?>;
            expect(body['flipped_count'], 2);
            expect(first.body, contains('"is_demo":false'));

            final replay = await _httpRequest(
              ctx.client,
              'POST',
              uri,
              idempotencyKey: 'idem-demo-live',
              body: const <String, Object?>{'target_mode': 'live'},
            );
            expect(replay.statusCode, 200);
            expect(ctx.demoSwitchGateway.calls, <String>[
              'flip:op-1:loc-1:user-1:2026-05-13T12:00:00.000Z',
            ]);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }

          final restarted = await spinUp(demoSwitchGateway: demoSwitchGateway);
          try {
            final uri = restarted.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
            );
            final replay = await _httpRequest(
              restarted.client,
              'POST',
              uri,
              idempotencyKey: 'idem-demo-live',
              body: const <String, Object?>{'target_mode': 'live'},
            );
            expect(replay.statusCode, 200);
            final body = jsonDecode(replay.body) as Map<String, Object?>;
            expect(body['flipped_count'], 2);
            expect(demoSwitchGateway.calls, <String>[
              'flip:op-1:loc-1:user-1:2026-05-13T12:00:00.000Z',
            ]);
          } finally {
            restarted.client.close(force: true);
            await restarted.server.close(force: true);
          }
        });
      },
    );

    test('POST demo master switch rejects live to demo', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
          );
          final response = await _httpRequest(
            ctx.client,
            'POST',
            uri,
            idempotencyKey: 'idem-live-demo',
            body: const <String, Object?>{'target_mode': 'demo'},
          );
          expect(response.statusCode, 409);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'live_to_demo_refused');
          expect(body['message'], contains('live data has arrived'));
          expect(ctx.demoSwitchGateway.calls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'POST demo master switch requires operator write role and idem key',
      () async {
        await withRealHttp(() async {
          final noRole = await spinUp(
            claims: const ProxyJwtClaims(
              userId: 'user-1',
              operatorId: 'op-1',
              locationId: 'loc-1',
              roles: <String>['location_manager'],
            ),
          );
          try {
            final uri = noRole.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
            );
            final forbidden = await _httpRequest(
              noRole.client,
              'POST',
              uri,
              idempotencyKey: 'idem-forbidden',
            );
            expect(forbidden.statusCode, 403);
          } finally {
            noRole.client.close(force: true);
            await noRole.server.close(force: true);
          }

          final missingIdem = await spinUp();
          try {
            final uri = missingIdem.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
            );
            final response = await _httpRequest(
              missingIdem.client,
              'POST',
              uri,
            );
            expect(response.statusCode, 400);
            expect(response.body, contains('idempotency_key_missing'));
          } finally {
            missingIdem.client.close(force: true);
            await missingIdem.server.close(force: true);
          }
        });
      },
    );
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  _SettableVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _FakeAdminRequestIdempotencyStore
    implements AdminRequestIdempotencyStore {
  final Map<String, _FakeAdminRequestIdempotencyRow> _rows =
      <String, _FakeAdminRequestIdempotencyRow>{};
  final List<String?> reserveActorUserIds = <String?>[];
  int reserveCalls = 0;

  @override
  Future<AdminRequestIdempotencyEntry?> lookup({
    required String idempotencyKey,
    required String requestType,
    required String requestBodyHash,
  }) async {
    final row = _rows[idempotencyKey];
    if (row == null) return null;
    if (row.requestType != requestType ||
        row.requestBodyHash != requestBodyHash) {
      throw const AdminIdempotencyKeyConflict(
        message: 'Idempotency-Key was already used for another request',
      );
    }
    return AdminRequestIdempotencyEntry(
      idempotencyKey: idempotencyKey,
      requestType: row.requestType,
      responseStatus: row.responseStatus,
      responsePayload: row.responsePayload,
      completedAt: row.completedAt,
      expiresAt: row.expiresAt,
    );
  }

  @override
  Future<bool> reserve({
    required String idempotencyKey,
    required String requestType,
    required String? actorUserId,
    required String requestBodyHash,
  }) async {
    reserveCalls += 1;
    reserveActorUserIds.add(actorUserId);
    if (_rows.containsKey(idempotencyKey)) return false;
    _rows[idempotencyKey] = _FakeAdminRequestIdempotencyRow(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: DateTime.utc(2026, 5, 6, 12, 15),
    );
    return true;
  }

  @override
  Future<void> completeReservation({
    required String idempotencyKey,
    required int responseStatus,
    required Map<String, Object?> responsePayload,
  }) async {
    final row = _rows[idempotencyKey];
    if (row == null) return;
    _rows[idempotencyKey] = row.copyWith(
      responseStatus: responseStatus,
      responsePayload: responsePayload,
      completedAt: DateTime.utc(2026, 5, 6, 12, 1),
    );
  }

  @override
  Future<bool> tryReclaimOrphan({required String idempotencyKey}) async {
    return false;
  }

  @override
  Future<int> sweepExpiredOrphans() async {
    return 0;
  }
}

class _FakeAdminRequestIdempotencyRow {
  const _FakeAdminRequestIdempotencyRow({
    required this.requestType,
    required this.requestBodyHash,
    required this.expiresAt,
    this.responseStatus,
    this.responsePayload,
    this.completedAt,
  });

  final String requestType;
  final String requestBodyHash;
  final DateTime? expiresAt;
  final int? responseStatus;
  final Map<String, Object?>? responsePayload;
  final DateTime? completedAt;

  _FakeAdminRequestIdempotencyRow copyWith({
    int? responseStatus,
    Map<String, Object?>? responsePayload,
    DateTime? completedAt,
  }) {
    return _FakeAdminRequestIdempotencyRow(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: expiresAt,
      responseStatus: responseStatus ?? this.responseStatus,
      responsePayload: responsePayload ?? this.responsePayload,
      completedAt: completedAt ?? this.completedAt,
    );
  }
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
        'walk_in_handling_mode': 'walk_ins_added_to_reservations',
        'walk_in_manual_entries': <String, Object?>{'2026-05-06': 8},
        'updated_at': '2026-05-06T12:00:00Z',
      },
    };
  }

  @override
  Future<Map<String, Object?>> upsertDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    calls.add(
      'data_accuracy_settings_write:$operatorId:$locationId:'
      '${body['covers_source_lunch']}:${body['wage_source']}',
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'setting_id': 'setting-1',
        'operator_id': operatorId,
        'location_id': locationId,
        'covers_source_lunch': body['covers_source_lunch'] ?? 'vendor',
        'covers_source_dinner': body['covers_source_dinner'] ?? 'vendor',
        'covers_source_late_night':
            body['covers_source_late_night'] ?? 'vendor',
        'covers_manual_entries':
            body['covers_manual_entries'] ?? const <String, Object?>{},
        'wage_source': body['wage_source'] ?? 'vendor',
        'walk_in_handling_mode':
            body['walk_in_handling_mode'] ?? 'reservations_only',
        'walk_in_manual_entries':
            body['walk_in_manual_entries'] ?? const <String, Object?>{},
        'created_at': '2026-05-06T12:00:00Z',
        'updated_at': '2026-05-06T12:01:00Z',
        'updated_by': scope.userId,
      },
    };
  }

  @override
  Future<Map<String, Object?>> upsertDataAccuracyManualCovers({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    final businessDate = body['business_date']! as String;
    final servicePeriodKey = body['service_period_key']! as String;
    calls.add(
      'manual_covers_write:$operatorId:$locationId:'
      '$businessDate:$servicePeriodKey:'
      '${body['covers']}',
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'setting_id': 'setting-1',
        'operator_id': operatorId,
        'location_id': locationId,
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'manual',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': <String, Object?>{
          businessDate: <String, Object?>{servicePeriodKey: body['covers']},
        },
        'wage_source': 'manual_mix',
        'walk_in_handling_mode': 'walk_ins_added_to_reservations',
        'walk_in_manual_entries': <String, Object?>{'2026-05-06': 8},
        'created_at': '2026-05-06T12:00:00Z',
        'updated_at': '2026-05-06T12:01:00Z',
        'updated_by': scope.userId,
      },
    };
  }

  @override
  Future<Map<String, Object?>> upsertDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    calls.add(
      'data_accuracy_service_period_settings_write:$operatorId:$locationId:'
      '${body['service_period_key']}:${body['covers_source']}:'
      '${body['wage_source']}:${body['effective_at_business_date']}',
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'id': 'period-setting-1',
        'operator_id': operatorId,
        'location_id': locationId,
        'service_period_key': body['service_period_key'] ?? 'breakfast',
        'covers_source': body['covers_source'] ?? 'vendor',
        'wage_source': body['wage_source'] ?? 'vendor_per_employee',
        'effective_at_business_date':
            body['effective_at_business_date'] ?? '2026-05-07',
        'created_at': '2026-05-07T12:00:00Z',
        'updated_at': '2026-05-07T12:01:00Z',
        'updated_by': scope.userId,
      },
    };
  }

  @override
  Future<Map<String, Object?>> fetchDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('data_accuracy_service_period_settings:$operatorId:$locationId');
    return const <String, Object?>{
      'data_accuracy_service_period_settings': <Map<String, Object?>>[
        <String, Object?>{
          'id': 'setting-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'service_period_key': 'dinner',
          'effective_at_business_date': '2026-05-06',
          'covers_source': 'manual',
          'wage_source': 'manual_mix',
          'created_at': '2026-05-06T12:00:00Z',
          'updated_at': '2026-05-06T12:00:00Z',
          'updated_by': 'user-1',
        },
      ],
    };
  }

  @override
  Future<Map<String, Object?>> fetchWageRoleRows({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) async {
    calls.add(
      'wage_role_rows:$operatorId:$locationId:$modifiedSince:$pageSize',
    );
    return const <String, Object?>{
      'wage_role_rows': <Map<String, Object?>>[
        <String, Object?>{
          'server_id': 'wage-row-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'restaurant_id': 'loc-1',
          'role_name': 'Server',
          'labor_bucket': 'foh',
          'hourly_rate': 22.5,
          'weighted_hours': 32.0,
          'job_code': '5001',
          'vendor_id': 'quickbooks_time',
          'vendor_role_id': '5001',
          'source': 'operator_manual',
          'is_active': true,
          'effective_at': '2026-05-06T12:00:00Z',
          'metadata': <String, Object?>{'source_label': 'manual mix'},
          'created_at': '2026-05-06T12:00:00Z',
          'updated_at': '2026-05-06T12:30:00Z',
          'updated_by': 'user-1',
        },
      ],
      'next_cursor': '2026-05-06T12:30:00.000Z',
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

class _FakeDemoModeMasterSwitchGateway implements DemoModeMasterSwitchGateway {
  final List<String> calls = <String>[];
  final Map<String, DemoModeMasterSwitchResult> _responses =
      <String, DemoModeMasterSwitchResult>{};
  final Map<String, String> _hashes = <String, String>{};
  bool alreadyLive = false;

  @override
  Future<DemoModeMasterSwitchResult> flipAllDemoRowsToLive({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime flippedAt,
    required String idempotencyKey,
    required String requestBodyHash,
  }) async {
    final key = '$operatorId|$locationId|$idempotencyKey';
    final storedHash = _hashes[key];
    if (storedHash != null && storedHash != requestBodyHash) {
      throw const DemoModeMasterSwitchRejected(
        code: 'idempotency_key_conflict',
        message: 'Idempotency-Key was already used for another request',
        statusCode: 409,
      );
    }
    final stored = _responses[key];
    if (stored != null) return stored;
    calls.add(
      'flip:$operatorId:$locationId:$actorUserId:'
      '${flippedAt.toUtc().toIso8601String()}',
    );
    if (alreadyLive) {
      return const DemoModeMasterSwitchResult(
        flippedCount: 0,
        records: <DemoModeRecord>[
          DemoModeRecord(
            operatorId: 'op-1',
            locationId: 'loc-1',
            category: IntegrationCategory.pos,
            isDemo: false,
          ),
        ],
      );
    }
    alreadyLive = true;
    final result = DemoModeMasterSwitchResult(
      flippedCount: 2,
      records: <DemoModeRecord>[
        DemoModeRecord(
          operatorId: operatorId,
          locationId: locationId,
          category: IntegrationCategory.labor,
          isDemo: false,
          flippedToLiveAt: flippedAt,
        ),
        DemoModeRecord(
          operatorId: operatorId,
          locationId: locationId,
          category: IntegrationCategory.pos,
          isDemo: false,
          flippedToLiveAt: flippedAt,
        ),
      ],
    );
    _hashes[key] = requestBodyHash;
    _responses[key] = result;
    return result;
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
  final responseBody = await utf8.decodeStream(response);
  return _HttpResult(response.statusCode, responseBody);
}

Future<_HttpResult> _httpRequest(
  HttpClient client,
  String method,
  Uri uri, {
  String authorization = 'Bearer token',
  Map<String, Object?> body = const <String, Object?>{},
  String? idempotencyKey,
}) async {
  final request = await client.openUrl(method, uri);
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body.isNotEmpty) {
    final encoded = utf8.encode(jsonEncode(body));
    request.headers.contentType = ContentType.json;
    request.contentLength = encoded.length;
    request.add(encoded);
  }
  final response = await request.close();
  final responseBody = await utf8.decodeStream(response);
  return _HttpResult(response.statusCode, responseBody);
}

class _HttpResult {
  const _HttpResult(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
