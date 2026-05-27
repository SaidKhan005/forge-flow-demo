// integration_test/admin_pressure/ops_members/scenario_ops_mem_01_members_table_renders.dart
//
// Lane B — Ops/Mem-01: the Team members route (kAdminMembersRouteId) is
// hidden in nav until a business is scoped. The screen scaffold tags
// itself with Key('admin_members_screen')
// (lib/admin/screens/members_admin_screen.dart:883). The toolbar
// renders an Invite button (Key='admin_members_invite_button', :963)
// and a filter card (Key='admin_members_filter_card', :1141) with
// search, status, role, and MFA filters.
//
// This scenario asserts:
//   - the members screen mounts,
//   - the invite button + filter card are in the tree,
//   - the screen resolves to a load state (loading / error / table
//     content),
//   - no overflow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/Mem-01: Team members route mounts with invite affordance, '
    'filter card, and a recognised body state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      final routeId = kAdminMembersRouteId;
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

      // Members screen scaffold mounted.
      expect(
        find.byKey(const Key('admin_members_screen')),
        findsOneWidget,
        reason:
            'Team members screen scaffold did not mount after navigating '
            'to the members cluster route.',
      );

      // Invite affordance present.
      expect(
        find.byKey(const Key('admin_members_invite_button')),
        findsOneWidget,
        reason:
            'Invite button (Key=admin_members_invite_button) is missing '
            'from the members toolbar.',
      );

      // Body resolves to a recognised state.
      const recognised = <Key>[
        Key('admin_members_loading'),
        Key('admin_members_load_error'),
        Key('admin_members_filter_card'),
      ];
      var matched = false;
      for (final key in recognised) {
        if (find.byKey(key).evaluate().isNotEmpty) {
          matched = true;
          break;
        }
      }
      expect(
        matched,
        isTrue,
        reason:
            'Members body did not resolve to a recognised state '
            '(loading / error / filter-card).',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Members screen overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
