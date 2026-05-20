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

// Bounded pump loop: replaces unbounded `tester.pumpAndSettle()` to avoid
// never-settling timer flake (the dominant flake shape in this repo per
// docs/KNOWN_FAILING_TESTS.md). 20 frames * 50ms == 1s of virtual time,
// which exceeds the longest legitimate animation/route transition in
// this screen's flow. If a future expectation needs more time, prefer a
// `pumpUntil(tester, () => find.X.evaluate().isNotEmpty)` polling form
// rather than widening this default.
Future<void> pumpEventually(
  WidgetTester tester, {
  int frames = 20,
  Duration step = const Duration(milliseconds: 50),
}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

// Polling form: pumps until [condition] returns true, or fails loudly
// with the exhausted-time budget once [maxIterations] is reached. Use
// this when the test asserts a specific condition right after the
// settle (e.g. a dialog has mounted, a snackbar has rendered).
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 50),
  int maxIterations = 60,
}) async {
  for (int i = 0; i < maxIterations; i++) {
    if (condition()) return;
    await tester.pump(step);
  }
  expect(
    condition(),
    isTrue,
    reason:
        'pumpUntil exhausted ${maxIterations * step.inMilliseconds}ms '
        'budget waiting for condition.',
  );
}

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

  testWidgets('share preview mode shows demo-data pill and hides sign out', (
    tester,
  ) async {
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

    expect(
      find.byKey(const Key('admin_header_share_preview_pill')),
      findsOneWidget,
    );
    expect(find.text('Demo data'), findsOneWidget);
    expect(find.byKey(const Key('admin_header_signout')), findsNothing);
    expect(find.text('Support access'), findsOneWidget);
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
}
