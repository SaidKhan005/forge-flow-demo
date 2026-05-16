// Demo Forge & Flow flavor — writer-side DemoAuthLoginService.
//
// Proves:
//  * the demo operator credential mints an `ff_support` (F&F-admin)
//    session whose roles satisfy the Settings F&F gates;
//  * scope ids stay pinned to the demo data scope so SQLite demo data
//    still resolves under the signed-in session (drift guard against
//    `DemoScope`);
//  * every other credential fails closed (`invalid_credentials`) — the
//    elevation is fixture-scoped, not an always-allow path;
//  * the synthetic token decodes the honest demo identity used by the
//    Account-card fallback.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart'
    show DemoScope;
import 'package:forge_and_flow/services/auth/demo_auth_login_service.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';

void main() {
  const service = DemoAuthLoginService();

  test('demo operator credential mints an ff_support F&F-admin session', () async {
    final result = await service.signInWithEmailPassword(
      email: kDemoOperatorEmail,
      password: kDemoOperatorPassword,
    );

    expect(result, isA<AuthLoginSuccess>());
    final session = (result as AuthLoginSuccess).session;

    // F&F-admin: ff_support satisfies `_isFFAccount` /
    // `_shouldShowDataTab` (admin.debug_console.view tier) and
    // `kAdminConsoleRoles`, WITHOUT the destructive super_admin tier.
    expect(session.roles, contains('ff_support'));
    expect(session.roles, isNot(contains('super_admin')));
    expect(session.roles, contains('roles_version:1'));
    expect(session.mfaEnrolled, isFalse);
    expect(session.isLive(now: DateTime.now()), isTrue);
  });

  test('email match is case-insensitive', () async {
    final result = await service.signInWithEmailPassword(
      email: '  DEMO.Operator@ForgeFlow.test ',
      password: kDemoOperatorPassword,
    );
    expect(result, isA<AuthLoginSuccess>());
  });

  test('scope ids stay pinned to the demo data scope (DemoScope drift guard)', () async {
    final session =
        ((await service.signInWithEmailPassword(
                  email: kDemoOperatorEmail,
                  password: kDemoOperatorPassword,
                ))
                as AuthLoginSuccess)
            .session;

    expect(session.operatorId, kDemoOperatorOperatorId);
    // The demo session's location must resolve the demo SQLite data
    // scope; if `DemoScope.restaurantId` ever changes this fails loud.
    expect(session.locationId, DemoScope.restaurantId);
    expect(kDemoOperatorLocationId, DemoScope.restaurantId);
  });

  test('synthetic token decodes the honest demo identity', () async {
    final session =
        ((await service.signInWithEmailPassword(
                  email: kDemoOperatorEmail,
                  password: kDemoOperatorPassword,
                ))
                as AuthLoginSuccess)
            .session;

    final parts = session.firebaseIdToken.split('.');
    expect(parts.length, greaterThanOrEqualTo(2));
    final payload =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, Object?>;
    expect(payload['email'], kDemoOperatorEmail);
    expect(payload['name'], 'Demo Operator');
    expect(payload['is_ff_support'], true);
  });

  test('wrong password fails closed (invalid_credentials)', () async {
    final result = await service.signInWithEmailPassword(
      email: kDemoOperatorEmail,
      password: 'not-the-demo-password',
    );
    expect(result, isA<AuthLoginFailure>());
    expect((result as AuthLoginFailure).code, 'invalid_credentials');
  });

  test('unknown email fails closed — elevation is fixture-scoped', () async {
    final result = await service.signInWithEmailPassword(
      email: 'someone.else@example.com',
      password: kDemoOperatorPassword,
    );
    expect(result, isA<AuthLoginFailure>());
    expect((result as AuthLoginFailure).code, 'invalid_credentials');
  });

  test('refreshSession re-issues the same identity with a fresh window', () async {
    final original =
        ((await service.signInWithEmailPassword(
                  email: kDemoOperatorEmail,
                  password: kDemoOperatorPassword,
                ))
                as AuthLoginSuccess)
            .session;
    final refreshed = await service.refreshSession(original);
    expect(refreshed, isNotNull);
    expect(refreshed!.operatorId, original.operatorId);
    expect(refreshed.roles, contains('ff_support'));
  });
}
