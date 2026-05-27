// integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_01_two_demo_operators_present.dart
//
// Lane B — Ops/BA-01: Business accounts route renders both seeded demo
// operators (Demo Diner Co., Sunset Cafe Group).
//
// Background: the share-preview demo fixture seeds exactly two
// operators (see lib/admin/admin_routes_demo_gateways_part.dart:188
// "Demo Diner Co." and :223 "Sunset Cafe Group"). The Business accounts
// landing page is the entry point for every per-business surface and
// every regression in the 2026-05-22 manual pressure test ultimately
// drilled in from here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/BA-01: Business accounts route shows both demo operators '
      '(Demo Diner Co. + Sunset Cafe Group)', (tester) async {
    final tap = FlutterErrorTap.install();
    addTearDown(tap.restore);

    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);

    // Navigate to Business accounts (the initial route is this id —
    // see lib/admin/admin_shell.dart:56 `initialRouteId` default, but
    // tap anyway so the scenario also exercises the nav row).
    await tapAdminNav(tester, kAdminOperatorsRouteId);

    // The screen scaffold mounts (Key from
    // lib/admin/screens/operator_location_admin_screen.dart:365).
    expect(
      find.byKey(const Key('admin_operators_screen')),
      findsOneWidget,
      reason: 'Business accounts screen scaffold did not mount.',
    );

    // Both seeded operator names appear in the tree. The list
    // surfaces them as Text(...) — match by visible label, which is
    // also how the runbook walks them.
    expect(
      find.text('Demo Diner Co.'),
      findsAtLeast(1),
      reason:
          'Demo Diner Co. operator row missing from Business accounts '
          '— share-preview seed broken (see '
          'lib/admin/admin_routes_demo_gateways_part.dart:188).',
    );
    expect(
      find.text('Sunset Cafe Group'),
      findsAtLeast(1),
      reason:
          'Sunset Cafe Group operator row missing — share-preview seed '
          'broken (see admin_routes_demo_gateways_part.dart:223).',
    );

    // Header workspace tabs key exists (one of the operators is
    // auto-selected on load, so the detail pane is present).
    expect(
      find.byKey(const Key('admin_operators_detail_pane')),
      findsAtLeast(1),
      reason:
          'Detail pane (Key=admin_operators_detail_pane) missing — the '
          'list-detail layout was not built.',
    );

    // No overflows on the landing layout.
    expect(
      tap.overflowErrors,
      isEmpty,
      reason:
          'Business accounts landing overflowed: '
          '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
