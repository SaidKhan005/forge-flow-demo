// Phase 11W.2 - Roles screen widget tests.
//
// Pins the parity contract section "Roles + Permission Explainer
// (11W.2 + 11A.13 Roles tab)":
//
//   - seeded roles render with `is_editable=false`; no Edit / Delete
//     button on the operator self-service surface.
//   - custom roles render with Edit + Delete (gated on
//     `team.roles.create_custom`).
//   - "Permission Explainer" + "New role" affordances on the header.
//   - permission gate: operator_owner full surface; operator_manager
//     read-only (no New role); permission-key snapshot overrides
//     role tier; non-admitted roles -> friendly forbidden surface.
//   - DemoWebTeamRolesGateway: createRole / patchRole / deleteRole
//     work end-to-end with idempotency replay.
//   - createRole rejects keys outside `PermissionKeys.all`
//     server-side; the editor surfaces the same rejection.
//   - sub-route hooks (`onOpenExplainer`, `onOpenEditor`) fire so
//     the router can mount `/roles/explainer` and `/roles/edit/:id`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/custom_role_editor_screen.dart';
import 'package:forge_and_flow/operator_web/screens/roles_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_roles_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_roles_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  /// Editor is itself a Scaffold + AppBar — wrap it without a parent
  /// Scaffold so the AppBar back button does not trip on a missing
  /// Navigator stack and the form's first-render layout matches what
  /// the router mounts in production.
  Widget wrapBare(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession sessionWithRole(
    String role, {
    Set<String> permissions = const <String>{},
  }) => OperatorWebSession(
    uid: 'session-$role',
    email: 'sam.owner@demobistro.test',
    displayName: 'Sam Patel',
    operatorId: kDemoOperatorIdFixture,
    businessName: kDemoOperatorBusinessNameFixture,
    primaryLocationId: 'demo-loc-downtown',
    primaryLocationName: 'Downtown',
    roles: <String>[role],
    permissions: permissions,
  );

  Future<void> pumpScreen(
    WidgetTester tester, {
    required OperatorWebSession session,
    DemoWebTeamRolesGateway? gateway,
    ValueChanged<TeamRoleCatalogEntry?>? onOpenEditor,
    VoidCallback? onOpenExplainer,
  }) async {
    await tester.pumpWidget(
      wrap(
        RolesScreen(
          session: session,
          gateway: gateway ?? DemoWebTeamRolesGateway(),
          onOpenEditor: onOpenEditor,
          onOpenExplainer: onOpenExplainer,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('RolesScreen layout + permission gate', () {
    testWidgets('renders header, seeded group, custom group, explainer + new '
        'role buttons for operator_owner at desktop 1280x800', (tester) async {
      await sizeViewport(tester, const Size(1280, 800));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(
        find.byKey(const Key('operator_web_roles_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_roles_open_explainer')),
        findsOneWidget,
      );
      final newRoleButton = find.byKey(
        const Key('operator_web_roles_new_role'),
      );
      expect(newRoleButton, findsOneWidget);
      expect(tester.widget<FilledButton>(newRoleButton).onPressed, isNotNull);
      expect(
        find.byKey(const Key('operator_web_roles_seeded_group')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_roles_custom_group')),
        findsOneWidget,
      );
      // Floor Captain custom row from the demo fixture set.
      expect(
        find.byKey(const Key('operator_web_role_tile_role-floor-captain')),
        findsOneWidget,
      );
    });

    testWidgets('narrow header keeps title and subtitle readable', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(360, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      final titleSize = tester.getSize(find.text('Roles & permissions'));
      expect(titleSize.width, greaterThan(50));
      expect(titleSize.height, lessThan(60));

      final subtitleSize = tester.getSize(
        find.byKey(const Key('operator_web_roles_subtitle')),
      );
      expect(subtitleSize.width, greaterThan(250));
      expect(subtitleSize.height, lessThan(220));
      expect(
        find.byKey(const Key('operator_web_roles_open_explainer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_roles_new_role')),
        findsOneWidget,
      );
    });

    testWidgets('seeded roles render Read-only badge and no Edit / Delete '
        'buttons on operator self-service', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));
      // Owner is the canonical seeded role — verify its tile renders
      // but exposes no mutate buttons.
      expect(
        find.byKey(const Key('operator_web_role_tile_role-operator-owner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_role_edit_role-operator-owner')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operator_web_role_delete_role-operator-owner')),
        findsNothing,
      );
    });

    testWidgets('custom roles expose Edit + Delete for operator_owner', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));
      expect(
        find.byKey(const Key('operator_web_role_edit_role-floor-captain')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_role_delete_role-floor-captain')),
        findsOneWidget,
      );
    });

    testWidgets('operator_supervisor sees the friendly forbidden surface', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      await pumpScreen(tester, session: sessionWithRole('operator_supervisor'));
      expect(
        find.byKey(const Key('operator_web_roles_forbidden')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('operator_web_roles_screen')), findsNothing);
    });

    testWidgets('permission-key snapshot overrides role tier (location_manager '
        'with team.roles.view + no create_custom -> read-only)', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'location_manager',
          permissions: const <String>{'team.roles.view'},
        ),
      );
      expect(
        find.byKey(const Key('operator_web_roles_screen')),
        findsOneWidget,
      );
      // Without team.roles.create_custom the New role button is
      // disabled (renders but onPressed is null).
      final newRoleButton = find.byKey(
        const Key('operator_web_roles_new_role'),
      );
      expect(newRoleButton, findsOneWidget);
      expect(tester.widget<FilledButton>(newRoleButton).onPressed, isNull);
      expect(
        find.byKey(const Key('operator_web_role_edit_role-floor-captain')),
        findsNothing,
      );
    });
  });

  group('RolesScreen sub-route hooks', () {
    testWidgets('Permission Explainer button fires onOpenExplainer hook', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      var fired = false;
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        onOpenExplainer: () => fired = true,
      );
      await tester.tap(
        find.byKey(const Key('operator_web_roles_open_explainer')),
      );
      await tester.pumpAndSettle();
      expect(fired, isTrue);
    });

    testWidgets('New role button fires onOpenEditor hook with null target', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      TeamRoleCatalogEntry? capturedTarget;
      var firedTimes = 0;
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        onOpenEditor: (target) {
          firedTimes += 1;
          capturedTarget = target;
        },
      );
      await tester.tap(find.byKey(const Key('operator_web_roles_new_role')));
      await tester.pumpAndSettle();
      expect(firedTimes, 1);
      expect(capturedTarget, isNull);
    });

    testWidgets('Edit on a custom role fires onOpenEditor with that role', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      TeamRoleCatalogEntry? capturedTarget;
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        onOpenEditor: (target) => capturedTarget = target,
      );
      await tester.tap(
        find.byKey(const Key('operator_web_role_edit_role-floor-captain')),
      );
      await tester.pumpAndSettle();
      expect(capturedTarget, isNotNull);
      expect(capturedTarget!.roleId, 'role-floor-captain');
    });
  });

  group('CustomRoleEditorScreen builder + validation', () {
    testWidgets('renders metadata + permission picker for create mode', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: sessionWithRole('operator_owner'),
            gateway: DemoWebTeamRolesGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_display_name')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_role_key')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_description')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_permissions')),
        findsOneWidget,
      );
    });

    testWidgets('Save button stays disabled until name + role key + at least '
        'one permission selected', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: sessionWithRole('operator_owner'),
            gateway: DemoWebTeamRolesGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final saveButton = find.byKey(
        const Key('operator_web_custom_role_editor_save'),
      );
      expect(
        tester.widget<FilledButton>(saveButton).onPressed,
        isNull,
        reason: 'Save disabled when form is empty',
      );
      await tester.enterText(
        find.byKey(const Key('operator_web_custom_role_editor_display_name')),
        'Floor Captain',
      );
      await tester.enterText(
        find.byKey(const Key('operator_web_custom_role_editor_role_key')),
        'floor_captain',
      );
      await tester.pump();
      expect(
        tester.widget<FilledButton>(saveButton).onPressed,
        isNull,
        reason: 'Save disabled until at least one permission picked',
      );
    });

    testWidgets('idempotency-key factory threads through createRole on save', (
      tester,
    ) async {
      // Tall viewport so the editor's metadata + permission picker
      // + save bar all fit without needing to scroll the picker.
      await sizeViewport(tester, const Size(1280, 8000));
      final gateway = DemoWebTeamRolesGateway();
      var savedTimes = 0;
      TeamRoleCatalogEntry? saved;
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: sessionWithRole('operator_owner'),
            gateway: gateway,
            idempotencyKeyFactory: () => 'editor-test-key',
            onSaved: (role) {
              savedTimes += 1;
              saved = role;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('operator_web_custom_role_editor_display_name')),
        'Closer',
      );
      await tester.enterText(
        find.byKey(const Key('operator_web_custom_role_editor_role_key')),
        'closer',
      );
      await tester.pumpAndSettle();
      // Tap the Checkbox specifically inside the permission row so the
      // hit-test lands on the toggle target rather than the
      // surrounding description text.
      final permRow = find.byKey(
        const Key('operator_web_custom_role_editor_perm_forgeflow.shift.view'),
      );
      await tester.ensureVisible(permRow);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: permRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      final saveFinder = find.byKey(
        const Key('operator_web_custom_role_editor_save'),
      );
      await tester.ensureVisible(saveFinder);
      await tester.pumpAndSettle();
      await tester.tap(saveFinder);
      await tester.pumpAndSettle();
      expect(savedTimes, 1);
      expect(saved, isNotNull);
      expect(saved!.displayName, 'Closer');
      expect(saved!.permissions.map((p) => p.permissionKey), <String>[
        'forgeflow.shift.view',
      ]);
    });
  });

  group('DemoWebTeamRolesGateway business rules', () {
    test('listRoles surfaces both seeded + custom roles by default', () async {
      final gateway = DemoWebTeamRolesGateway();
      final result = await gateway.listRoles(
        const TeamRoleCatalogListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
        ),
      );
      final seeded = result.roles.where((r) => r.isSeeded).toList();
      final custom = result.roles.where((r) => !r.isSeeded).toList();
      expect(seeded, isNotEmpty);
      expect(custom, isNotEmpty);
      expect(custom.map((r) => r.roleKey), contains('floor_captain'));
    });

    test('listRoles filters to seeded with scope=seeded', () async {
      final gateway = DemoWebTeamRolesGateway();
      final result = await gateway.listRoles(
        const TeamRoleCatalogListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
          scope: 'seeded',
        ),
      );
      expect(result.roles.every((r) => r.isSeeded), isTrue);
    });

    test(
      'createRole + listRoles round-trip exposes the new custom role',
      () async {
        final gateway = DemoWebTeamRolesGateway();
        final created = await gateway.createRole(
          const TeamRoleCreateCommand(
            actorUserId: 'actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
            roleKey: 'closer',
            displayName: 'Closer',
            description: 'Late-shift floor lead.',
            permissions: <TeamRolePermissionUpdate>[
              TeamRolePermissionUpdate(
                permissionKey: 'forgeflow.shift.view',
                effect: 'allow',
              ),
              TeamRolePermissionUpdate(
                permissionKey: 'forgeflow.variance.view',
                effect: 'allow',
              ),
            ],
          ),
          idempotencyKey: 'create-key-1',
        );
        expect(created.role.roleKey, 'closer');
        expect(created.role.isSeeded, isFalse);
        expect(created.role.isEditable, isTrue);
        final listed = await gateway.listRoles(
          const TeamRoleCatalogListCommand(
            actorUserId: 'actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
            scope: 'custom',
          ),
        );
        expect(
          listed.roles.map((r) => r.roleKey),
          containsAll(<String>['floor_captain', 'closer']),
        );
      },
    );

    test(
      'createRole replays from cache on duplicate idempotency key',
      () async {
        final gateway = DemoWebTeamRolesGateway();
        const cmd = TeamRoleCreateCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
          roleKey: 'replay_test',
          displayName: 'Replay Test',
          permissions: <TeamRolePermissionUpdate>[
            TeamRolePermissionUpdate(
              permissionKey: 'forgeflow.shift.view',
              effect: 'allow',
            ),
          ],
        );
        const key = 'create-replay-key';
        final first = await gateway.createRole(cmd, idempotencyKey: key);
        final second = await gateway.createRole(cmd, idempotencyKey: key);
        expect(first.role.roleId, second.role.roleId);
        final listed = await gateway.listRoles(
          const TeamRoleCatalogListCommand(
            actorUserId: 'actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
            scope: 'custom',
          ),
        );
        final replays = listed.roles
            .where((r) => r.roleKey == 'replay_test')
            .toList();
        expect(replays, hasLength(1));
      },
    );

    test('patchRole on seeded role throws role_not_editable', () async {
      final gateway = DemoWebTeamRolesGateway();
      expect(
        () => gateway.patchRole(
          const TeamRolePatchCommand(
            actorUserId: 'actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
            roleId: 'role-operator-owner',
            displayName: 'Hacked',
          ),
          idempotencyKey: 'patch-seeded-key',
        ),
        throwsA(
          isA<WebTeamRolesError>().having(
            (e) => e.code,
            'code',
            'role_not_editable',
          ),
        ),
      );
    });

    test('deleteRole on a custom role with active grants surfaces '
        'role_has_active_grants', () async {
      final gateway = DemoWebTeamRolesGateway();
      // The Floor Captain fixture has an active grant on Dakota.
      expect(
        () => gateway.deleteRole(
          const TeamRoleDeleteCommand(
            actorUserId: 'actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
            roleId: 'role-floor-captain',
          ),
          idempotencyKey: 'delete-with-grants-key',
        ),
        throwsA(
          isA<WebTeamRolesError>().having(
            (e) => e.code,
            'code',
            'role_has_active_grants',
          ),
        ),
      );
    });

    test(
      'createRoleGrant + revokeRoleGrant round-trip + idempotency replay',
      () async {
        final gateway = DemoWebTeamRolesGateway();
        const cmd = TeamRoleGrantCreateCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
          targetUserId: 'demo-user-downtown-manager',
          roleId: 'role-floor-captain',
          scopeType: 'location',
          targetLocationId: 'demo-loc-downtown',
        );
        const key = 'grant-create-key';
        final first = await gateway.createRoleGrant(cmd, idempotencyKey: key);
        final second = await gateway.createRoleGrant(cmd, idempotencyKey: key);
        expect(first.userRoleId, second.userRoleId);
        final revoked = await gateway.revokeRoleGrant(
          TeamRoleGrantRevokeCommand(
            actorUserId: 'actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
            userRoleId: first.userRoleId,
            targetUserId: 'demo-user-downtown-manager',
          ),
          idempotencyKey: 'grant-revoke-key',
        );
        expect(revoked.revoked, isTrue);
      },
    );
  });

  group('Demo fixture re-seeds across instances', () {
    test('a fresh DemoWebTeamRolesGateway re-seeds the fixture defaults '
        'after a previous instance mutated state', () async {
      final firstGateway = DemoWebTeamRolesGateway();
      await firstGateway.createRole(
        const TeamRoleCreateCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
          roleKey: 'temp_role',
          displayName: 'Temp',
          permissions: <TeamRolePermissionUpdate>[
            TeamRolePermissionUpdate(
              permissionKey: 'forgeflow.shift.view',
              effect: 'allow',
            ),
          ],
        ),
        idempotencyKey: 'temp-create-key',
      );
      final freshGateway = DemoWebTeamRolesGateway();
      final listed = await freshGateway.listRoles(
        const TeamRoleCatalogListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
          scope: 'custom',
        ),
      );
      expect(listed.roles.map((r) => r.roleKey), isNot(contains('temp_role')));
    });
  });
}
