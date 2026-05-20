// Shared test helpers for the target_cycle_*_test.dart split.
//
// Bucket 5e of the 2026-05-20 test-suite tightening audit: extracted out of
// `test/target_cycle_service_test.dart` (2,365 lines) when the original
// monolith was split into three focused files:
//   - target_cycle_lifecycle_test.dart                (groups A-F)
//   - target_cycle_override_and_projection_test.dart  (groups G-M)
//   - target_cycle_regression_and_advanced_test.dart  (groups N-P + code-health + per-daypart)
//
// The shared `setUp()` body that fires before every test in the original
// `main()` (reset BaselineData runtime state, reseed the demo SQLite
// singleton, then clear cycle-backed state) is consolidated here as
// `setUpTargetCycleTest()`. The cycle-table delete helper is exposed as
// `clearCycleBackedState()` so the few group-local `setUp()` blocks
// (groups A, H, N, CODE_HEALTH) and the per-test inline calls (groups G,
// Per-Daypart V1) keep working unchanged.
//
// Behaviour is byte-identical to the pre-split source. The
// `BaselineData.clear*()` reset is the same partial 2-clear (no
// clearHistoricalContext) that the original used — preserved verbatim
// rather than routed through `resetBaselineTestState()` to keep the
// existing semantics that depend on historical context surviving across
// tests.

import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/baseline_authority_service.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

/// Public re-export of [demoRestaurantId] (the canonical demo restaurant id,
/// `demo_restaurant_001`).
///
/// Re-exported here so the split test files can pick up `restaurantId` from
/// a single sibling import without also pulling in the `_test_helpers/`
/// path twice.
const String targetCycleDemoRestaurantId = demoRestaurantId;

/// Truncates the four cycle-backed tables (`benchmark_selection_summaries`,
/// `active_target_profiles`, `target_cycles`, `target_cycle_dayparts`) on the
/// shared SQLite demo singleton.
///
/// Used by the top-level `setUp()` registrar [setUpTargetCycleTest] and by
/// the group-local `setUp()` bodies that need an explicitly clean cycle
/// state at the start of each test (groups A, H, N), plus the inline calls
/// in groups G and Per-Daypart V1.
Future<void> clearCycleBackedState() async {
  final db = await SqliteDatabase.instance.database;
  await db.delete('benchmark_selection_summaries');
  await db.delete('active_target_profiles');
  await db.delete('target_cycles');
  await db.delete('target_cycle_dayparts');
}

/// Top-level `setUp()` body for every `target_cycle_*_test.dart` file.
///
/// Resets the BaselineData process-static state, reseeds the demo SQLite
/// singleton via [setUpSqliteDemo], then wipes the cycle-backed tables via
/// [clearCycleBackedState]. Byte-identical to the pre-split top-level
/// `setUp` body — the partial 2-clear (no `clearHistoricalContext`) is
/// intentional to preserve existing semantics.
///
/// Several groups inside the split files keep their own group-local
/// `setUp` that calls [clearCycleBackedState] again; under randomized
/// test ordering a sibling test that PERSISTED a cycle would otherwise
/// leave it behind — `getOrCreateActiveCycle` would then return the
/// existing row and skip the signal-priming write, causing the
/// "cycle write should set signals inline" assertion to find a null
/// `BaselineData.recommendationSignals`.
Future<void> setUpTargetCycleTest() async {
  BaselineData.clearRecommendationSignals();
  BaselineData.clearManagerOverride();
  await setUpSqliteDemo();
  await clearCycleBackedState();
}
