// Admin "Business accounts journey": one consolidated end-to-end
// acceptance guard.
//
// This file codifies the manual QA walkthrough of the recently-reworked
// admin Business-accounts surfaces into a single automated regression
// test. It mounts the FULL admin shell ([AdminConsoleApp]) as a
// super-admin with hermetic in-memory demo gateways (the same shape the
// production demo fallback wires: an operator gateway whose
// onLocationAdded / onLocationRemoved hooks keep the sibling hierarchy
// gateway in sync, which is the #1313 add/delete fix) and walks the
// operator journey, asserting each step.
//
// The journey, step by step:
//   1. On load (no scope chosen): the side nav pins "Business accounts"
//      first; the six per-business items are present but INACTIVE under
//      the "Pick a business first" hint; the Business accounts page shows
//      the shared scope tree + "New business" + a "Select a business"
//      empty prompt.
//   2. Picking a business in the scope tree activates the sidebar cluster
//      (header shows the business name, hint gone) AND loads the business
//      detail (contact email / location hierarchy).
//   3. Adding a location (the same dialog/gateway path the screen uses)
//      persists and the new row appears in the hierarchy tree.
//   4. Deleting that just-added location succeeds with NO 404 / error
//      snackbar and the row disappears (the #1313 regression guard).
//   5. Each of the six per-business cluster items, when active, navigates
//      to a screen that renders without throwing.
//   6. The scope tree / hierarchy detail render the canonical scope icons
//      (business = apartment, location = place, org unit = account_tree).
//
// Overlap with the focused unit tests (admin_operator_location_*,
// admin_shell_widget_test, scope_icons_test) is intentional: the value
// here is the SINGLE end-to-end guard that the whole journey holds
// together. Finders are key-first throughout (text finders proved
// brittle in a recent tab-rename incident).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/admin_business_accounts_back_button.dart';
import 'package:forge_and_flow/admin/widgets/admin_previous_screen_back_button.dart';
import 'package:forge_and_flow/admin/widgets/admin_scope_tree_pane.dart';

import '../_test_helpers/widget_pump_helpers.dart';

void main() {
  // The demo Diner business is the journey's subject. Org units: a corp
  // root with East + West regions; locations Toronto Yorkville (primary,
  // under East) and Vancouver Robson (under West). All ids mirror the
  // production demo seed so this test exercises the real shape.
  const dinerOperatorId = kDemoDinerOperatorId;
  const dinerLocationToronto = kDemoDinerLocationToronto;
  const dinerOrgUnitEast = kDemoDinerOrgUnitEast;

  // The six per-business cluster routes, in nav order, paired with a
  // robust anchor that proves the destination rendered. Vendor
  // integrations and Data Accuracy need a LOCATION scope to show their
  // operator surfaces; with a broader scope they honestly render their
  // location-required state, which is still a "renders without throwing"
  // outcome for this broad journey test.
  const sixClusterDestinations = <({String routeId, Key anchorKey})>[
    (routeId: kAdminMembersRouteId, anchorKey: Key('admin_members_screen')),
    (
      routeId: kAdminRolesHierarchySessionsRouteId,
      anchorKey: Key('admin_roles_hierarchy_sessions_screen'),
    ),
    (
      routeId: kAdminAuditedSupportActionsRouteId,
      anchorKey: Key('admin_audited_support_actions_screen'),
    ),
    (
      routeId: kAdminVendorIntegrationsRouteId,
      anchorKey: Key('admin_vendor_connections_location_required'),
    ),
    (
      routeId: kAdminDataAccuracyRouteId,
      anchorKey: Key('admin_data_accuracy_waiting_for_location_scope'),
    ),
    (
      routeId: kAdminTimingSetupRouteId,
      anchorKey: Key('admin_timing_setup_screen'),
    ),
  ];

  /// Hermetic demo gateways for one mount. Mirrors the production demo
  /// fallback wiring (`admin_routes_demo_gateways_part.dart`): the
  /// operator gateway mints a non-colliding id for an added location AND
  /// registers / unregisters it on the sibling hierarchy gateway through
  /// the onLocationAdded / onLocationRemoved hooks. That keep-in-sync
  /// wiring is exactly the #1313 add/delete fix, so the journey deletes a
  /// freshly-added location through the hierarchy gateway without 404ing.
  ({
    OperatorLocationAdminGateway operatorGateway,
    InMemoryRolesHierarchySessionsAdminGateway hierarchyGateway,
  })
  buildDemoGateways() {
    late final InMemoryRolesHierarchySessionsAdminGateway hierarchyGateway;
    var addedLocationCounter = 0;
    final operatorGateway = InMemoryOperatorLocationAdminGateway(
      idGenerator: () {
        addedLocationCounter += 1;
        final hex = addedLocationCounter.toRadixString(16).padLeft(2, '0');
        // `c`-prefixed tail can never collide with a seeded operator
        // (`...001`) or location (`...a1` / `...a2`) id.
        return '00000000-0000-4000-8000-0000000000c$hex';
      },
      onLocationAdded: (location) {
        final orgUnitId = location.parentOrgUnitId;
        if (orgUnitId == null || orgUnitId.trim().isEmpty) return;
        hierarchyGateway.registerDemoLocation(
          operatorId: location.operatorId,
          locationId: location.locationId,
          name: location.name,
          orgUnitId: orgUnitId.trim(),
        );
      },
      onLocationRemoved: ({required operatorId, required locationId}) {
        hierarchyGateway.removeDemoLocation(
          operatorId: operatorId,
          locationId: locationId,
        );
      },
      seed: <OperatorAdminBundle>[
        OperatorAdminBundle(
          operator: OperatorAdminRecord(
            operatorId: dinerOperatorId,
            businessName: 'Demo Diner Co.',
            ownerEmail: 'owner@demo-diner.test',
            subscriptionTier: 'pro',
            preferredCurrency: 'CAD',
            primaryLocationId: dinerLocationToronto,
            suspendedAt: null,
            createdAt: DateTime.utc(2026, 1, 12, 14, 30),
            updatedAt: DateTime.utc(2026, 4, 1, 10, 0),
          ),
          locations: <LocationAdminRecord>[
            LocationAdminRecord(
              locationId: dinerLocationToronto,
              operatorId: dinerOperatorId,
              parentOrgUnitId: dinerOrgUnitEast,
              name: 'Toronto Yorkville',
              address: '123 Main St, Toronto, ON',
              timezone: 'America/Toronto',
              businessDayRolloverHour: 4,
              createdAt: DateTime.utc(2026, 1, 12, 14, 30),
              updatedAt: DateTime.utc(2026, 1, 12, 14, 30),
            ),
            LocationAdminRecord(
              locationId: kDemoDinerLocationVancouver,
              operatorId: dinerOperatorId,
              parentOrgUnitId: kDemoDinerOrgUnitWest,
              name: 'Vancouver Robson',
              address: '456 Robson St, Vancouver, BC',
              timezone: 'America/Vancouver',
              businessDayRolloverHour: 4,
              createdAt: DateTime.utc(2026, 2, 1, 9, 0),
              updatedAt: DateTime.utc(2026, 2, 1, 9, 0),
            ),
          ],
        ),
      ],
    );
    hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      locationsByOperator: kDemoHierarchyLocationsByOperator(),
    );
    return (
      operatorGateway: operatorGateway,
      hierarchyGateway: hierarchyGateway,
    );
  }

  /// Mounts the full admin console (auth gate + shell + routes) as a
  /// signed-in super admin, with the hermetic demo gateways injected via
  /// [AdminConsoleServicesScope]. Returns the operator gateway so the
  /// test can read the minted id of a location it adds.
  Future<OperatorLocationAdminGateway> pumpAdminConsole(
    WidgetTester tester,
  ) async {
    // Wide desktop admin window so BOTH the side nav and the Business
    // accounts split layout (scope pane + detail, >= 920px) render at
    // once instead of the compact 2-tab fallback.
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateways = buildDemoGateways();
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      AdminConsoleServicesScope(
        operatorLocationGateway: gateways.operatorGateway,
        rolesHierarchySessionsAdminGateway: gateways.hierarchyGateway,
        adminAuthSource: source,
        child: AdminConsoleApp(authSource: source),
      ),
    );
    await pumpEventually(tester);
    return gateways.operatorGateway;
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await pumpEventually(tester);
    await tester.tap(finder);
    await pumpEventually(tester);
  }

  Future<void> tapLocationOverflowAction(
    WidgetTester tester,
    String locationId,
    Key actionKey,
  ) async {
    await tapKey(tester, Key('admin_location_more_$locationId'));
    await tapKey(tester, actionKey);
  }

  /// Asserts the single canonical glyph for [scopeRowKey], routed through
  /// the shared `scopeIcon` helper, is present somewhere in that row.
  void expectScopeIcon(WidgetTester tester, Key scopeRowKey, IconData icon) {
    expect(
      find.descendant(of: find.byKey(scopeRowKey), matching: find.byIcon(icon)),
      findsOneWidget,
      reason: '$scopeRowKey must render the canonical scope glyph $icon',
    );
  }

  testWidgets(
    'super admin walks the Business accounts journey end to end: inactive '
    'cluster -> pick business -> add + delete location -> open all six '
    'per-business screens, canonical icons throughout',
    (tester) async {
      final operatorGateway = await pumpAdminConsole(tester);

      // ---------------------------------------------------------------
      // STEP 1: On load (no scope chosen).
      // ---------------------------------------------------------------
      // The shell opens on Business accounts (its default route).
      expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);

      // Side nav: Business accounts is pinned at the very top, above the
      // per-business cluster.
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
                find.byKey(
                  const Key('admin_nav_per_business_cluster_inactive'),
                ),
              )
              .dy,
        ),
        reason: 'Business accounts must pin above the per-business cluster',
      );
      expect(find.byKey(const Key('admin_nav_item_operators')), findsOneWidget);

      // The cluster is present but INACTIVE: the "Pick a business first"
      // hint stands in for the active business-name header, and the
      // active cluster (with a header) is absent.
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_inactive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_inactive_hint')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_header')),
        findsNothing,
      );

      // All six per-business items are present (discoverable) but inactive.
      for (final destination in sixClusterDestinations) {
        expect(
          find.byKey(Key('admin_nav_cluster_item_${destination.routeId}')),
          findsOneWidget,
          reason: 'inactive cluster row ${destination.routeId} must be present',
        );
      }

      // The Business accounts page itself: shared scope tree on the left,
      // "New business" reachable, and a "Select a business" empty prompt
      // (no profile card) on the right before any node is picked.
      expect(
        find.byKey(const Key('admin_setup_workspace_scope_pane')),
        findsOneWidget,
      );
      expect(find.byType(AdminScopeTreePane), findsOneWidget);
      expect(
        find.byKey(Key('admin_setup_scope_business_$dinerOperatorId')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operators_new_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operators_detail_empty')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      // ---------------------------------------------------------------
      // STEP 2: Picking the business activates the cluster AND loads the
      // detail.
      // ---------------------------------------------------------------
      await tapKey(tester, Key('admin_setup_scope_business_$dinerOperatorId'));

      // Sidebar cluster is now ACTIVE: headed by the business name, the
      // "Pick a business first" hint is gone.
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_header')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_business_name')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_inactive')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_nav_per_business_cluster_inactive_hint')),
        findsNothing,
      );

      // The right detail pane now shows the business profile + location
      // hierarchy (contact email + the location hierarchy panel), and the
      // empty prompt is gone.
      expect(
        find.byKey(const Key('admin_operators_detail_empty')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_business_hierarchy_panel')),
        findsOneWidget,
      );
      expect(find.text('owner@demo-diner.test'), findsWidgets);
      expect(tester.takeException(), isNull);

      // ---------------------------------------------------------------
      // STEP 6 (icons): canonical scope glyphs in the scope tree AND the
      // detail hierarchy. Asserted here while every row is on screen.
      // ---------------------------------------------------------------
      // Picking the business auto-expanded its subtree in the left scope
      // tree, so the org-unit + location rows are present.
      expectScopeIcon(
        tester,
        Key('admin_setup_scope_business_$dinerOperatorId'),
        Icons.apartment_outlined,
      );
      expectScopeIcon(
        tester,
        Key('admin_setup_scope_org_unit_$dinerOrgUnitEast'),
        Icons.account_tree_outlined,
      );
      expectScopeIcon(
        tester,
        Key('admin_setup_scope_location_$dinerLocationToronto'),
        Icons.place_outlined,
      );
      // Right detail hierarchy: the business scope row + the seeded
      // location row carry the same canonical glyphs.
      expectScopeIcon(
        tester,
        const Key('admin_hierarchy_business_scope_row'),
        Icons.apartment_outlined,
      );
      expectScopeIcon(
        tester,
        Key('admin_hierarchy_location_$dinerLocationToronto'),
        Icons.place_outlined,
      );

      // ---------------------------------------------------------------
      // STEP 3: Add a location. Adding requires a selected org-unit scope
      // (the add button is disabled otherwise), so pick the East region in
      // the detail hierarchy first, then add through the same dialog the
      // screen uses.
      // ---------------------------------------------------------------
      await tapKey(tester, Key('admin_hierarchy_org_unit_$dinerOrgUnitEast'));

      // With an org unit selected the add-location button is enabled.
      final addButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('admin_operator_add_location_button')),
      );
      expect(
        addButton.onPressed,
        isNotNull,
        reason: 'selecting an org unit must enable Add location',
      );

      await tapKey(tester, const Key('admin_operator_add_location_button'));
      expect(
        find.byKey(const Key('admin_location_add_dialog')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('admin_location_name_field')),
        'Markham Unionville',
      );
      // Choose an IANA timezone through the picker.
      await tapKey(tester, const Key('admin_location_timezone_field'));
      await tester.enterText(
        find.byKey(const Key('admin_timezone_search_field')),
        'America/Toronto',
      );
      await pumpEventually(tester);
      await tapKey(
        tester,
        const Key('admin_timezone_option_text_America/Toronto'),
      );
      await tapKey(tester, const Key('admin_location_submit_button'));

      // Dialog closed and the location persisted on the operator gateway.
      expect(find.byKey(const Key('admin_location_add_dialog')), findsNothing);
      final afterAdd = await operatorGateway.listOperators();
      final addedLocation = afterAdd.single.locations.firstWhere(
        (location) => location.name == 'Markham Unionville',
      );
      expect(addedLocation.parentOrgUnitId, equals(dinerOrgUnitEast));

      // The new row appears in the detail hierarchy tree immediately.
      final addedRowKey = Key(
        'admin_hierarchy_location_${addedLocation.locationId}',
      );
      await tester.ensureVisible(find.byKey(addedRowKey));
      await pumpEventually(tester);
      expect(
        find.byKey(addedRowKey),
        findsOneWidget,
        reason: 'the added location must render in the hierarchy tree',
      );
      expect(tester.takeException(), isNull);

      // ---------------------------------------------------------------
      // STEP 4: Delete the just-added location: NO 404 / error snackbar,
      // and the row disappears. This is the #1313 regression guard (the
      // operator-gateway add registered the location on the hierarchy
      // gateway, so the hierarchy delete resolves instead of 404ing).
      // ---------------------------------------------------------------
      await tapKey(tester, addedRowKey);
      await tapLocationOverflowAction(
        tester,
        addedLocation.locationId,
        Key('admin_location_remove_${addedLocation.locationId}'),
      );

      // The delete asks for an admin reason (audited hierarchy delete).
      expect(
        find.byKey(const Key('admin_hierarchy_location_delete_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_location_delete_reason')),
        'added in error during walkthrough',
      );
      await tapKey(tester, const Key('admin_hierarchy_location_delete_submit'));

      // No 404 / failure snackbar (the #1313 symptom was an error snack).
      expect(
        find.textContaining('Could not delete location'),
        findsNothing,
        reason: 'deleting an added location must not 404 (the #1313 fix)',
      );
      expect(find.textContaining('unknown_location'), findsNothing);
      // The row is gone from the tree.
      expect(
        find.byKey(addedRowKey),
        findsNothing,
        reason: 'the deleted location row must disappear',
      );
      expect(tester.takeException(), isNull);

      // ---------------------------------------------------------------
      // STEP 5: Each of the six active per-business cluster items
      // navigates to a screen that renders without throwing.
      // ---------------------------------------------------------------
      for (final destination in sixClusterDestinations) {
        await tapKey(
          tester,
          Key('admin_nav_cluster_item_${destination.routeId}'),
        );
        expect(
          find.byKey(destination.anchorKey),
          findsOneWidget,
          reason:
              'cluster item ${destination.routeId} must open a rendered '
              'screen (anchor ${destination.anchorKey})',
        );
        expect(
          find.byKey(kAdminBusinessAccountsBackButtonKey),
          findsNothing,
          reason:
              'per-business tab ${destination.routeId} must not show the '
              'top Business accounts back button',
        );
        // The cluster stays active (the scope is still chosen) so the
        // journey can keep hopping between per-business screens.
        expect(
          find.byKey(const Key('admin_nav_per_business_cluster')),
          findsOneWidget,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'opening ${destination.routeId} must not throw',
        );
      }
    },
  );

  testWidgets(
    'demo Data Accuracy opens the operator surface for Toronto Yorkville',
    (tester) async {
      await pumpAdminConsole(tester);

      await tapKey(tester, Key('admin_setup_scope_business_$dinerOperatorId'));
      await tapKey(
        tester,
        Key('admin_setup_scope_location_$dinerLocationToronto'),
      );
      await tapKey(
        tester,
        Key('admin_nav_cluster_item_$kAdminDataAccuracyRouteId'),
      );

      expect(
        find.byKey(const Key('admin_data_accuracy_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('data_accuracy_covers_source_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('data_accuracy_wage_source_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_data_accuracy_business_timing_error'),
        ),
        findsNothing,
      );
      expect(find.text('Open Polling Setup'), findsOneWidget);
      expect(find.text('Request faster data freshness'), findsNothing);

      await tapKey(tester, const Key('polling_tier_request_change_button'));
      expect(
        find.byKey(const Key('admin_polling_pricing_screen')),
        findsOneWidget,
      );
      expect(find.byKey(kAdminPreviousScreenBackButtonKey), findsOneWidget);
      expect(find.text('Data accuracy needs Business Timing'), findsNothing);

      await tapKey(tester, kAdminPreviousScreenBackButtonKey);
      expect(
        find.byKey(const Key('admin_data_accuracy_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsOneWidget,
      );
      expect(find.text('Open Polling Setup'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // A focused companion to the journey: tapping an INACTIVE cluster row
  // (before any business is picked) must not silently open the screen; it
  // routes the operator to Business accounts to choose a business first.
  // Guards the "deliberate scope choice" model the cluster depends on.
  testWidgets('before a business is picked, an inactive cluster row routes to '
      'Business accounts instead of opening the screen', (tester) async {
    await pumpAdminConsole(tester);

    // Start somewhere other than Business accounts so the redirect is
    // observable (the operators surface appears).
    await tapKey(tester, const Key('admin_nav_item_health'));
    expect(find.byKey(const Key('admin_health_screen')), findsOneWidget);

    // Tapping an inactive per-business row opens a "pick a business
    // first" dialog, NOT the destination screen.
    await tapKey(tester, Key('admin_nav_cluster_item_$kAdminMembersRouteId'));
    expect(find.byKey(const Key('admin_members_screen')), findsNothing);
    expect(
      find.byKey(const Key('admin_pick_business_first_dialog')),
      findsOneWidget,
    );

    // Its link routes to Business accounts.
    await tapKey(tester, const Key('admin_pick_business_first_dialog_link'));
    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
