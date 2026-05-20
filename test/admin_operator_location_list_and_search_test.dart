// Phase 11A.1 — Admin Operator/Location screen widget tests: LIST + SEARCH.
//
// Bucket 5h of the 2026-05-20 test-suite tightening audit. Split out
// of the ~2,131-line `admin_operator_location_screen_test.dart`
// monolith. Covers operator-list rendering, search filtering, the
// empty state, master/detail pane stacking, and the master/detail
// tile-tap navigations (support logs, scope prompt, integrations).
//
// Shared fixtures (`wrap`, `seedBundle`) and bounded pump helpers
// (`pumpEventually`) live in `admin_operator_location_test_helpers.dart`
// and `_test_helpers/widget_pump_helpers.dart`, respectively, so each
// split file imports a single source of truth.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/admin_business_accounts_back_button.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';

import '_test_helpers/widget_pump_helpers.dart';
import 'admin_operator_location_test_helpers.dart';

void main() {
  testWidgets('renders one row per seeded operator', (tester) async {
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

    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-1')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_manage_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_operator_manage_op-2')), findsNothing);
    expect(find.text('Click to manage'), findsNothing);
    expect(
      find.text(
        'Start with the business, then move into setup, locations, team, access, audit, and data controls.',
      ),
      findsNothing,
    );
    final newBusinessSize = tester.getSize(
      find.byKey(const Key('admin_operators_new_button')),
    );
    expect(newBusinessSize.width, greaterThanOrEqualTo(168));
    expect(newBusinessSize.height, greaterThanOrEqualTo(50));
    final profileCard = find.byKey(const Key('admin_operator_profile_card'));
    expect(
      find.descendant(of: profileCard, matching: find.text('Account profile')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_account_profile')),
      findsNothing,
    );
    final setupCard = find.byKey(const Key('admin_business_setup_op-1'));
    expect(
      find.descendant(
        of: setupCard,
        matching: find.text('Selected business scope'),
      ),
      findsOneWidget,
    );
    for (final noisyLabel in <String>[
      'Ready',
      'Needs details',
      'Review',
      'Location required',
      'Business default',
      'Inherited',
      'Effective: Business default',
      'Editable',
      'Set at this scope',
    ]) {
      expect(
        find.descendant(of: setupCard, matching: find.text(noisyLabel)),
        findsNothing,
      );
    }
    final operationsGroup = find.byKey(
      const Key('admin_business_setup_group_operations'),
    );
    expect(operationsGroup, findsOneWidget);
    for (final label in <String>[
      'Integrations',
      'Covers and Wage Data Accuracy',
      'Timing',
    ]) {
      expect(
        find.descendant(of: operationsGroup, matching: find.text(label)),
        findsOneWidget,
      );
    }
    final peopleGroup = find.byKey(
      const Key('admin_business_setup_group_people'),
    );
    expect(
      find.descendant(
        of: peopleGroup,
        matching: find.text('People, access, and roles'),
      ),
      findsOneWidget,
    );
    final safetyGroup = find.byKey(
      const Key('admin_business_setup_group_safety_support'),
    );
    expect(
      find.descendant(
        of: safetyGroup,
        matching: find.text('Security, audit, and sessions'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: safetyGroup, matching: find.text('Support logs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_data_accuracy')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_polling_pricing')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_people_access_roles')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('admin_business_setup_tile_security_audit_sessions'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_support_logs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_integrations')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_timing')),
      findsOneWidget,
    );
    expect(find.text('Support workspace'), findsNothing);
    // The selected operator's name shows in both the list row and the
    // detail card; the unselected operator's name only in the list.
    expect(find.text('Alpha Cafe'), findsWidgets);
    expect(find.text('Beta Bistro'), findsWidgets);
  });

  testWidgets('operator detail opens support logs for operator and location', (
    tester,
  ) async {
    final supportLogRequests = <List<String?>>[];
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-support',
          primaryLocationId: 'loc-support',
          businessName: 'Support Cafe',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          onOpenSupportLogs: (operatorId, locationId) {
            supportLogRequests.add(<String?>[operatorId, locationId]);
          },
        ),
      ),
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
      operatorId: 'op-support',
      scopeType: 'business',
    );
    expect(supportLogRequests, hasLength(1));
    expect(supportLogRequests.single, <String?>['op-support', null]);

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-support'),
    );
    await tester.ensureVisible(locationRow);
    await pumpEventually(tester);
    await tester.tap(locationRow);
    await pumpEventually(tester);
    await tester.ensureVisible(supportLogsTile);
    await pumpEventually(tester);
    await tester.tap(supportLogsTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-support',
      scopeType: 'location',
      locationId: 'loc-support',
    );
    expect(supportLogRequests, hasLength(2));
    expect(supportLogRequests.last, <String?>['op-support', 'loc-support']);
  });

  testWidgets('setup tiles offer business, org-unit, and location scope', (
    tester,
  ) async {
    final scopes = <AdminHierarchyScopeIntent>[];
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-workspace',
          primaryLocationId: 'loc-workspace',
          businessName: 'Workspace Cafe',
        ),
      ],
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-workspace': const <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Workspace root',
            operatorId: 'op-workspace',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-workspace': const <HierarchyLocationLeaf>[
          HierarchyLocationLeaf(
            locationId: 'loc-workspace',
            name: 'HQ',
            operatorId: 'op-workspace',
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
          onOpenPeopleAccessRolesScope: scopes.add,
        ),
      ),
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
      operatorId: 'op-workspace',
      scopeType: 'business',
    );
    expect(scopes, hasLength(1));
    expect(scopes.single.operatorId, 'op-workspace');
    expect(scopes.single.scopeType, AdminHierarchyScopeType.business);
    expect(scopes.single.locationId, isNull);
    expect(scopes.single.operatorName, 'Workspace Cafe');

    final orgUnitRow = find.byKey(
      const Key('admin_hierarchy_org_unit_org-root'),
    );
    await tester.ensureVisible(orgUnitRow);
    await pumpEventually(tester);
    await tester.tapAt(tester.getTopLeft(orgUnitRow) + const Offset(24, 24));
    await pumpEventually(tester);

    await tester.ensureVisible(peopleTile);
    await pumpEventually(tester);
    await tester.tap(peopleTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-workspace',
      scopeType: 'org_unit',
      orgUnitId: 'org-root',
    );
    expect(scopes, hasLength(2));
    expect(scopes.last.operatorId, 'op-workspace');
    expect(scopes.last.scopeType, AdminHierarchyScopeType.orgUnit);
    expect(scopes.last.orgUnitId, 'org-root');
    expect(scopes.last.orgUnitName, 'Workspace root');

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-workspace'),
    );
    await tester.ensureVisible(locationRow);
    await pumpEventually(tester);
    await tester.tap(locationRow);
    await pumpEventually(tester);
    await tester.ensureVisible(peopleTile);
    await pumpEventually(tester);
    await tester.tap(peopleTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-workspace',
      scopeType: 'location',
      orgUnitId: 'org-root',
      locationId: 'loc-workspace',
    );
    expect(scopes, hasLength(3));
    expect(scopes.last.operatorId, 'op-workspace');
    expect(scopes.last.scopeType, AdminHierarchyScopeType.location);
    expect(scopes.last.locationId, 'loc-workspace');
    expect(scopes.last.operatorName, 'Workspace Cafe');
    expect(scopes.last.orgUnitId, 'org-root');
    expect(scopes.last.orgUnitName, 'Workspace root');
    expect(scopes.last.locationName, 'HQ');
  });

  testWidgets('search filters operators by operator and location text', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
        seedBundle(
          operatorId: 'op-2',
          businessName: 'Beta Bistro',
          primaryLocationId: 'loc-beta',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'beta',
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operator_row_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'toronto',
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operator_row_op-1')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'zzzz',
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_no_matches')), findsOneWidget);
  });

  testWidgets('stacks master/detail panes on compact widths', (tester) async {
    tester.view.physicalSize = const Size(520, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-compact',
          businessName: 'Very Long Compact Width Operator Name',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_list')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_operator_detail_op-compact')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the empty state when no operators are seeded', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway();
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_empty')), findsOneWidget);
    expect(find.text('No business accounts yet'), findsOneWidget);
  });

  testWidgets('location vendor action is a manage integrations button', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-seed-1'),
    );
    await tester.ensureVisible(locationRow);
    await pumpEventually(tester);
    await tester.tap(locationRow);
    await pumpEventually(tester);

    final integrationsTile = find.byKey(
      const Key('admin_business_setup_tile_integrations'),
    );
    await tester.ensureVisible(integrationsTile);
    await pumpEventually(tester);

    expect(integrationsTile, findsOneWidget);
    expect(find.text('Integrations'), findsOneWidget);

    await tester.tap(integrationsTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-seed-1',
      scopeType: 'location',
      locationId: 'loc-seed-1',
    );

    expect(
      find.byKey(const Key('admin_vendor_connections_screen')),
      findsOneWidget,
    );
  });

  testWidgets(
    'business Integrations tile requires a location and then mounts live gateway',
    (tester) async {
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(
            operatorId: 'op-integrations',
            primaryLocationId: 'loc-integrations',
            businessName: 'Integrations Cafe',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            vendorConnectionsGateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
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
        operatorId: 'op-integrations',
        scopeType: 'business',
      );

      expect(
        find.byKey(const Key('admin_vendor_connections_location_required')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_scope_prompt')),
        findsNothing,
      );

      await tester.tap(find.byKey(kAdminBusinessAccountsBackButtonKey));
      await pumpEventually(tester);

      final locationRow = find.byKey(
        const Key('admin_hierarchy_location_loc-integrations'),
      );
      await tester.ensureVisible(locationRow);
      await pumpEventually(tester);
      await tester.tap(locationRow);
      await pumpEventually(tester);
      await tester.ensureVisible(integrationsTile);
      await pumpEventually(tester);
      await tester.tap(integrationsTile);
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_hierarchy_scope_prompt')),
        findsNothing,
      );

      expect(
        find.byKey(const Key('admin_vendor_connections_location_required')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('vendor_connections_section_pos')),
        findsOneWidget,
      );
    },
  );
}
