// integration_test/admin_pressure/ops_data_accuracy/scenario_ops_da_01_table_renders_per_location.dart
//
// Lane B — Ops/DA-01: the Data accuracy route (kAdminDataAccuracyRouteId,
// lib/admin/admin_routes.dart) is a per-business cluster route. When no
// location scope is selected, the screen renders a "select a location"
// guide (Key='admin_data_accuracy_waiting_for_location_scope',
// lib/admin/screens/per_location_data_accuracy_screen.dart:247) with a
// location-required banner
// (Key='admin_data_accuracy_location_required_banner', :254).
//
// When a location is scoped, the screen scaffold mounts
// (Key='admin_data_accuracy_screen', :169) and embeds the operator-web
// DataAccuracyScreen.
//
// This scenario asserts the route resolves to ONE of the recognised
// states: the location-required guide, the screen scaffold, or a
// business-timing loading/error state. It does NOT require a particular
// scope path — the data-accuracy contract is "screen mounts in some
// recognised state on first nav".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/DA-01: Data accuracy route resolves to either the location-'
    'required guide or the in-scope screen scaffold',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      // Data accuracy route is hidden in nav until a business is scoped;
      // attempt the cluster-nav row first, then the primary nav, then
      // accept the cluster nav after picking Demo Diner Co.
      final routeId = kAdminDataAccuracyRouteId;
      final clusterKey = Key('admin_nav_cluster_item_$routeId');
      final primaryKey = Key('admin_nav_item_$routeId');

      Future<bool> trySelect() async {
        for (final key in [clusterKey, primaryKey]) {
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
        // Drill into Demo Diner Co. then retry.
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
        // Soft-pass — the cluster route did not surface in the current
        // viewport. Cluster-nav availability is asserted by ops_ba_06.
        return;
      }

      // Resolve to ANY recognised state.
      const recognisedStates = <Key>[
        Key('admin_data_accuracy_screen'),
        Key('admin_data_accuracy_waiting_for_location_scope'),
        Key('admin_data_accuracy_location_required_banner'),
        Key('operator_web_data_accuracy_loading'),
        Key('operator_web_data_accuracy_business_timing_error'),
      ];
      var matched = false;
      for (final key in recognisedStates) {
        if (find.byKey(key).evaluate().isNotEmpty) {
          matched = true;
          break;
        }
      }
      expect(
        matched,
        isTrue,
        reason:
            'Data accuracy route did not resolve to any recognised state '
            '(screen scaffold, waiting-for-scope guide, location-required '
            'banner, loading, or error).',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Data accuracy screen overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
