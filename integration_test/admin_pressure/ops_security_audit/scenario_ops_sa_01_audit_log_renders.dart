// integration_test/admin_pressure/ops_security_audit/scenario_ops_sa_01_audit_log_renders.dart
//
// Lane B — Ops/SA-01: the Audit log route
// (kAdminAuditedSupportActionsRouteId) is hidden in nav until a business
// is scoped. The screen tags itself with
// Key('admin_audited_support_actions_screen')
// (lib/admin/screens/audited_support_actions_admin_screen.dart:624)
// and renders a filters row (Key='admin_asa_filters', :794) plus a
// list / loading / error / empty body (Keys 'admin_asa_audit_log_list'
// :1051, '_loading' :1096, '_error' :1121, '_empty' :1162).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/SA-01: Audit log route mounts with filters and resolves to a '
    'recognised body state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      final routeId = kAdminAuditedSupportActionsRouteId;
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

      // Either the screen scaffold mounts, or the forbidden state.
      final scaffold =
          find.byKey(const Key('admin_audited_support_actions_screen'));
      final forbidden = find.byKey(const Key('admin_asa_audit_log_forbidden'));
      expect(
        scaffold.evaluate().isNotEmpty || forbidden.evaluate().isNotEmpty,
        isTrue,
        reason:
            'Audit log route resolved to neither the screen scaffold nor '
            'a forbidden state.',
      );

      if (scaffold.evaluate().isNotEmpty) {
        // Filters row present.
        expect(
          find.byKey(const Key('admin_asa_filters')),
          findsOneWidget,
          reason: 'Audit log filters row missing.',
        );

        // Body resolves to a recognised state.
        const recognised = <Key>[
          Key('admin_asa_audit_log_loading'),
          Key('admin_asa_audit_log_error'),
          Key('admin_asa_audit_log_list'),
          Key('admin_asa_audit_log_empty'),
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
              'Audit log body did not resolve to loading/error/list/empty.',
        );
      }

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Audit log screen overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
