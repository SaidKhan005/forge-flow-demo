# Compatibility Bridge Scope

Exact remaining `BaselineData` / demo-bridge surfaces after Phase 7.51d.

## Canonical Authority

The persisted `ActiveTargetProfile` is the canonical active-target authority. It is loaded and propagated through `ActiveTargetProfileNotifier`. Production screens read from that notifier or from repository-backed state.

## Remaining Allowed Bridge Surfaces

### BaselineTracker

- **Classification**: Baseline-owned surface
- **Reads**: `BaselineData` for baseline-specific display (range visualization, selected shift context, OPZ graph, benchmark labels)
- **Rationale**: BaselineTracker is the source-of-truth tab for baseline/override management. It legitimately owns the baseline view. This is not app-wide active-target authority.
- **Retirement plan**: None needed — this is intentional baseline ownership, not a bridge.

### LearnTeachingAnalyzer

- **Classification**: Retired — no longer a bridge (7.55l.8a)
- **Reads**: Injected `LearnBenchmarkContext` only. No `BaselineData` imports.
- **Rationale**: As of 7.55l.8a, `LearnTeachingAnalyzer` accepts an immutable
  `LearnBenchmarkContext` parameter resolved by `LearnBenchmarkContextService`.
  Source label, targets, selection count, and range quality all come from
  persisted cycle/profile/summary authority. The analyzer no longer reads
  `BaselineData` directly.
- **Retirement plan**: Complete. See `docs/archive/phases/7_55l/phase_7_55l_8_learn_bridge_closeout.md`.

### LearnBenchmarkContextService

- **Classification**: Narrow compatibility bridge (two paths only)
- **Reads**: Persisted `ActiveTargetProfile`, `TargetCycle`, and
  `BenchmarkSelectionSummary` in the canonical path. `BaselineData` only
  in two intentionally narrow fallback paths:
  1. Explicit bridge-only mode (`enableBridgeOnly()`) for widget tests
     without SQLite
  2. Genuine no-profile bootstrap (first launch before any cycle/profile)
- **Rationale**: The canonical production path is fully persisted. The two
  remaining bridge surfaces are intentional and limited to non-production
  runtime scenarios.
- **Retirement plan**: Bridge-only mode retires when widget tests migrate to
  repository-backed test harnesses. No-profile bootstrap retires when the
  app guarantees a cycle/profile exists before Learn loads. Non-blocking
  for Phase 8.

### StaticShiftDataSource

- **Classification**: Demo/offline bridge only
- **Reads**: `MockIntegrationReplaySeed.output` + `BaselineData` + `MeridianConfig` for offline/static mode
- **Rationale**: Not used in production live path. `LiveShiftDataSource` reads from repository-backed state via `ShiftService` and SQLite. The static source exists for widget tests that cannot use sqflite I/O. Not wired into `ForgeFlowScope`.
- **Retirement plan**: Retire when widget tests migrate to repository-backed test harnesses. Non-blocking for Phase 8.

### SqliteDatabase.buildActiveTargetProfileFromBaseline

- **Classification**: Compatibility / pure-test helper
- **Reads**: `BaselineData` + `MeridianConfig` to build a bridge-era active target profile shape
- **Rationale**: The live seeded/bootstrap path now prefers cycle projection and profile repair from the active `TargetCycle`. This helper remains for narrow compatibility and pure-test scenarios; it is no longer the main app bootstrap authority path.
- **Retirement plan**: Keep reducing helper-only usage until all remaining compatibility/test paths can project from persisted cycle-backed state directly.

### ScheduleDay / DaypartForecast (legacy_fixture_data.dart)

- **Classification**: Fixture-source data classes only — no longer used for rendered Schedule output
- **Reads**: `BaselineData.derivedTarget*` for model-hour getters and daypart breakdown
- **Rationale**: These data classes remain in `legacy_fixture_data.dart` but are no longer consumed by the visible Schedule surface. `ScheduleForecastNotifier.adjustedDayViews` now computes all rendered day-row and daypart-subrow model hours from injected target values using `ScheduleDayView` / `ScheduleDaySubrow` view models. Daypart cover proportioning uses a local fixture-derived weight map (`_daypartCoverWeight`) instead of `BaselineData.daypartRanges`.
- **Retirement plan**: The `ScheduleDay` and `DaypartForecast` classes could be removed entirely since they are no longer consumed by the visible surface. Non-blocking for Phase 8.

### ScheduleBuilder initial-load fallback

- **Classification**: Bootstrap bridge — fires only during the brief moment before `ActiveTargetProfileNotifier.profile` loads
- **Reads**: `BaselineData.derivedTarget*` and `MeridianConfig` wages to construct the initial `ScheduleForecastNotifier` when the active profile is not yet loaded
- **Rationale**: The `ChangeNotifierProxyProvider` `update:` callback immediately replaces these values from the persisted active-target profile. The bridge values are only visible for a single frame at most.
- **Retirement plan**: Could be replaced with a loading state. Non-blocking for Phase 8.

## Surfaces That Are NOT Bridges

These production surfaces now read from persisted or injected state, not from `BaselineData`:

- `LearnTeachingAnalyzer` — reads injected `LearnBenchmarkContext` (resolved from persisted cycle/profile/summary)
- `ShiftDashboard` — reads `ShiftDashboardNotifier` (repository-backed)
- `ZoneStatusCard` — reads constructor params from the read model
- `VarianceReport` This Week — reads `WeekDataNotifier` (repository-backed)
- `VarianceReport` Full Week closed detail — reads locked `ShiftRecord` fields
- `VarianceReport` Full Week open/projected detail — reads from `ShiftDataSource` (repository-backed)
- `WeekDetailScreen` — reads locked `WeekRecord` target fields
- `ScheduleForecastNotifier` — reads injected active-target values from `ActiveTargetProfileNotifier`
- `main.dart` app shell — rebuilds from `ActiveTargetProfileNotifier.revision`
