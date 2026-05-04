// Phase 11A.0 — Admin shell widget tests.
//
// Verifies the brand-styled shell renders, the side nav surfaces
// every route from `kAdminRoutes`, the default route opens the live
// operator surface, and the header sign-out
// affordance routes through the auth source.

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

  testWidgets('renders branded header with role pill + identity chip', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    expect(find.byKey(const Key('admin_shell_scaffold')), findsOneWidget);
    expect(find.byKey(const Key('admin_header_bar')), findsOneWidget);
    expect(find.byKey(const Key('admin_header_role_pill')), findsOneWidget);
    expect(find.text('Platform admin'), findsOneWidget);
    expect(find.byKey(const Key('admin_header_identity')), findsOneWidget);
    expect(find.text(superAdmin.email), findsOneWidget);
    // Brand wordmark from AppTextStyles.display20.
    expect(find.text('Forge & Flow'), findsOneWidget);
    expect(find.text('Admin Console'), findsOneWidget);
  });

  testWidgets('side nav lists every route in kAdminRoutes', (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    expect(find.byKey(const Key('admin_side_nav')), findsOneWidget);
    expect(
      tester
          .getTopLeft(find.byKey(const Key('admin_nav_section_operations')))
          .dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('admin_nav_section_ai'))).dy,
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('admin_nav_section_ai'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('admin_nav_section_dev'))).dy,
      ),
    );
    expect(find.byKey(const Key('admin_nav_section_ai')), findsOneWidget);
    expect(find.byKey(const Key('admin_nav_section_badge_ai')), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('Work in progress'), findsOneWidget);
    expect(find.byKey(const Key('admin_nav_section_dev')), findsOneWidget);
    expect(find.text('Platform'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_nav_section_operations')),
      findsOneWidget,
    );
    expect(find.text('Operations'), findsOneWidget);

    expect(
      kAdminRoutes
          .where((route) => route.section == AdminRouteSection.ai)
          .map((route) => route.id),
      <String>[kAdminPricingRouteId, kAdminCorpusRouteId],
    );
    expect(
      kAdminRoutes
          .where((route) => route.section == AdminRouteSection.dev)
          .map((route) => route.id),
      <String>[
        kAdminIntegrationsRouteId,
        kAdminHealthRouteId,
        kAdminFeatureFlagsRouteId,
        kAdminDebugConsoleRouteId,
        kAdminObservabilityRouteId,
      ],
    );
    expect(
      kAdminRoutes
          .where((route) => route.section == AdminRouteSection.operations)
          .map((route) => route.id),
      <String>[kAdminOperatorsRouteId],
    );

    for (final route in kAdminRoutes) {
      expect(
        find.byKey(Key('admin_nav_item_${route.id}')),
        findsOneWidget,
        reason: 'side nav must surface ${route.id}',
      );
    }
  });

  testWidgets('default route renders the live operator surface', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    expect(find.byKey(const Key('admin_nav_item_home')), findsNothing);
    expect(find.text('Overview'), findsNothing);
    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('observability route renders the live metrics surface', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    await tester.ensureVisible(
      find.byKey(const Key('admin_nav_item_observability')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_nav_item_observability')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_observability_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_placeholder_observability')),
      findsNothing,
    );
    expect(find.byKey(const Key('admin_operators_screen')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('11A.5 promotes the debug route from placeholder to live', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    await tester.ensureVisible(find.byKey(const Key('admin_nav_item_debug')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_nav_item_debug')));
    await tester.pumpAndSettle();

    // The live debug console screen renders; the old placeholder is
    // gone.
    expect(find.byKey(const Key('admin_debug_console_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_placeholder_debug')), findsNothing);
    // Regression guard: pre-fix the embedded screen overflowed by
    // ~124 px at the normal shell viewport. The ListView refactor
    // + tightened header copy must keep the embed clean.
    expect(tester.takeException(), isNull);
  });

  testWidgets('operator support action opens logs with exact filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );
    await tester.pumpAndSettle();

    final logsButton = find.byKey(
      const Key(
        'admin_operator_support_logs_00000000-0000-4000-8000-000000000001',
      ),
    );
    await tester.ensureVisible(logsButton);
    await tester.pumpAndSettle();
    await tester.tap(logsButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_debug_console_screen')), findsOneWidget);
    expect(
      find.text('Operator: 00000000-0000-4000-8000-000000000001'),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'admin_debug_console_row_req-00000000-0000-4000-8000-000000000a01',
        ),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_operators_screen')), findsNothing);
  });

  testWidgets('operators route renders the live admin surface (11A.1)', (
    tester,
  ) async {
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

  testWidgets('initialRouteId selects the requested route on first paint', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(
        AdminShell(
          session: superAdmin,
          authSource: source,
          initialRouteId: 'observability',
        ),
      ),
    );

    expect(find.byKey(const Key('admin_observability_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_operators_screen')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
