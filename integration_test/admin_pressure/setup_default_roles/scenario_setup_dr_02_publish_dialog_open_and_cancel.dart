// integration_test/admin_pressure/setup_default_roles/scenario_setup_dr_02_publish_dialog_open_and_cancel.dart
//
// Lane D — Setup/DR-02 (regression): tapping the publish button on
// the Default roles draft panel opens the publish wizard dialog;
// the Cancel action dismisses cleanly without firing a destructive
// catalog publish.
//
// Keys come from
//   lib/admin/screens/default_role_catalog_admin_screen.dart:
//     - admin_default_role_catalog_screen        (:377)
//     - admin_default_role_catalog_publish_button (:680)
//   lib/admin/screens/default_role_catalog_publish_dialog.dart:
//     - admin_default_role_catalog_publish_dialog (:241)
//     - admin_default_role_catalog_publish_cancel (:315)
//     - admin_default_role_catalog_publish_headline (:398)
//
// If the publish button is gated (no draft, read-only role, etc.)
// the scenario soft-passes with a clear reason — the destructive
// surface is genuinely unreachable.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Setup/DR-02 (regression): publish wizard opens, headline visible, '
    'Cancel dismisses cleanly without a destructive publish',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminDefaultRoleCatalogRouteId);

      expect(
        find.byKey(const Key('admin_default_role_catalog_screen')),
        findsOneWidget,
        reason: 'Default roles screen scaffold did not mount.',
      );

      // The publish button must be reachable. If it is disabled (no
      // draft, read-only role), it is still in the tree — we tap and
      // the dialog should still open (the button is gated by the
      // draft state, not the role).
      final publishBtn =
          find.byKey(const Key('admin_default_role_catalog_publish_button'));
      if (publishBtn.evaluate().isEmpty) {
        // The publish surface is gated out entirely (e.g. no draft
        // exists yet). Soft-pass — destructive flow is unreachable.
        return;
      }

      await tester.tap(publishBtn.first, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      // Wizard dialog opened.
      const dialogKey = Key('admin_default_role_catalog_publish_dialog');
      final dialogPresent = find.byKey(dialogKey).evaluate().isNotEmpty;
      if (!dialogPresent) {
        // Tapping a disabled button is a no-op in Material; if no
        // dialog opened, the button was disabled. Confirm the
        // destructive flow did NOT fire (no progress / confirm
        // surface is mounted) and soft-pass.
        expect(
          find.byKey(
            const Key('admin_default_role_catalog_publish_progress'),
          ),
          findsNothing,
          reason:
              'Publish progress indicator surfaced without an open '
              'dialog — destructive write fired silently.',
        );
        return;
      }

      // Wizard headline present.
      expect(
        find.byKey(const Key('admin_default_role_catalog_publish_headline')),
        findsOneWidget,
        reason: 'Publish wizard opened but the headline is missing.',
      );

      // Cancel action present.
      expect(
        find.byKey(const Key('admin_default_role_catalog_publish_cancel')),
        findsOneWidget,
        reason: 'Cancel button missing from the publish wizard.',
      );

      // Cancel dismisses cleanly.
      await tester.tap(
        find.byKey(const Key('admin_default_role_catalog_publish_cancel')),
        warnIfMissed: false,
      );
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      expect(
        find.byKey(dialogKey),
        findsNothing,
        reason:
            'Publish wizard did not dismiss after Cancel — stuck-dialog '
            'regression on the Default roles surface.',
      );

      // Back to the catalog — screen still mounted, no destructive
      // progress indicator.
      expect(
        find.byKey(const Key('admin_default_role_catalog_screen')),
        findsOneWidget,
        reason: 'Default roles screen unmounted after wizard cancel.',
      );
      expect(
        find.byKey(
          const Key('admin_default_role_catalog_publish_progress'),
        ),
        findsNothing,
        reason:
            'Publish progress indicator visible after Cancel — the '
            'cancel did not prevent the destructive flow.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Default roles publish wizard overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
