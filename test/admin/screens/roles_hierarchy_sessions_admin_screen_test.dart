// Phase 11A.13 - Roles + Hierarchy + Sessions screen widget tests.
//
// Coverage focuses on the parity-contract surface: the role/hierarchy
// tabs render after picking an operator, seeded-role edit is gated on
// `canEditSeededRoles`, custom-role create captures admin_reason,
// location move dialogs stay live, org-unit moves are visibly gated,
// the reusable sessions panel captures admin_reason and disables the
// admin's own session, view-only mode hides every mutate affordance,
// and every write path captures the F&F admin's UID + a non-empty
// admin_reason on the audit row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/screens/roles_hierarchy_sessions_admin_screen.dart'
    show
        ActiveSessionsAdminPanel,
        CreateCustomRoleDialog,
        CustomRoleDraft,
        RolesHierarchySessionsAdminScreen;
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/domain/hierarchy/org_unit_depth_rule.dart';
import 'package:forge_and_flow/services/auth/custom_role_validator.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '../../_test_helpers/widget_pump_helpers.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  OperatorPickerResult demoPick() => const OperatorPickerResult(
    operatorId: kDemoDinerOperatorId,
    locationId: kDemoDinerLocationToronto,
    operatorBusinessName: 'Demo Diner Co.',
    locationName: 'Toronto Yorkville',
  );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  InMemoryRolesHierarchySessionsAdminGateway buildDemoGateway() {
    return InMemoryRolesHierarchySessionsAdminGateway(
      rolesByOperator: kDemoRolesByOperator(),
      orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      locationsByOperator: kDemoHierarchyLocationsByOperator(),
      sessionsByOperator: kDemoSessionsByOperator(),
    );
  }

  Future<void> selectRoleEditorPermission(
    WidgetTester tester,
    String permissionKey, {
    String keyPrefix = 'admin_rhs_custom_role_editor',
  }) async {
    final checkbox = find.byKey(
      Key('${keyPrefix}_perm_${permissionKey}_checkbox'),
    );
    await tester.ensureVisible(checkbox);
    await pumpEventually(tester);
    await tester.tap(checkbox);
    await pumpEventually(tester);
  }

  group('role and hierarchy render', () {
    testWidgets('renders Roles and Hierarchy tabs after operator pick', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(find.byKey(const Key('admin_rhs_tab_bar')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_tab_roles')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_tab_hierarchy')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_tab_sessions')), findsNothing);
      expect(find.byKey(const Key('admin_rhs_roles_tab')), findsOneWidget);
      expect(find.text('Scope context'), findsNothing);
      expect(find.text('Selected location scope'), findsNothing);
    });

    testWidgets('renders provided hierarchy scope context', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            initialScope: const AdminHierarchyScopeIntent.orgUnit(
              operatorId: kDemoDinerOperatorId,
              orgUnitId: kDemoDinerOrgUnitEast,
              operatorName: 'Demo Diner Co.',
              orgUnitName: 'East Region',
            ),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(find.text('Selected org unit scope'), findsNothing);
      expect(find.text('Demo Diner Co. / East Region'), findsNothing);
    });

    testWidgets('loads only the selected tab until another tab is opened', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = _CountingRolesHierarchySessionsGateway(
        rolesByOperator: kDemoRolesByOperator(),
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
        sessionsByOperator: kDemoSessionsByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(gateway.listRolesCalls, equals(1));
      expect(gateway.listOrgUnitsCalls, equals(0));
      expect(gateway.listHierarchyLocationsCalls, equals(0));
      expect(gateway.listSessionsCalls, equals(0));

      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      expect(gateway.listRolesCalls, equals(1));
      expect(gateway.listOrgUnitsCalls, equals(1));
      expect(gateway.listHierarchyLocationsCalls, equals(1));
      expect(gateway.listSessionsCalls, equals(0));
    });

    testWidgets('Hierarchy tab renders org-unit tree + locations', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_rhs_org_unit_$kDemoDinerOrgUnitRoot')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('inheritance_tree')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_rhs_org_unit_$kDemoDinerOrgUnitEast')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_rhs_location_$kDemoDinerLocationToronto')),
        findsOneWidget,
      );
    });

    testWidgets(
      'non-root org units expose no Move button and no gated-move notice',
      (tester) async {
        // Admin-web verbiage parity: operator-web's hierarchy screen has
        // no org-unit Move affordance and no implementation-detail
        // "gated until..." notice, so the admin screen shows neither.
        // Rename / Add child / Delete affordances stay (asserted
        // elsewhere); org-unit moves simply do not exist here.
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            RolesHierarchySessionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
        await pumpEventually(tester);

        expect(
          find.byKey(
            const Key('admin_rhs_org_unit_move_$kDemoDinerOrgUnitEast'),
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('admin_rhs_org_unit_move_$kDemoDinerOrgUnitWest'),
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('admin_rhs_org_unit_move_gated_$kDemoDinerOrgUnitEast'),
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('admin_rhs_org_unit_move_gated_$kDemoDinerOrgUnitWest'),
          ),
          findsNothing,
        );
        expect(find.textContaining('gated until'), findsNothing);
        expect(
          find.byKey(const Key('admin_rhs_move_org_unit_dialog')),
          findsNothing,
        );
      },
    );

    testWidgets('location move button remains live', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      final moveFinder = find.byKey(
        const Key('admin_rhs_location_move_$kDemoDinerLocationToronto'),
      );
      expect(moveFinder, findsOneWidget);
      final button = tester.widget<OutlinedButton>(moveFinder);
      expect(button.onPressed, isNotNull);

      await tester.ensureVisible(moveFinder);
      await tester.tap(moveFinder);
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_rhs_move_location_dialog')),
        findsOneWidget,
      );
    });

    testWidgets('add child org unit affordance writes audited create', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            idempotencyKeyFactory: () => 'idem-add-child-org-unit',
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      final addFinder = find.byKey(
        const Key('admin_rhs_org_unit_add_child_$kDemoDinerOrgUnitRoot'),
      );
      expect(addFinder, findsOneWidget);
      await tester.tap(addFinder);
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_rhs_add_child_org_unit_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_rhs_add_org_unit_name')),
        'North district',
      );
      await tester.enterText(
        find.byKey(const Key('admin_rhs_add_org_unit_reason')),
        'operator requested hierarchy setup',
      );
      await tester.tap(find.byKey(const Key('admin_rhs_add_org_unit_submit')));
      await pumpEventually(tester);

      expect(find.text('North district'), findsOneWidget);
      final event = gateway.capturedAuditEvents.single;
      expect(event.action, equals('team.org_unit.create'));
      expect(event.actorKind, equals('forge_admin'));
      expect(event.actorUserId, equals('demo-super-admin'));
      expect(event.adminReason, equals('operator requested hierarchy setup'));
      expect(event.payload['label'], equals('north_district'));
    });

    testWidgets('add child org unit dialog blocks empty admin_reason', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);
      await tester.tap(
        find.byKey(
          const Key('admin_rhs_org_unit_add_child_$kDemoDinerOrgUnitRoot'),
        ),
      );
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_rhs_add_org_unit_name')),
        'North district',
      );
      await tester.tap(find.byKey(const Key('admin_rhs_add_org_unit_submit')));
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_rhs_add_child_org_unit_dialog')),
        findsOneWidget,
      );
      expect(find.text('Add a reason before continuing.'), findsOneWidget);
      expect(gateway.capturedAuditEvents, isEmpty);
    });

    testWidgets('rename org unit affordance writes audited rename '
        '(GAP A1, forge_admin + admin_reason)', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            idempotencyKeyFactory: () => 'idem-rename-org-unit',
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      // The corp root IS renameable — rename affordance present on the
      // business root (no root carve-out).
      final renameRoot = find.byKey(
        const Key('admin_rhs_org_unit_rename_$kDemoDinerOrgUnitRoot'),
      );
      expect(renameRoot, findsOneWidget);
      await tester.tap(
        find.byKey(
          const Key('admin_rhs_org_unit_rename_$kDemoDinerOrgUnitEast'),
        ),
      );
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_rhs_rename_org_unit_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_rhs_rename_org_unit_name')),
        'Eastern Region',
      );
      await tester.tap(
        find.byKey(const Key('admin_rhs_rename_org_unit_submit')),
      );
      await pumpEventually(tester);

      // Then the shared admin-reason dialog (admin path REQUIRES it).
      await tester.enterText(
        find.byKey(const Key('admin_rhs_reason_field')),
        'operator requested label cleanup',
      );
      await tester.tap(find.byKey(const Key('admin_rhs_reason_submit')));
      await pumpEventually(tester);

      expect(find.text('Eastern Region'), findsOneWidget);
      final renameEvents = gateway.capturedAuditEvents
          .where((e) => e.action == 'team.org_unit.rename')
          .toList();
      expect(renameEvents, hasLength(1));
      expect(renameEvents.single.actorKind, equals('forge_admin'));
      expect(renameEvents.single.actorUserId, equals('demo-super-admin'));
      expect(
        renameEvents.single.adminReason,
        equals('operator requested label cleanup'),
      );
      expect(
        (renameEvents.single.payload['after'] as Map)['name'],
        equals('Eastern Region'),
      );
    });

    testWidgets('rename dialog rejects a duplicate sibling name with the '
        'locked copy (GAP A1)', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      // East + West regions are siblings under root in the demo set.
      await tester.tap(
        find.byKey(
          const Key('admin_rhs_org_unit_rename_$kDemoDinerOrgUnitEast'),
        ),
      );
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_rhs_rename_org_unit_name')),
        'West region',
      );
      await tester.tap(
        find.byKey(const Key('admin_rhs_rename_org_unit_submit')),
      );
      await pumpEventually(tester);

      // Client-side re-validation blocks before the reason prompt.
      expect(
        find.text('An org unit with this name already exists in this group.'),
        findsOneWidget,
      );
      expect(gateway.capturedAuditEvents, isEmpty);
    });

    testWidgets('rename affordance hidden when editing disabled', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            editingEnabled: false,
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      expect(
        find.byKey(
          const Key('admin_rhs_org_unit_rename_$kDemoDinerOrgUnitEast'),
        ),
        findsNothing,
      );
    });

    testWidgets('reusable sessions panel renders one row per session', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          ActiveSessionsAdminPanel(
            gateway: gateway,
            operatorId: kDemoDinerOperatorId,
            operatorName: 'Demo Diner Co.',
            actorUserId: 'demo-super-admin',
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(
          const Key('admin_rhs_session_row_session-diner-owner-mobile'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_rhs_session_row_session-diner-manager-mobile'),
        ),
        findsOneWidget,
      );
      expect(find.text('People and devices signed in'), findsOneWidget);
      expect(find.text("Dana Owner's device"), findsWidgets);
      expect(find.text('Device: '), findsWidgets);
      expect(find.text('Place: '), findsWidgets);
      expect(find.text('Last active: '), findsWidgets);
      expect(find.text('Sign out device'), findsWidgets);
    });
  });

  group('Roles tab gating', () {
    testWidgets('seeded-role edit hidden when canEditSeededRoles is false', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      // Seeded rows render but the edit button is hidden.
      expect(
        find.byKey(const Key('admin_rhs_role_row_role-seed-operator-owner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_rhs_role_edit_role-seed-operator-owner')),
        findsNothing,
      );
    });

    testWidgets('seeded-role edit visible when canEditSeededRoles is true', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            canEditSeededRoles: true,
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_rhs_role_edit_role-seed-operator-owner')),
        findsOneWidget,
      );
    });

    testWidgets('view-only mode disables or hides every mutate affordance', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-ff-support',
            pickedOperator: demoPick(),
            editingEnabled: false,
            canEditSeededRoles: false,
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_rhs_readonly_banner')),
        findsOneWidget,
      );
      final newRole = tester.widget<FilledButton>(
        find.byKey(const Key('admin_rhs_roles_new_role')),
      );
      expect(newRole.onPressed, isNull);
      expect(
        find.byKey(
          const Key('admin_rhs_role_delete_role-custom-floor-captain'),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);
      expect(
        find.byKey(
          const Key('admin_rhs_org_unit_add_child_$kDemoDinerOrgUnitRoot'),
        ),
        findsNothing,
      );
    });
  });

  group('write paths capture admin_reason', () {
    testWidgets(
      'force-logout writes audit row with forge_admin + admin_reason',
      (tester) async {
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            ActiveSessionsAdminPanel(
              gateway: gateway,
              operatorId: kDemoDinerOperatorId,
              operatorName: 'Demo Diner Co.',
              actorUserId: 'demo-super-admin',
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(
          find.byKey(
            const Key(
              'admin_rhs_session_force_logout_session-diner-owner-mobile',
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.enterText(
          find.byKey(const Key('admin_rhs_reason_field')),
          'walkthrough verification',
        );
        await tester.tap(find.byKey(const Key('admin_rhs_reason_submit')));
        await pumpEventually(tester);

        expect(gateway.capturedAuditEvents, hasLength(1));
        final event = gateway.capturedAuditEvents.single;
        expect(event.action, equals('admin.session.force_logout'));
        expect(event.actorKind, equals('forge_admin'));
        expect(event.actorUserId, equals('demo-super-admin'));
        expect(event.adminReason, equals('walkthrough verification'));
      },
    );

    testWidgets(
      'create custom role dialog requires admin_reason and writes audit row',
      (tester) async {
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            RolesHierarchySessionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.ensureVisible(
          find.byKey(const Key('admin_rhs_roles_new_role')),
        );
        await pumpEventually(tester);
        await tester.tap(find.byKey(const Key('admin_rhs_roles_new_role')));
        await pumpEventually(tester);

        expect(
          find.byKey(const Key('admin_rhs_custom_role_editor_search')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('admin_rhs_custom_role_editor_product_forgeflow'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_rhs_create_custom_role_key')),
          findsNothing,
        );
        await selectRoleEditorPermission(tester, 'forgeflow.shift.edit');

        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_name')),
          'Line Lead',
        );
        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_reason')),
          'support-onboarding',
        );
        await pumpEventually(tester);
        await tester.tap(
          find.byKey(const Key('admin_rhs_create_custom_role_submit')),
        );
        await pumpEventually(tester);

        expect(gateway.capturedAuditEvents, hasLength(1));
        final event = gateway.capturedAuditEvents.single;
        expect(event.action, equals('team.roles.create_custom'));
        expect(event.adminReason, equals('support-onboarding'));
        expect(event.actorKind, equals('forge_admin'));
        final permissionKeys = event.payload['permission_keys'];
        expect(
          permissionKeys,
          containsAll(<String>['forgeflow.shift.view', 'forgeflow.shift.edit']),
        );
      },
    );

    testWidgets(
      'create custom role dialog blocks submit with no effective permissions',
      (tester) async {
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            RolesHierarchySessionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.ensureVisible(
          find.byKey(const Key('admin_rhs_roles_new_role')),
        );
        await pumpEventually(tester);
        await tester.tap(find.byKey(const Key('admin_rhs_roles_new_role')));
        await pumpEventually(tester);

        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_name')),
          'Line Lead',
        );
        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_reason')),
          'support-onboarding',
        );
        await pumpEventually(tester);
        final submit = tester.widget<FilledButton>(
          find.byKey(const Key('admin_rhs_create_custom_role_submit')),
        );
        expect(submit.onPressed, isNull);

        expect(
          find.byKey(const Key('admin_rhs_create_custom_role_dialog')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('admin_rhs_create_custom_role_permissions_error'),
          ),
          findsNothing,
        );
        expect(gateway.capturedAuditEvents, isEmpty);
      },
    );

    testWidgets(
      'create custom role dialog blocks submit on empty admin_reason',
      (tester) async {
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            RolesHierarchySessionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.ensureVisible(
          find.byKey(const Key('admin_rhs_roles_new_role')),
        );
        await pumpEventually(tester);
        await tester.tap(find.byKey(const Key('admin_rhs_roles_new_role')));
        await pumpEventually(tester);

        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_name')),
          'Line Lead',
        );
        await selectRoleEditorPermission(tester, 'forgeflow.shift.edit');
        await pumpEventually(tester);
        // Reason intentionally left blank.
        final submit = tester.widget<FilledButton>(
          find.byKey(const Key('admin_rhs_create_custom_role_submit')),
        );
        expect(submit.onPressed, isNull);

        // Dialog stays open + no audit row was written.
        expect(
          find.byKey(const Key('admin_rhs_create_custom_role_dialog')),
          findsOneWidget,
        );
        expect(gateway.capturedAuditEvents, isEmpty);
      },
    );

    testWidgets(
      'edit custom role uses the Ops-shaped editor and writes audit',
      (tester) async {
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            RolesHierarchySessionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(
          find.byKey(
            const Key('admin_rhs_role_edit_role-custom-floor-captain'),
          ),
        );
        await pumpEventually(tester);

        expect(find.text('Edit role'), findsOneWidget);
        expect(
          find.byKey(const Key('admin_rhs_custom_role_editor_search')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_rhs_create_custom_role_key')),
          findsNothing,
        );

        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_name')),
          'Shift Captain',
        );
        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_reason')),
          'support role cleanup',
        );
        await pumpEventually(tester);
        await tester.tap(
          find.byKey(const Key('admin_rhs_create_custom_role_submit')),
        );
        await pumpEventually(tester);

        final event = gateway.capturedAuditEvents.singleWhere(
          (event) => event.action == 'team.roles.update_custom',
        );
        expect(event.adminReason, equals('support role cleanup'));
        expect(event.actorKind, equals('forge_admin'));
        expect(
          event.payload['display_name'],
          equals(<String, Object?>{
            'from': 'Floor Captain',
            'to': 'Shift Captain',
          }),
        );
      },
    );
  });

  group('cannot revoke own admin session', () {
    testWidgets(
      'force-logout button is disabled for a session belonging to the actor',
      (tester) async {
        wideViewport(tester);
        // Seed a fixture where the actor owns one of the sessions; the
        // demo gateway would otherwise throw cannot_revoke_self at the
        // gateway layer. Here we pin the screen-level disable too so
        // the affordance never even fires.
        final actorSeededSessions = <String, List<SessionAdminRow>>{
          kDemoDinerOperatorId: <SessionAdminRow>[
            SessionAdminRow(
              sessionId: 'session-actor',
              userId: 'demo-super-admin',
              userDisplayName: 'F&F Admin',
              userEmail: 'super.admin@forgeflow.test',
              deviceFingerprint: 'Chrome on macOS',
              ipGeoCity: 'Toronto, ON',
              lastActiveAt: DateTime.utc(2026, 5, 5, 11, 30),
              createdAt: DateTime.utc(2026, 5, 5, 9, 0),
            ),
          ],
        };
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          rolesByOperator: kDemoRolesByOperator(),
          orgUnitsByOperator: kDemoOrgUnitsByOperator(),
          locationsByOperator: kDemoHierarchyLocationsByOperator(),
          sessionsByOperator: actorSeededSessions,
        );
        await tester.pumpWidget(
          wrap(
            ActiveSessionsAdminPanel(
              gateway: gateway,
              operatorId: kDemoDinerOperatorId,
              operatorName: 'Demo Diner Co.',
              actorUserId: 'demo-super-admin',
            ),
          ),
        );
        await pumpEventually(tester);

        final button = tester.widget<OutlinedButton>(
          find.byKey(const Key('admin_rhs_session_force_logout_session-actor')),
        );
        expect(button.onPressed, isNull);
      },
    );
  });

  group('GAP A3 - org-unit type label (admin parity)', () {
    testWidgets('renders the real unit_type as plain-English copy, not a '
        'generic synthesized string', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      // Root is corp -> "Business"; East/West are regions -> "Region".
      expect(
        find.descendant(
          of: find.byKey(
            const Key('admin_rhs_org_unit_type_$kDemoDinerOrgUnitRoot'),
          ),
          matching: find.text('Business'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const Key('admin_rhs_org_unit_type_$kDemoDinerOrgUnitEast'),
          ),
          matching: find.text('Region'),
        ),
        findsOneWidget,
      );
      // The old lossy synthesized 'org_unit' string must never surface.
      expect(find.text('org_unit'), findsNothing);
    });

    test('HierarchyValidationCopy.unitTypeLabel maps schema -> friendly', () {
      expect(HierarchyValidationCopy.unitTypeLabel('corp'), 'Business');
      expect(HierarchyValidationCopy.unitTypeLabel('brand'), 'Brand');
      expect(HierarchyValidationCopy.unitTypeLabel('region'), 'Region');
      expect(HierarchyValidationCopy.unitTypeLabel('district'), 'District');
      expect(
        HierarchyValidationCopy.unitTypeLabel('location_group'),
        'Location group',
      );
      expect(HierarchyValidationCopy.unitTypeLabel(null), 'Group');
    });
  });

  group('GAP A2 - admin delete affordance', () {
    testWidgets('confirm dialog then admin_reason deletes an empty org unit '
        'and writes a forge_admin audit row', (tester) async {
      wideViewport(tester);
      // An empty leaf region (no children, no locations) is deletable.
      // Both demo regions hold a location, so we inject an extra empty
      // one under the corp root.
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          kDemoDinerOperatorId: <OrgUnitAdminNode>[
            const OrgUnitAdminNode(
              orgUnitId: kDemoDinerOrgUnitRoot,
              name: 'Demo Diner Co.',
              operatorId: kDemoDinerOperatorId,
              unitType: 'corp',
            ),
            const OrgUnitAdminNode(
              orgUnitId: 'empty-region',
              name: 'Empty Region',
              operatorId: kDemoDinerOperatorId,
              parentOrgUnitId: kDemoDinerOrgUnitRoot,
              unitType: 'region',
            ),
          ],
        },
        locationsByOperator: const <String, List<HierarchyLocationLeaf>>{},
        sessionsByOperator: const <String, List<SessionAdminRow>>{},
      );
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      await tester.tap(
        find.byKey(const Key('admin_rhs_org_unit_delete_empty-region')),
      );
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_rhs_delete_org_unit_dialog')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('admin_rhs_delete_org_unit_confirm')),
      );
      await pumpEventually(tester);

      // Then the shared admin-reason dialog.
      await tester.enterText(
        find.byKey(const Key('admin_rhs_reason_field')),
        'closing the west region',
      );
      await tester.tap(find.byKey(const Key('admin_rhs_reason_submit')));
      await pumpEventually(tester);

      final deleteEvents = gateway.capturedAuditEvents
          .where((e) => e.action == 'team.org_unit.delete')
          .toList();
      expect(deleteEvents, hasLength(1));
      expect(deleteEvents.single.actorKind, equals('forge_admin'));
      expect(deleteEvents.single.actorUserId, equals('demo-super-admin'));
      expect(
        deleteEvents.single.adminReason,
        equals('closing the west region'),
      );
    });

    testWidgets('deleting a non-empty org unit surfaces the friendly '
        'move-things-out message (backend 409)', (tester) async {
      wideViewport(tester);
      // East region contains Toronto Yorkville in the demo set, so the
      // backend refuses with org_unit_not_empty.
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      await tester.tap(
        find.byKey(
          const Key('admin_rhs_org_unit_delete_$kDemoDinerOrgUnitEast'),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(
        find.byKey(const Key('admin_rhs_delete_org_unit_confirm')),
      );
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_rhs_reason_field')),
        'try to delete east',
      );
      await tester.tap(find.byKey(const Key('admin_rhs_reason_submit')));
      await pumpEventually(tester);

      expect(find.text(HierarchyValidationCopy.deleteNotEmpty), findsOneWidget);
      expect(
        gateway.capturedAuditEvents.where(
          (e) => e.action == 'team.org_unit.delete',
        ),
        isEmpty,
      );
    });

    testWidgets('no delete affordance on the business root', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      expect(
        find.byKey(
          const Key('admin_rhs_org_unit_delete_$kDemoDinerOrgUnitRoot'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('admin_rhs_org_unit_delete_$kDemoDinerOrgUnitWest'),
        ),
        findsOneWidget,
      );
    });
  });

  group('GAP A4 - admin depth-cap two-layer guard', () {
    // A 6-deep chain: root -> n2 -> n3 -> n4 -> n5 -> n6. n6 is at the
    // cap; n5 is one below it.
    Map<String, List<OrgUnitAdminNode>> deepChainOrgUnits() {
      return <String, List<OrgUnitAdminNode>>{
        kDemoDinerOperatorId: <OrgUnitAdminNode>[
          const OrgUnitAdminNode(
            orgUnitId: 'n1',
            name: 'Level 1',
            operatorId: kDemoDinerOperatorId,
            unitType: 'corp',
          ),
          const OrgUnitAdminNode(
            orgUnitId: 'n2',
            name: 'Level 2',
            operatorId: kDemoDinerOperatorId,
            parentOrgUnitId: 'n1',
            unitType: 'region',
          ),
          const OrgUnitAdminNode(
            orgUnitId: 'n3',
            name: 'Level 3',
            operatorId: kDemoDinerOperatorId,
            parentOrgUnitId: 'n2',
            unitType: 'district',
          ),
          const OrgUnitAdminNode(
            orgUnitId: 'n4',
            name: 'Level 4',
            operatorId: kDemoDinerOperatorId,
            parentOrgUnitId: 'n3',
            unitType: 'location_group',
          ),
          const OrgUnitAdminNode(
            orgUnitId: 'n5',
            name: 'Level 5',
            operatorId: kDemoDinerOperatorId,
            parentOrgUnitId: 'n4',
            unitType: 'location_group',
          ),
          const OrgUnitAdminNode(
            orgUnitId: 'n6',
            name: 'Level 6',
            operatorId: kDemoDinerOperatorId,
            parentOrgUnitId: 'n5',
            unitType: 'location_group',
          ),
        ],
      };
    }

    testWidgets('parent at the max depth (6): add-child shows locked copy, '
        'no dialog', (tester) async {
      wideViewport(tester);
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
        orgUnitsByOperator: deepChainOrgUnits(),
        locationsByOperator: const <String, List<HierarchyLocationLeaf>>{},
        sessionsByOperator: const <String, List<SessionAdminRow>>{},
      );
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      // The 6-deep synthetic chain is taller than the test viewport
      // (GAP A1 added a third org-unit action). Scroll the deepest
      // node into view before tapping — the depth-cap *behavior* is
      // what this test pins, not pixel layout.
      final addN6 = find.byKey(const Key('admin_rhs_org_unit_add_child_n6'));
      await tester.ensureVisible(addN6);
      await pumpEventually(tester);
      await tester.tap(addN6);
      await pumpEventually(tester);

      expect(
        find.text(HierarchyValidationCopy.depthCapReached),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_rhs_add_child_org_unit_dialog')),
        findsNothing,
      );
    });

    testWidgets('parent one below the cap (5): add-child opens the dialog', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
        orgUnitsByOperator: deepChainOrgUnits(),
        locationsByOperator: const <String, List<HierarchyLocationLeaf>>{},
        sessionsByOperator: const <String, List<SessionAdminRow>>{},
      );
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await pumpEventually(tester);

      // Scroll the depth-5 node into view first (tall synthetic chain).
      final addN5 = find.byKey(const Key('admin_rhs_org_unit_add_child_n5'));
      await tester.ensureVisible(addN5);
      await pumpEventually(tester);
      await tester.tap(addN5);
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_rhs_add_child_org_unit_dialog')),
        findsOneWidget,
      );
      expect(find.text(HierarchyValidationCopy.depthCapReached), findsNothing);
    });

    test('admin depth-cap copy aliases the shared rule copy', () {
      expect(HierarchyValidationCopy.depthCapReached, kOrgUnitDepthCapMessage);
    });
  });

  group('W4 - CustomRoleValidator advisory warnings in create dialog', () {
    // The admin create-custom-role dialog now calls
    // CustomRoleValidator.validate(...) on the ticked permissions and
    // surfaces the resulting advisory warnings, mirroring the
    // operator-web editor. The picker only exposes Forge & Flow keys
    // (all of which auto-satisfy their `*.view` sibling through the
    // implies graph, so a real selection is always coherent); we pin
    // the warning set with an injected stub validator, exactly as the
    // operator-web editor allows for its own tests.
    Future<void> pumpDialog(
      WidgetTester tester, {
      required CustomRoleValidator validator,
      ValueChanged<CustomRoleDraft?>? onResult,
    }) async {
      wideViewport(tester);
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open_dialog'),
                onPressed: () async {
                  final draft = await showDialog<CustomRoleDraft>(
                    context: context,
                    builder: (_) => CreateCustomRoleDialog(
                      existingRoleKeys: const <String>{},
                      validator: validator,
                    ),
                  );
                  onResult?.call(draft);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_dialog')));
      await pumpEventually(tester);
    }

    testWidgets('incoherent draft surfaces the advisory warning banner '
        'and the per-warning row', (tester) async {
      await pumpDialog(tester, validator: const _AlwaysWarnValidator());

      // No permissions ticked yet -> no warnings.
      expect(
        find.byKey(const Key('admin_rhs_create_custom_role_warnings')),
        findsNothing,
      );

      await selectRoleEditorPermission(tester, 'forgeflow.shift.edit');

      // The stub flags any non-empty role: banner + the keyed
      // per-warning row both render.
      expect(
        find.byKey(const Key('admin_rhs_create_custom_role_warnings')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key(
            'admin_rhs_create_custom_role_warning_orphanViewDependency',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Heads up: this role has 1 thing worth a second look'),
        findsOneWidget,
      );
      expect(find.text(_AlwaysWarnValidator.kMessage), findsOneWidget);
    });

    testWidgets('coherent draft shows no warning banner', (tester) async {
      await pumpDialog(tester, validator: const _NeverWarnValidator());

      await selectRoleEditorPermission(tester, 'forgeflow.shift.edit');

      expect(
        find.byKey(const Key('admin_rhs_create_custom_role_warnings')),
        findsNothing,
      );
    });

    testWidgets('warnings are advisory: submit still returns a draft '
        'while a warning is showing', (tester) async {
      CustomRoleDraft? captured;
      var resultSet = false;
      await pumpDialog(
        tester,
        validator: const _AlwaysWarnValidator(),
        onResult: (draft) {
          captured = draft;
          resultSet = true;
        },
      );

      await selectRoleEditorPermission(tester, 'forgeflow.shift.edit');
      expect(
        find.byKey(const Key('admin_rhs_create_custom_role_warnings')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('admin_rhs_create_custom_role_name')),
        'Line Lead',
      );
      await tester.enterText(
        find.byKey(const Key('admin_rhs_create_custom_role_reason')),
        'support-onboarding',
      );
      await pumpEventually(tester);
      await tester.tap(
        find.byKey(const Key('admin_rhs_create_custom_role_submit')),
      );
      await pumpEventually(tester);

      // The warning never blocked submit: the dialog closed and handed
      // back a populated draft.
      expect(resultSet, isTrue);
      expect(captured, isNotNull);
      expect(captured!.displayName, equals('Line Lead'));
      expect(
        captured!.permissionKeys,
        containsAll(<String>['forgeflow.shift.view', 'forgeflow.shift.edit']),
      );
      expect(
        find.byKey(const Key('admin_rhs_create_custom_role_dialog')),
        findsNothing,
      );
    });
  });

  group('zero em dashes in operator-facing literals', () {
    testWidgets('rendered text never contains an em dash', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          RolesHierarchySessionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            editingEnabled: false,
          ),
        ),
      );
      await pumpEventually(tester);

      // Sweep every visible Text widget; none should contain an em dash.
      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final t in texts) {
        final data = t.data;
        if (data == null) continue;
        expect(data.contains('—'), isFalse, reason: data);
      }
    });
  });
}

class _CountingRolesHierarchySessionsGateway
    extends InMemoryRolesHierarchySessionsAdminGateway {
  _CountingRolesHierarchySessionsGateway({
    required super.rolesByOperator,
    required super.orgUnitsByOperator,
    required super.locationsByOperator,
    required super.sessionsByOperator,
  });

  int listRolesCalls = 0;
  int listOrgUnitsCalls = 0;
  int listHierarchyLocationsCalls = 0;
  int listSessionsCalls = 0;

  @override
  Future<List<RoleAdminRow>> listRoles({required String operatorId}) {
    listRolesCalls += 1;
    return super.listRoles(operatorId: operatorId);
  }

  @override
  Future<List<OrgUnitAdminNode>> listOrgUnits({required String operatorId}) {
    listOrgUnitsCalls += 1;
    return super.listOrgUnits(operatorId: operatorId);
  }

  @override
  Future<List<HierarchyLocationLeaf>> listHierarchyLocations({
    required String operatorId,
  }) {
    listHierarchyLocationsCalls += 1;
    return super.listHierarchyLocations(operatorId: operatorId);
  }

  @override
  Future<List<SessionAdminRow>> listSessions({required String operatorId}) {
    listSessionsCalls += 1;
    return super.listSessions(operatorId: operatorId);
  }
}

/// Stub validator that flags any non-empty role with a single advisory
/// warning. Lets the dialog test pin the warning surface without
/// seeding an incoherent permission combination through the picker
/// (which only exposes Forge & Flow keys, all of which auto-satisfy
/// their view sibling). Mirrors the operator-web editor's injectable
/// `validator` test hook.
class _AlwaysWarnValidator extends CustomRoleValidator {
  const _AlwaysWarnValidator();

  static const String kMessage =
      'Test stub: this role looks incoherent and would hide a screen.';

  @override
  List<RoleWarning> validate(
    Set<String> permissionKeys, {
    required RoleScope scope,
    String roleDisplayName = '',
  }) {
    if (permissionKeys.isEmpty) return const <RoleWarning>[];
    return const <RoleWarning>[
      RoleWarning(
        severity: RoleWarningSeverity.warn,
        code: RoleWarningCode.orphanViewDependency,
        affectedKeys: <String>['forgeflow.shift.edit'],
        message: kMessage,
      ),
    ];
  }
}

/// Stub validator that never warns, so the dialog test can assert the
/// banner is absent for a coherent draft.
class _NeverWarnValidator extends CustomRoleValidator {
  const _NeverWarnValidator();

  @override
  List<RoleWarning> validate(
    Set<String> permissionKeys, {
    required RoleScope scope,
    String roleDisplayName = '',
  }) => const <RoleWarning>[];
}
