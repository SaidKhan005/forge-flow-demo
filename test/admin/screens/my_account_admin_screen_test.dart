// Wave 2 W-4 — Admin "My Account" parity widget tests.
//
// Verifies the parity surface renders all four sections (header,
// identity, security, active sessions), the identity card surfaces
// the admin role badge + global-scope label (HP #11 degradation),
// the security section renders read-only when no admin mutation
// gateway is wired, and the demo-mode mount renders identically to
// production (HP #2). Also covers the side-nav wiring at the admin
// shell level so a side-nav click lands on the new route.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/admin_shell.dart';
import 'package:forge_and_flow/admin/screens/my_account_admin_screen.dart';
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

  group('MyAccountAdminScreen render', () {
    testWidgets('renders header + identity, security, and sessions cards', (
      tester,
    ) async {
      wideViewport(tester);
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);
      final session = AdminAuthSession(
        uid: 'demo-super-admin',
        email: 'super.admin@forgeflow.test',
        displayName: 'Demo Super Admin',
        roles: const <String>['super_admin'],
        lastFreshAuthAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
      );

      await tester.pumpWidget(
        wrap(
          MyAccountAdminScreen(
            session: session,
            authSource: source,
            now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
          ),
        ),
      );

      expect(find.byKey(const Key('admin_my_account_screen')), findsOneWidget);
      expect(find.text('My account'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_my_account_identity_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_my_account_security_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_my_account_active_sessions_card')),
        findsOneWidget,
      );

      // Identity values rendered.
      expect(find.text('Demo Super Admin'), findsOneWidget);
      expect(find.text('super.admin@forgeflow.test'), findsOneWidget);
      // Role badge (ecosystem admin).
      expect(find.byKey(const Key('admin_my_account_role_badge')), findsOneWidget);
      expect(find.text('Ecosystem admin'), findsOneWidget);
      // HP #11 scope degraded to global label (no business / region /
      // location triple).
      expect(find.text('Global: cross-operator'), findsOneWidget);
    });

    testWidgets(
      'renders ff_support role label and read-only security note',
      (tester) async {
        wideViewport(tester);
        final source = DemoAdminAuthSource.signedInAsSupport();
        addTearDown(source.dispose);
        final session = AdminAuthSession(
          uid: 'demo-ff-support',
          email: 'support@forgeflow.test',
          displayName: 'Demo F&F Support',
          roles: const <String>['ff_support'],
          lastFreshAuthAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
        );

        await tester.pumpWidget(
          wrap(
            MyAccountAdminScreen(
              session: session,
              authSource: source,
              now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
            ),
          ),
        );

        expect(find.text('Support access'), findsOneWidget);
        // 2FA status read off lastFreshAuthAt.
        expect(find.byKey(const Key('admin_my_account_mfa_status')), findsOneWidget);
        expect(find.text('On'), findsOneWidget);
        // Read-only note is present in security card.
        expect(
          find.byKey(const Key('admin_my_account_security_readonly_note')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'renders unknown 2FA state when lastFreshAuthAt is null',
      (tester) async {
        wideViewport(tester);
        final source = DemoAdminAuthSource.signedInAsSuperAdmin();
        addTearDown(source.dispose);
        const session = AdminAuthSession(
          uid: 'demo-no-stamp',
          email: 'nofresh@forgeflow.test',
          displayName: 'No Stamp',
          roles: <String>['super_admin'],
        );

        await tester.pumpWidget(
          wrap(MyAccountAdminScreen(session: session, authSource: source)),
        );

        // 2FA status shows 'Unknown' when there's no auth_time stamp.
        expect(find.text('Unknown'), findsOneWidget);
        // The helper copy nudges the operator to re-sign-in.
        expect(
          find.textContaining('Sign in again from'),
          findsOneWidget,
        );
      },
    );

    testWidgets('renders Sign-out CTA on the active sessions card', (
      tester,
    ) async {
      wideViewport(tester);
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);
      final session = AdminAuthSession(
        uid: 'demo-super-admin',
        email: 'super.admin@forgeflow.test',
        displayName: 'Demo Super Admin',
        roles: const <String>['super_admin'],
        lastFreshAuthAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
      );

      await tester.pumpWidget(
        wrap(
          MyAccountAdminScreen(
            session: session,
            authSource: source,
            now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
          ),
        ),
      );

      expect(
        find.byKey(const Key('admin_my_account_current_session_row')),
        findsOneWidget,
      );
      expect(find.text('This admin console session'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_my_account_sign_out_button')),
        findsOneWidget,
      );

      // Tap the sign-out button — this should drive the auth source
      // back to an unauthenticated state.
      await tester.tap(
        find.byKey(const Key('admin_my_account_sign_out_button')),
      );
      await tester.pumpAndSettle();

      expect(source.current, isA<AdminAuthUnauthenticated>());
    });

    testWidgets(
      'handles empty display name + email gracefully',
      (tester) async {
        wideViewport(tester);
        final source = DemoAdminAuthSource.signedInAsSuperAdmin();
        addTearDown(source.dispose);
        const session = AdminAuthSession(
          uid: 'demo-empty',
          email: '',
          displayName: '',
          roles: <String>['super_admin'],
        );

        await tester.pumpWidget(
          wrap(MyAccountAdminScreen(session: session, authSource: source)),
        );

        // Both empty fields fall back to "Not on file".
        expect(find.text('Not on file'), findsNWidgets(2));
      },
    );

    testWidgets(
      'demo-mode mount renders the same surface as production',
      (tester) async {
        // HP #2 parity: the same widget tree renders regardless of the
        // demo-mode flag. The screen does not branch on `kDemoMode`;
        // it reads the session payload only. Sanity-check both demo
        // factories produce a session with the parity surface mounted.
        wideViewport(tester);
        for (final factory in <DemoAdminAuthSource Function()>[
          DemoAdminAuthSource.signedInAsSuperAdmin,
          DemoAdminAuthSource.signedInAsSupport,
        ]) {
          final source = factory();
          addTearDown(source.dispose);
          final auth = source.current as AdminAuthAuthenticated;
          await tester.pumpWidget(
            wrap(
              MyAccountAdminScreen(
                session: auth.session,
                authSource: source,
                now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
              ),
            ),
          );
          expect(
            find.byKey(const Key('admin_my_account_screen')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('admin_my_account_identity_card')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('admin_my_account_security_card')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('admin_my_account_active_sessions_card')),
            findsOneWidget,
          );
        }
      },
    );
  });

  group('Admin shell side-nav wiring', () {
    testWidgets('My Account route mounts via the admin shell side nav', (
      tester,
    ) async {
      wideViewport(tester);
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);
      final session = (source.current as AdminAuthAuthenticated).session;

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeData,
          home: AdminConsoleServicesScope(
            adminAuthSource: source,
            child: AdminShell(
              session: session,
              authSource: source,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The side nav exposes a row keyed by the route id.
      final myAccountNavItem = find.byKey(
        Key('admin_nav_item_$kAdminMyAccountRouteId'),
      );
      expect(myAccountNavItem, findsOneWidget);

      await tester.ensureVisible(myAccountNavItem);
      await tester.pumpAndSettle();
      await tester.tap(myAccountNavItem);
      await tester.pumpAndSettle();

      // After the tap, the screen mounts.
      expect(find.byKey(const Key('admin_my_account_screen')), findsOneWidget);
      expect(find.text('My account'), findsWidgets);
    });

    testWidgets(
      'fallback renders when no admin auth source is wired into the scope',
      (tester) async {
        wideViewport(tester);
        final source = DemoAdminAuthSource.signedInAsSuperAdmin();
        addTearDown(source.dispose);
        final session = (source.current as AdminAuthAuthenticated).session;

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.themeData,
            // NOTE: no AdminConsoleServicesScope.adminAuthSource — the
            // scope is missing entirely, so the route builder must
            // render the fallback surface.
            home: AdminShell(
              session: session,
              authSource: source,
              initialRouteId: kAdminMyAccountRouteId,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('admin_my_account_unauthenticated_fallback')),
          findsOneWidget,
        );
      },
    );
  });
}
