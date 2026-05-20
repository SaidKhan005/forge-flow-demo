// Shared SQLite-demo `setUp` helpers for the ~42 tests that reseed the
// demo SQLite database before every case.
//
// Bucket 4b of the 2026-05-20 test-suite tightening audit collapsed the
// "reseed the demo SQLite singleton before every test" preamble — and
// the matching `BaselineData.clear*()` reset preamble used by a smaller
// subset — into the helpers below. The canonical shape is the simplest
// existing copy: a single top-level
// `setUp(() async { await SqliteDatabase.instance.reseedDemo(); });`,
// optionally preceded by the three `BaselineData.clear*()` resets that
// the baseline-aware tests use. Both `SqliteDatabase.instance` and the
// thin `DatabaseHelper.instance` wrapper resolve to the same reseed
// implementation; this helper picks the underlying singleton so callers
// don't need to know which side the wrapper lives on.
//
// `demoRestaurantId` re-exports `DemoScope.restaurantId` so callers can
// drop the per-file `const restaurantId = DemoScope.restaurantId;` line
// without breaking the test body's existing references — the existing
// const declaration is replaced by `const restaurantId = demoRestaurantId;`
// or the helper symbol is used directly.
//
// All members are public so future callers can pick the subset they
// need (reseed only, baseline reset only, or both via the convenience
// `resetAllDemoTestState`). Adding to this file is preferred over
// re-introducing per-test duplicates.

import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/baseline_authority_service.dart';

/// Public re-export of `DemoScope.restaurantId` (the canonical demo
/// restaurant id, `demo_restaurant_001`).
///
/// Lets callers drop the per-file `const restaurantId = DemoScope.restaurantId;`
/// preamble without re-importing `DemoScope` everywhere; existing test
/// bodies keep their `restaurantId` references unchanged by writing
/// `const restaurantId = demoRestaurantId;` in `main()`.
const String demoRestaurantId = DemoScope.restaurantId;

/// `setUp` body that reseeds the shared `SqliteDatabase` demo singleton.
///
/// Pass directly to `setUp`:
///
/// ```dart
/// setUp(setUpSqliteDemo);
/// ```
///
/// Idempotent — equivalent to the previously-duplicated bare
/// `await SqliteDatabase.instance.reseedDemo();` body.
Future<void> setUpSqliteDemo() async {
  await SqliteDatabase.instance.reseedDemo();
}

/// Resets the three `BaselineData` runtime overrides
/// (`clearManagerOverride`, `clearHistoricalContext`,
/// `clearRecommendationSignals`) to their default empty/null state.
///
/// Use when a test mutates baseline state via `applyManagerOverride`,
/// `applyHistoricalContext`, or `applyRecommendationSignals` and needs
/// a clean per-test starting point. Synchronous on purpose — matches
/// the underlying `BaselineData.*` shape.
void resetBaselineTestState() {
  BaselineData.clearManagerOverride();
  BaselineData.clearHistoricalContext();
  BaselineData.clearRecommendationSignals();
}

/// Convenience: resets baseline runtime state AND reseeds the demo
/// SQLite singleton, in the order the multi-line callers previously
/// used (baseline resets first, then reseed).
///
/// Pass directly to `setUp`:
///
/// ```dart
/// setUp(resetAllDemoTestState);
/// ```
Future<void> resetAllDemoTestState() async {
  resetBaselineTestState();
  await SqliteDatabase.instance.reseedDemo();
}
