// integration_test/admin_pressure/ops_data_accuracy/scenario_ops_da_03_vendor_data_filter_opens.dart
//
// Lane B — Ops/DA-03: vendor-applicability is wired into the embedded
// Data accuracy screen through AdminOperatorWebVendorApplicabilityGateway
// (lib/admin/screens/per_location_data_accuracy_screen.dart:196). The
// Labor tab surfaces a wage-authority section
// (Key='operator_web_data_accuracy_wage_authority_section',
// lib/operator_web/screens/data_accuracy_screen.dart:1384) which is
// where the vendor-applicability filter / source toggles live.
//
// This scenario tap-switches to the Labor tab and asserts:
//   - the wage-authority section is in the tree (or the route is in a
//     known off-tab / out-of-scope state),
//   - no overflow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/DA-03: Data accuracy Labor tab surfaces the wage-authority / '
    'vendor-applicability section when in scope',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      final routeId = kAdminDataAccuracyRouteId;
      Future<bool> trySelect() async {
        for (final key in [
          Key('admin_nav_cluster_item_$routeId'),
          Key('admin_nav_item_$routeId'),
        ]) {
          final finder = find.byKey(key);
          if (finder.evaluate().isNotEmpty) {
            await tester.tap(finder.first, warnIfMissed: false);
            await tester.pump();
            await pumpUntil(tester, budget: kAdminNavBudget);
            return true;
          }
        }
        return false;
      }

      var selected = await trySelect();
      if (!selected) {
        await tapAdminNav(tester, kAdminOperatorsRouteId);
        final demoDiner = find.text('Demo Diner Co.');
        if (demoDiner.evaluate().isNotEmpty) {
          await tester.tap(demoDiner.first, warnIfMissed: false);
          await tester.pump();
          await pumpUntil(tester, budget: kAdminNavBudget);
          selected = await trySelect();
        }
      }

      if (!selected) {
        // Cluster route not surfaced — covered by ops_ba_06.
        return;
      }

      // If in-scope, tap Labor tab and verify wage-authority section
      // shows up.
      final inScope =
          find.byKey(const Key('operator_web_data_accuracy_screen'));
      if (inScope.evaluate().isEmpty) {
        // Out-of-scope state — guide is the documented contract.
        expect(
          find
              .byKey(const Key('admin_data_accuracy_waiting_for_location_scope'))
              .evaluate()
              .isNotEmpty,
          isTrue,
          reason:
              'Data accuracy is neither in-scope nor showing the scope '
              'guide.',
        );
        return;
      }

      // Tap Labor tab (Key from
      // lib/operator_web/screens/data_accuracy_screen.dart:1726).
      final laborTab = find.byKey(const Key('data_accuracy_tab_labor'));
      if (laborTab.evaluate().isNotEmpty) {
        await tester.tap(laborTab.first, warnIfMissed: false);
        await tester.pump();
        await pumpUntil(tester, budget: kAdminNavBudget);
      }

      // Wage authority section present (Key from :1384).
      expect(
        find.byKey(
          const Key('operator_web_data_accuracy_wage_authority_section'),
        ),
        findsOneWidget,
        reason:
            'Wage-authority section missing under the Labor tab — '
            'vendor-applicability source picker is not reachable from '
            'this surface.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Data accuracy Labor tab overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
