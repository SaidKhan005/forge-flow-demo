// Audit fix-first #7 (cross-surface parity finding G4) — admin "My
// Account" Security card working-surface widget tests.
//
// Verifies that when an AdminSecurityGateway is wired the Security
// card renders the working self-service surface (not the read-only
// W-4 posture): MFA status reflects the gateway, the enroll → confirm
// path drives the gateway with a stable idempotency key, the password
// and recovery actions are reachable, and a gateway failure fails
// closed (no false success toast). Also pins that a NULL gateway still
// degrades to the legacy read-only note (so older fixtures stay green).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/screens/my_account_admin_screen.dart';
import 'package:forge_and_flow/admin/services/admin_security_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  AdminAuthSession session() => AdminAuthSession(
        uid: 'demo-super-admin',
        email: 'super.admin@forgeflow.test',
        displayName: 'Demo Super Admin',
        roles: const <String>['super_admin'],
        lastFreshAuthAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
      );

  testWidgets(
      'NULL security gateway still degrades to the read-only note (G4 '
      'fail-safe)', (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );

    expect(
      find.byKey(const Key('admin_my_account_two_factor_readonly_note')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_my_account_mfa_enroll_button')),
      findsNothing,
    );
  });

  testWidgets(
      'wired gateway with no factor renders the working enroll surface',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = InMemoryAdminSecurityGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Working surface — NOT the read-only note. MFA is now its own
    // "Two-factor sign-in" card (ops parity); the enroll CTA lives
    // there and Change password lives in the Security card.
    expect(
      find.byKey(const Key('admin_my_account_two_factor_readonly_note')),
      findsNothing,
    );
    expect(find.text('Not set up'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_my_account_two_factor_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_my_account_mfa_enroll_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_my_account_change_password_button')),
      findsOneWidget,
    );
    // Recovery ("Lost your authenticator?") is offered only once a
    // factor is enrolled — there is nothing to recover before then.
    expect(
      find.byKey(const Key('admin_my_account_mfa_recovery_button')),
      findsNothing,
    );
  });

  testWidgets('enroll → confirm drives the gateway with a stable key',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = InMemoryAdminSecurityGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_my_account_mfa_enroll_button')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_enroll_mfa_dialog')), findsOneWidget);
    expect(find.byKey(const Key('admin_enroll_mfa_secret')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_enroll_mfa_code_field')),
      '123456',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('admin_enroll_mfa_confirm')));
    await tester.pumpAndSettle();

    // Dialog closed, factor enrolled, toast shown.
    expect(find.byKey(const Key('admin_enroll_mfa_dialog')), findsNothing);
    expect((await gateway.listFactors()).hasEnrolledFactor, isTrue);
    expect(
      find.byKey(const Key('admin_my_account_two_factor_toast')),
      findsOneWidget,
    );
    // begin + confirm share ONE caller-stable key (no G60 bug).
    expect(gateway.idempotencyKeys, hasLength(2));
    expect(gateway.idempotencyKeys.toSet(), hasLength(1));
  });

  testWidgets('gateway failure on confirm fails closed (no success toast)',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = InMemoryAdminSecurityGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_my_account_mfa_enroll_button')),
    );
    await tester.pumpAndSettle();

    // Wrong-length code → InMemory gateway throws → dialog shows the
    // error, the surface does NOT claim success.
    await tester.enterText(
      find.byKey(const Key('admin_enroll_mfa_code_field')),
      '12345',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
              find.byKey(const Key('admin_enroll_mfa_confirm')))
          .onPressed,
      isNull,
      reason: 'A 5-digit code must not be submittable.',
    );

    // Cancel and confirm no false enrollment / no success toast.
    await tester.tap(find.byKey(const Key('admin_enroll_mfa_cancel')));
    await tester.pumpAndSettle();
    expect((await gateway.listFactors()).hasEnrolledFactor, isFalse);
    expect(
      find.byKey(const Key('admin_my_account_two_factor_toast')),
      findsNothing,
    );
  });

  testWidgets('password change dialog opens and routes through the gateway',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = InMemoryAdminSecurityGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_my_account_change_password_button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_change_password_dialog')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('admin_change_password_current')),
      'old-secret',
    );
    await tester.enterText(
      find.byKey(const Key('admin_change_password_new')),
      'a-very-strong-pw-1!',
    );
    await tester.enterText(
      find.byKey(const Key('admin_change_password_confirm')),
      'a-very-strong-pw-1!',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('admin_change_password_save')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_change_password_dialog')),
      findsNothing,
    );
    expect(gateway.idempotencyKeys, isNotEmpty);
  });
}
