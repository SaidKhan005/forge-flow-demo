// integration_test/admin_pressure/shell/scenario_shell_01_all_nav_routes_mount.dart
//
// Lane A — Shell-01: every primary-nav route mounts when tapped.
//
// Walks the 13 primary nav routes listed in
// `runbooks/admin_console_browser_qa_runbook.md` Step 6 (the ones with
// `visibleInNav: true` in `kAdminRoutes`). Each tap must:
//   - find the `admin_nav_item_<routeId>` key.
//   - settle without a RenderFlex overflow.
//   - leave the shell scaffold mounted afterward.
//
// This is the admin-side equivalent of mobile pressure scenario
// shell_01_all_tabs_mount.dart, but the admin shell is built around a
// left-nav rail (not a bottom-nav), and there are 13 visible routes
// (not 4). The shell does not currently expose an "active route" Key,
// so this scenario asserts shell-still-mounted + no overflow after each
// nav transition.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

// The list mirrors kAdminRoutes filter visibleInNav=true in
// lib/admin/admin_routes.dart and the runbook checklist. Keep in route
// id (not display label) terms so the scenario stays stable across
// re-labelling slices.
const List<String> _kVisibleAdminRouteIds = <String>[
  kAdminOperatorsRouteId,                  // Business accounts
  kAdminVendorApplicabilityRouteId,        // Vendor applicability
  kAdminPricingRouteId,                    // Plans and limits
  kAdminCorpusRouteId,                     // Knowledge base
  kAdminObservabilityRouteId,              // AI Metrics
  kAdminHealthRouteId,                     // System health
  kAdminDebugConsoleRouteId,               // Support logs
  kAdminIntegrationsRouteId,               // Connected services
  kAdminFeatureFlagsRouteId,               // Launch controls
  kAdminDefaultRoleCatalogRouteId,         // Default roles
  kAdminMyAccountRouteId,                  // My account
  kAdminNotificationPreferencesRouteId,    // Notifications
];

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-01: each of the 12 primary-nav routes mounts cleanly when '
    'tapped from the left-side rail',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      for (final routeId in _kVisibleAdminRouteIds) {
        await tapAdminNav(tester, routeId);
        await expectAdminShellMounted(tester);
        expect(
          tap.overflowErrors,
          isEmpty,
          reason:
              'RenderFlex overflow detected after navigating to "$routeId": '
              '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
        );
      }

      // Round-trip back to Business accounts and confirm the shell is
      // still mounted — IndexedStack / route disposal must not have
      // destroyed it.
      await tapAdminNav(tester, kAdminOperatorsRouteId);
      await expectAdminShellMounted(tester);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
