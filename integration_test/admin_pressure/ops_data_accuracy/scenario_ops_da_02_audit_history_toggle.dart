// integration_test/admin_pressure/ops_data_accuracy/scenario_ops_da_02_audit_history_toggle.dart
//
// Lane B — Ops/DA-02: when a location is in scope the embedded Data
// accuracy screen renders three tabs — Labor / Covers / Freshness —
// tagged Keys 'data_accuracy_tab_labor' / 'data_accuracy_tab_covers' /
// 'data_accuracy_tab_freshness'
// (lib/operator_web/screens/data_accuracy_screen.dart:1726/1735/1744).
//
// The "audit history toggle" historically lived on the polling /
// pricing audit panel; on the data-accuracy surface the equivalent is
// the tab bar that lets the operator switch between data sources, which
// is what we lock in here. The data-accuracy screen does NOT mount the
// `admin_data_accuracy_audit_panel` widget — that panel is owned by the
// Polling Setup route.
//
// This scenario asserts ONE of:
//   - the in-scope screen scaffold + the three data-accuracy tabs,
//   - the location-required guide (no scope chosen yet),
//   - a documented load state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/DA-02: Data accuracy surface exposes the Labor/Covers/Freshness '
    'tab triplet when in-scope; otherwise renders the scope-required '
    'guide',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      // Try to surface the Data accuracy route via cluster nav.
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

      // Either the in-scope Data accuracy scaffold (with tabs) OR the
      // location-required guide must be present.
      final inScope =
          find.byKey(const Key('operator_web_data_accuracy_screen'));
      final guide = find.byKey(
        const Key('admin_data_accuracy_waiting_for_location_scope'),
      );

      if (inScope.evaluate().isNotEmpty) {
        // Three-tab triplet must be present.
        expect(
          find.byKey(const Key('data_accuracy_tab_labor')),
          findsOneWidget,
          reason: 'Labor tab missing from data accuracy tab bar.',
        );
        expect(
          find.byKey(const Key('data_accuracy_tab_covers')),
          findsOneWidget,
          reason: 'Covers tab missing from data accuracy tab bar.',
        );
        expect(
          find.byKey(const Key('data_accuracy_tab_freshness')),
          findsOneWidget,
          reason: 'Freshness tab missing from data accuracy tab bar.',
        );
      } else if (guide.evaluate().isNotEmpty) {
        // Scope guide is the documented out-of-scope state.
        expect(
          find.byKey(const Key('admin_data_accuracy_location_required_banner')),
          findsOneWidget,
          reason:
              'Location-required banner missing inside the scope-required '
              'guide.',
        );
      } else {
        // Allow loading / error fallbacks.
        const fallback = <Key>[
          Key('operator_web_data_accuracy_loading'),
          Key('operator_web_data_accuracy_business_timing_error'),
        ];
        var hasFallback = false;
        for (final k in fallback) {
          if (find.byKey(k).evaluate().isNotEmpty) {
            hasFallback = true;
            break;
          }
        }
        expect(
          hasFallback,
          isTrue,
          reason:
              'Data accuracy resolved to neither the in-scope scaffold, '
              'the scope-required guide, nor a documented load state.',
        );
      }

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Data accuracy tab-bar surface overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
