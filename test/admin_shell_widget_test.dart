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
    expect(find.text('Ecosystem admin'), findsOneWidget);
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
        tester
            .getTopLeft(
              find.byKey(const Key('admin_nav_section_systemMonitoring')),
            )
            .dy,
      ),
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(const Key('admin_nav_section_systemMonitoring')),
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('admin_nav_section_serviceSetup')))
            .dy,
      ),
    );
    expect(find.byKey(const Key('admin_nav_section_ai')), findsOneWidget);
    expect(find.byKey(const Key('admin_nav_section_badge_ai')), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('Work in progress'), findsWidgets);
    expect(
      find.byKey(const Key('admin_nav_section_systemMonitoring')),
      findsOneWidget,
    );
    expect(find.text('System monitoring'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_nav_section_serviceSetup')),
      findsOneWidget,
    );
    expect(find.text('Service setup'), findsOneWidget);
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
          .where((route) => route.section == AdminRouteSection.systemMonitoring)
          .map((route) => route.id),
      <String>[
        kAdminHealthRouteId,
        kAdminDebugConsoleRouteId,
        kAdminObservabilityRouteId,
      ],
    );
    expect(
      kAdminRoutes
          .where((route) => route.section == AdminRouteSection.serviceSetup)
          .map((route) => route.id),
      <String>[kAdminIntegrationsRouteId, kAdminFeatureFlagsRouteId],
    );
    expect(
      kAdminRoutes
          .where((route) => route.section == AdminRouteSection.operations)
          .map((route) => route.id),
      <String>[
        kAdminOperatorsRouteId,
        kAdminSupportOperatorViewRouteId,
        kAdminDataAccuracyRouteId,
        kAdminPollingPricingRouteId,
        kAdminMembersRouteId,
        kAdminRolesHierarchySessionsRouteId,
        kAdminAuditedSupportActionsRouteId,
      ],
    );

    for (final route in kAdminRoutes) {
      expect(
        find.byKey(Key('admin_nav_item_${route.id}')),
        findsOneWidget,
        reason: 'side nav must surface ${route.id}',
      );
    }
  });

  testWidgets('compact nav keeps narrow admin pages readable', (tester) async {
    tester.view.physicalSize = const Size(390, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(
        AdminShell(
          session: superAdmin,
          authSource: source,
          initialRouteId: kAdminSupportOperatorViewRouteId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_side_nav')), findsNothing);
    expect(find.byKey(const Key('admin_compact_nav')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_nav_item_support-operator-view')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_support_operator_view_no_scope_state')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(
            find.byKey(const Key('admin_support_operator_view_no_scope_state')),
          )
          .width,
      greaterThan(320),
    );
    expect(tester.takeException(), isNull);
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

  testWidgets(
    'operator-scoped routes wait inline instead of auto-opening the picker',
    (tester) async {
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          AdminShell(
            session: superAdmin,
            authSource: source,
            initialRouteId: kAdminMembersRouteId,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_members_no_operator_state')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsNothing,
      );
      expect(find.text('Choose an operator'), findsOneWidget);
      expect(find.text('Choose operator'), findsOneWidget);
    },
  );

  testWidgets('support workspace waits inline until a business is chosen', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(
        AdminShell(
          session: superAdmin,
          authSource: source,
          initialRouteId: kAdminSupportOperatorViewRouteId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_support_operator_view_no_scope_state')),
      findsOneWidget,
    );
    expect(find.text('Choose a business'), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_picker_screen')), findsNothing);
  });

  testWidgets(
    'Operations routes reuse selected operator context across Team, Access, and Audit',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
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

      await tester.ensureVisible(
        find.byKey(const Key('admin_nav_item_members')),
      );
      await tester.tap(find.byKey(const Key('admin_nav_item_members')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin_members_screen')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsNothing,
      );

      await tester.ensureVisible(
        find.byKey(const Key('admin_nav_item_roles-hierarchy-sessions')),
      );
      await tester.tap(
        find.byKey(const Key('admin_nav_item_roles-hierarchy-sessions')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_roles_hierarchy_sessions_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsNothing,
      );

      await tester.ensureVisible(
        find.byKey(const Key('admin_nav_item_audited-support-actions')),
      );
      await tester.tap(
        find.byKey(const Key('admin_nav_item_audited-support-actions')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_audited_support_actions_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Business accounts opens the scoped support workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1100);
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

    final supportViewButton = find.byKey(
      const Key(
        'admin_operator_support_view_00000000-0000-4000-8000-000000000001',
      ),
    );
    await tester.ensureVisible(supportViewButton);
    await tester.pumpAndSettle();
    await tester.tap(supportViewButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_support_operator_view_screen')),
      findsOneWidget,
    );
    expect(find.text('Support workspace'), findsWidgets);
    expect(find.text('Demo Diner Co.'), findsWidgets);
    expect(find.text('Toronto Yorkville'), findsWidgets);
    expect(
      find.byKey(const Key('admin_support_operator_view_no_scope_state')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('operator action buttons keep the same scope for Team', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1100);
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

    final dataAccuracyButton = find.byKey(
      const Key(
        'admin_operator_data_accuracy_00000000-0000-4000-8000-000000000001',
      ),
    );
    await tester.ensureVisible(dataAccuracyButton);
    await tester.pumpAndSettle();
    await tester.tap(dataAccuracyButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_data_accuracy_screen')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('admin_nav_item_members')));
    await tester.tap(find.byKey(const Key('admin_nav_item_members')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_members_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_members_no_operator_state')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
