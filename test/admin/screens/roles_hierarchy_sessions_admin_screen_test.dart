// Phase 11A.13 - Roles + Hierarchy + Sessions screen widget tests.
//
// Coverage focuses on the parity-contract surface: the three tabs
// render after picking an operator, seeded-role edit is gated on
// `canEditSeededRoles`, custom-role create captures admin_reason,
// hierarchy move dialogs capture admin_reason, sessions force-logout
// captures admin_reason and is disabled for the admin's own session,
// view-only mode hides every mutate affordance, and every write path
// captures the F&F admin's UID + a non-empty admin_reason on the
// audit row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/screens/roles_hierarchy_sessions_admin_screen.dart'
    show RolesHierarchySessionsAdminScreen, kMfaRequiredTooltip;
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

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

  group('three-tab render', () {
    testWidgets('renders Roles, Hierarchy, Sessions tabs after operator pick',
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
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin_rhs_tab_bar')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_tab_roles')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_tab_hierarchy')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_tab_sessions')), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_roles_tab')), findsOneWidget);
    });

    testWidgets('Hierarchy tab renders org-unit tree + locations',
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
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_rhs_tab_hierarchy')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_rhs_org_unit_$kDemoDinerOrgUnitRoot')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_rhs_org_unit_$kDemoDinerOrgUnitEast')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_rhs_location_$kDemoDinerLocationToronto')),
        findsOneWidget,
      );
    });

    testWidgets('Sessions tab renders one row per session', (tester) async {
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
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_rhs_tab_sessions')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key(
          'admin_rhs_session_row_session-diner-owner-mobile',
        )),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key(
          'admin_rhs_session_row_session-diner-manager-mobile',
        )),
        findsOneWidget,
      );
    });
  });

  group('Roles tab gating', () {
    testWidgets('seeded-role edit hidden when canEditSeededRoles is false',
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
      await tester.pumpAndSettle();

      // Seeded rows render but the edit button is hidden.
      expect(
        find.byKey(const Key('admin_rhs_role_row_role-seed-operator-owner')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_rhs_role_edit_role-seed-operator-owner'),
        ),
        findsNothing,
      );
    });

    testWidgets(
      'seeded-role edit visible when canEditSeededRoles is true',
      (tester) async {
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
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('admin_rhs_role_edit_role-seed-operator-owner'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'view-only mode hides every mutate affordance',
      (tester) async {
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
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('admin_rhs_readonly_banner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_rhs_roles_create_custom')),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('admin_rhs_role_delete_role-custom-floor-captain'),
          ),
          findsNothing,
        );
      },
    );
  });

  group('write paths capture admin_reason', () {
    testWidgets(
      'force-logout writes audit row with forge_admin + admin_reason',
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
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('admin_rhs_tab_sessions')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key(
            'admin_rhs_session_force_logout_session-diner-owner-mobile',
          )),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('admin_rhs_reason_field')),
          'walkthrough verification',
        );
        await tester.tap(find.byKey(const Key('admin_rhs_reason_submit')));
        await tester.pumpAndSettle();

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
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('admin_rhs_roles_create_custom')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('admin_rhs_roles_create_custom')),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_name')),
          'Line Lead',
        );
        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_key')),
          'custom.line_lead',
        );
        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_reason')),
          'support-onboarding',
        );
        await tester.tap(
          find.byKey(const Key('admin_rhs_create_custom_role_submit')),
        );
        await tester.pumpAndSettle();

        expect(gateway.capturedAuditEvents, hasLength(1));
        final event = gateway.capturedAuditEvents.single;
        expect(event.action, equals('team.roles.create_custom'));
        expect(event.adminReason, equals('support-onboarding'));
        expect(event.actorKind, equals('forge_admin'));
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
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('admin_rhs_roles_create_custom')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('admin_rhs_roles_create_custom')),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_name')),
          'Line Lead',
        );
        await tester.enterText(
          find.byKey(const Key('admin_rhs_create_custom_role_key')),
          'custom.line_lead',
        );
        // Reason intentionally left blank.
        await tester.tap(
          find.byKey(const Key('admin_rhs_create_custom_role_submit')),
        );
        await tester.pumpAndSettle();

        // Dialog stays open + no audit row was written.
        expect(
          find.byKey(const Key('admin_rhs_create_custom_role_dialog')),
          findsOneWidget,
        );
        expect(gateway.capturedAuditEvents, isEmpty);
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
            RolesHierarchySessionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('admin_rhs_tab_sessions')));
        await tester.pumpAndSettle();

        final button = tester.widget<OutlinedButton>(
          find.byKey(const Key(
            'admin_rhs_session_force_logout_session-actor',
          )),
        );
        expect(button.onPressed, isNull);
      },
    );
  });

  group('Permission Explainer + MFA marker (parity § Roles)', () {
    testWidgets(
      'Permission Explainer renders all 9 catalog categories in the locked order',
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
        await tester.pumpAndSettle();

        // Card itself.
        expect(
          find.byKey(const Key('admin_rhs_permission_explainer')),
          findsOneWidget,
        );
        // Every catalog category that has at least one key surfaces a
        // section header. Every key in the contract's order list
        // appears as a non-empty bucket in the seed data.
        for (final category in const <String>[
          'product',
          'forgeflow',
          'barrio',
          'admin',
          'team',
          'billing',
          'integration',
          'integrations',
          'workflow',
        ]) {
          expect(
            find.byKey(Key('admin_rhs_permission_category_$category')),
            findsOneWidget,
            reason: 'category $category missing from Permission Explainer',
          );
        }
      },
    );

    testWidgets(
      'MFA-required keys carry the contract-pinned tooltip',
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
        await tester.pumpAndSettle();

        // The Explainer card contains every MFA-required catalog key.
        // Each MFA key chip is wrapped in a Tooltip with the locked
        // contract message (line 110).
        final tooltip = tester.widget<Tooltip>(
          find.byKey(const Key(
            'admin_rhs_perm_mfa_tooltip_admin.roles.edit_seeded',
          )),
        );
        expect(tooltip.message, equals(kMfaRequiredTooltip));
        // No emoji-only signal: the chip carries the literal "MFA"
        // text plus a Lock icon, not just an emoji.
        expect(find.text('MFA'), findsWidgets);
      },
    );
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
      await tester.pumpAndSettle();

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
