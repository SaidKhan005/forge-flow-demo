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
- **Retirement plan**: Complete. See `docs/phase_7_55l_8_learn_bridge_closeout.md`.

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
- **Reads**: `BaselineData` + `MeridianConfig` + `WeekToDate` + `DemoData` for offline/static mode
- **Rationale**: Not used in production live path. `LiveShiftDataSource` reads from repository-backed state. The static source exists for test harnesses and demo/offline fallback.
- **Retirement plan**: Retire when demo mode migrates fully to fixture-replay persistence. Non-blocking for Phase 8.

### SqliteDatabase.buildActiveTargetProfileFromBaseline

- **Classification**: Compatibility bootstrap
- **Reads**: `BaselineData` + `MeridianConfig` to build the initial persisted active target profile
- **Rationale**: This is called during `reseedDemo()`, `_onCreate`, and as a missing-profile fallback. It bridges the in-memory `BaselineData` state into the persisted `ActiveTargetProfile`. After the profile is persisted, it is not re-read from `BaselineData` at runtime.
- **Retirement plan**: Replace with a profile builder that reads directly from persisted baseline-build state. Pending future pass when `BaselineBuild` is persisted.

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
