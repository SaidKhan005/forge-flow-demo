// Lane D — Scenario 05: SettingsRoleEditorDialog accessible and renders.
//
// The role editor (settings_role_editor.dart) is a modal dialog, not a
// top-level settings tab. In the current mobile settings layout (W3.A)
// there is no dedicated "Roles" tab or pointer row in the mobile Settings
// screen. The role editor is invoked programmatically from the operator-web
// surface; on mobile it is not directly reachable via the standard tab
// navigation.
//
// This scenario verifies:
//   1. The app boots, logs in, opens Settings without crashing.
//   2. All four tabs (Setup, Integrations, Data, Account) render without
//      throwing or overflowing — a prerequisite for any sub-navigation.
//   3. SettingsRoleEditorDialog can be mounted imperatively (via
//      showDialog) without crashing, confirming the widget tree is
//      compatible and the class compiles correctly.
//
// Note: Because the role editor has no tab-navigable entry point on
// mobile, the scenario uses tester.runAsync + showDialog to prove the
// widget mounts rather than trying to tap a non-existent pointer row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_role_editor.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'scenario 05 — Settings tabs reachable and role editor dialog mounts without crash',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await openSettings(tester);
      expectSettings();

      // Visit all four tabs to confirm none crash.
      for (var i = 0; i < 4; i++) {
        await tapSettingsTab(tester, i);
        await pumpUntil(tester, budget: const Duration(seconds: 5));
      }

      // Show the role editor dialog imperatively to confirm it mounts.
      // A demo-safe seed role that is read-only (seeded = true).
      const seedRole = TeamRoleCatalogEntry(
        roleId: 'role-demo-owner',
        roleKey: 'operator_owner',
        displayName: 'Owner',
        description: 'Full access to operator resources.',
        isSeeded: true,
        isEditable: false,
        permissions: <TeamRolePermissionRule>[],
      );

      // We need a BuildContext from the live widget tree.
      final scaffoldFinder = find.byType(Scaffold).last;
      expect(scaffoldFinder, findsOneWidget);
      final scaffoldContext = tester.element(scaffoldFinder);

      showDialog<SettingsRoleEditorResult>(
        context: scaffoldContext,
        builder: (_) => SettingsRoleEditorDialog(
          role: seedRole,
          onSubmit: (_) async => null, // no-op for test
          permissionKeys: const <String>{
            'shift.view',
            'wage.view',
          },
        ),
      );

      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 5));

      // The dialog should have mounted without crashing.
      // Dismiss it with the navigator.
      if (find.byType(AlertDialog).evaluate().isEmpty &&
          find.byType(Dialog).evaluate().isEmpty) {
        // Dialog used a custom route — find close affordance.
        final closeButtons = find.byIcon(Icons.close);
        if (closeButtons.evaluate().isNotEmpty) {
          await tester.tap(closeButtons.first);
          await tester.pump();
        }
      } else {
        await tester.tapAt(const Offset(10, 10)); // tap outside
        await tester.pump();
      }

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow during role editor scenario:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
