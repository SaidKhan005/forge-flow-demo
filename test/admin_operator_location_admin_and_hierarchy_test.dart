// Phase 11A.1 — Admin Operator/Location screen widget tests: ADMIN + HIERARCHY.
//
// Bucket 5h of the 2026-05-20 test-suite tightening audit. Split out
// of the ~2,131-line `admin_operator_location_screen_test.dart`
// monolith. Covers the admin-only and hierarchy-management flows:
// the read-only "Coming soon" AI plan selector, the "add location
// requires an org unit" guard, the business-hierarchy manager's
// create / move / suspend / reactivate / delete org-unit and
// location operations, the non-admin auth-gate forbidden-card path,
// and the admin-shell scope override + `ff_support` read-only render.
//
// 2026-05-24 update: the Business accounts screen now presents scope
// the SAME way as the AI setup tabs — a shared searchable business ->
// org unit -> location tree (`AdminScopeTreePane`) as the LEFT pane,
// with the business profile + location hierarchy as the RIGHT detail.
// The redundant drill-in setup tiles (Operations / People /
// Safety-Support) and the per-location drill-in buttons (Support view
// / People / Access / Timing) were removed because the sidebar now
// owns that navigation; the lifecycle buttons (Edit / Make primary /
// Remove) stay. Tests select a business in the left tree before
// interacting with the detail, and assert the removed affordances are
// gone while lifecycle + "New business" stay reachable.
//
// Shared fixtures (`wrap`, `seedBundle`) and bounded pump helpers
// (`pumpEventually`) live in `admin_operator_location_test_helpers.dart`
// and `_test_helpers/widget_pump_helpers.dart`, respectively, so each
// split file imports a single source of truth.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/admin_scope_tree_pane.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '_test_helpers/widget_pump_helpers.dart';
import 'admin_operator_location_test_helpers.dart';

void main() {
  /// Forces the wide split layout (scope pane + detail side-by-side)
  /// so a test can see both panes at once instead of the compact
  /// 2-tab ("Scope" / "Business") layout used below 920px.
  void useWideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Taps the business node in the shared left scope tree, which
  /// selects the owning business for the right detail pane.
  Future<void> selectBusinessScope(
    WidgetTester tester,
    String operatorId,
  ) async {
    final businessRow = find.byKey(
      Key('admin_setup_scope_business_$operatorId'),
    );
    await tester.ensureVisible(businessRow);
    await pumpEventually(tester);
    await tester.tap(businessRow);
    await pumpEventually(tester);
  }

  // Canonical scope-entity icons: every business / org-unit / location row
  // in the admin Business accounts surface (the shared left scope tree AND
  // the right detail hierarchy) must resolve its glyph through the shared
  // `scopeIcon` helper so the icon set matches operator-web and mobile.
  //   business       -> Icons.apartment_outlined
  //   location       -> Icons.place_outlined
  //   org unit (region) -> Icons.public (sub-type glyph via unit_type)
  testWidgets(
    'scope tree + hierarchy detail render canonical scope-entity icons',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle()],
      );
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-seed-1': <OrgUnitAdminNode>[
            const OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'East Region',
              operatorId: 'op-seed-1',
              unitType: 'region',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-seed-1': <HierarchyLocationLeaf>[
            const HierarchyLocationLeaf(
              locationId: 'loc-seed-1',
              name: 'HQ',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-root',
            ),
          ],
        },
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
          ),
        ),
      );
      await pumpEventually(tester);

      // The collapsed left tree shows the business row up front; selecting it
      // expands its org-unit / location children AND opens the right detail
      // pane, so every scope-entity row is in the tree at once.
      expect(
        find.descendant(
          of: find.byKey(const Key('admin_setup_scope_business_op-seed-1')),
          matching: find.byIcon(Icons.apartment_outlined),
        ),
        findsOneWidget,
        reason: 'scope-tree business row must use the canonical business glyph',
      );

      await selectBusinessScope(tester, 'op-seed-1');

      // Left scope tree (now expanded): org unit -> canonical generic
      // org-unit glyph (the tree resolver passes no unit_type), location ->
      // place.
      expect(
        find.descendant(
          of: find.byKey(const Key('admin_setup_scope_org_unit_org-root')),
          matching: find.byIcon(Icons.account_tree_outlined),
        ),
        findsOneWidget,
        reason: 'scope-tree org-unit row uses the canonical org-unit glyph',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('admin_setup_scope_location_loc-seed-1')),
          matching: find.byIcon(Icons.place_outlined),
        ),
        findsOneWidget,
        reason: 'scope-tree location row must use the canonical location glyph',
      );

      // Right detail hierarchy rows: business scope row -> apartment, the
      // region org unit -> its canonical sub-type glyph (public, resolved via
      // `org_units.unit_type`), the location -> place. The old admin glyphs
      // (business_outlined / storefront_outlined) are gone.
      expect(
        find.descendant(
          of: find.byKey(const Key('admin_hierarchy_business_scope_row')),
          matching: find.byIcon(Icons.apartment_outlined),
        ),
        findsOneWidget,
        reason: 'detail business scope row must use the canonical glyph',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('admin_hierarchy_org_unit_org-root')),
          matching: find.byIcon(Icons.public),
        ),
        findsOneWidget,
        reason: 'a region org unit must render its canonical sub-type glyph',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('admin_hierarchy_location_loc-seed-1')),
          matching: find.byIcon(Icons.place_outlined),
        ),
        findsOneWidget,
        reason: 'detail location row must use the canonical location glyph',
      );

      // The pre-canonical admin glyphs are fully retired from this surface.
      expect(find.byIcon(Icons.business_outlined), findsNothing);
      expect(find.byIcon(Icons.storefront_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('operator AI plan selection is read-only while coming soon', (
    tester,
  ) async {
    useWideSurface(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    await selectBusinessScope(tester, 'op-seed-1');

    expect(find.text('Plan'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_operator_ai_plan_detail_row')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('admin_operator_edit_button')));
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_edit_operator_dialog')), findsOneWidget);
    expect(find.text('Forge & Flow AI plan'), findsWidgets);
    expect(find.text('Coming soon'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Coming soon')).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('admin_subscription_tier_dropdown')),
            )
            .dy,
      ),
    );

    final planField = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('admin_subscription_tier_dropdown')),
    );
    expect(planField.onChanged, isNull);
  });

  testWidgets(
    'Business accounts uses the shared scope tree and a select-a-business '
    'prompt before a node is picked',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
          seedBundle(operatorId: 'op-2', businessName: 'Beta Bistro'),
        ],
      );
      await tester.pumpWidget(
        wrap(OperatorLocationAdminScreen(gateway: gateway)),
      );
      await pumpEventually(tester);

      // Left pane is the SAME shared scope tree as the AI setup tabs.
      expect(
        find.byKey(const Key('admin_setup_workspace_scope_pane')),
        findsOneWidget,
      );
      expect(find.byType(AdminScopeTreePane), findsOneWidget);
      expect(find.text('Scope'), findsWidgets);
      expect(
        find.byKey(const Key('admin_setup_scope_business_op-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_setup_scope_business_op-2')),
        findsOneWidget,
      );
      // The old flat operator list / tile / search are gone.
      expect(find.byKey(const Key('admin_operators_list')), findsNothing);
      expect(find.byKey(const Key('admin_operator_row_op-1')), findsNothing);
      expect(
        find.byKey(const Key('admin_operators_search_field')),
        findsNothing,
      );

      // Before a business is picked the detail pane shows the prompt.
      expect(
        find.byKey(const Key('admin_operators_detail_empty')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsNothing,
      );

      // Picking a business reveals its detail.
      await selectBusinessScope(tester, 'op-1');
      expect(
        find.byKey(const Key('admin_operators_detail_empty')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_operator_detail_op-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsOneWidget,
      );

      // The redundant drill-in setup tiles (now in the sidebar) are gone.
      for (final removedTile in <String>[
        'admin_business_setup_op-1',
        'admin_business_setup_group_operations',
        'admin_business_setup_group_people',
        'admin_business_setup_group_safety_support',
        'admin_business_setup_tile_integrations',
        'admin_business_setup_tile_data_accuracy',
        'admin_business_setup_tile_polling_pricing',
        'admin_business_setup_tile_timing',
        'admin_business_setup_tile_people_access_roles',
        'admin_business_setup_tile_security_audit_sessions',
        'admin_business_setup_tile_support_logs',
      ]) {
        expect(
          find.byKey(Key(removedTile)),
          findsNothing,
          reason: '$removedTile should be removed (now owned by the sidebar)',
        );
      }
    },
  );

  testWidgets('New business onboarding stays reachable from the scope pane', (
    tester,
  ) async {
    useWideSurface(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    final newButton = find.byKey(const Key('admin_operators_new_button'));
    expect(newButton, findsOneWidget);
    // It lives inside the left scope pane now, above the search field.
    expect(
      find.descendant(
        of: find.byKey(const Key('admin_setup_workspace_scope_pane')),
        matching: newButton,
      ),
      findsOneWidget,
    );

    await tester.tap(newButton);
    await pumpEventually(tester);
    expect(
      find.byKey(const Key('admin_onboard_operator_dialog')),
      findsOneWidget,
    );
  });

  testWidgets('add location requires a selected hierarchy org unit', (
    tester,
  ) async {
    useWideSurface(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    await selectBusinessScope(tester, 'op-seed-1');

    final addButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('admin_operator_add_location_button')),
    );
    expect(addButton.onPressed, isNull);
    expect(
      find.byKey(const Key('admin_location_parent_org_unit_required_copy')),
      findsNothing,
    );
  });

  testWidgets(
    'location hierarchy keeps lifecycle controls and drops drill-in buttons',
    (tester) async {
      useWideSurface(tester);
      final created = DateTime.utc(2026, 1, 1);
      final bundle = OperatorAdminBundle(
        operator: OperatorAdminRecord(
          operatorId: 'op-seed-1',
          businessName: 'Seed Cafe',
          ownerEmail: 'owner@seed.test',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationId: 'loc-primary',
          suspendedAt: null,
          createdAt: created,
          updatedAt: created,
        ),
        locations: <LocationAdminRecord>[
          LocationAdminRecord(
            locationId: 'loc-primary',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
            name: 'HQ',
            address: '',
            timezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            createdAt: created,
            updatedAt: created,
          ),
          LocationAdminRecord(
            locationId: 'loc-west',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
            name: 'West Coast',
            address: '',
            timezone: 'America/Vancouver',
            businessDayRolloverHour: 4,
            createdAt: created,
            updatedAt: created,
          ),
        ],
      );
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[bundle],
      );
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-seed-1': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Demo Diner Co.',
              operatorId: 'op-seed-1',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-seed-1': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-primary',
              name: 'HQ',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-root',
            ),
            HierarchyLocationLeaf(
              locationId: 'loc-west',
              name: 'West Coast',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-root',
            ),
          ],
        },
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
            idempotencyKeyFactory: () => 'idem-lifecycle-keep',
          ),
        ),
      );
      await pumpEventually(tester);

      await selectBusinessScope(tester, 'op-seed-1');

      // Lifecycle controls remain on the non-primary location row.
      expect(
        find.byKey(const Key('admin_location_edit_loc-west')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_location_make_primary_loc-west')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_location_remove_loc-west')),
        findsOneWidget,
      );

      // The drill-in per-location buttons were removed (sidebar owns them).
      for (final removed in <String>[
        'admin_location_support_view_loc-west',
        'admin_location_team_loc-west',
        'admin_location_access_loc-west',
        'admin_location_timing_loc-west',
        'admin_location_data_accuracy_loc-west',
        'admin_location_polling_pricing_loc-west',
        'admin_location_audit_support_loc-west',
        'admin_location_support_logs_loc-west',
        'admin_location_vendor_connections_loc-west',
      ]) {
        expect(
          find.byKey(Key(removed)),
          findsNothing,
          reason: '$removed drill-in should be removed',
        );
      }
    },
  );

  testWidgets('business hierarchy manager creates a child org unit', (
    tester,
  ) async {
    useWideSurface(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-seed-1': <OrgUnitAdminNode>[
          const OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Demo Diner Co.',
            operatorId: 'op-seed-1',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-seed-1': <HierarchyLocationLeaf>[
          const HierarchyLocationLeaf(
            locationId: 'loc-seed-1',
            name: 'HQ',
            operatorId: 'op-seed-1',
            orgUnitId: 'org-root',
          ),
        ],
      },
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          actorUserId: 'demo-super-admin',
          idempotencyKeyFactory: () => 'idem-business-hierarchy-add-child',
        ),
      ),
    );
    await pumpEventually(tester);

    await selectBusinessScope(tester, 'op-seed-1');

    final addChild = find.byKey(
      const Key('admin_hierarchy_org_unit_add_child_org-root'),
    );
    await tester.ensureVisible(addChild);
    await pumpEventually(tester);
    await tester.tap(addChild);
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_hierarchy_add_child_org_unit_dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_hierarchy_add_org_unit_label')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const Key('admin_hierarchy_add_org_unit_name')),
      'North district',
    );
    await tester.enterText(
      find.byKey(const Key('admin_hierarchy_add_org_unit_reason')),
      'operator requested hierarchy setup',
    );
    await tester.tap(
      find.byKey(const Key('admin_hierarchy_add_org_unit_submit')),
    );
    await pumpEventually(tester);

    expect(find.text('North district'), findsOneWidget);
    final event = hierarchyGateway.capturedAuditEvents.single;
    expect(event.action, equals('team.org_unit.create'));
    expect(event.actorUserId, equals('demo-super-admin'));
    expect(event.adminReason, equals('operator requested hierarchy setup'));
    expect(event.payload['parent_org_unit_id'], equals('org-root'));
  });

  testWidgets('business hierarchy manager moves a location with a reason', (
    tester,
  ) async {
    useWideSurface(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-seed-1': const <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Demo Diner Co.',
            operatorId: 'op-seed-1',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-north',
            name: 'North district',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-seed-1': const <HierarchyLocationLeaf>[
          HierarchyLocationLeaf(
            locationId: 'loc-seed-1',
            name: 'HQ',
            operatorId: 'op-seed-1',
            orgUnitId: 'org-root',
          ),
        ],
      },
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          actorUserId: 'demo-super-admin',
          idempotencyKeyFactory: () => 'idem-business-hierarchy-move-location',
        ),
      ),
    );
    await pumpEventually(tester);

    await selectBusinessScope(tester, 'op-seed-1');

    final moveButton = find.byKey(const Key('admin_location_move_loc-seed-1'));
    await tester.ensureVisible(moveButton);
    await pumpEventually(tester);
    await tester.tap(moveButton);
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_hierarchy_move_location_dialog')),
      findsOneWidget,
    );
    expect(find.text('Demo Diner Co. / North district'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('admin_hierarchy_move_location_reason')),
      'move hq under the north district',
    );
    await tester.tap(
      find.byKey(const Key('admin_hierarchy_move_location_submit')),
    );
    await pumpEventually(tester);

    final moved = (await hierarchyGateway.listHierarchyLocations(
      operatorId: 'op-seed-1',
    )).single;
    expect(moved.orgUnitId, equals('org-north'));
    final event = hierarchyGateway.capturedAuditEvents.single;
    expect(event.action, equals('team.location.move'));
    expect(event.actorUserId, equals('demo-super-admin'));
    expect(event.adminReason, equals('move hq under the north district'));
    expect(event.payload['org_unit_id'], isA<Map<String, Object?>>());
  });

  testWidgets('business hierarchy manager moves an org unit with a reason', (
    tester,
  ) async {
    useWideSurface(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-seed-1': const <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Demo Diner Co.',
            operatorId: 'op-seed-1',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-east',
            name: 'East district',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-downtown',
            name: 'Downtown group',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-east',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-west',
            name: 'West district',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-seed-1': const <HierarchyLocationLeaf>[
          HierarchyLocationLeaf(
            locationId: 'loc-seed-1',
            name: 'HQ',
            operatorId: 'op-seed-1',
            orgUnitId: 'org-east',
          ),
        ],
      },
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          actorUserId: 'demo-super-admin',
          idempotencyKeyFactory: () => 'idem-business-hierarchy-move-org-unit',
        ),
      ),
    );
    await pumpEventually(tester);

    await selectBusinessScope(tester, 'op-seed-1');

    final rootMoveButton = tester.widget<IconButton>(
      find.byKey(const Key('admin_hierarchy_org_unit_move_org-root')),
    );
    expect(rootMoveButton.onPressed, isNull);

    final moveButton = find.byKey(
      const Key('admin_hierarchy_org_unit_move_org-east'),
    );
    await tester.ensureVisible(moveButton);
    await pumpEventually(tester);
    await tester.tap(moveButton);
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_hierarchy_move_org_unit_dialog')),
      findsOneWidget,
    );
    expect(find.text('Demo Diner Co. / West district'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('admin_hierarchy_move_org_unit_reason')),
      'rebalance the district reporting line',
    );
    await tester.tap(
      find.byKey(const Key('admin_hierarchy_move_org_unit_submit')),
    );
    await pumpEventually(tester);

    final moved = (await hierarchyGateway.listOrgUnits(
      operatorId: 'op-seed-1',
    )).singleWhere((unit) => unit.orgUnitId == 'org-east');
    expect(moved.parentOrgUnitId, equals('org-west'));
    final event = hierarchyGateway.capturedAuditEvents.single;
    expect(event.action, equals('team.org_unit.move'));
    expect(event.actorUserId, equals('demo-super-admin'));
    expect(event.adminReason, equals('rebalance the district reporting line'));
    expect(event.payload['parent_org_unit_id'], isA<Map<String, Object?>>());
  });

  testWidgets(
    'business hierarchy manager suspends reactivates and deletes org units',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle()],
      );
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-seed-1': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Demo Diner Co.',
              operatorId: 'op-seed-1',
            ),
            OrgUnitAdminNode(
              orgUnitId: 'org-east',
              name: 'East district',
              operatorId: 'op-seed-1',
              parentOrgUnitId: 'org-root',
            ),
            OrgUnitAdminNode(
              orgUnitId: 'org-empty',
              name: 'Empty district',
              operatorId: 'op-seed-1',
              parentOrgUnitId: 'org-root',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-seed-1': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-seed-1',
              name: 'HQ',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-east',
            ),
          ],
        },
      );
      var idempotency = 0;
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
            idempotencyKeyFactory: () => 'idem-org-lifecycle-${idempotency++}',
          ),
        ),
      );
      await pumpEventually(tester);

      await selectBusinessScope(tester, 'op-seed-1');

      final rootSuspend = tester.widget<IconButton>(
        find.byKey(const Key('admin_hierarchy_org_unit_suspend_org-root')),
      );
      expect(rootSuspend.onPressed, isNull);

      final suspendButton = find.byKey(
        const Key('admin_hierarchy_org_unit_suspend_org-east'),
      );
      await tester.ensureVisible(suspendButton);
      await pumpEventually(tester);
      await tester.tap(suspendButton);
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_hierarchy_org_unit_suspend_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_org_unit_suspend_reason')),
        'district temporarily paused by admin',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_org_unit_suspend_submit')),
      );
      await pumpEventually(tester);

      expect(find.text('Suspended branch'), findsOneWidget);
      final suspended = (await hierarchyGateway.listOrgUnits(
        operatorId: 'op-seed-1',
      )).singleWhere((unit) => unit.orgUnitId == 'org-east');
      expect(suspended.isSuspended, isTrue);
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.org_unit.suspend'),
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.adminReason,
        equals('district temporarily paused by admin'),
      );

      final reactivateButton = find.byKey(
        const Key('admin_hierarchy_org_unit_reactivate_org-east'),
      );
      await tester.ensureVisible(reactivateButton);
      await pumpEventually(tester);
      await tester.tap(reactivateButton);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_org_unit_reactivate_reason')),
        'district ready for use again',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_org_unit_reactivate_submit')),
      );
      await pumpEventually(tester);

      final reactivated = (await hierarchyGateway.listOrgUnits(
        operatorId: 'op-seed-1',
      )).singleWhere((unit) => unit.orgUnitId == 'org-east');
      expect(reactivated.isSuspended, isFalse);
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.org_unit.reactivate'),
      );

      final deleteButton = find.byKey(
        const Key('admin_hierarchy_org_unit_delete_org-empty'),
      );
      await tester.ensureVisible(deleteButton);
      await pumpEventually(tester);
      await tester.tap(deleteButton);
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_hierarchy_org_unit_delete_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_org_unit_delete_reason')),
        'empty district created in error',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_org_unit_delete_submit')),
      );
      await pumpEventually(tester);

      final units = await hierarchyGateway.listOrgUnits(
        operatorId: 'op-seed-1',
      );
      expect(units.any((unit) => unit.orgUnitId == 'org-empty'), isFalse);
      expect(
        find.byKey(const Key('admin_hierarchy_org_unit_org-empty')),
        findsNothing,
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.org_unit.delete'),
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.adminReason,
        equals('empty district created in error'),
      );
    },
  );

  testWidgets(
    'business hierarchy manager suspends reactivates and deletes locations',
    (tester) async {
      useWideSurface(tester);
      final created = DateTime.utc(2026, 1, 1);
      final bundle = OperatorAdminBundle(
        operator: OperatorAdminRecord(
          operatorId: 'op-seed-1',
          businessName: 'Seed Cafe',
          ownerEmail: 'owner@seed.test',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationId: 'loc-primary',
          suspendedAt: null,
          createdAt: created,
          updatedAt: created,
        ),
        locations: <LocationAdminRecord>[
          LocationAdminRecord(
            locationId: 'loc-primary',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
            name: 'HQ',
            address: '',
            timezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            createdAt: created,
            updatedAt: created,
          ),
          LocationAdminRecord(
            locationId: 'loc-west',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
            name: 'West Coast',
            address: '',
            timezone: 'America/Vancouver',
            businessDayRolloverHour: 4,
            createdAt: created,
            updatedAt: created,
          ),
        ],
      );
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[bundle],
      );
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-seed-1': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Demo Diner Co.',
              operatorId: 'op-seed-1',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-seed-1': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-primary',
              name: 'HQ',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-root',
            ),
            HierarchyLocationLeaf(
              locationId: 'loc-west',
              name: 'West Coast',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-root',
            ),
          ],
        },
      );
      var idempotency = 0;
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
            idempotencyKeyFactory: () =>
                'idem-location-lifecycle-${idempotency++}',
          ),
        ),
      );
      await pumpEventually(tester);

      await selectBusinessScope(tester, 'op-seed-1');

      final primaryDelete = tester.widget<IconButton>(
        find.byKey(const Key('admin_location_remove_loc-primary')),
      );
      expect(primaryDelete.onPressed, isNull);

      final suspendButton = find.byKey(
        const Key('admin_location_suspend_loc-west'),
      );
      await tester.ensureVisible(suspendButton);
      await pumpEventually(tester);
      await tester.tap(suspendButton);
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_hierarchy_location_suspend_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_location_suspend_reason')),
        'seasonal closure requested',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_location_suspend_submit')),
      );
      await pumpEventually(tester);

      expect(find.text('Suspended location'), findsOneWidget);
      final suspended = (await hierarchyGateway.listHierarchyLocations(
        operatorId: 'op-seed-1',
      )).singleWhere((location) => location.locationId == 'loc-west');
      expect(suspended.isSuspended, isTrue);
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.location.suspend'),
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.adminReason,
        equals('seasonal closure requested'),
      );

      final reactivateButton = find.byKey(
        const Key('admin_location_reactivate_loc-west'),
      );
      await tester.ensureVisible(reactivateButton);
      await pumpEventually(tester);
      await tester.tap(reactivateButton);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_location_reactivate_reason')),
        'location reopened',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_location_reactivate_submit')),
      );
      await pumpEventually(tester);

      final reactivated = (await hierarchyGateway.listHierarchyLocations(
        operatorId: 'op-seed-1',
      )).singleWhere((location) => location.locationId == 'loc-west');
      expect(reactivated.isSuspended, isFalse);
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.location.reactivate'),
      );

      final deleteButton = find.byKey(
        const Key('admin_location_remove_loc-west'),
      );
      await tester.ensureVisible(deleteButton);
      await pumpEventually(tester);
      await tester.tap(deleteButton);
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_hierarchy_location_delete_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_location_delete_reason')),
        'duplicate location record',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_location_delete_submit')),
      );
      await pumpEventually(tester);

      final locations = await hierarchyGateway.listHierarchyLocations(
        operatorId: 'op-seed-1',
      );
      expect(
        locations.any((location) => location.locationId == 'loc-west'),
        isFalse,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_location_loc-west')),
        findsNothing,
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.location.delete'),
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.adminReason,
        equals('duplicate location record'),
      );
    },
  );

  testWidgets('non-admin user is blocked by the admin auth gate', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsNonAdmin();
    addTearDown(source.dispose);
    await tester.pumpWidget(AdminConsoleApp(authSource: source));
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_forbidden_card')), findsOneWidget);
    expect(find.byKey(const Key('admin_operators_screen')), findsNothing);
    expect(find.text('Operators'), findsNothing);
  });

  testWidgets(
    'admin services scope overrides the default gateway in the shell',
    (tester) async {
      useWideSurface(tester);
      final overrideGateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(operatorId: 'op-override', businessName: 'Override Co'),
        ],
      );
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);

      // AdminConsoleApp owns its own MaterialApp; wrapping the scope
      // above it puts the override on the InheritedWidget path that
      // the operators-route builder reads via
      // `AdminConsoleServicesScope.operatorLocationGatewayOf`.
      await tester.pumpWidget(
        AdminConsoleServicesScope(
          operatorLocationGateway: overrideGateway,
          child: AdminConsoleApp(authSource: source),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_nav_item_operators')));
      await pumpEventually(tester);

      expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
      // The overridden gateway's business shows as a node in the shared
      // scope tree (the old flat operator-row key is gone).
      expect(
        find.byKey(const Key('admin_setup_scope_business_op-override')),
        findsOneWidget,
      );
    },
  );

  testWidgets('admin shell with ff_support renders operators read-only', (
    tester,
  ) async {
    useWideSurface(tester);
    final source = DemoAdminAuthSource(
      initial: const AdminAuthAuthenticated(
        AdminAuthSession(
          uid: 'demo-ff-support',
          email: 'support@forgeflow.test',
          displayName: 'Demo F&F Support',
          roles: <String>['ff_support'],
        ),
      ),
    );
    addTearDown(source.dispose);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle(operatorId: 'op-support-shell')],
    );

    await tester.pumpWidget(
      AdminConsoleServicesScope(
        operatorLocationGateway: gateway,
        adminAuthSource: source,
        child: AdminConsoleApp(authSource: source),
      ),
    );
    await pumpEventually(tester);

    await tester.tap(find.byKey(const Key('admin_nav_item_operators')));
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_operators_readonly_banner')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_operators_new_button')), findsNothing);
    // The business profile edit button only appears after a business is
    // picked; in read-only mode it is absent regardless.
    expect(find.byKey(const Key('admin_operator_edit_button')), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // 2026-05-24 — Business accounts pick activates the sidebar cluster.
  //
  // Selecting a business in the LEFT scope tree must notify the shell with a
  // hierarchyScope (which flips the shell's "business chosen" latch so the
  // per-business sidebar cluster activates), while the on-load seed must NOT
  // (the cluster stays "Pick a business first" until a real pick).
  // ---------------------------------------------------------------------------
  testWidgets(
    'selecting a business in the scope tree emits a hierarchyScope intent '
    'while the on-load seed emits only an operator-location scope',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
          seedBundle(operatorId: 'op-2', businessName: 'Beta Bistro'),
        ],
      );
      final chosenScopes = <AdminHierarchyScopeIntent>[];
      final seededScopes = <AdminOperatorLocationScopeIntent>[];
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            onChooseBusinessScope: chosenScopes.add,
            onSelectOperatorScope: seededScopes.add,
          ),
        ),
      );
      await pumpEventually(tester);

      // On load the screen seeds the shell scope (so the top bar shows the
      // first business) WITHOUT activating the cluster: only the
      // operator-location seed fires; the cluster-activating hierarchyScope
      // callback has NOT been called.
      expect(
        chosenScopes,
        isEmpty,
        reason: 'the on-load seed must not activate the sidebar cluster',
      );
      expect(
        seededScopes,
        isNotEmpty,
        reason: 'the on-load seed still syncs the shell operator scope',
      );

      // A deliberate business pick in the left tree emits a hierarchyScope
      // carrying the picked business, which is what flips the shell latch.
      await selectBusinessScope(tester, 'op-2');

      expect(chosenScopes, isNotEmpty);
      final picked = chosenScopes.last;
      expect(picked.operatorId, equals('op-2'));
      expect(picked.scopeType, equals(AdminHierarchyScopeType.business));
    },
  );

  testWidgets(
    'selecting a location node in the scope tree also emits a hierarchyScope '
    'intent for the owning business',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle(operatorId: 'op-1')],
      );
      // A hierarchy gateway so the location leaf renders under its org unit
      // in the LEFT tree (without one, a location carrying a non-null
      // parentOrgUnitId is neither "unassigned" nor under a rendered org
      // unit, so the leaf row would not appear).
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-1': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Demo Diner Co.',
              operatorId: 'op-1',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-1': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-seed-1',
              name: 'HQ',
              operatorId: 'op-1',
              orgUnitId: 'org-root',
            ),
          ],
        },
      );
      final chosenScopes = <AdminHierarchyScopeIntent>[];
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            onChooseBusinessScope: chosenScopes.add,
          ),
        ),
      );
      await pumpEventually(tester);
      expect(chosenScopes, isEmpty);

      // Expand the business, then pick its location leaf.
      await selectBusinessScope(tester, 'op-1');
      chosenScopes.clear();
      final locationRow = find.byKey(
        const Key('admin_setup_scope_location_loc-seed-1'),
      );
      await tester.ensureVisible(locationRow);
      await pumpEventually(tester);
      await tester.tap(locationRow);
      await pumpEventually(tester);

      expect(chosenScopes, isNotEmpty);
      final picked = chosenScopes.last;
      expect(picked.operatorId, equals('op-1'));
      expect(picked.locationId, equals('loc-seed-1'));
      expect(picked.scopeType, equals(AdminHierarchyScopeType.location));
    },
  );

  // ---------------------------------------------------------------------------
  // 2026-05-24: hierarchy tree actions stay compact, keyed, and accessible.
  // ---------------------------------------------------------------------------
  testWidgets(
    'hierarchy tree actions render as icon buttons with the destructive '
    'ones in the danger style, keeping their existing keys',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle()],
      );
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-seed-1': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Demo Diner Co.',
              operatorId: 'op-seed-1',
            ),
            OrgUnitAdminNode(
              orgUnitId: 'org-east',
              name: 'East district',
              operatorId: 'op-seed-1',
              parentOrgUnitId: 'org-root',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-seed-1': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-seed-1',
              name: 'HQ',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-east',
            ),
          ],
        },
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
            idempotencyKeyFactory: () => 'idem-labeled-buttons',
          ),
        ),
      );
      await pumpEventually(tester);

      await selectBusinessScope(tester, 'op-seed-1');

      // The hierarchy uses compact icon buttons with tooltips so row names
      // remain the primary readable content.
      for (final label in <String>[
        'Add child org unit',
        'Move org unit',
        'Suspend org unit',
        'Edit location',
        'Make primary location',
        'Delete org unit',
        'Delete location',
      ]) {
        expect(
          find.byTooltip(label),
          findsWidgets,
          reason: 'tree action "$label" must keep a tooltip',
        );
      }

      // Each action keeps a stable keyed IconButton.
      void expectIconButton(Key key, IconData icon) {
        expect(
          find.descendant(of: find.byKey(key), matching: find.byIcon(icon)),
          findsOneWidget,
          reason: '$key must show the expected icon',
        );
      }

      expectIconButton(
        const Key('admin_hierarchy_org_unit_add_child_org-east'),
        Icons.add,
      );
      expectIconButton(
        const Key('admin_location_edit_loc-seed-1'),
        Icons.edit_outlined,
      );
      expectIconButton(
        const Key('admin_location_make_primary_loc-seed-1'),
        Icons.star_outline,
      );

      // Destructive actions use the danger (negative) secondary style.
      Color? foregroundOf(Key key) {
        final button = tester.widget<IconButton>(find.byKey(key));
        return button.style?.foregroundColor?.resolve(<WidgetState>{});
      }

      expect(
        foregroundOf(const Key('admin_hierarchy_org_unit_delete_org-east')),
        equals(AppColors.negative),
        reason: 'Delete org unit must use the danger style',
      );
      expect(
        foregroundOf(const Key('admin_location_remove_loc-seed-1')),
        equals(AppColors.negative),
        reason: 'Remove location must use the danger style',
      );

      // Existing widget keys still resolve (tests + selectors keep working).
      for (final key in <Key>[
        const Key('admin_hierarchy_org_unit_add_child_org-east'),
        const Key('admin_hierarchy_org_unit_move_org-east'),
        const Key('admin_hierarchy_org_unit_suspend_org-east'),
        const Key('admin_hierarchy_org_unit_delete_org-east'),
        const Key('admin_location_move_loc-seed-1'),
        const Key('admin_location_suspend_loc-seed-1'),
        const Key('admin_location_edit_loc-seed-1'),
        const Key('admin_location_make_primary_loc-seed-1'),
        const Key('admin_location_remove_loc-seed-1'),
      ]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key must resolve');
      }

      // No regressions: the tree rows did not overflow at the wide width.
      expect(tester.takeException(), isNull);
    },
  );

  // ---------------------------------------------------------------------------
  // Regression: add location persists AND shows in the hierarchy tree
  // immediately (no manual reload), even when the hierarchy gateway is
  // wired.
  //
  // Root cause this guards: the hierarchy panel cached its load future
  // from initState and only reloaded on operator/gateway change, so after
  // `_runAndRefresh` re-fetched the operator bundles the panel never
  // re-ran; AND `_buildTreeRows` dropped any operator-bundle location with
  // no live hierarchy leaf, which is exactly the state of a freshly-added
  // location (the demo's operator + hierarchy gateways are separate
  // in-memory stores, so the new leaf never appears in the hierarchy
  // read). Net effect: the "Location added" toast fired but the row was
  // invisible until a manual reload. The fix reloads the panel on a
  // location-set change AND renders a never-surfaced location by its own
  // parentOrgUnitId while still hiding hierarchy-deleted leaves.
  // ---------------------------------------------------------------------------
  testWidgets('adding a location persists and appears in the hierarchy tree '
      'immediately when a hierarchy gateway is wired', (tester) async {
    useWideSurface(tester);
    // Operator gateway starts with only the primary location. The
    // hierarchy gateway knows the org units + the primary leaf, but NOT
    // the location we are about to add (mirrors the live divergence
    // before the next hierarchy read, and the permanent divergence of
    // the demo's two in-memory stores).
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(operatorId: 'op-add', primaryLocationId: 'loc-add-hq'),
      ],
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-add': const <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Demo Diner Co.',
            operatorId: 'op-add',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-east',
            name: 'East district',
            operatorId: 'op-add',
            parentOrgUnitId: 'org-root',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-add': const <HierarchyLocationLeaf>[
          HierarchyLocationLeaf(
            locationId: 'loc-add-hq',
            name: 'HQ',
            operatorId: 'op-add',
            orgUnitId: 'org-root',
          ),
        ],
      },
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          actorUserId: 'demo-super-admin',
          idempotencyKeyFactory: () => 'idem-add-location-shows',
        ),
      ),
    );
    await pumpEventually(tester);

    await selectBusinessScope(tester, 'op-add');

    // The "Add location" button is disabled until an org unit is the
    // selected scope. Pick the East district org unit in the left tree.
    final orgUnitRow = find.byKey(
      const Key('admin_setup_scope_org_unit_org-east'),
    );
    await tester.ensureVisible(orgUnitRow);
    await pumpEventually(tester);
    await tester.tap(orgUnitRow);
    await pumpEventually(tester);

    final addButton = find.byKey(
      const Key('admin_operator_add_location_button'),
    );
    await tester.ensureVisible(addButton);
    await pumpEventually(tester);
    expect(
      tester.widget<OutlinedButton>(addButton).onPressed,
      isNotNull,
      reason: 'selecting an org unit must enable Add location',
    );
    await tester.tap(addButton);
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_location_add_dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('admin_location_name_field')),
      'East Annex',
    );
    await chooseTimezone(
      tester,
      const Key('admin_location_timezone_field'),
      'America/Toronto',
    );
    await tester.tap(find.byKey(const Key('admin_location_submit_button')));
    await pumpEventually(tester);

    // (a) Persisted: the operator gateway's listOperators returns the
    // new location, parented to the org unit that was selected.
    final operators = await gateway.listOperators();
    expect(operators.single.locations, hasLength(2));
    final added = operators.single.locations.firstWhere(
      (l) => l.name == 'East Annex',
    );
    expect(added.parentOrgUnitId, equals('org-east'));

    // (b) Refreshed: the new location row is in the hierarchy tree right
    // away, with NO manual reload. This is the core of the fix.
    expect(
      find.byKey(Key('admin_hierarchy_location_${added.locationId}')),
      findsOneWidget,
      reason:
          'the added location must appear in the hierarchy tree '
          'immediately after the add, with no manual reload',
    );
    expect(find.text('East Annex'), findsWidgets);
  });

  // Guard the other half of the filter: a hierarchy-gateway delete still
  // HIDES the row even though the location lingers in the operator bundle
  // (the hierarchy delete does not mutate the operator gateway). This is
  // the behavior the add-location fix had to preserve when it stopped
  // unconditionally dropping leaf-less operator-bundle locations.
  testWidgets(
    'a hierarchy-deleted location stays hidden after the panel reloads',
    (tester) async {
      useWideSurface(tester);
      final created = DateTime.utc(2026, 1, 1);
      final bundle = OperatorAdminBundle(
        operator: OperatorAdminRecord(
          operatorId: 'op-del',
          businessName: 'Seed Cafe',
          ownerEmail: 'owner@seed.test',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationId: 'loc-del-primary',
          suspendedAt: null,
          createdAt: created,
          updatedAt: created,
        ),
        locations: <LocationAdminRecord>[
          LocationAdminRecord(
            locationId: 'loc-del-primary',
            operatorId: 'op-del',
            parentOrgUnitId: 'org-root',
            name: 'HQ',
            address: '',
            timezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            createdAt: created,
            updatedAt: created,
          ),
          LocationAdminRecord(
            locationId: 'loc-del-west',
            operatorId: 'op-del',
            parentOrgUnitId: 'org-root',
            name: 'West Coast',
            address: '',
            timezone: 'America/Vancouver',
            businessDayRolloverHour: 4,
            createdAt: created,
            updatedAt: created,
          ),
        ],
      );
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[bundle],
      );
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-del': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Demo Diner Co.',
              operatorId: 'op-del',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-del': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-del-primary',
              name: 'HQ',
              operatorId: 'op-del',
              orgUnitId: 'org-root',
            ),
            HierarchyLocationLeaf(
              locationId: 'loc-del-west',
              name: 'West Coast',
              operatorId: 'op-del',
              orgUnitId: 'org-root',
            ),
          ],
        },
      );
      var idempotency = 0;
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
            idempotencyKeyFactory: () => 'idem-del-guard-${idempotency++}',
          ),
        ),
      );
      await pumpEventually(tester);

      await selectBusinessScope(tester, 'op-del');

      // The hierarchy gateway has surfaced loc-del-west, so deleting it
      // there must hide the row even though it stays in the operator
      // bundle.
      expect(
        find.byKey(const Key('admin_hierarchy_location_loc-del-west')),
        findsOneWidget,
      );
      final deleteButton = find.byKey(
        const Key('admin_location_remove_loc-del-west'),
      );
      await tester.ensureVisible(deleteButton);
      await pumpEventually(tester);
      await tester.tap(deleteButton);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_location_delete_reason')),
        'duplicate location record',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_location_delete_submit')),
      );
      await pumpEventually(tester);

      // Still listed by the operator gateway (the hierarchy delete does
      // not touch it) but hidden in the tree.
      final operators = await gateway.listOperators();
      expect(
        operators.single.locations.any((l) => l.locationId == 'loc-del-west'),
        isTrue,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_location_loc-del-west')),
        findsNothing,
        reason: 'a hierarchy-deleted location must stay hidden',
      );
    },
  );
}
