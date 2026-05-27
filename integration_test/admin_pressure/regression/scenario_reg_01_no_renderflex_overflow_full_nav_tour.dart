// integration_test/admin_pressure/regression/scenario_reg_01_no_renderflex_overflow_full_nav_tour.dart
//
// Lane E — Reg-01 (regression): a full primary-nav tour of the admin
// shell completes without a single RenderFlex overflow.
//
// Background: the 2026-05-22 manual pressure test surfaced a 76 px
// header overflow on the admin shell. shell_03 locks in the header
// alone; this scenario takes the broader regression: walk every
// visible nav row from a typical narrow desktop width (where the
// historical overflow zone lives) and assert zero overflow errors
// across the whole tour.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

const List<String> _kFullTour = <String>[
  kAdminOperatorsRouteId,
  kAdminVendorApplicabilityRouteId,
  kAdminPricingRouteId,
  kAdminCorpusRouteId,
  kAdminObservabilityRouteId,
  kAdminHealthRouteId,
  kAdminDebugConsoleRouteId,
  kAdminIntegrationsRouteId,
  kAdminFeatureFlagsRouteId,
  kAdminDefaultRoleCatalogRouteId,
  kAdminMyAccountRouteId,
  kAdminNotificationPreferencesRouteId,
];

void main() {
  bootstrapBinding();

  testWidgets('Reg-01 (regression): full primary-nav tour at narrow desktop '
      'width emits zero RenderFlex overflows', (tester) async {
    final tap = FlutterErrorTap.install();
    addTearDown(tap.restore);

    // The historical overflow zone — set surface size BEFORE boot
    // so the layout is built once at this width.
    await tester.binding.setSurfaceSize(const Size(980, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);

    for (final routeId in _kFullTour) {
      await tapAdminNav(tester, routeId);
      await expectAdminShellMounted(tester);
      // Fail fast — capture which route triggered the overflow.
      if (tap.overflowErrors.isNotEmpty) {
        fail(
          'RenderFlex overflow during nav tour at route "$routeId" '
          'at 980x900: '
          '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
