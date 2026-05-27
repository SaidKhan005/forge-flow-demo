// integration_test/admin_pressure/ops_vendor_applicability/scenario_ops_va_01_table_renders.dart
//
// Lane B — Ops/VA-01: the Vendor Applicability route mounts the screen
// scaffold, the toolbar with the standard actions (refresh, recommended
// defaults, reset defaults, defaults help, add), and either the list
// body, the loading state, or the load-error state.
//
// Keys come from lib/admin/screens/vendor_applicability_admin_screen.dart:
//   - admin_vendor_applicability_screen     (:735)
//   - admin_vendor_applicability_toolbar    (:1171)
//   - admin_vendor_applicability_refresh    (:1180)
//   - admin_vendor_applicability_recommended_defaults (:1186)
//   - admin_vendor_applicability_reset_defaults       (:1196)
//   - admin_vendor_applicability_defaults_help        (:1206)
//   - admin_vendor_applicability_add        (:1213)
//   - admin_vendor_applicability_list       (:885)
//   - admin_vendor_applicability_loading    (:863)
//   - admin_vendor_applicability_load_error (:872)
//
// This scenario also asserts no RenderFlex overflow on the toolbar
// + list layout (the 2026-05-22 manual pressure test surfaced a
// 76 px header overflow at narrow breakpoints; this is the per-route
// equivalent of regression_reg_01 for vendor applicability).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/VA-01: Vendor Applicability route mounts scaffold, toolbar, '
    'standard toolbar actions, and a recognised body state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminVendorApplicabilityRouteId);

      // Scaffold mounted.
      expect(
        find.byKey(const Key('admin_vendor_applicability_screen')),
        findsOneWidget,
        reason:
            'Vendor Applicability screen scaffold '
            '(Key=admin_vendor_applicability_screen) did not mount.',
      );

      // Toolbar mounted with the standard refresh action.
      expect(
        find.byKey(const Key('admin_vendor_applicability_toolbar')),
        findsOneWidget,
        reason: 'Vendor Applicability toolbar missing.',
      );
      expect(
        find.byKey(const Key('admin_vendor_applicability_refresh')),
        findsOneWidget,
        reason: 'Refresh action missing from the Vendor Applicability toolbar.',
      );

      // At least one of the destructive-defaults toolbar actions is
      // present (recommended/reset/defaults-help — exact set depends
      // on role + flag state, but a super-admin must see at least one).
      final hasRecommended = find
          .byKey(const Key('admin_vendor_applicability_recommended_defaults'))
          .evaluate()
          .isNotEmpty;
      final hasReset = find
          .byKey(const Key('admin_vendor_applicability_reset_defaults'))
          .evaluate()
          .isNotEmpty;
      final hasDefaultsHelp = find
          .byKey(const Key('admin_vendor_applicability_defaults_help'))
          .evaluate()
          .isNotEmpty;
      expect(
        hasRecommended || hasReset || hasDefaultsHelp,
        isTrue,
        reason:
            'None of the recommended/reset/defaults-help actions are '
            'present in the toolbar — a super-admin should see at least '
            'one defaults-management affordance.',
      );

      // Body resolves to a recognised state: list, loading, or load
      // error. Reject the "blank screen" failure mode.
      final hasList = find
          .byKey(const Key('admin_vendor_applicability_list'))
          .evaluate()
          .isNotEmpty;
      final hasLoading = find
          .byKey(const Key('admin_vendor_applicability_loading'))
          .evaluate()
          .isNotEmpty;
      final hasError = find
          .byKey(const Key('admin_vendor_applicability_load_error'))
          .evaluate()
          .isNotEmpty;
      expect(
        hasList || hasLoading || hasError,
        isTrue,
        reason:
            'Vendor Applicability body did not resolve to a recognised '
            'state (list, loading, or load-error). The surface is blank.',
      );

      // No RenderFlex overflows on the toolbar + body layout.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Vendor Applicability overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
