// integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_02_drill_into_demo_diner.dart
//
// Lane B — Ops/BA-02: drilling into Demo Diner Co. from Business
// accounts surfaces the operator detail pane with its profile card,
// AI-plan row, and hierarchy panel.
//
// The Business accounts list-detail surface tags the detail pane with
// Key('admin_operators_detail_pane')
// (lib/admin/screens/operator_location_admin_screen.dart:535/565). The
// operator profile card is Key('admin_operator_profile_card') (:842),
// the AI-plan tile is Key('admin_operator_ai_plan_detail_row') (:873),
// and the per-operator surface root is
// Key('admin_operator_detail_<operatorId>') (:815). The hierarchy panel
// is Key('admin_business_hierarchy_panel') (:1831).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/BA-02: drilling into Demo Diner Co. surfaces the operator '
    'profile card, AI-plan row, and hierarchy panel',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminOperatorsRouteId);

      // Business accounts screen mounted.
      expect(
        find.byKey(const Key('admin_operators_screen')),
        findsOneWidget,
        reason: 'Business accounts screen did not mount.',
      );

      // Tap Demo Diner Co. row to drill into the detail (the row might
      // already be auto-selected on first mount). The seed name lives at
      // lib/admin/admin_routes_demo_gateways_part.dart:188.
      final demoDiner = find.text('Demo Diner Co.');
      if (demoDiner.evaluate().isNotEmpty) {
        await tester.tap(demoDiner.first, warnIfMissed: false);
        await tester.pump();
        await pumpUntil(tester, budget: kAdminNavBudget);
      }

      // Detail pane mounted (Key=admin_operators_detail_pane).
      expect(
        find.byKey(const Key('admin_operators_detail_pane')),
        findsAtLeast(1),
        reason:
            'Operator detail pane did not mount after drilling into Demo '
            'Diner Co. (Key=admin_operators_detail_pane missing).',
      );

      // The profile card is in the tree (Key from :842).
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsOneWidget,
        reason:
            'Operator profile card (Key=admin_operator_profile_card) is '
            'missing — the detail body did not render its profile header.',
      );

      // The AI-plan detail row tile is in the tree (Key from :873). This
      // is what reg_02 regression locks on — the row must exist before
      // we can assert it is non-tappable.
      expect(
        find.byKey(const Key('admin_operator_ai_plan_detail_row')),
        findsOneWidget,
        reason:
            'AI plan detail row (Key=admin_operator_ai_plan_detail_row) '
            'missing from the operator detail.',
      );

      // The hierarchy panel renders below the profile (Key from :1831).
      expect(
        find.byKey(const Key('admin_business_hierarchy_panel')),
        findsOneWidget,
        reason:
            'Business hierarchy panel did not render under the profile — '
            'either the hierarchy gateway is broken or the panel is gated '
            'unexpectedly.',
      );

      // Demo Diner Co. label is still on screen (we are still in the
      // expected drill).
      expect(
        isTextMounted('Demo Diner Co.'),
        isTrue,
        reason:
            'Demo Diner Co. label disappeared after the drill — selection '
            'state did not stick.',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Demo Diner drill-in overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
