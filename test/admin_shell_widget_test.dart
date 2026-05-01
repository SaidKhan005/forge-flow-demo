// Phase 11A.0 — Admin shell widget tests.
//
// Verifies the brand-styled shell renders, the side nav surfaces
// every route from `kAdminRoutes`, the home route renders its empty
// landing card, placeholder routes render the branded "coming soon"
// surface, and the header sign-out affordance routes through the
// auth source.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/admin_shell.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  const superAdmin = AdminAuthSession(
    uid: 'demo-super-admin',
    email: 'super.admin@forgeflow.test',
    displayName: 'Demo Super Admin',
    roles: <String>['super_admin'],
  );

  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: child,
      );

  testWidgets('renders branded header with role pill + identity chip',
      (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    expect(find.byKey(const Key('admin_shell_scaffold')), findsOneWidget);
    expect(find.byKey(const Key('admin_header_bar')), findsOneWidget);
    expect(find.byKey(const Key('admin_header_role_pill')), findsOneWidget);
    expect(find.text('super_admin'), findsOneWidget);
    expect(find.byKey(const Key('admin_header_identity')), findsOneWidget);
    expect(find.text(superAdmin.email), findsOneWidget);
    // Brand wordmark from AppTextStyles.display20.
    expect(find.text('Forge & Flow'), findsOneWidget);
    expect(find.text('Operations Console'), findsOneWidget);
  });

  testWidgets('side nav lists every route in kAdminRoutes', (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    expect(find.byKey(const Key('admin_side_nav')), findsOneWidget);
    for (final route in kAdminRoutes) {
      expect(
        find.byKey(Key('admin_nav_item_${route.id}')),
        findsOneWidget,
        reason: 'side nav must surface ${route.id}',
      );
    }
  });

  testWidgets('home route renders its branded empty landing card',
      (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    expect(find.byKey(const Key('admin_home_card')), findsOneWidget);
    expect(find.text('Operations console'), findsOneWidget);
    expect(
      find.text('Welcome to the F&F Operations Console.'),
      findsOneWidget,
    );
  });

  testWidgets('placeholder routes render the branded coming-soon surface',
      (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    // Click into a route that is still deliberately placeholder-only.
    await tester.tap(find.byKey(const Key('admin_nav_item_corpus')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_placeholder_corpus')),
      findsOneWidget,
    );
    expect(
      find.text('Markdown corpus admin lands in 11A.3.'),
      findsOneWidget,
    );
    // Home card should no longer be in the tree.
    expect(find.byKey(const Key('admin_home_card')), findsNothing);
  });

  testWidgets('operators route renders the live admin surface (11A.1)',
      (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    await tester.tap(find.byKey(const Key('admin_nav_item_operators')));
    await tester.pumpAndSettle();

    // 11A.1 promoted operators from placeholder to live.
    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_placeholder_operators')), findsNothing);
  });

  testWidgets('header sign-out routes through the auth source', (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    expect(source.current, isA<AdminAuthAuthenticated>());

    await tester.tap(find.byKey(const Key('admin_header_signout')));
    await tester.pumpAndSettle();

    expect(source.current, isA<AdminAuthUnauthenticated>());
  });

  testWidgets('initialRouteId selects the requested route on first paint',
      (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(
        AdminShell(
          session: superAdmin,
          authSource: source,
          initialRouteId: 'corpus',
        ),
      ),
    );

    expect(
      find.byKey(const Key('admin_placeholder_corpus')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_home_card')), findsNothing);
  });
}
