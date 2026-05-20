// Mobile operational sync proxy routes — shift records, GET endpoints,
// RLS-on-reads, and pagination validation tests.
//
// Bucket 5i-shift-records of the 2026-05-20 test-suite tightening audit:
// split out of `test/proxy/mobile_operational_sync_routes_test.dart`
// (2,067 lines). This file holds the read-path tests:
//
//   - GET endpoints route through token-matched operator scope (the
//     fan-out canonical that exercises every read surface and pins the
//     V1.A timing-provenance triplet on closed shift_records).
//   - wage_role_rows POST/PATCH return 404 (read-only resource).
//   - production gateway unconfigured returns 503.
//   - URL-scope vs bearer-scope mismatch on a read returns 403.
//   - page_size + modified_since validation rejected before any
//     gateway dispatch.
//
// Shared `spinUp()` harness + fakes live in
// `mobile_operational_sync_test_helpers.dart`. The original top-level
// `group('mobile operational sync proxy routes', ...)` wrapper is
// preserved per-file so failures stay attributed to the same suite name
// in CI output.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'mobile_operational_sync_test_helpers.dart';

void main() {
  group('mobile operational sync proxy routes', () {
    test('GET endpoints route through token-matched operator scope', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final shift = await httpGet(
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

          final open = await httpGet(
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

          final timing = await httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/timing/resolved'
              '?business_date=2026-05-06',
            ),
          );
          expect(timing.statusCode, 200);
          expect(timing.body, contains('timing_config'));

          final demo = await httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/demo_mode_states',
            ),
          );
          expect(demo.statusCode, 200);
          expect(demo.body, contains('demo_mode_states'));

          final accuracy = await httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
            ),
          );
          expect(accuracy.statusCode, 200);
          expect(accuracy.body, contains('covers_source_lunch'));
          expect(accuracy.body, contains('walk_in_handling_mode'));

          final periodAccuracy = await httpGet(
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

          final wageRows = await httpGet(
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

          final tier = await httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/polling_tier_assignment',
            ),
          );
          expect(tier.statusCode, 200);
          expect(tier.body, contains('polling_cadence_per_vendor_seconds'));

          final backfill = await httpGet(
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
            'wage_role_rows:op-1:loc-1:2026-05-06T12:00:00Z:1:false',
            'polling_tier_assignment:op-1:loc-1',
            'first_backfill_status:op-1:loc-1',
          ]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('does not accept writes for wage role rows', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/operators/op-1/locations/loc-1/wage_role_rows',
          );
          final post = await httpRequest(ctx.client, 'POST', uri);
          expect(post.statusCode, 404);
          final patch = await httpRequest(ctx.client, 'PATCH', uri);
          expect(patch.statusCode, 404);
          expect(ctx.gateway.calls, isEmpty);
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
          final response = await httpGet(
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

    test('validates page size and cursor before gateway dispatch', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final badPage = await httpGet(
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

          final badCursor = await httpGet(
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
