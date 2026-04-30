// Phase 9.UX.2 — Settings → Team → Roles widget tests.
//
// Covers visibility gates, seeded vs custom rendering, the create flow
// (including failure surfaces), edit-only flow for non-editable roles,
// and the delete confirmation. No live HTTP — every gateway interaction
// is captured by inline test fakes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:forge_and_flow/screens/settings/settings_custom_roles_section.dart';
import 'package:forge_and_flow/screens/settings/settings_role_editor.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';

const TeamScopeActor _ownerActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.roles.view',
    'team.roles.create_custom',
    'team.roles.assign',
    'team.roles.revoke',
  },
);

const TeamScopeActor _readOnlyActor = TeamScopeActor(
  actorRoles: <String>{'operator_manager'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{'loc-1'},
  actorPermissions: <String>{'team.users.view', 'team.roles.view'},
);

const TeamScopeActor _lockedActor = TeamScopeActor(
  actorRoles: <String>{'operator_supervisor'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{'loc-1'},
  actorPermissions: <String>{},
);

TeamRoleCatalogEntry _seededOwner() {
  return const TeamRoleCatalogEntry(
    roleId: 'role-seed-owner',
    roleKey: 'operator_owner',
    displayName: 'Operator Owner',
    description: 'Full operator-scope admin.',
    isSeeded: true,
    isEditable: false,
    permissions: <TeamRolePermissionRule>[
      TeamRolePermissionRule(
        permissionKey: 'team.users.view',
        effect: 'allow',
      ),
      TeamRolePermissionRule(
        permissionKey: 'team.roles.assign',
        effect: 'allow',
      ),
    ],
  );
}

TeamRoleCatalogEntry _seededManager() {
  return const TeamRoleCatalogEntry(
    roleId: 'role-seed-manager',
    roleKey: 'operator_manager',
    displayName: 'Operator Manager',
    description: 'Manager-tier operator user.',
    isSeeded: true,
    isEditable: true,
    permissions: <TeamRolePermissionRule>[
      TeamRolePermissionRule(
        permissionKey: 'team.users.view',
        effect: 'allow',
      ),
    ],
  );
}

TeamRoleCatalogEntry _customKitchenLead({
  String roleId = 'role-custom-1',
  String displayName = 'Kitchen Lead',
}) {
  return TeamRoleCatalogEntry(
    roleId: roleId,
    roleKey: 'kitchen_lead',
    displayName: displayName,
    description: 'Operator-scoped kitchen lead.',
    isSeeded: false,
    isEditable: true,
    operatorId: 'op-1',
    permissions: const <TeamRolePermissionRule>[
      TeamRolePermissionRule(
        permissionKey: 'forgeflow.shift.view',
        effect: 'allow',
      ),
      TeamRolePermissionRule(
        permissionKey: 'forgeflow.shift.edit',
        effect: 'allow',
      ),
    ],
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  group('SettingsCustomRolesSection — visibility', () {
    testWidgets('renders seeded + custom catalog with badges', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SettingsCustomRolesSection(
            actor: _ownerActor,
            roleCatalog: <TeamRoleCatalogEntry>[
              _seededOwner(),
              _seededManager(),
              _customKitchenLead(),
            ],
            onCreateRole: (_) async => null,
            onPatchRole: (_) async => null,
            onDeleteRole: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings_custom_roles_section')),
        findsOneWidget,
      );
      expect(find.text('Custom roles (1)'), findsOneWidget);
      expect(find.text('Seeded roles (2)'), findsOneWidget);
      expect(find.text('Kitchen Lead'), findsOneWidget);
      expect(find.text('Operator Owner'), findsOneWidget);

      // Operator Owner is seeded AND non-editable → renders View, not Edit.
      expect(
        find.byKey(const Key('settings_custom_role_view_role-seed-owner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings_custom_role_edit_role-seed-owner')),
        findsNothing,
      );

      // Operator Manager is seeded with isEditable=true, but the
      // operator-facing surface still treats every seeded role as
      // View-only (seeded edits route through admin.roles.edit_seeded,
      // not team.roles.create_custom). Edit + Delete must stay hidden.
      expect(
        find.byKey(const Key('settings_custom_role_edit_role-seed-manager')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('settings_custom_role_view_role-seed-manager')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings_custom_role_delete_role-seed-manager')),
        findsNothing,
      );

      // Custom roles expose Edit + Delete to an actor with create_custom.
      expect(
        find.byKey(const Key('settings_custom_role_edit_role-custom-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings_custom_role_delete_role-custom-1')),
        findsOneWidget,
      );
    });

    testWidgets('hides catalog from actors without team.roles.view', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SettingsCustomRolesSection(
            actor: _lockedActor,
            roleCatalog: <TeamRoleCatalogEntry>[_customKitchenLead()],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings_custom_roles_locked')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings_custom_roles_section')),
        findsNothing,
      );
    });

    testWidgets('read-only actor sees roles but no create/edit/delete', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SettingsCustomRolesSection(
            actor: _readOnlyActor,
            roleCatalog: <TeamRoleCatalogEntry>[
              _seededManager(),
              _customKitchenLead(),
            ],
            onCreateRole: (_) async => null,
            onPatchRole: (_) async => null,
            onDeleteRole: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings_custom_roles_create_button')),
        findsNothing,
      );
      // Custom + seeded both render View (not Edit) for read-only actors.
      expect(
        find.byKey(const Key('settings_custom_role_edit_role-custom-1')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('settings_custom_role_view_role-custom-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings_custom_role_delete_role-custom-1')),
        findsNothing,
      );
    });
  });

  group('SettingsCustomRolesSection — create flow', () {
    testWidgets('creates a custom role and surfaces a snack', (tester) async {
      final captured = <SettingsRoleEditorResult>[];
      Future<TeamRoleCatalogEntry?> onCreate(
        SettingsRoleEditorResult result,
      ) async {
        captured.add(result);
        return _customKitchenLead(
          roleId: 'role-new-1',
          displayName: result.displayName,
        );
      }

      await tester.pumpWidget(
        _wrap(
          SettingsCustomRolesSection(
            actor: _ownerActor,
            roleCatalog: const <TeamRoleCatalogEntry>[],
            onCreateRole: onCreate,
            onPatchRole: (_) async => null,
            onDeleteRole: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('settings_custom_roles_create_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings_role_editor_dialog')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('settings_role_editor_role_key')),
        'kitchen_lead',
      );
      await tester.enterText(
        find.byKey(const Key('settings_role_editor_display_name')),
        'Kitchen Lead',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('settings_role_editor_save')));
      await tester.pumpAndSettle();

      expect(captured, hasLength(1));
      expect(captured.single.isCreate, isTrue);
      expect(captured.single.roleKey, equals('kitchen_lead'));
      expect(captured.single.displayName, equals('Kitchen Lead'));
      expect(
        find.text('Role "Kitchen Lead" created'),
        findsOneWidget,
      );
    });

    testWidgets('save failure surfaces an inline error', (tester) async {
      Future<TeamRoleCatalogEntry?> onCreate(
        SettingsRoleEditorResult _,
      ) async {
        return null;
      }

      await tester.pumpWidget(
        _wrap(
          SettingsCustomRolesSection(
            actor: _ownerActor,
            roleCatalog: const <TeamRoleCatalogEntry>[],
            onCreateRole: onCreate,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('settings_custom_roles_create_button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('settings_role_editor_role_key')),
        'kitchen_lead',
      );
      await tester.enterText(
        find.byKey(const Key('settings_role_editor_display_name')),
        'Kitchen Lead',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings_role_editor_save')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings_role_editor_error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings_role_editor_dialog')),
        findsOneWidget,
      );
    });

    testWidgets(
      'save button stays disabled when role key violates the rule',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            SettingsCustomRolesSection(
              actor: _ownerActor,
              roleCatalog: const <TeamRoleCatalogEntry>[],
              onCreateRole: (_) async => _customKitchenLead(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('settings_custom_roles_create_button')),
        );
        await tester.pumpAndSettle();

        Future<void> enter(String roleKey) async {
          await tester.enterText(
            find.byKey(const Key('settings_role_editor_role_key')),
            roleKey,
          );
          await tester.enterText(
            find.byKey(const Key('settings_role_editor_display_name')),
            'Test Role',
          );
          await tester.pump();
        }

        FilledButton saveButton() => tester.widget<FilledButton>(
          find.byKey(const Key('settings_role_editor_save')),
        );

        // Uppercase + space + ! — must reject.
        await enter('Bad Key!');
        expect(saveButton().onPressed, isNull);

        // Backend rule is `^[a-z][a-z0-9_]{2,63}$` (length 3..64).
        // 2-char keys must reject.
        await enter('kl');
        expect(saveButton().onPressed, isNull);

        // Exactly 3 chars must accept.
        await enter('kl1');
        expect(saveButton().onPressed, isNotNull);

        // 64 chars must accept; 65 must reject.
        final sixtyFour = 'a${'b' * 63}';
        expect(sixtyFour.length, equals(64));
        await enter(sixtyFour);
        expect(saveButton().onPressed, isNotNull);

        await enter('a${'b' * 64}');
        expect(saveButton().onPressed, isNull);
      },
    );
  });

  group('SettingsCustomRolesSection — edit / view flow', () {
    testWidgets('non-editable seeded role opens a read-only dialog', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SettingsCustomRolesSection(
            actor: _ownerActor,
            roleCatalog: <TeamRoleCatalogEntry>[_seededOwner()],
            onCreateRole: (_) async => null,
            onPatchRole: (_) async => null,
            onDeleteRole: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('settings_custom_role_view_role-seed-owner')),
      );
      await tester.pumpAndSettle();

      // Save button must NOT exist — read-only mode.
      expect(
        find.byKey(const Key('settings_role_editor_save')),
        findsNothing,
      );
      expect(find.text('View role'), findsOneWidget);
      // Only Close action is present (cancel button labeled Close).
      expect(
        find.byKey(const Key('settings_role_editor_cancel')),
        findsOneWidget,
      );
    });

    testWidgets(
      'View on seeded isEditable=true role opens read-only dialog',
      (tester) async {
        var patchCalls = 0;
        await tester.pumpWidget(
          _wrap(
            SettingsCustomRolesSection(
              actor: _ownerActor,
              // Seeded `operator_manager` ships isEditable=true in the
              // payload but the operator UI must still treat it as
              // View-only — only `admin.roles.edit_seeded` mutates
              // seeded rows and that path lives elsewhere.
              roleCatalog: <TeamRoleCatalogEntry>[_seededManager()],
              onPatchRole: (_) async {
                patchCalls += 1;
                return _seededManager();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('settings_custom_role_view_role-seed-manager')),
        );
        await tester.pumpAndSettle();

        // Save button must NOT exist in read-only mode regardless of
        // the actor's create_custom permission.
        expect(
          find.byKey(const Key('settings_role_editor_save')),
          findsNothing,
        );
        expect(find.text('View role'), findsOneWidget);
        // onPatchRole must not have been called even once for a View
        // open.
        expect(patchCalls, equals(0));
      },
    );

    testWidgets(
      'read-only actor View on a custom role cannot mutate it',
      (tester) async {
        var patchCalls = 0;
        await tester.pumpWidget(
          _wrap(
            SettingsCustomRolesSection(
              actor: _readOnlyActor,
              roleCatalog: <TeamRoleCatalogEntry>[_customKitchenLead()],
              // Live wiring may pass the same callbacks regardless of
              // actor; the section must still gate by permission, not
              // by the presence of the callback.
              onPatchRole: (_) async {
                patchCalls += 1;
                return _customKitchenLead();
              },
              onCreateRole: (_) async => null,
              onDeleteRole: (_) async => true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('settings_custom_role_view_role-custom-1')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('settings_role_editor_save')),
          findsNothing,
        );
        expect(find.text('View role'), findsOneWidget);

        await tester.tap(
          find.byKey(const Key('settings_role_editor_cancel')),
        );
        await tester.pumpAndSettle();

        expect(patchCalls, equals(0));
      },
    );

    testWidgets('editing a custom role only sends changed permissions', (
      tester,
    ) async {
      final captured = <SettingsRoleEditorResult>[];
      Future<TeamRoleCatalogEntry?> onPatch(
        SettingsRoleEditorResult result,
      ) async {
        captured.add(result);
        return _customKitchenLead(displayName: result.displayName);
      }

      await tester.pumpWidget(
        _wrap(
          SettingsCustomRolesSection(
            actor: _ownerActor,
            roleCatalog: <TeamRoleCatalogEntry>[_customKitchenLead()],
            onPatchRole: onPatch,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('settings_custom_role_edit_role-custom-1')),
      );
      await tester.pumpAndSettle();

      // Display name change without permission edits — patch payload
      // should carry the new name and zero permission updates.
      await tester.enterText(
        find.byKey(const Key('settings_role_editor_display_name')),
        'Kitchen Lead 2',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings_role_editor_save')));
      await tester.pumpAndSettle();

      expect(captured, hasLength(1));
      final result = captured.single;
      expect(result.isCreate, isFalse);
      expect(result.roleId, equals('role-custom-1'));
      expect(result.displayName, equals('Kitchen Lead 2'));
      expect(result.permissionUpdates, isEmpty);
    });
  });

  group('SettingsCustomRolesSection — delete flow', () {
    testWidgets('confirmation modal is required before delete', (
      tester,
    ) async {
      var deleteCalls = 0;
      Future<bool> onDelete(TeamRoleCatalogEntry _) async {
        deleteCalls += 1;
        return true;
      }

      await tester.pumpWidget(
        _wrap(
          SettingsCustomRolesSection(
            actor: _ownerActor,
            roleCatalog: <TeamRoleCatalogEntry>[_customKitchenLead()],
            onDeleteRole: onDelete,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('settings_custom_role_delete_role-custom-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Delete role?'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('settings_custom_roles_delete_cancel')),
      );
      await tester.pumpAndSettle();
      expect(deleteCalls, equals(0));

      await tester.tap(
        find.byKey(const Key('settings_custom_role_delete_role-custom-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('settings_custom_roles_delete_confirm')),
      );
      await tester.pumpAndSettle();

      expect(deleteCalls, equals(1));
      expect(find.text('Role "Kitchen Lead" deleted'), findsOneWidget);
    });
  });
}
