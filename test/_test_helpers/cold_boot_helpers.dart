// Shared SQLite cold-boot debug override helpers.
//
// Bucket 4d of the 2026-05-20 test-suite tightening audit codifies the
// "set + reset `SqliteDatabase.debugColdBoot*Override`" discipline into
// a single helper so every future caller gets the discipline
// automatically — without re-introducing the PR #1091 bug shape.
//
// PR #1091 root-caused a flake to a test that set
// `SqliteDatabase.debugColdBootNowOverride = '...'` in `setUp` but
// never cleared it in `tearDown`. The leaked override leaked across
// test isolates, anchoring the next test's cold-boot seed to the
// previous test's pinned date. The fix shipped that file, but the bug
// SHAPE is "set a static field, forget to reset it" — recurring
// anywhere either of these two `@visibleForTesting` static seams is
// touched. The 2026-05-20 audit's flake-risk scan found 10 such
// callers across `test/`; all are properly cleared today, but a
// future caller could trivially re-introduce the leak.
//
// This file ships two shapes; pick the one that fits the call site:
//
//   1. [ColdBootOverrideScope] — the preferred shape when the override
//      is set in `setUp` (or right at the top of a single test body).
//      Construction applies the overrides; `dispose()` resets them to
//      `null`. Pair with `addTearDown(scope.dispose)` and you cannot
//      forget the reset — the test runner does it for you, even if the
//      test throws.
//
//        setUp(() {
//          final scope = ColdBootOverrideScope(
//            now: '2026-03-27T19:45:00',
//          );
//          addTearDown(scope.dispose);
//        });
//
//   2. [resetColdBootOverrides] — the fallback shape when the override
//      is set INSIDE a per-test helper function (e.g. `coldBoot(today)`)
//      that's invoked one or more times per test case with different
//      values. The scope shape doesn't fit cleanly there because the
//      `set` isn't co-located with `setUp`. Instead, register the
//      reset once in the top-level `setUp` via `addTearDown` and drop
//      the inline `tearDown` reset lines:
//
//        setUp(() {
//          addTearDown(resetColdBootOverrides);
//        });
//
// Both shapes converge on the same invariant: every test that touches
// either `debugColdBootTodayOverride` or `debugColdBootNowOverride`
// has a matching reset queued before the test body runs. Future
// callers should reach for one of these helpers rather than hand-rolling
// the set/reset pair.

import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

/// Scoped set+reset for `SqliteDatabase.debugColdBoot*Override`.
///
/// Construction applies the requested overrides to the static seams
/// on `SqliteDatabase`; [dispose] resets both to `null`. Always pair
/// construction with `addTearDown(scope.dispose)` (or an explicit
/// `tearDown` that calls it) so the reset runs even if the test
/// throws — that's the whole point of the helper.
///
/// At least one of [today] / [now] should be non-null; passing both
/// `null` is allowed (the scope is a no-op set) but the dispose still
/// clears both fields, which makes it safe to use as a defensive
/// "reset on tearDown" guard.
class ColdBootOverrideScope {
  /// Apply the requested cold-boot overrides.
  ///
  /// [today] sets `SqliteDatabase.debugColdBootTodayOverride` (legacy
  /// date-only seam; canonical 19:45 time-of-day).
  /// [now] sets `SqliteDatabase.debugColdBootNowOverride` (date+time
  /// seam; wins over [today] for open-period selection).
  ///
  /// Pass `null` (the default) to leave a field untouched at
  /// construction time — but note that [dispose] always clears BOTH,
  /// regardless of which fields were passed here. That asymmetry is
  /// intentional: tests typically set ONE seam but want BOTH cleared
  /// (defense in depth against a sibling test having dirtied the
  /// other seam earlier in the isolate).
  ColdBootOverrideScope({String? today, String? now}) {
    if (today != null) {
      SqliteDatabase.debugColdBootTodayOverride = today;
    }
    if (now != null) {
      SqliteDatabase.debugColdBootNowOverride = now;
    }
  }

  /// Reset both `debugColdBoot*Override` seams to `null`.
  ///
  /// Idempotent — safe to call multiple times, safe to call when the
  /// fields are already `null`. Designed to be passed directly to
  /// `addTearDown` (no arguments, no return value).
  void dispose() {
    SqliteDatabase.debugColdBootTodayOverride = null;
    SqliteDatabase.debugColdBootNowOverride = null;
  }
}

/// Reset BOTH `SqliteDatabase.debugColdBoot*Override` seams to `null`.
///
/// Use this when the override is set inside a per-test helper (e.g. a
/// `coldBoot(injectedToday)` closure invoked from inside test bodies)
/// rather than in `setUp`, so [ColdBootOverrideScope] doesn't fit
/// cleanly. Register once in `setUp` via
/// `addTearDown(resetColdBootOverrides)` and drop any inline `tearDown`
/// reset lines.
///
/// Idempotent — safe to call multiple times, safe to call when the
/// fields are already `null`.
void resetColdBootOverrides() {
  SqliteDatabase.debugColdBootTodayOverride = null;
  SqliteDatabase.debugColdBootNowOverride = null;
}
