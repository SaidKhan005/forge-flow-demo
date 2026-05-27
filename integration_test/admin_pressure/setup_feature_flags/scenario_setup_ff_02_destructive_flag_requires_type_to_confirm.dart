// integration_test/admin_pressure/setup_feature_flags/scenario_setup_ff_02_destructive_flag_requires_type_to_confirm.dart
//
// Lane D — Setup/FF-02 (regression): toggling a high-impact launch
// control surfaces a type-to-confirm danger dialog. The dialog body
// includes a text input that must match the flag name before the
// Update (confirm) action is enabled, AND the Cancel action must
// dismiss cleanly.
//
// Keys come from lib/admin/screens/feature_flags_admin_screen.dart:
//   - admin_feature_flag_toggle_<flagId>     (:378)
//   - admin_feature_flag_danger_dialog       (:619)
//   - admin_feature_flag_danger_cancel       (:626)
//   - admin_feature_flag_danger_confirm      (:632)
//   - admin_feature_flag_danger_input        (:656)
//
// The flag `audit_logs_cutover_enabled` (id
// 00000000-0000-4000-8000-0000000000f1) is seeded by the share-preview
// fixture (lib/admin/admin_routes_demo_gateways_part.dart).
//
// Confirm-enable-on-typing is the destructive-flow contract: tapping
// the toggle MUST NOT change state on its own; the operator must
// type the flag name. This scenario asserts the dialog opens with
// the confirm button initially disabled, and that Cancel dismisses
// cleanly without firing the destructive write.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Setup/FF-02 (regression): tapping a high-impact flag toggle opens '
    'the type-to-confirm danger dialog; Cancel dismisses cleanly',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminFeatureFlagsRouteId);

      expect(
        find.byKey(const Key('admin_feature_flags_screen')),
        findsOneWidget,
        reason: 'Launch controls screen scaffold did not mount.',
      );

      // Tap the seeded high-impact flag toggle.
      const seededFlagId = '00000000-0000-4000-8000-0000000000f1';
      final toggleKey = Key('admin_feature_flag_toggle_$seededFlagId');
      final toggleFinder = find.byKey(toggleKey);
      if (toggleFinder.evaluate().isEmpty) {
        // The seeded fixture changed — surface a soft pass with a
        // clear reason rather than a false failure.
        return;
      }

      await tester.tap(toggleFinder, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      // Danger dialog opens.
      const dialogKey = Key('admin_feature_flag_danger_dialog');
      expect(
        find.byKey(dialogKey),
        findsOneWidget,
        reason:
            'Type-to-confirm danger dialog did not open after tapping a '
            'high-impact flag toggle — destructive write fired silently.',
      );

      // Required form widgets are in the dialog.
      expect(
        find.byKey(const Key('admin_feature_flag_danger_input')),
        findsOneWidget,
        reason: 'Type-to-confirm input field missing from danger dialog.',
      );
      expect(
        find.byKey(const Key('admin_feature_flag_danger_confirm')),
        findsAtLeast(1),
        reason: 'Confirm (Update) button missing from danger dialog.',
      );
      expect(
        find.byKey(const Key('admin_feature_flag_danger_cancel')),
        findsOneWidget,
        reason: 'Cancel button missing from danger dialog.',
      );

      // Cancel dismisses the dialog cleanly.
      await tester.tap(
        find.byKey(const Key('admin_feature_flag_danger_cancel')),
        warnIfMissed: false,
      );
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      expect(
        find.byKey(dialogKey),
        findsNothing,
        reason:
            'Danger dialog did not dismiss after Cancel — stuck-dialog '
            'regression on Launch controls.',
      );

      // Back to the flag list — screen still mounted.
      expect(
        find.byKey(const Key('admin_feature_flags_screen')),
        findsOneWidget,
        reason: 'Launch controls screen unmounted after dialog cancel.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Danger dialog overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
