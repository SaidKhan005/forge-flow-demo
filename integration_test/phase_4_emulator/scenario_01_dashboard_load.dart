// Phase 4 Scenario 1 — Demo dashboard load with realistic vendor data.
//
// SCENARIO GAP (vs prompt's "tap 'Use demo operator' -> login ->
// dashboard" framing): the standalone Forge & Flow demo flavor in
// `lib/main_forgeflow.dart` ONLY routes through the login screen when
// `--dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true` is set (which
// requires a real Firebase Auth backend, out of scope for an offline
// emulator click-path per HP #2 + the Phase 4 "no network" rule). The
// default demo boot path (no Firebase) skips AuthGate and lands
// directly on AppShell with `requireAuth=false`. So this scenario
// asserts the dashboard-load contract that fires AFTER the (skipped)
// login, against the same SQLite seed Phase 1 fixtures shape via
// `_seedDemoDataFromReplay` -> `MockReplayDataSourceProvider`. The
// "tap 'Use demo operator'" affordance is covered as a widget-level
// `find.byKey(login_demo_operator_button)` assertion in the existing
// `test/widget_test.dart` smoke; the live-button-tap end-to-end path
// requires Firebase Auth and is intentionally out of scope here.
//
// Realistic vendor data: the demo seed wraps the SAME Phase 1
// fixture-shaped corpora (`MockIntegrationReplaySeed.output`) that
// drive Phase 8 vendor connectors after `kDemoMode = false`, per HP
// #2. So the dashboard is rendered against POS sales (toast, square,
// clover-shape), labor punches (adp, 7shifts-shape), and reservations
// (libro, opentable-shape) — the same bytes Phase 1 corpora pin.
//
// Path: cold boot (demo) -> AppShell mounts -> Shift dashboard tab.
// Asserts: AppShell mounts within 30s; no RenderFlex overflow
// exceptions; the dashboard's primary metric pills hold non-error
// state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '_harness.dart';

void main() {
  bootstrapPhase4Binding();

  testWidgets('scenario 01 — demo cold boot reaches dashboard', (
    WidgetTester tester,
  ) async {
    final tap = FlutterErrorTap.install();
    addTearDown(tap.restore);

    await launchDemoApp(tester);
    await expectAppShellMounted(tester);

    // The demo boot lands on Shift (tab index 0). Confirm the dashboard
    // is the visible tab and that it rendered ANY metric chrome (live
    // metric or empty state) rather than blank-screening.
    expectShiftDashboardMounted();
    expect(
      find.byType(CircularProgressIndicator).hitTestable(),
      findsNothing,
      reason:
          'Dashboard still showing global progress indicator after the '
          'boot budget. The SQLite seed or the dashboard notifier is '
          'stuck loading.',
    );

    // Demo banner mount is the Phase 2D contract surface — banner is in
    // the tree even when it renders nothing because no demo_mode_state
    // rows exist yet (Phase 8 surface). We still assert the widget
    // type is reachable so a future regression that strips it surfaces
    // here.
    expectDemoModeBannerMounted();

    // Bottom nav must be wired so subsequent scenarios can navigate
    // between tabs without a re-boot.
    expect(find.byType(BottomNavigationBar), findsOneWidget);

    // No layout overflows tolerated. RenderFlex overflow exceptions
    // accumulate via the global FlutterError.onError tap.
    expect(
      tap.overflowErrors,
      isEmpty,
      reason:
          'RenderFlex overflow detected during dashboard cold boot:\n'
          '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
    );
  });
}
