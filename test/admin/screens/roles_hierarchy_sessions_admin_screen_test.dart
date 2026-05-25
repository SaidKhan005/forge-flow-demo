// Phase 11A.13 - Admin Roles + permissions widget tests.
//
// Admin aligns to the operator-web Roles surface. The only accepted
// admin-shell difference is the surrounding operator scope picker/chrome;
// this screen must not expose hierarchy tabs or hierarchy mutations.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  group('roles surface parity', () {
    testWidgets('renders roles directly with no hierarchy tab surface', (
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

      expect(find.byKey(const Key('admin_rhs_roles_screen')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_roles_tab')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_tab_bar')), findsNothing);
      expect(find.byKey(const Key('admin_rhs_tab_roles')), findsNothing);
      expect(find.byKey(const Key('admin_rhs_tab_hierarchy')), findsNothing);
      expect(find.text('Role policy'), findsNothing);
      expect(find.text('Location hierarchy'), findsNothing);
      expect(find.text('Roles & permissions'), findsOneWidget);
      expect(find.text('Custom roles (1)'), findsOneWidget);
      expect(find.text('Default roles (10)'), findsOneWidget);
    });

    testWidgets('loads roles only and never pulls hierarchy data', (
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
    });

    testWidgets('default roles have no edit affordance even with admin flag', (
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
        find.byKey(const Key('admin_rhs_role_row_role-seed-operator-owner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_rhs_role_edit_role-seed-operator-owner')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_rhs_role_delete_role-seed-operator-owner')),
        findsNothing,
      );
    });

    testWidgets('read-only mode disables custom-role mutations', (
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
        find.byKey(const Key('admin_rhs_role_edit_role-custom-floor-captain')),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('admin_rhs_role_delete_role-custom-floor-captain'),
        ),
        findsNothing,
      );
    });
  });

  group('custom role actions', () {
    testWidgets(
      'create custom role requires admin reason and writes an audit row',
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

        await tester.tap(find.byKey(const Key('admin_rhs_roles_new_role')));
        await pumpEventually(tester);

        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_name')),
          'Line Lead',
        );
        await selectRoleEditorPermission(tester, 'forgeflow.shift.edit');
        await pumpEventually(tester);

        final disabledSubmit = tester.widget<FilledButton>(
          find.byKey(const Key('admin_rhs_create_custom_role_submit')),
        );
        expect(disabledSubmit.onPressed, isNull);
        expect(gateway.capturedAuditEvents, isEmpty);

        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_reason')),
          'support onboarding',
        );
        await pumpEventually(tester);
        await tester.tap(
          find.byKey(const Key('admin_rhs_create_custom_role_submit')),
        );
        await pumpEventually(tester);

        final event = gateway.capturedAuditEvents.single;
        expect(event.action, equals('team.roles.create_custom'));
        expect(event.actorKind, equals('forge_admin'));
        expect(event.actorUserId, equals('demo-super-admin'));
        expect(event.adminReason, equals('support onboarding'));
        expect(
          event.payload['permission_keys'],
          containsAll(<String>['forgeflow.shift.view', 'forgeflow.shift.edit']),
        );
      },
    );

    testWidgets('delete custom role confirms before admin reason', (
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

      await tester.tap(
        find.byKey(
          const Key('admin_rhs_role_delete_role-custom-floor-captain'),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_rhs_delete_role_confirm')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_rhs_reason_dialog')), findsNothing);

      await tester.tap(find.byKey(const Key('admin_rhs_delete_role_confirm')));
      await pumpEventually(tester);

      expect(find.byKey(const Key('admin_rhs_reason_dialog')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('admin_rhs_reason_field')),
        'cleanup duplicate role',
      );
      await tester.tap(find.byKey(const Key('admin_rhs_reason_submit')));
      await pumpEventually(tester);

      final event = gateway.capturedAuditEvents.singleWhere(
        (event) => event.action == 'team.roles.delete_custom',
      );
      expect(event.adminReason, equals('cleanup duplicate role'));
      expect(event.actorKind, equals('forge_admin'));
    });

    testWidgets('edit custom role writes audit row', (tester) async {
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
        find.byKey(const Key('admin_rhs_role_edit_role-custom-floor-captain')),
      );
      await pumpEventually(tester);

      expect(find.text('Edit role'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_rhs_custom_role_editor_search')),
        findsOneWidget,
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
      expect(
        event.payload['display_name'],
        equals(<String, Object?>{
          'from': 'Floor Captain',
          'to': 'Shift Captain',
        }),
      );
    });
  });

  group('custom role warning panel', () {
    testWidgets('advisory warning appears in create dialog', (tester) async {
      wideViewport(tester);
      CustomRoleDraft? draft;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                draft = await showDialog<CustomRoleDraft>(
                  context: context,
                  builder: (_) => const CreateCustomRoleDialog(
                    existingRoleKeys: <String>{},
                    validator: _AlwaysWarnValidator(),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await pumpEventually(tester);

      await tester.enterText(
        find.byKey(const Key('admin_rhs_create_custom_role_name')),
        'Line Lead',
      );
      await selectRoleEditorPermission(tester, 'forgeflow.shift.edit');
      await tester.enterText(
        find.byKey(const Key('admin_rhs_create_custom_role_reason')),
        'support onboarding',
      );
      await pumpEventually(tester);

      expect(find.text(_AlwaysWarnValidator.kMessage), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('admin_rhs_create_custom_role_submit')),
      );
      await pumpEventually(tester);
      expect(draft?.displayName, equals('Line Lead'));
    });
  });

  group('active sessions panel', () {
    testWidgets('renders sessions and blocks the admin from revoking self', (
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
            actorUserId: 'demo-user-diner-owner',
          ),
        ),
      );
      await pumpEventually(tester);

      expect(find.text('People and devices signed in'), findsOneWidget);
      expect(
        find.byKey(
          const Key('admin_rhs_session_row_session-diner-owner-mobile'),
        ),
        findsOneWidget,
      );
      final ownButton = tester.widget<OutlinedButton>(
        find.byKey(
          const Key(
            'admin_rhs_session_force_logout_session-diner-owner-mobile',
          ),
        ),
      );
      expect(ownButton.onPressed, isNull);
    });
  });

  group('copy hygiene', () {
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

      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final text in texts) {
        final data = text.data;
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
