// integration_test/admin_pressure/sysmon_health/scenario_sysmon_health_02_run_check_button_present.dart
//
// Lane D — Sysmon/Health-02 (regression): the System health surface
// must expose a manual refresh button so the operator can re-run
// the health probe. The button is keyed
// 'admin_health_refresh_button' and appears in two places
// (lib/admin/screens/health_admin_screen.dart):
//   - :981 in the standard manual-refresh row
//   - :1038 in the empty-state prompt
//
// This scenario does NOT click the button — that would fire the
// manual health check, which surfaces a confirmation dialog
// ('admin_health_confirm_dialog', :1002) gated by a destructive
// action. The brief explicitly forbids clicking "Run metrics check"
// because the confirmation flow wedges the gesture loop without a
// deterministic seed. We assert PRESENCE only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Sysmon/Health-02 (presence): refresh button is reachable but the '
    'confirmation dialog is NOT pre-mounted',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminHealthRouteId);

      expect(
        find.byKey(const Key('admin_health_screen')),
        findsOneWidget,
        reason: 'System health screen scaffold did not mount.',
      );

      // The refresh button MUST be reachable somewhere on the screen
      // (either in the manual-refresh row or in the empty-state prompt).
      expect(
        find.byKey(const Key('admin_health_refresh_button')),
        findsAtLeast(1),
        reason:
            'Manual refresh button (admin_health_refresh_button) is not '
            'in the tree — the operator has no way to trigger a health '
            'check. See health_admin_screen.dart:981 / :1038.',
      );

      // The confirmation dialog MUST NOT be pre-mounted — that would
      // fire the destructive flow without operator input.
      expect(
        find.byKey(const Key('admin_health_confirm_dialog')),
        findsNothing,
        reason:
            'Health confirmation dialog was pre-mounted on first render '
            '— the destructive run-check flow fired without operator '
            'input.',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'System health overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
