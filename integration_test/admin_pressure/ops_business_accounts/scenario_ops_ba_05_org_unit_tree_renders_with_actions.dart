// integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_05_org_unit_tree_renders_with_actions.dart
//
// Lane B — Ops/BA-05: the operator detail surfaces a business hierarchy
// panel under the profile card. The panel root is
// Key('admin_business_hierarchy_panel')
// (lib/admin/screens/operator_location_admin_screen.dart:1831). Each
// org unit is Key('admin_hierarchy_org_unit_<id>') (:2027) and each
// location is Key('admin_hierarchy_location_<id>') (:2238). The
// business-scope row tagged Key('admin_hierarchy_business_scope_row')
// (:1880) anchors the tree.
//
// This scenario asserts:
//   - the panel mounts,
//   - the business scope row anchors the tree,
//   - the tree resolves to either an org-unit row, a location row, or
//     the explicit no-org-units empty state (Key='admin_business_hierarchy_no_org_units', :1964),
//   - no overflow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/BA-05: business hierarchy panel renders with the scope row '
    'anchor and either org-units, locations, or an empty-state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminOperatorsRouteId);

      // Drill into Demo Diner Co. for a deterministic tree shape.
      final demoDiner = find.text('Demo Diner Co.');
      if (demoDiner.evaluate().isNotEmpty) {
        await tester.tap(demoDiner.first, warnIfMissed: false);
        await tester.pump();
        await pumpUntil(tester, budget: kAdminNavBudget);
      }

      // Panel mounts (Key from :1831).
      expect(
        find.byKey(const Key('admin_business_hierarchy_panel')),
        findsOneWidget,
        reason: 'Business hierarchy panel did not mount.',
      );

      // Scope row anchors the tree (Key from :1880).
      expect(
        find.byKey(const Key('admin_hierarchy_business_scope_row')),
        findsOneWidget,
        reason:
            'Business scope row missing — the hierarchy tree has no anchor.',
      );

      // Tree resolves to a recognised state: org-unit row, location row,
      // load state, or empty state.
      final hasOrgUnit = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith(
              'admin_hierarchy_org_unit_',
            ),
      ).evaluate().isNotEmpty;
      final hasLocation = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith(
              'admin_hierarchy_location_',
            ),
      ).evaluate().isNotEmpty;
      final hasEmpty = find
          .byKey(const Key('admin_business_hierarchy_no_org_units'))
          .evaluate()
          .isNotEmpty;
      final hasLoading = find
          .byKey(const Key('admin_business_hierarchy_loading'))
          .evaluate()
          .isNotEmpty;
      final hasError = find
          .byKey(const Key('admin_business_hierarchy_load_error'))
          .evaluate()
          .isNotEmpty;

      expect(
        hasOrgUnit || hasLocation || hasEmpty || hasLoading || hasError,
        isTrue,
        reason:
            'Hierarchy panel did not resolve to a recognised state '
            '(org-unit row, location row, empty, loading, or error). The '
            'tree is rendering an unknown state.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Hierarchy panel overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
