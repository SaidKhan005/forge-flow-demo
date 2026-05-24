// Phase 11A.0 — Admin shell widget tests.
//
// Verifies the brand-styled shell renders, the side nav surfaces
// primary routes from `kAdminRoutes`, the default route opens the live
// operator surface, and the header sign-out
// affordance routes through the auth source.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/admin_shell.dart';
import 'package:forge_and_flow/admin/widgets/admin_business_accounts_back_button.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '_test_helpers/widget_pump_helpers.dart';

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

  Future<void> chooseScopePrompt(
    WidgetTester tester, {
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
  }) async {
    if (find
        .byKey(const Key('admin_hierarchy_scope_prompt'))
        .evaluate()
        .isEmpty) {
      return;
    }
    final cacheKey =
        '$operatorId|$scopeType|${orgUnitId ?? ''}|${locationId ?? ''}';
    final option = find.byKey(Key('admin_hierarchy_scope_option_$cacheKey'));
    await tester.ensureVisible(option);
    await pumpEventually(tester);
    await tester.tap(option);
    await pumpEventually(tester);
  }

  Future<void> chooseWorkspaceBusinessScope(
    WidgetTester tester, {
    required String operatorId,
    String? functionTabLabel,
  }) async {
    final option = find.byKey(Key('admin_setup_scope_business_$operatorId'));
    await tester.ensureVisible(option);
    await pumpEventually(tester);
    await tester.tap(option);
    await pumpEventually(tester);
    if (functionTabLabel != null &&
        find
            .byKey(const Key('admin_setup_workspace_tabs'))
            .evaluate()
            .isNotEmpty) {
      await tester.tap(find.widgetWithText(Tab, functionTabLabel));
      await pumpEventually(tester);
    }
  }

  Future<void> openSetupTileAndReturn(
    WidgetTester tester, {
    required Key tileKey,
    required Key screenKey,
    String scopeType = 'business',
    String? orgUnitId,
    String? locationId,
  }) async {
    final tile = find.byKey(tileKey);
    await tester.ensureVisible(tile);
    await pumpEventually(tester);
    await tester.tap(tile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: '00000000-0000-4000-8000-000000000001',
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: locationId,
    );

    expect(find.byKey(screenKey), findsOneWidget);
    expect(find.byKey(kAdminBusinessAccountsBackButtonKey), findsOneWidget);
    await tester.tap(find.byKey(kAdminBusinessAccountsBackButtonKey));
    await pumpEventually(tester);
    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(find.byKey(screenKey), findsNothing);
  }

  testWidgets('renders branded header with identity (no role/demo badges)', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    expect(find.byKey(const Key('admin_shell_scaffold')), findsOneWidget);
    expect(find.byKey(const Key('admin_header_bar')), findsOneWidget);
    // Badge clutter removed from the bar: no role pill, no demo-data pill.
    expect(find.byKey(const Key('admin_header_role_pill')), findsNothing);
    expect(find.text('Ecosystem admin'), findsNothing);
    expect(
      find.byKey(const Key('admin_header_share_preview_pill')),
      findsNothing,
    );
    // Username + sign out remain.
    expect(find.byKey(const Key('admin_header_identity')), findsOneWidget);
    expect(find.text(superAdmin.email), findsOneWidget);
    expect(find.byKey(const Key('admin_header_signout')), findsOneWidget);
    // Brand wordmark from AppTextStyles.display20.
    expect(find.text('Forge & Flow'), findsOneWidget);
    expect(find.text('Admin Console'), findsOneWidget);
  });

  testWidgets('side nav lists primary routes and hides setup-only routes', (
    tester,
  ) async {
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
      <String>[
        kAdminPricingRouteId,
        kAdminCorpusRouteId,
        kAdminObservabilityRouteId,
      ],
    );
    expect(
      kAdminRoutes
          .where((route) => route.section == AdminRouteSection.systemMonitoring)
          .map((route) => route.id),
      <String>[kAdminHealthRouteId, kAdminDebugConsoleRouteId],
    );
    expect(
      kAdminRoutes
          .where((route) => route.section == AdminRouteSection.serviceSetup)
          .map((route) => route.id),
      <String>[
        kAdminIntegrationsRouteId,
        kAdminFeatureFlagsRouteId,
        // Lane B B2.2 — Default Role catalog admin editor added to
        // the Service setup section as a F&F-admin-only surface.
        kAdminDefaultRoleCatalogRouteId,
      ],
    );
    expect(
      kAdminRoutes
          .where((route) => route.section == AdminRouteSection.operations)
          .where((route) => route.visibleInNav)
          .map((route) => route.id),
      // Re-pinned 2026-05-20: the operations section now surfaces both
      // `operators` (lib/admin/admin_routes.dart:311) and
      // `vendor-applicability` (lib/admin/admin_routes.dart:435) as
      // visible primary nav rows; the latter was added post-test.
      <String>[kAdminOperatorsRouteId, kAdminVendorApplicabilityRouteId],
    );

    final hiddenSetupRoutes = <String>{
      kAdminDataAccuracyRouteId,
      kAdminPollingPricingRouteId,
      kAdminMembersRouteId,
      kAdminRolesHierarchySessionsRouteId,
      kAdminAuditedSupportActionsRouteId,
    };
    for (final route in kAdminRoutes.where((route) => route.visibleInNav)) {
      expect(
        find.byKey(Key('admin_nav_item_${route.id}')),
        findsOneWidget,
        reason: 'side nav must surface primary route ${route.id}',
      );
    }
    for (final routeId in hiddenSetupRoutes) {
      expect(
        find.byKey(Key('admin_nav_item_$routeId')),
        findsNothing,
        reason: '$routeId is reached through Business setup, not side nav',
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
          initialRouteId: kAdminOperatorsRouteId,
        ),
      ),
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_side_nav')), findsNothing);
    expect(find.byKey(const Key('admin_compact_nav')), findsOneWidget);
    expect(find.byKey(const Key('admin_nav_item_operators')), findsOneWidget);
    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('admin_operators_screen'))).width,
      greaterThan(320),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('share preview mode hides sign out and bar badges, keeps demo '
      'banner', (tester) async {
    final source = DemoAdminAuthSource.signedInAsSupport();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(
        AdminShell(
          session: const AdminAuthSession(
            uid: 'demo-ff-support',
            email: 'support@forgeflow.test',
            displayName: 'Demo F&F Support',
            roles: <String>['ff_support'],
          ),
          authSource: source,
          sharePreviewMode: true,
        ),
      ),
    );
    await pumpEventually(tester);

    // The in-bar demo-data pill and role pill were removed as clutter; the
    // full-width demo banner under the header still carries demo state.
    expect(
      find.byKey(const Key('admin_header_share_preview_pill')),
      findsNothing,
    );
    expect(find.byKey(const Key('admin_header_role_pill')), findsNothing);
    expect(find.text('Support access'), findsNothing);
    expect(find.byKey(const Key('admin_demo_banner')), findsOneWidget);
    // Share-preview is read-only: sign out is hidden; identity still shows.
    expect(find.byKey(const Key('admin_header_signout')), findsNothing);
    expect(find.byKey(const Key('admin_header_identity')), findsOneWidget);
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

  testWidgets(
    'observability route uses workspace before live metrics surface',
    (tester) async {
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(AdminShell(session: superAdmin, authSource: source)),
      );

      await tester.ensureVisible(
        find.byKey(const Key('admin_nav_item_observability')),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_nav_item_observability')));
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_setup_workspace_scope_pane')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_observability_screen')), findsNothing);

      await chooseWorkspaceBusinessScope(
        tester,
        operatorId: '00000000-0000-4000-8000-000000000001',
        functionTabLabel: 'AI Metrics',
      );

      expect(
        find.byKey(const Key('admin_observability_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_placeholder_observability')),
        findsNothing,
      );
      expect(find.byKey(const Key('admin_operators_screen')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in <({String routeId, String title, Key screenKey})>[
    (
      routeId: kAdminPricingRouteId,
      title: 'Plans and limits',
      screenKey: Key('admin_pricing_screen'),
    ),
    (
      routeId: kAdminCorpusRouteId,
      title: 'Knowledge Base',
      screenKey: Key('admin_corpus_screen'),
    ),
    (
      routeId: kAdminIntegrationsRouteId,
      title: 'Connected services',
      screenKey: Key('admin_integrations_screen'),
    ),
    (
      routeId: kAdminHealthRouteId,
      title: 'System health',
      screenKey: Key('admin_health_screen'),
    ),
    (
      routeId: kAdminObservabilityRouteId,
      title: 'AI Metrics',
      screenKey: Key('admin_observability_screen'),
    ),
    (
      routeId: kAdminFeatureFlagsRouteId,
      title: 'Launch controls',
      screenKey: Key('admin_feature_flags_screen'),
    ),
  ]) {
    testWidgets('${scenario.title} uses the shared hierarchy workspace', (
      tester,
    ) async {
      // Desktop admin window. The shell header is 96px (UX-parity Slice
      // B) so the body needs a realistic height for the taller-content
      // workspace panes (Knowledge Base / Connected services).
      tester.view.physicalSize = const Size(1280, 900);
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
            initialRouteId: scenario.routeId,
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_setup_workspace_scope_pane')),
        findsOneWidget,
      );
      expect(find.text(scenario.title), findsWidgets);
      expect(find.byKey(scenario.screenKey), findsNothing);

      await chooseWorkspaceBusinessScope(
        tester,
        operatorId: '00000000-0000-4000-8000-000000000001',
        functionTabLabel: scenario.title,
      );

      expect(find.byKey(scenario.screenKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('11A.5 promotes the debug route from placeholder to live', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(AdminShell(session: superAdmin, authSource: source)),
    );

    await tester.ensureVisible(find.byKey(const Key('admin_nav_item_debug')));
    await pumpEventually(tester);
    await tester.tap(find.byKey(const Key('admin_nav_item_debug')));
    await pumpEventually(tester);

    // The live Support logs route now starts in the shared hierarchy
    // workspace. The request table appears after a scope is selected.
    expect(
      find.byKey(const Key('admin_setup_workspace_scope_pane')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_placeholder_debug')), findsNothing);
    // Regression guard: pre-fix the embedded screen overflowed by
    // ~124 px at the normal shell viewport. The ListView refactor
    // + tightened header copy must keep the embed clean.
    expect(tester.takeException(), isNull);
  });

  testWidgets('operator support action opens logs with exact filters', (
    tester,
  ) async {
    // Taller window so the 96px shell header (UX-parity Slice B) does
    // not push the asserted debug-console row out of the lazy list's
    // built range.
    tester.view.physicalSize = const Size(1440, 1200);
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
    await pumpEventually(tester);

    final logsTile = find.byKey(
      const Key('admin_business_setup_tile_support_logs'),
    );
    await tester.ensureVisible(logsTile);
    await pumpEventually(tester);
    await tester.tap(logsTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: '00000000-0000-4000-8000-000000000001',
      scopeType: 'business',
    );

    expect(find.byKey(const Key('admin_debug_console_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_debug_console_scope_label')),
      findsOneWidget,
    );
    expect(find.textContaining('Business:'), findsWidgets);
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
    await pumpEventually(tester);

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
    await pumpEventually(tester);

    expect(source.current, isA<AdminAuthUnauthenticated>());
  });

  testWidgets('initialRouteId opens the requested workspace on first paint', (
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
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_setup_workspace_scope_pane')),
      findsOneWidget,
    );
    expect(find.text('AI Metrics'), findsWidgets);
    expect(find.byKey(const Key('admin_observability_screen')), findsNothing);

    await chooseWorkspaceBusinessScope(
      tester,
      operatorId: '00000000-0000-4000-8000-000000000001',
      functionTabLabel: 'AI Metrics',
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
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_setup_workspace_scope_pane')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsNothing,
      );
      expect(find.text('Scope'), findsWidgets);
      expect(
        find.text('Choose a business, org unit, or location.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Support Workspace is hidden from primary route IA', (
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
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_nav_item_support-operator-view')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_support_operator_view_no_scope_state')),
      findsOneWidget,
    );
  });

  testWidgets(
    'Setup tiles open hidden Operations routes without old side-nav entries',
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
      await pumpEventually(tester);

      expect(find.byKey(const Key('admin_nav_item_members')), findsNothing);
      expect(
        find.byKey(const Key('admin_nav_item_roles-hierarchy-sessions')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_nav_item_audited-support-actions')),
        findsNothing,
      );

      final peopleTile = find.byKey(
        const Key('admin_business_setup_tile_people_access_roles'),
      );
      await tester.ensureVisible(peopleTile);
      await tester.tap(peopleTile);
      await pumpEventually(tester);
      await chooseScopePrompt(
        tester,
        operatorId: '00000000-0000-4000-8000-000000000001',
        scopeType: 'business',
      );

      expect(find.byKey(const Key('admin_members_screen')), findsOneWidget);
      expect(find.text('People, access, and roles'), findsWidgets);
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('admin_members_open_access')));
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_roles_hierarchy_sessions_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('admin_nav_item_operators')));
      await pumpEventually(tester);

      final securityTile = find.byKey(
        const Key('admin_business_setup_tile_security_audit_sessions'),
      );
      await tester.ensureVisible(securityTile);
      await tester.tap(securityTile);
      await pumpEventually(tester);
      await chooseScopePrompt(
        tester,
        operatorId: '00000000-0000-4000-8000-000000000001',
        scopeType: 'business',
      );

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

  testWidgets('Business accounts opens scoped support logs from setup tile', (
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
    await pumpEventually(tester);

    final supportLogsTile = find.byKey(
      const Key('admin_business_setup_tile_support_logs'),
    );
    await tester.ensureVisible(supportLogsTile);
    await pumpEventually(tester);
    await tester.tap(supportLogsTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: '00000000-0000-4000-8000-000000000001',
      scopeType: 'business',
    );

    expect(find.byKey(const Key('admin_debug_console_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_debug_console_scope_label')),
      findsOneWidget,
    );
    expect(find.textContaining('Business:'), findsWidgets);
    expect(
      find.byKey(const Key('admin_support_operator_view_no_scope_state')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Business setup screens route back to Business accounts', (
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
    await pumpEventually(tester);

    await openSetupTileAndReturn(
      tester,
      tileKey: const Key('admin_business_setup_tile_data_accuracy'),
      screenKey: const Key('admin_data_accuracy_screen'),
    );
    await openSetupTileAndReturn(
      tester,
      tileKey: const Key('admin_business_setup_tile_polling_pricing'),
      screenKey: const Key('admin_polling_pricing_screen'),
    );
    await openSetupTileAndReturn(
      tester,
      tileKey: const Key('admin_business_setup_tile_people_access_roles'),
      screenKey: const Key('admin_members_screen'),
    );
    await openSetupTileAndReturn(
      tester,
      tileKey: const Key('admin_business_setup_tile_security_audit_sessions'),
      screenKey: const Key('admin_audited_support_actions_screen'),
    );
    await openSetupTileAndReturn(
      tester,
      tileKey: const Key('admin_business_setup_tile_support_logs'),
      screenKey: const Key('admin_debug_console_screen'),
    );
  });

  testWidgets('Team access setup screen routes back to Business accounts', (
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
    await pumpEventually(tester);

    final peopleTile = find.byKey(
      const Key('admin_business_setup_tile_people_access_roles'),
    );
    await tester.ensureVisible(peopleTile);
    await pumpEventually(tester);
    await tester.tap(peopleTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: '00000000-0000-4000-8000-000000000001',
      scopeType: 'business',
    );

    await tester.tap(find.byKey(const Key('admin_members_open_access')));
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_roles_hierarchy_sessions_screen')),
      findsOneWidget,
    );
    expect(find.byKey(kAdminBusinessAccountsBackButtonKey), findsOneWidget);
    await tester.tap(find.byKey(kAdminBusinessAccountsBackButtonKey));
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_roles_hierarchy_sessions_screen')),
      findsNothing,
    );
  });

  testWidgets('Integrations setup screen returns to Business accounts', (
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
    await pumpEventually(tester);

    final integrationsTile = find.byKey(
      const Key('admin_business_setup_tile_integrations'),
    );
    await tester.ensureVisible(integrationsTile);
    await pumpEventually(tester);
    await tester.tap(integrationsTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: '00000000-0000-4000-8000-000000000001',
      scopeType: 'location',
      orgUnitId: '00000000-0000-4000-8000-000000000d02',
      locationId: '00000000-0000-4000-8000-0000000000a1',
    );

    expect(
      find.byKey(const Key('admin_vendor_connections_screen')),
      findsOneWidget,
    );
    expect(find.byKey(kAdminBusinessAccountsBackButtonKey), findsOneWidget);
    await tester.tap(find.byKey(kAdminBusinessAccountsBackButtonKey));
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_vendor_connections_screen')),
      findsNothing,
    );
  });

  testWidgets('Business accounts opens People/access/roles with scope', (
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
    await pumpEventually(tester);

    final locationRow = find.byKey(
      const Key(
        'admin_hierarchy_location_00000000-0000-4000-8000-0000000000a1',
      ),
    );
    await tester.ensureVisible(locationRow);
    await pumpEventually(tester);
    await tester.tap(locationRow);
    await pumpEventually(tester);

    final peopleTile = find.byKey(
      const Key('admin_business_setup_tile_people_access_roles'),
    );
    await tester.ensureVisible(peopleTile);
    await pumpEventually(tester);
    await tester.tap(peopleTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: '00000000-0000-4000-8000-000000000001',
      scopeType: 'location',
      orgUnitId: '00000000-0000-4000-8000-000000000d02',
      locationId: '00000000-0000-4000-8000-0000000000a1',
    );

    expect(find.byKey(const Key('admin_members_screen')), findsOneWidget);
    expect(find.text('People, access, and roles'), findsWidgets);
    expect(find.byKey(const Key('admin_members_open_access')), findsOneWidget);
    await tester.tap(find.byKey(const Key('admin_members_open_access')));
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_roles_hierarchy_sessions_screen')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_rhs_no_operator_state')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // UX-parity Slice C — the scope-aware per-business nav cluster. These
  // exercise the SAME top-bar scope picker (Slice B) the production shell
  // uses; picking a business sets `_hierarchyScope`, which the cluster
  // gates on. The seeded demo business for operator `...001` is
  // "Demo Diner Co." (lib/admin/admin_routes.dart `_defaultDemoGateway`).
  Future<void> pickBusinessScopeFromTopBar(
    WidgetTester tester, {
    required String operatorId,
  }) async {
    await tester.tap(find.byKey(const Key('admin_scope_picker_trigger')));
    await pumpEventually(tester);
    final businessRow = find.byKey(
      Key('admin_scope_picker_business_$operatorId'),
    );
    await tester.ensureVisible(businessRow);
    await pumpEventually(tester);
    await tester.tap(businessRow);
    await pumpEventually(tester);
  }

  testWidgets(
    'per-business cluster renders headed by the business name with the six '
    'operator-named items once a scope is picked',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
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
      await pumpEventually(tester);

      // No scope yet: the cluster is absent and Business accounts remains
      // the only entry point.
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster')),
        findsNothing,
      );

      await pickBusinessScopeFromTopBar(
        tester,
        operatorId: '00000000-0000-4000-8000-000000000001',
      );

      // Cluster now present, headed by the selected business name.
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_business_name')),
        findsOneWidget,
      );
      expect(find.text('Demo Diner Co.'), findsWidgets);

      // All six per-business cluster rows render with operator vocabulary.
      for (final routeId in <String>[
        kAdminMembersRouteId,
        kAdminRolesHierarchySessionsRouteId,
        kAdminAuditedSupportActionsRouteId,
        kAdminVendorIntegrationsRouteId,
        kAdminDataAccuracyRouteId,
        kAdminTimingSetupRouteId,
      ]) {
        expect(
          find.byKey(Key('admin_nav_cluster_item_$routeId')),
          findsOneWidget,
          reason: 'cluster must surface per-business route $routeId',
        );
      }

      // Operator-web vocabulary (the renamed titles) is visible in the nav.
      expect(find.text('Team members'), findsWidgets);
      expect(find.text('Roles & permissions'), findsWidgets);
      expect(find.text('Audit log'), findsWidgets);
      expect(find.text('Data accuracy'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selecting a per-business cluster item navigates carrying the active '
    'scope',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
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
      await pumpEventually(tester);

      await pickBusinessScopeFromTopBar(
        tester,
        operatorId: '00000000-0000-4000-8000-000000000001',
      );

      // Tapping the Team members cluster row lands on the members screen
      // scoped to the picked business (no operator-picker detour, because
      // the cluster carries the active scope through `_selectIntent`).
      final teamRow = find.byKey(
        Key('admin_nav_cluster_item_$kAdminMembersRouteId'),
      );
      await tester.ensureVisible(teamRow);
      await pumpEventually(tester);
      await tester.tap(teamRow);
      await pumpEventually(tester);

      expect(find.byKey(const Key('admin_members_screen')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsNothing,
      );
      // The cluster row for the open destination is highlighted, and the
      // cluster stays visible (scope is still active).
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'per-business cluster renders inactive when no business is selected',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
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
      await pumpEventually(tester);

      // Operator-approved IA: with no scope the cluster is ALWAYS present,
      // but in its inactive form — the active (business-name) header is
      // absent and the "Pick a business first" hint stands in its place.
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_inactive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_header')),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('admin_nav_per_business_cluster_inactive_hint'),
        ),
        findsOneWidget,
      );
      expect(find.text('Pick a business first'), findsOneWidget);

      // All six per-business rows still render (so they are discoverable),
      // just inactive — they remain present even without a scope.
      for (final routeId in kAdminPerBusinessClusterRouteIds) {
        expect(
          find.byKey(Key('admin_nav_cluster_item_$routeId')),
          findsOneWidget,
          reason: 'inactive cluster row $routeId must still be present',
        );
      }
      expect(find.byKey(const Key('admin_nav_item_operators')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tapping an inactive cluster row routes to Business accounts without '
    'opening the per-business screen or auto-selecting a business',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
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
            // Start somewhere other than Business accounts so the tap has an
            // observable effect (the operators surface appears).
            initialRouteId: kAdminHealthRouteId,
          ),
        ),
      );
      await pumpEventually(tester);

      final teamRow = find.byKey(
        Key('admin_nav_cluster_item_$kAdminMembersRouteId'),
      );
      await tester.ensureVisible(teamRow);
      await pumpEventually(tester);
      await tester.tap(teamRow);
      await pumpEventually(tester);

      // Lands on Business accounts (the choose-a-business entry point), NOT
      // the Team members screen, and no business was auto-selected (cluster
      // stays inactive).
      expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
      expect(find.byKey(const Key('admin_members_screen')), findsNothing);
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_inactive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tapping the inactive cluster hint routes to Business accounts',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
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
            initialRouteId: kAdminHealthRouteId,
          ),
        ),
      );
      await pumpEventually(tester);

      final hint = find.byKey(
        const Key('admin_nav_per_business_cluster_inactive_hint'),
      );
      await tester.ensureVisible(hint);
      await pumpEventually(tester);
      await tester.tap(hint);
      await pumpEventually(tester);

      expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Business accounts is pinned as the first wide-nav entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
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
    await pumpEventually(tester);

    // The pinned Business accounts container is the topmost nav block:
    // above the per-business cluster and above every section panel.
    final pinnedTop = tester
        .getTopLeft(
          find.byKey(const Key('admin_nav_business_accounts_pinned')),
        )
        .dy;
    expect(
      pinnedTop,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('admin_nav_per_business_cluster_inactive')),
            )
            .dy,
      ),
    );
    expect(
      pinnedTop,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('admin_nav_section_panel_operations')),
            )
            .dy,
      ),
    );
    // Business accounts appears exactly once in the wide nav (pinned, not
    // duplicated inside the Operations section).
    expect(find.byKey(const Key('admin_nav_item_operators')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
