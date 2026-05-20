// Mobile operational sync proxy routes — demo-mode master switch and
// error-path tests.
//
// Bucket 5i-demo-and-error-paths of the 2026-05-20 test-suite tightening
// audit: split out of `test/proxy/mobile_operational_sync_routes_test.dart`
// (2,067 lines). This file holds the cross-cutting failure-mode tests:
//
//   - 503 wrapper when the production gateway is not installed
//     (`mobile_operational_sync_not_configured`).
//   - 503 envelope when the upstream gateway throws
//     (`mobile_operational_sync_unavailable`); supporting test for the
//     mobile pull-loop's 401-retry honesty.
//   - 400 rejection of an invalid timing/resolved business_date
//     (`invalid_business_date`) before any gateway dispatch.
//   - POST demo-mode master switch flip + durable idempotency replay,
//     including the documented "live→demo refused" 409 and the
//     operator-write-role + Idempotency-Key requirements.
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
    test('returns 503 when production gateway is not installed', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(gatewayConfigured: false);
        try {
          final response = await httpGet(
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
            final response = await httpGet(
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

    test(
      'rejects invalid timing business date before gateway dispatch',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await httpGet(
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
          final demoSwitchGateway = FakeDemoModeMasterSwitchGateway();
          final ctx = await spinUp(demoSwitchGateway: demoSwitchGateway);
          try {
            final uri = ctx.baseUri.resolve(
              '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
            );
            final first = await httpRequest(
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

            final replay = await httpRequest(
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
            final replay = await httpRequest(
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
          final response = await httpRequest(
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
            final forbidden = await httpRequest(
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
            final response = await httpRequest(
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
