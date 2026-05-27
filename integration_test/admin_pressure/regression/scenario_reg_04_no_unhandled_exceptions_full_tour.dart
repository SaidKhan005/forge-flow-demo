// integration_test/admin_pressure/regression/scenario_reg_04_no_unhandled_exceptions_full_tour.dart
//
// Reg-04: a non-AI admin tour completes without Flutter framework errors.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

const List<String> _kNonAiPrimaryTour = <String>[
  kAdminOperatorsRouteId,
  kAdminVendorApplicabilityRouteId,
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

  testWidgets(
    'Reg-04: non-AI full tour has no unhandled errors',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      for (final routeId in _kNonAiPrimaryTour) {
        await tapAdminNav(tester, routeId);
        await expectAdminShellMounted(tester);
      }

      await selectDemoDinerBusinessScope(tester);
      for (final routeId in <String>[
        kAdminMembersRouteId,
        kAdminRolesHierarchySessionsRouteId,
        kAdminAuditedSupportActionsRouteId,
        kAdminPollingPricingRouteId,
      ]) {
        await tapAdminClusterRoute(tester, routeId);
        await expectAdminShellMounted(tester);
      }

      expect(tap.all, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
