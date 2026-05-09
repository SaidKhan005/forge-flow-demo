// Forge & Flow — Phase 4 (pressure preview) emulator click-path harness.
//
// Shared bootstrap + assertion helpers for the per-scenario integration
// tests under `integration_test/phase_4_emulator/`. Each scenario file
// owns its own `void main()` so the suite can be run as a single
// invocation:
//
//     flutter test integration_test/phase_4_emulator/ \
//       --flavor forgeflow \
//       --dart-define=kDemoMode=true
//
// Or as a single scenario:
//
//     flutter test integration_test/phase_4_emulator/scenario_01_dashboard_load.dart \
//       --flavor forgeflow \
//       --dart-define=kDemoMode=true
//
// Constraints honored by every scenario:
//
// 1. HP #2 (CLAUDE.md → Demo Mode) — `kDemoMode` is a writer-side
//    switch. We boot the production `main_forgeflow.main()` with
//    `--dart-define=kDemoMode=true`; the SQLite seed
//    (`_seedDemoDataFromReplay`) writes `MockReplayDataSourceProvider`
//    output into the SAME tables (`shift_records`, `week_records`,
//    `target_cycles`, `import_runs`, `restaurant_locations`, ...) the
//    production reader path consumes. Phase 1 fixtures
//    (`test/fixtures/vendor_payloads/<vendor>/`) are the input shapes
//    the demo writer mirrors today; this scaffold does NOT introduce a
//    parallel demo-only reader path.
// 2. The suite must NOT depend on a network connection or a real
//    Postgres / proxy. Default boot path
//    (`bootstrapAndRunApp(const ForgeFlowApp())` without
//    `FORGE_FLOW_USE_FIREBASE_AUTH=true`) is fully local SQLite.
// 3. No production-code reader-side branching on `kDemoMode`. Any
//    additive `Key`s for find-by-key are surgical and explained in the
//    PR body.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/main_forgeflow.dart' as ff_app;
import 'package:forge_and_flow/screens/settings_screen.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/widgets/demo_mode_banner.dart';

/// Compile-time guard so the suite refuses to run against a non-demo
/// binary. Phase 4 is a demo-mode walkthrough only (CLAUDE.md
/// "Frontend Exposure" rule + HP #2). Fails fast with a clear error
/// instead of silently asserting against production-flavor data.
const bool kDemoMode = bool.fromEnvironment('kDemoMode');

/// Hard ceiling for any single click-path scenario. Operator-facing
/// reality: anything above this on a real device is a bug, not a slow
/// emulator. The pressure-preview Phase 3A latency budget (2000ms p95
/// per request) is per-screen-paint, not per-scenario; this is the
/// cold-boot envelope.
const Duration kScenarioBootBudget = Duration(seconds: 30);

/// Pump-and-settle wrapper that retries up to [kScenarioBootBudget] for
/// the cold-boot path while the SQLite seed runs. `pumpAndSettle`
/// alone hangs for streams that pump on a wall-clock timer (the
/// dashboard's `_LiveClock`); we cap the wait and accept partial
/// settlement.
Future<void> pumpUntilSettledOrBudget(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 100),
  Duration budget = kScenarioBootBudget,
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < budget) {
    await tester.pump(step);
    if (!tester.binding.hasScheduledFrame) return;
  }
}

/// Boots the demo F&F app via the standard `main_forgeflow.main()`.
/// Returns once the first frame is laid out. Caller awaits an
/// additional `pumpUntilSettledOrBudget(tester)` to let the SQLite
/// seed and shell scaffolding settle.
///
/// We DO NOT call `tester.pumpWidget(const ForgeFlowApp())` directly —
/// that would skip `bootstrapAndRunApp`, which is where
/// `WidgetsFlutterBinding.ensureInitialized()`, the secure-storage
/// scaffold, and the realtime/auth providers wire up. The integration
/// binding is initialised by [bootstrapPhase4Binding] before this call.
Future<void> launchDemoApp(WidgetTester tester) async {
  if (!kDemoMode) {
    throw StateError(
      'Phase 4 emulator click-path requires --dart-define=kDemoMode=true. '
      'Re-invoke flutter test with the demo flag, or refer to '
      'integration_test/phase_4_emulator/README.md for the full command.',
    );
  }
  await ff_app.main();
  await tester.pump();
  await pumpUntilSettledOrBudget(tester);
}

/// Initialises the Flutter integration_test binding and returns it.
/// Each scenario file calls this in its own `main()` before declaring
/// `testWidgets(...)`. The binding is process-singleton, so calling
/// it from every scenario is idempotent.
IntegrationTestWidgetsFlutterBinding bootstrapPhase4Binding() {
  return IntegrationTestWidgetsFlutterBinding.ensureInitialized();
}

/// Asserts the active widget tree contains an [AppShell] (i.e. the
/// app reached the post-login destination). Pumps until the AppShell
/// is found or [budget] elapses (default: 10s on top of the boot
/// budget already consumed by [launchDemoApp]).
Future<void> expectAppShellMounted(
  WidgetTester tester, {
  Duration budget = const Duration(seconds: 10),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < budget) {
    if (find.byType(AppShell).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(
    find.byType(AppShell),
    findsOneWidget,
    reason:
        'AppShell never mounted within $budget — the demo seed or auth '
        'gate likely failed. Check the SQLite seed log and '
        '`bootstrapAndRunApp` for thrown exceptions.',
  );
}

/// Assert no `RenderFlex` overflow exceptions accumulated on
/// [FlutterError.onError] during the scenario. Subscribers should
/// call [FlutterErrorTap.install] at scenario start and assert
/// [overflowErrors] is empty at scenario close. Pair with
/// `addTearDown(tap.restore)` to restore the previous handler.
class FlutterErrorTap {
  FlutterErrorTap._();

  final List<FlutterErrorDetails> _errors = <FlutterErrorDetails>[];
  FlutterExceptionHandler? _previous;

  static FlutterErrorTap install() {
    final tap = FlutterErrorTap._();
    tap._previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      tap._errors.add(details);
      tap._previous?.call(details);
    };
    return tap;
  }

  /// Restores the previous error handler. Call in the scenario's
  /// `addTearDown` block.
  void restore() {
    FlutterError.onError = _previous;
  }

  /// Returns the captured `RenderFlex` overflow records, if any.
  List<FlutterErrorDetails> get overflowErrors {
    return _errors
        .where(
          (e) =>
              e.exception.toString().contains('RenderFlex') ||
              (e.context?.toString().toLowerCase().contains('overflow') ??
                  false),
        )
        .toList(growable: false);
  }

  /// All captured errors regardless of category.
  List<FlutterErrorDetails> get all => List.unmodifiable(_errors);
}

/// Taps the bottom-nav tab at [tabIndex] and pumps until settled or
/// the per-tab budget (~10s) elapses. Throws if [BottomNavigationBar]
/// is not mounted.
///
/// Bottom-nav indexes match the build order in `forge_flow_app.dart`
/// `_AppBottomNav`:
///   0 = Shift, 1 = Variance, 2 = Plan, 3 = Benchmark.
///
/// We read the [BottomNavigationBar]'s `onTap` callback rather than
/// hit-testing pixel coordinates so the test is robust to bar
/// re-layout (e.g. the operator-web admin variant). The forwarded
/// callback is `_AppShellState._navigateTo`.
Future<void> tapBottomNavTab(WidgetTester tester, int tabIndex) async {
  expect(
    find.byType(BottomNavigationBar),
    findsOneWidget,
    reason: 'Bottom nav not mounted — AppShell not reached.',
  );
  final bar = tester.widget<BottomNavigationBar>(
    find.byType(BottomNavigationBar),
  );
  bar.onTap?.call(tabIndex);
  await tester.pump();
  await pumpUntilSettledOrBudget(
    tester,
    budget: const Duration(seconds: 10),
  );
}

/// Confirms the scenario reached the [ShiftDashboard] surface. Used by
/// scenarios 1, 3, and 5 as a precondition.
void expectShiftDashboardMounted() {
  expect(find.byType(ShiftDashboard), findsOneWidget);
}

/// Confirms the [SettingsScreen] is the top route. Used by scenario
/// 2.
void expectSettingsScreenMounted() {
  expect(find.byType(SettingsScreen), findsOneWidget);
}

/// Confirms the [DemoModeBanner] widget is part of the tree. The
/// banner only renders runtime chrome when `demo_mode_state` rows
/// exist for the active scope (Phase 8 surface), so we assert mount
/// rather than visibility — mount is the contract Phase 2D pinned.
void expectDemoModeBannerMounted() {
  expect(find.byType(DemoModeBanner), findsWidgets);
}
