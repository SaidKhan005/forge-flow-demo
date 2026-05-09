// Phase 4 click-path runner — runs all five demo-mode emulator
// scenarios in a single `flutter test` invocation.
//
// Per `flutter integration_test` convention each scenario file owns
// its own `void main()` so individual scenarios can be invoked
// directly. This runner imports each scenario's `main` under an alias
// and dispatches them in order.
//
// Operator command (run all scenarios):
//
//     flutter pub get
//     flutter test integration_test/phase_4_emulator/click_path_runner.dart \
//       --flavor forgeflow \
//       --dart-define=kDemoMode=true
//
// Or, equivalently, point flutter at the entire folder and it picks
// up every `*.dart` test file:
//
//     flutter test integration_test/phase_4_emulator/ \
//       --flavor forgeflow \
//       --dart-define=kDemoMode=true
//
// SCENARIO GAP markers (one per substituted scenario):
//   - Scenario 1: prompt's "tap 'Use demo operator' -> login" framing
//     is gated to `FORGE_FLOW_USE_FIREBASE_AUTH=true` (offline
//     emulator can't reach Firebase Auth) — covered as a widget-level
//     find-by-key in `test/widget_test.dart`. Click-path asserts the
//     post-login destination instead.
//   - Scenario 2: 10-section traversal is mostly Operator Web post-W3.A;
//     mobile asserts the surfaces that DO exist (Account, Active
//     sessions, Setup, Data + the two demo carve-outs).
//   - Scenario 3: "switch week -> review locked snapshot" is operator-
//     web week-detail; mobile Benchmark surface is BaselineTracker,
//     which is what we assert.
//   - Scenario 4: hierarchy-scoped UX trio is Operator Web / admin
//     only (zero matches in lib/screens/). Substituted with Variance
//     tab render against demo facts.
//   - Scenario 5: there is no separate "shift detail" screen on mobile —
//     ShiftDashboard IS the whole-day authoritative view per CLAUDE.md.
//     We assert the three sticky-section headers
//     (SHIFT OUTPUTS / SHIFT INPUTS / FOH PRODUCTIVITY) or a
//     recognized empty state.
//
// See `integration_test/phase_4_emulator/README.md` for the full run
// instructions, prerequisites, and how to add a new scenario.

import 'scenario_01_dashboard_load.dart' as scenario_01;
import 'scenario_02_settings_traversal.dart' as scenario_02;
import 'scenario_03_weekly_plan_review.dart' as scenario_03;
import 'scenario_04_variance_review.dart' as scenario_04;
import 'scenario_05_shift_detail.dart' as scenario_05;

void main() {
  scenario_01.main();
  scenario_02.main();
  scenario_03.main();
  scenario_04.main();
  scenario_05.main();
}
