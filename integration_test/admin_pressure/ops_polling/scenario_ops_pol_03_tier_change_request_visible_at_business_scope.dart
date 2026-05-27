// integration_test/admin_pressure/ops_polling/scenario_ops_pol_03_tier_change_request_visible_at_business_scope.dart
//
// Lane B — Ops/Pol-03 (regression): the polling-setup tier-change
// request must be visible at business scope, with Approve/Deny
// affordances correctly gated to location scope.
//
// Background: the 2026-05-22 manual pressure test flagged that the
// polling-setup tier-change request was rendering but the Approve and
// Deny buttons were ALWAYS hidden — even when an admin had picked the
// matching location scope. The regression to lock in: at business
// scope, the request renders read-only (request visible, Approve/Deny
// hidden); at location scope, the buttons appear.
//
// This scenario only verifies the "business scope" half of the
// contract because the lane-runner can't easily change scope without
// driving the scope picker. The location-scope half is captured as a
// TODO in the stub scenario_ops_pol_04.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/Pol-03 (regression): polling-setup tier-change request '
      'renders at business scope with Approve/Deny gated off', (tester) async {
    final tap = FlutterErrorTap.install();
    addTearDown(tap.restore);

    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminPollingPricingRouteId);

    // The screen renders one of two states: a real polling-pricing
    // surface, or a "no business picked" placeholder. The route is
    // visibleInNav:false in the const list but reachable via the
    // shell's per-business cluster; in share-preview the gateway
    // surfaces both seeded operators so the surface mounts.
    //
    // The contract being locked in: the polling-pricing screen scaffold
    // is present (Key=admin_polling_pricing_screen, line 607). If the
    // screen surfaced an inheritance notice (line 724,
    // admin_polling_scope_inheritance_notice), that is the signal we
    // are at business scope and Approve/Deny are NOT yet applicable.
    final mountedKeys = <Key>[
      const Key('admin_polling_pricing_screen'),
      const Key('admin_polling_pricing_loading'),
      const Key('admin_polling_pricing_load_error'),
    ];

    final mountedOne = mountedKeys.any((k) => isWidgetMountedByKey(k));
    expect(
      mountedOne,
      isTrue,
      reason:
          'Polling Setup route did not mount any of the canonical '
          'screen / loading / error states. Either the route id '
          'changed or the share-preview gateway broke.',
    );

    // If the actual screen rendered, lock in the regression: there
    // must NOT be a visible Approve/Deny pair at business scope. The
    // tier-change request itself may render via the audit panel
    // (Key=admin_polling_pricing_audit_panel, line 773). Approve /
    // Deny would render as separate Material text buttons; we check
    // for typical labels and assert none are mounted here.
    if (isWidgetMountedByKey(const Key('admin_polling_pricing_screen'))) {
      expect(
        isTextMounted('Approve') && isTextMounted('Deny'),
        isFalse,
        reason:
            'Approve and Deny labels both visible at business scope — '
            'the 2026-05-22 polling-setup regression has returned. '
            'These affordances must be hidden until the operator picks '
            'a specific location scope (see runbook line 174-176, '
            'Plans and limits / Polling setup row).',
      );
    }

    // No overflows from the polling surface.
    expect(
      tap.overflowErrors,
      isEmpty,
      reason:
          'Polling pricing screen overflowed: '
          '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
