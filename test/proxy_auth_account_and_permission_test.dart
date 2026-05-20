// Phase 9 live-closeout - proxy auth account info + permission snapshot
// route tests.
//
// Bucket 5d-account+permission of the 2026-05-20 test-suite tightening
// audit: split out of `test/proxy_auth_operations_route_test.dart`
// (3,599 lines). This file holds the GET permission snapshot, GET
// account info (including the Wave 2 W-5-mobile-FU-2 `logo_url`
// round-trip), and the "Team permission not required for account
// info" route tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'proxy_auth_test_helpers.dart';

void main() {
  group('Phase 9 auth-operation proxy routes', () {
    test('GET permission snapshot returns resolver payload', () async {
      await withRealHttp(() async {
        final harness = await RouteHarness.start(
          permissionSnapshotResolver: FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: proxyAuthUserId,
              operatorId: proxyAuthOperatorId,
              locationId: proxyAuthLocationId,
              rolesVersion: 7,
              evaluatedAt: DateTime.utc(2026, 4, 28, 12),
              permissions: const <String, PermissionEffect>{
                'team.users.view': PermissionEffect.allow,
                'team.users.invite': PermissionEffect.deny,
              },
              requiresMfaKeys: const <String>{'billing.manage'},
            ),
          ),
        );
        try {
          final response = await harness.get(authPermissionsSnapshotPath);
          final body = response.json;

          expect(response.statusCode, equals(200));
          expect(body['user_id'], equals(proxyAuthUserId));
          expect(body['roles_version'], equals(7));
          expect(
            body['permissions'],
            equals(<String, Object?>{
              'team.users.view': 'allow',
              'team.users.invite': 'deny',
            }),
          );
          expect(body['requires_mfa'], equals(<Object?>['billing.manage']));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET account info is self-scoped and returns friendly payload',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAccountInfoGateway();
          final harness = await RouteHarness.start(
            accountInfoGateway: gateway,
          );
          try {
            final response = await harness.get(
              '$authAccountInfoPath?user_id=someone-else',
            );
            final body = response.json;

            expect(response.statusCode, equals(200));
            expect(gateway.requests.single.actorUserId, equals(proxyAuthUserId));
            expect(gateway.requests.single.operatorId, equals(proxyAuthOperatorId));
            expect(body['display_name'], equals('Jane Operator'));
            expect(body['location_label'], equals('Downtown'));
            expect(body['role_labels'], equals(<Object?>['Kitchen Lead']));
            expect(body['mfa_enabled'], isTrue);
            expect(body.containsKey('user_id'), isFalse);
            expect(body.containsKey('operator_id'), isFalse);
            expect(body.containsKey('location_id'), isFalse);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'Wave 2 W-5-mobile-FU-2: GET account info serializes logo_url when set',
      () async {
        await withRealHttp(() async {
          // Pin the proxy → mobile/operator-web wire contract for
          // `operators.logo_url`. The W-5-mobile-FU client (PR #695)
          // already accepts the field forward-compatibly; this test
          // locks the proxy half so the round-trip cannot regress.
          final gateway = RecordingAccountInfoGateway(
            logoUrl: 'https://cdn.example/op-logo.png',
          );
          final harness = await RouteHarness.start(
            accountInfoGateway: gateway,
          );
          try {
            final response = await harness.get(authAccountInfoPath);
            final body = response.json;

            expect(response.statusCode, equals(200));
            expect(body.containsKey('logo_url'), isTrue);
            expect(body['logo_url'], equals('https://cdn.example/op-logo.png'));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'Wave 2 W-5-mobile-FU-2: GET account info serializes logo_url as null when unset',
      () async {
        await withRealHttp(() async {
          // Operators that have not uploaded a brand-mark must still
          // see the field as an explicit `null` in the JSON so the
          // mobile client renders the F&F splash fallback rather than
          // tripping a "missing field" malformed_response.
          final gateway = RecordingAccountInfoGateway();
          final harness = await RouteHarness.start(
            accountInfoGateway: gateway,
          );
          try {
            final response = await harness.get(authAccountInfoPath);
            final body = response.json;

            expect(response.statusCode, equals(200));
            expect(body.containsKey('logo_url'), isTrue);
            expect(body['logo_url'], isNull);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('GET account info does not require Team permission', () async {
      await withRealHttp(() async {
        final gateway = RecordingAccountInfoGateway();
        final guard = RecordingAdminGuard(
          decision: const ProxyAdminDeniedDefault(),
        );
        final harness = await RouteHarness.start(
          accountInfoGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.get(authAccountInfoPath);

          expect(response.statusCode, equals(200));
          expect(guard.permissionKeys, isEmpty);
          expect(gateway.requests, hasLength(1));
        } finally {
          await harness.close();
        }
      });
    });

  });
}
