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
// Shared fixtures (`wrap`, `seedBundle`) and bounded pump helpers
// (`pumpEventually`) live in `admin_operator_location_test_helpers.dart`
// and `_test_helpers/widget_pump_helpers.dart`, respectively, so each
// split file imports a single source of truth.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/admin_responsive_layout.dart';

import '_test_helpers/widget_pump_helpers.dart';
import 'admin_operator_location_test_helpers.dart';

void main() {
  testWidgets('operator AI plan selection is read-only while coming soon', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    expect(find.text('Forge & Flow AI plan'), findsOneWidget);
    final detailRow = tester.widget<AdminDetailRow>(
      find.byKey(const Key('admin_operator_ai_plan_detail_row')),
    );
    expect(detailRow.muted, isTrue);

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

  testWidgets('add location requires a selected hierarchy org unit', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    final addButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('admin_operator_add_location_button')),
    );
    expect(addButton.onPressed, isNull);
    expect(
      find.byKey(const Key('admin_location_parent_org_unit_required_copy')),
      findsOneWidget,
    );
  });

  testWidgets('business hierarchy manager creates a child org unit', (
    tester,
  ) async {
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
      expect(
        find.byKey(const Key('admin_operator_row_op-override')),
        findsOneWidget,
      );
    },
  );

  testWidgets('admin shell with ff_support renders operators read-only', (
    tester,
  ) async {
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
    expect(find.byKey(const Key('admin_operator_edit_button')), findsNothing);
  });
}
