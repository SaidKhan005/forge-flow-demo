// Mobile operational sync proxy routes — PATCH sync writes and
// idempotency conflict/replay tests.
//
// Bucket 5i-sync-and-idempotency of the 2026-05-20 test-suite tightening
// audit: split out of `test/proxy/mobile_operational_sync_routes_test.dart`
// (2,067 lines). This file holds every PATCH-path test against the
// three writable resources:
//
//   - data_accuracy_service_period_settings (write, clear, replay,
//     conflict, missing-key, role-guard, invalid key / business date,
//     URL-scope mismatch).
//   - data_accuracy_settings legacy + keyed PATCH (write, replay,
//     conflict, missing-key, legacy-keys-disabled gate, role-guard,
//     per-(O,L) idempotency scoping through the shared ledger).
//   - data_accuracy_settings/manual_covers PATCH (write merge, replay,
//     conflict, missing-key, impossible-date guard).
//
// Shared `spinUp()` harness + fakes live in
// `mobile_operational_sync_test_helpers.dart`. The original top-level
// `group('mobile operational sync proxy routes', ...)` wrapper is
// preserved per-file so failures stay attributed to the same suite name
// in CI output.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import 'mobile_operational_sync_test_helpers.dart';

void main() {
  group('mobile operational sync proxy routes', () {
    test('PATCH service-period settings writes through owner scope', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/'
            'data_accuracy_service_period_settings',
          );
          final post = await httpRequest(ctx.client, 'POST', uri);
          expect(post.statusCode, 404);
          final patch = await httpRequest(
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

    test('PATCH service-period settings clears through owner scope', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/'
            'data_accuracy_service_period_settings',
          );
          final patch = await httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: const <String, Object?>{
              'service_period_key': 'breakfast',
              'clear': true,
            },
            idempotencyKey: 'service-period-clear-key-1',
          );
          expect(patch.statusCode, 200);
          final body = jsonDecode(patch.body) as Map<String, Object?>;
          expect(
            body['data_accuracy_service_period_settings'],
            isA<List<Object?>>(),
          );
          expect(ctx.gateway.calls, <String>[
            'data_accuracy_service_period_settings_clear:op-1:loc-1:breakfast',
          ]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH service-period settings clear rejects mixed write fields',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/'
                'data_accuracy_service_period_settings',
              ),
              body: const <String, Object?>{
                'service_period_key': 'breakfast',
                'clear': true,
                'covers_source': 'manual',
              },
              idempotencyKey: 'service-period-clear-mixed-key',
            );
            expect(response.statusCode, 400);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], 'invalid_service_period_clear');
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
      'PATCH service-period settings rejects missing Idempotency-Key',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await httpRequest(
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
          final first = await httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: body,
            idempotencyKey: 'service-period-replay-key',
          );
          final replay = await httpRequest(
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
            final first = await httpRequest(
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
            final conflict = await httpRequest(
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
          final response = await httpRequest(
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
            final response = await httpRequest(
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
          final response = await httpRequest(
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
            final response = await httpRequest(
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
            final response = await httpRequest(
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
            final response = await httpRequest(
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
          final response = await httpRequest(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
            ),
            body: const <String, Object?>{
              'covers_source_per_service_period': <String, Object?>{
                'lunch': 'manual',
                'dinner': 'vendor',
                'late_night': 'forecast',
              },
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
      'PATCH data accuracy settings rejects legacy covers-source keys',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
              ),
              body: const <String, Object?>{
                'covers_source_lunch': 'manual',
                'wage_source': 'manual_mix',
              },
              idempotencyKey: 'data-accuracy-settings-legacy-key',
            );
            expect(response.statusCode, 410);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], 'legacy_covers_source_write_keys_disabled');
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
      'PATCH data accuracy settings rejects missing Idempotency-Key',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await httpRequest(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
              ),
              body: const <String, Object?>{
                'covers_source_per_service_period': <String, Object?>{
                  'lunch': 'manual',
                },
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
            'covers_source_per_service_period': <String, Object?>{
              'lunch': 'manual',
            },
            'wage_source': 'manual_mix',
          };
          final first = await httpRequest(
            ctx.client,
            'PATCH',
            uri,
            body: body,
            idempotencyKey: 'data-accuracy-settings-replay-key',
          );
          final replay = await httpRequest(
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
            final first = await httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'covers_source_per_service_period': <String, Object?>{
                  'lunch': 'manual',
                },
                'wage_source': 'manual_mix',
              },
              idempotencyKey: 'data-accuracy-settings-conflict-key',
            );
            final conflict = await httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'covers_source_per_service_period': <String, Object?>{
                  'lunch': 'vendor',
                },
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

    test('PATCH data accuracy settings scopes idempotency by operator and '
        'location before using the shared ledger', () async {
      await withRealHttp(() async {
        final sharedStore = FakeAdminRequestIdempotencyStore();
        final firstCtx = await spinUp(idempotencyStore: sharedStore);
        try {
          final first = await httpRequest(
            firstCtx.client,
            'PATCH',
            firstCtx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
            ),
            body: const <String, Object?>{
              'covers_source_per_service_period': <String, Object?>{
                'lunch': 'manual',
              },
              'wage_source': 'manual_mix',
            },
            idempotencyKey: 'same-visible-key',
          );
          expect(first.statusCode, 200);
        } finally {
          firstCtx.client.close(force: true);
          await firstCtx.server.close(force: true);
        }

        final secondCtx = await spinUp(
          claims: const ProxyJwtClaims(
            userId: 'user-2',
            operatorId: 'op-1',
            locationId: 'loc-2',
            roles: <String>['operator_owner'],
          ),
          idempotencyStore: sharedStore,
        );
        try {
          final second = await httpRequest(
            secondCtx.client,
            'PATCH',
            secondCtx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-2/data_accuracy_settings',
            ),
            body: const <String, Object?>{
              'covers_source_per_service_period': <String, Object?>{
                'lunch': 'vendor',
              },
              'wage_source': 'vendor',
            },
            idempotencyKey: 'same-visible-key',
          );
          expect(second.statusCode, 200);
          expect(secondCtx.gateway.calls, <String>[
            'data_accuracy_settings_write:op-1:loc-2:vendor:vendor',
          ]);
          expect(sharedStore.reserveIdempotencyKeys, <String>[
            'operator:op-1:location:loc-1:same-visible-key',
            'operator:op-1:location:loc-2:same-visible-key',
          ]);
        } finally {
          secondCtx.client.close(force: true);
          await secondCtx.server.close(force: true);
        }
      });
    });

    test('PATCH manual covers rejects missing Idempotency-Key', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await httpRequest(
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
          final response = await httpRequest(
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
          final response = await httpRequest(
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
            final first = await httpRequest(
              ctx.client,
              'PATCH',
              uri,
              body: body,
              idempotencyKey: 'manual-cover-replay-key',
            );
            final replay = await httpRequest(
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
          final first = await httpRequest(
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
          final conflict = await httpRequest(
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
          final response = await httpRequest(
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
            final response = await httpRequest(
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
  });
}
