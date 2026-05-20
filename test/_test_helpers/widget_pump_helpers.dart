// Shared widget-test pump helpers for bounded async settling.
//
// Bucket 4c of the 2026-05-20 test-suite tightening audit consolidated
// five byte-identical copies of these helpers (~40 LOC duplicated
// across five admin widget tests) into this single file. The five
// callers — PRs #1099 (admin_operator_location_screen_test.dart),
// #1105 (members_admin_screen_test.dart), #1106
// (roles_hierarchy_sessions_admin_screen_test.dart), #1108
// (audited_support_actions_admin_screen_test.dart), and #1109
// (admin_shell_widget_test.dart) — all landed with the same shape
// while migrating away from unbounded `tester.pumpAndSettle()`, which
// is the dominant flake shape in this repo (see
// `docs/KNOWN_FAILING_TESTS.md`: a single never-settling timer causes
// `pumpAndSettle` to hang until the harness kills the test).
//
// Two complementary helpers, picked deliberately:
//
//   * `pumpEventually` — fixed budget (20 frames * 50ms = 1s of
//     virtual time). Use when the test just needs the pending micro-
//     tasks/animations to drain before the next assertion. The 1s
//     default is calibrated to comfortably exceed the longest
//     legitimate route/animation transition in the admin shell, while
//     still failing fast on a runaway timer loop. Prefer widening via
//     a `pumpUntil` polling form over bumping this default.
//
//   * `pumpUntil` — conditional budget (60 iterations * 50ms = 3s of
//     virtual time by default). Use when the test asserts a specific
//     visible condition right after the settle (e.g. a dialog has
//     mounted, a snackbar has rendered, a list now contains an
//     expected row). Exits early as soon as the condition holds;
//     fails LOUDLY with the exhausted-budget reason when it doesn't —
//     that explicit `expect(condition(), isTrue, reason: …)` is what
//     turns "test timed out at 30s" into "pumpUntil exhausted 3000ms
//     waiting for X", which is the diagnostic the original five
//     callers all wanted.
//
// All members are public so future widget tests can import this file
// instead of re-introducing per-file duplicates. The API surface is
// intentionally minimal — add new helpers here rather than overloading
// these two signatures with more knobs.

import 'package:flutter_test/flutter_test.dart';

/// Bounded pump loop: replaces unbounded `tester.pumpAndSettle()` to avoid
/// never-settling timer flake (the dominant flake shape in this repo per
/// docs/KNOWN_FAILING_TESTS.md). 20 frames * 50ms == 1s of virtual time,
/// which exceeds the longest legitimate animation/route transition in
/// admin-shell flows. If a future expectation needs more time, prefer a
/// `pumpUntil(tester, () => find.X.evaluate().isNotEmpty)` polling form
/// rather than widening this default.
Future<void> pumpEventually(
  WidgetTester tester, {
  int frames = 20,
  Duration step = const Duration(milliseconds: 50),
}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// Polling form: pumps until [condition] returns true, or fails loudly
/// with the exhausted-time budget once [maxIterations] is reached. Use
/// this when the test asserts a specific condition right after the
/// settle (e.g. a dialog has mounted, a snackbar has rendered).
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 50),
  int maxIterations = 60,
}) async {
  for (int i = 0; i < maxIterations; i++) {
    if (condition()) return;
    await tester.pump(step);
  }
  expect(
    condition(),
    isTrue,
    reason:
        'pumpUntil exhausted ${maxIterations * step.inMilliseconds}ms '
        'budget waiting for condition.',
  );
}
