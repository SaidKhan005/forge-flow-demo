# Phase 7.55j.1 — Codebase Feature Inventory

Updated: 2026-04-12
Owner: Claude (inventory), Codex (verification)
Status: Complete — repo-grounded inventory

## Purpose

This document walks every current Forge & Flow product surface that consumes
operational truth, and maps each one to:

- the files that implement it
- the operational truth it currently reads
- what freshness it requires
- what source system should own that data after Phase 8 / 8R
- what target architecture destination should hold the data after `7.55l`
- what bridge/demo/runtime dependencies still exist today
- what later phase owns each unresolved migration

No code changes, no architecture redefinition. Inventory only.

## Architecture Reference

```text
POS + Labor + Reservation Systems
-> Canonical Operational Facts
-> 60-Day Benchmark Snapshot
-> TargetCycle + DemandForecastContext
-> SchedulePlan
-> WeeklyPlanSnapshot
-> Shift
-> Variance
-> History
-> Learn
```

Active planning rule:
- standards lock on a 60-day `TargetCycle`
- demand rolls from level 1 baseline + fixed 3-week recent trend
- `WeeklyPlanSnapshot` auto-generates and locks the week
- no intended UX change to Benchmark, Schedule, History, or Learn

---

## 1. Benchmark / Manager Override

### User-facing purpose

Show the rolling 60-day benchmark, derived CPLH/SPLH/PPA/OPZ targets, and let
the manager override by selecting "star shifts."

### Main files

| File | Role |
|------|------|
| `lib/screens/baseline_tracker.dart` | Benchmark display: summary cards, CPLH range bar, daypart table, targets card |
| `lib/screens/baseline_manager_screen.dart` | Manager override selection screen |
| `lib/data/baseline_manager_service.dart` | Candidate loading, selection persistence, BaselineData priming, ActiveTargetProfile persistence |
| `lib/data/active_target_profile_notifier.dart` | App-wide persisted target authority notifier |
| `lib/data/legacy_fixture_data.dart` (`BaselineData`) | In-memory compatibility bridge for benchmark/target reads |
| `lib/data/legacy_fixture_data.dart` (`MeridianConfig`) | Static default constants — fallback/bootstrap bridge |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | `buildActiveTargetProfileFromBaseline()` bridges BaselineData → persisted profile |

### Current operational truth consumed

- **Closed shift history** (60-day date window) from `shift_records` table via `SqliteShiftRecordRepository`
- **BaselineData** in-memory globals: `derivedTargetCPLH`, `derivedTargetSPLH`, `derivedTargetPPA`, `opzFloorCPLH`, `opzCeilingCPLH`, `historicalTotalCoversTracked`, `historicalWeeklyAvgCovers`, `daypartRanges`, `rangeGraphModel`, `baselineRangeValidation`, `hasManagerOverride`, `selectedRecordCount`
- **MeridianConfig** defaults: `fohWage`, `bohWage`, `targetCPLH`, `targetPPA`, `targetSPLH`, `opzFloorCPLH`, `opzCeilingCPLH`
- **ActiveTargetProfile** persisted in `active_target_profiles` table
- **Baseline selection** persisted in `baseline_selections` table
- **Wage authority** from `WageStandardContextService` (integration-first path)

### Freshness needs

- Historical: closed shifts within rolling 60-day date window
- Target recalculation: on manager override commit
- Wage rates: resolved on profile persistence

### Future source ownership

| Data | Source |
|------|--------|
| Closed shift covers/sales/hours | POS + Labor |
| Wage rates | Labor (preferred), app fallback generator |
| Manager override selection state | App-owned |
| Derived targets (CPLH/SPLH/PPA/OPZ) | App-owned (computed from closed truth) |

### Target architecture destination

- `TargetCycle` — locks standards for 60 days (replaces live BaselineData recalculation)
- `ActiveTargetProfile` — runtime projection of the current cycle (already exists)

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| `BaselineData` in-memory globals | **Bridge** | Baseline tracker reads all display values directly from BaselineData; not yet migrated to ActiveTargetProfile |
| `MeridianConfig` static defaults | **Bridge** | Fallback wages in `_BaselineTargetsCard` when profile hasn't loaded; default OPZ bounds |
| `buildActiveTargetProfileFromBaseline()` | **Bridge** | Reads BaselineData globals to build persisted profile; should be replaced by TargetCycle |
| `primeManagerOverride()` at bootstrap | **Bridge** | Primes BaselineData from persisted selection on app start; temporary compat layer |
| Replay-seeded `shift_records` | **Demo** | 60-day window populated from `MockIntegrationReplaySeed`; Phase 8 replaces with live POS/labor |

### Owning phase for unresolved migrations

- `7.55l.1`–`7.55l.2`: TargetCycle replaces live BaselineData recalculation
- `7.55l.4`: ActiveTargetProfile becomes TargetCycle projection
- `7.55l.8`: Learn bridge cleanup retires remaining BaselineData reads
- Phase 8: Live POS/labor replaces replay-seeded shift data

---

## 2. Schedule

### User-facing purpose

Show the current week's operating plan: weekly forecast covers/sales,
FOH/BOH required hours, labor budget, and day-level allocation.

### Main files

| File | Role |
|------|------|
| `lib/screens/schedule_builder.dart` | Schedule display: weekly summary, day-level rows, daypart subrows |
| `lib/data/schedule_plan_read_service.dart` | Shared SchedulePlan resolution service (7.55i.2) |
| `lib/data/demand_forecast_context_service.dart` | Repository-backed demand context (7.55i.1) |
| `lib/data/demand_forecast_context_notifier.dart` | App-wide demand context notifier |
| `lib/data/schedule_distribution_weights_notifier.dart` | Day-level allocation weights from closed history |
| `lib/domain/services/schedule_plan_resolver.dart` | Formula engine: demand + targets + weights → plan |
| `lib/domain/services/schedule_forecast_demand_resolver.dart` | Covers → forecast sales derivation |
| `lib/domain/services/distribution_weight_builder.dart` | Builds distribution weights from closed shifts |

### Current operational truth consumed

- **DemandForecastContext** (repository-backed): `historicalWeeklyAvgCovers` from 60-day closed shift window
- **ActiveTargetProfile** (persisted): CPLH, SPLH, PPA, wages
- **ScheduleDistributionWeights**: day-level cover/sales/FOH/BOH shares from most recent 8 completed weeks
- **SchedulePlan** resolved through `SchedulePlanReadService.resolveFromInputs()`
- **BaselineData** fallback: `schedule_builder.dart:381–385` reads `BaselineData.derivedTargetCPLH/PPA/SPLH` and `MeridianConfig.fohWage/bohWage` as fallback when profile isn't ready

### Freshness needs

- Demand covers: rolling 60-day average (updated on closed shift ingest)
- Targets: stable within 60-day TargetCycle
- Distribution weights: recalculated from most recent 8 weeks on load
- Day allocation: recalculates each render from current inputs

### Future source ownership

| Data | Source |
|------|--------|
| Forecast covers | App-owned (derived from POS closed history) |
| Forecast sales | App-owned (covers × target PPA) |
| Target standards | App-owned (from TargetCycle) |
| Distribution weights | App-owned (from closed shift history) |
| Day allocation | App-owned (from demand + weights) |

### Target architecture destination

- `DemandForecastContext` — rolling demand (already exists, v2 in `7.55l.5`)
- `SchedulePlan` — weekly plan from demand + targets + weights (already exists)
- `WeeklyPlanSnapshot` — locked weekly plan auto-generated at week start (`7.55l.6`)

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| `BaselineData.derivedTarget*` fallback in `schedule_builder.dart` | **Bridge** | Used when profile not yet loaded; 3 reads at lines 381–383 |
| `MeridianConfig.fohWage/bohWage` fallback in `schedule_builder.dart` | **Bridge** | Lines 384–385 |
| Distribution weights from recent 8 weekIds | **Bridge** | Temporary 60-day approximation; should be explicit weekly plan allocation |
| Replay-seeded closed shifts for demand | **Demo** | DemandForecastContextService reads from replay-seeded shift_records |

### Owning phase for unresolved migrations

- `7.55l.3`: Weekly demand/day allocation becomes explicit plan generation rule
- `7.55l.5`: Rolling DemandForecastContext v2 with baseline + 3-week trend
- `7.55l.6`: WeeklyPlanSnapshot auto-generates and locks the week
- `7.55l.7`: Schedule reads the current locked weekly plan
- Phase 8: Live POS history replaces replay demand baseline

---

## 3. Shift

### User-facing purpose

Show today's live plan-vs-actual dashboard: whole-day forecast vs actuals for
covers, sales, FOH/BOH hours, labor dollars, and "In the books" reservation
signal.

### Main files

| File | Role |
|------|------|
| `lib/screens/shift_dashboard.dart` | Shift dashboard display |
| `lib/data/shift_dashboard_notifier.dart` | Loads ShiftDashboardReadModel from plan + snapshots |
| `lib/data/shift_service.dart` | `getShiftDashboard()` and `getFullWeekShifts()` |
| `lib/models/shift_dashboard_read_model.dart` | Whole-day read model built from aggregated snapshots |
| `lib/data/schedule_plan_read_service.dart` | Provides the day-level plan for the open shift's day |

### Current operational truth consumed

- **ActiveTargetProfile** (persisted): profile for OPZ zone status
- **SchedulePlan** day row: `forecastCovers`, `forecastSales`, `requiredFohHours`, `requiredBohHours`
- **Open shift snapshots** from `open_shift_snapshots` table: actual covers, sales, hours to date
- **Reservation book snapshots** from `reservation_book_snapshots` table: unseated covers (aggregated per day)
- **AppDataStatus**: determines empty/stale/current state display

### Freshness needs

- Plan values: stable for the week (from SchedulePlan; will be from WeeklyPlanSnapshot)
- Actuals: as close to real-time as the source provides (currently static open_shift_snapshots seeded by replay)
- Reservation signal: near-real-time (currently static reservation_book_snapshots seeded by replay)
- Shift is whole-business-day until Phase 10.5

### Future source ownership

| Data | Source |
|------|--------|
| Live covers/sales to date | POS |
| Scheduled/actual labor hours | Labor |
| Unseated reservation covers | Reservation |
| Forecast plan values | App-owned (from WeeklyPlanSnapshot) |
| OPZ zone status | App-owned |

### Target architecture destination

- `WeeklyPlanSnapshot` day row — replaces live SchedulePlan resolution for plan values
- Shift remains whole-day plan-vs-actual until Phase 10.5

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| Replay-seeded `open_shift_snapshots` | **Demo** | Static mid-service snapshot from `MockIntegrationReplaySeed`; Phase 8 replaces with live POS/labor |
| Replay-seeded `reservation_book_snapshots` | **Demo** | Static reservation data from replay seeder; Phase 8R replaces with live reservation vendor |
| Shift clock is static | **Demo** | No live clock ticking; Phase 8 work |
| `WageStandardContextService` profile load | **Bridge** | `loadOrBootstrapProfile()` for profile; bootstrap fallback still active |

### Owning phase for unresolved migrations

- `7.55l.6`–`7.55l.7`: Shift compares against WeeklyPlanSnapshot instead of live SchedulePlan
- Phase 8: Live POS/labor data replaces static open_shift_snapshots
- Phase 8R: Live reservation vendor replaces static reservation_book_snapshots
- Phase 10.5: Shift daypart-live behavior

---

## 4. Variance — This Week (WTD)

### User-facing purpose

Show week-to-date variance: actual vs target for covers, blended wage, PPA,
FOH/BOH hours, CPLH, SPLH, labor %. Dollar impact card. Primary driver.

### Main files

| File | Role |
|------|------|
| `lib/screens/variance_report.dart` (`_ThisWeekTab`) | WTD display: variance table, dollar impact, primary driver, full week projection |
| `lib/data/week_data_notifier.dart` | Shared WTD state loaded from ShiftDataSource |
| `lib/models/week_data.dart` | WTD aggregation model with all computed getters |
| `lib/data/shift_service.dart` (`getWeekToDate()`) | Aggregates closed shifts for current week |
| `lib/data/shift_data_source.dart` | Abstraction layer: LiveShiftDataSource (SQLite) vs StaticShiftDataSource (test) |

### Current operational truth consumed

- **Closed shift_records** for the current weekId: covers, sales, FOH/BOH hours, labor dollars
- **ActiveTargetProfile** (persisted): target CPLH, SPLH, PPA, wages, theoretical labor %
- **Open shift snapshots** (via `getFullWeekShifts()`): projected rows for unclosed days
- **LaborModel**: model hours, dollar gap, lever determination formulas

### Freshness needs

- Closed shifts: updated on each shift close
- Projected shifts: from open_shift_snapshots for future days within the current week
- Targets: stable within the current TargetCycle

### Future source ownership

| Data | Source |
|------|--------|
| Closed actual covers/sales/hours | POS + Labor |
| Target standards for comparison | App-owned (from locked WeeklyPlanSnapshot) |
| Projected future days | App-owned (from WeeklyPlanSnapshot) |
| Dollar gap / lever formulas | App-owned (LaborModel) |

### Target architecture destination

- `WeeklyPlanSnapshot` — Variance compares closed actuals against the locked weekly plan
- Closed actuals remain in `shift_records` table (already correct)

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| `StaticShiftDataSource` uses `BaselineData.derivedTarget*` | **Bridge** | Test-only source reads targets from BaselineData globals (lines 76–101) |
| `StaticShiftDataSource` uses `MeridianConfig.*` | **Bridge** | Test-only source reads wages and locked target defaults from MeridianConfig (lines 97–131) |
| `ShiftService.getWeekToDate()` uses `ActiveTargetProfile` | **Correct** | Already reads persisted profile, not BaselineData |
| `ShiftService._buildWeekRecord()` fallback wage uses `MeridianConfig` | **Bridge** | `MeridianConfig.fohWage/bohWage` as zero-hour fallback (line 285–286) |
| Replay-seeded shift_records | **Demo** | Current week shifts from replay seed; Phase 8 replaces |

### Owning phase for unresolved migrations

- `7.55l.6`–`7.55l.7`: Variance compares against locked WeeklyPlanSnapshot
- Phase 8: Live POS/labor data replaces replay-seeded shift data

---

## 5. Variance — History

### User-facing purpose

Show completed historical weeks: lever outcome, covers, PPA, CPLH, SPLH,
labor %, dollar gap. Tap into per-week detail.

### Main files

| File | Role |
|------|------|
| `lib/screens/variance_report.dart` (`_HistoryTab`) | History week list with lever tiles |
| `lib/screens/week_detail_screen.dart` | Per-week detail view |
| `lib/widgets/week_history_tile.dart` | Week row display widget |
| `lib/data/shift_service.dart` (`getWeekHistory()`) | Loads completed WeekRecords from SQLite |
| `lib/models/week_record.dart` | Completed week model with locked target fields |

### Current operational truth consumed

- **WeekRecords** from `week_records` table: aggregated metrics + locked targets from closed shifts
- **Locked target fields on WeekRecord**: `targetCPLH`, `targetSPLH`, `targetPPA`, `targetFohWage`, `targetBohWage`, `theoreticalFohLaborPct`, `theoreticalBohLaborPct`
- **MeridianConfig** defaults: `blendedFohWage/blendedBohWage` defaults in WeekRecord constructor (lines 51–52); `fromMap()` fallback (lines 141–143)

### Freshness needs

- Historical: fully closed weeks only (materialized when all 14 shifts are closed)
- Targets: locked at close time (TargetSnapshot on each shift; weighted average on week)

### Future source ownership

| Data | Source |
|------|--------|
| Week-level actuals | POS + Labor (aggregated from closed shifts) |
| Locked targets per week | App-owned (from TargetCycle in force at close time) |

### Target architecture destination

- `WeeklyPlanSnapshot` identity — History should show which TargetCycle and weekly plan each week belonged to
- Closed historical truth remains in `week_records` + `shift_records` (already correct)

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| `MeridianConfig.fohWage/bohWage` as WeekRecord defaults | **Bridge** | Constructor defaults and `fromMap()` fallback; only fires for pre-backfill rows |
| Replay-seeded `week_records` | **Demo** | 8 historical weeks from replay; Phase 8 replaces with real closed weeks |

### Owning phase for unresolved migrations

- `7.55l.7`: History preserves cycle and weekly-plan identity
- Phase 8: Live POS/labor data produces real completed weeks

---

## 6. History Pattern Analysis

### User-facing purpose

Builds the lever pattern signal from closed shifts that feeds both the History
teaching summary and the Learn teaching summary.

### Main files

| File | Role |
|------|------|
| `lib/services/history_pattern_builder.dart` | Builds `HistoryPatternRecord`s from closed shifts |
| `lib/services/history_teaching_analyzer.dart` | Summarizes: most common leak, top leak dayparts, benchmark dayparts |
| `lib/models/history_pattern_record.dart` | Per-shift pattern record: weekId, dayLabel, daypart, leverId, isBenchmark |

### Current operational truth consumed

- **Closed ShiftRecords**: `normalizedLeverId`, `weekId`, `dayLabel`, `daypart`
- **LeverCards** from `legacy_fixture_data.dart`: lever id validation, `isFavorable` check, `sideLabel`
- **LaborModel.isFavorableLever()**: benchmark classification

### Freshness needs

- Historical: closed shifts only
- Recalculated on each History/Learn tab open

### Future source ownership

| Data | Source |
|------|--------|
| Closed lever outcomes | App-owned (computed from POS + Labor actuals vs locked targets) |
| Lever card definitions | App-owned |

### Target architecture destination

- No model change needed; already operates on closed truth
- `7.55k` landed evidence-backed daypart depth (`7.55k.5` History benchmarks, `7.55k.7` visibility policy)

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| `LeverCards.all` from `legacy_fixture_data.dart` | **Bridge** | Lever definitions live in a legacy fixture file; should be standalone domain constants |
| Replay-seeded historical shifts | **Demo** | Pattern data derived from replay-seeded shifts |

### Owning phase for unresolved migrations

- `7.55k`: Evidence-backed daypart depth for History benchmark dayparts — **landed** (`7.55k.5`/`7.55k.5a` + `7.55k.7`/`7.55k.7a`)
- Phase 8: Real closed shifts replace replay-seeded history

---

## 7. Learn

### User-facing purpose

Summarize recurring leaks, benchmark patterns, repeatable wins, and coaching
guidance. Combines History pattern analysis with active baseline truth.

### Main files

| File | Role |
|------|------|
| `lib/screens/variance_report.dart` (`_LearnTab`) | Learn display: benchmark set, recurring leak, repeatable wins, coach next week |
| `lib/services/learn_teaching_analyzer.dart` | Combines history patterns with injected benchmark context (no BaselineData reads since 7.55l.8a) |
| `lib/data/learn_benchmark_context_service.dart` | Resolves `LearnBenchmarkContext` from persisted cycle/profile/summary authority |
| `lib/models/learn_benchmark_context.dart` | Immutable benchmark context model |
| `lib/models/learn_teaching_summary.dart` | Immutable summary model |

### Current operational truth consumed

- **HistoryPatternRecords** via `ShiftDataSource.getHistoryPatternRecords()`
- **LearnBenchmarkContext** (resolved by `LearnBenchmarkContextService` from persisted authority):
  - `benchmarkSourceLabel` — from `ActiveTargetProfile.sourceType`
  - `selectedShiftCount` — from persisted `BenchmarkSelectionSummary`
  - `targetCPLH` / `targetSPLH` / `targetPPA` — from persisted `ActiveTargetProfile`
  - `rangeQualityLabel` / `rangeQualityMessage` — from persisted `BenchmarkSelectionSummary`
- **HistoryTeachingAnalyzer** output: leak id/count/dayparts, benchmark id/count/side

### Freshness needs

- Historical: closed shifts only (pattern records)
- Benchmark context: from persisted cycle/profile/summary authority (updated on cycle creation or manager override commit)
- Recalculated on Learn tab open

### Future source ownership

| Data | Source |
|------|--------|
| History pattern records | App-owned (from closed shifts) |
| Benchmark/target context | App-owned (from TargetCycle) |
| Teaching summaries | App-owned |

### Target architecture destination

- `TargetCycle` — benchmark context authority (implemented, 7.55l.8a–8d1)
- `BenchmarkSelectionSummary` — persisted selection analytics tied to cycle (implemented, 7.55l.8c)
- `WeeklyPlanSnapshot` — comparison truth for pattern analysis

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| ~~`BaselineData` — 6 direct reads~~ | **Retired (7.55l.8a)** | `LearnTeachingAnalyzer` no longer reads `BaselineData`. Benchmark context now comes from injected `LearnBenchmarkContext` resolved from persisted authority. |
| `LearnBenchmarkContextService` bridge-only mode | **Bridge** | Widget tests use `enableBridgeOnly()` to bypass SQLite. Intentional. |
| `LearnBenchmarkContextService` no-profile bootstrap | **Bridge** | First launch before any cycle/profile. Intentional and narrow. |
| `_LearnTabState` inline `Future.wait().then()` | **Bridge** | Load pattern in initState; could move to notifier |
| Replay-seeded history for patterns | **Demo** | Pattern data from replay-seeded closed shifts |

### Owning phase for unresolved migrations

- ~~**`7.55l.8`**: Learn migration — move off BaselineData benchmark context~~ — **Complete (7.55l.8a–8d1)**
- `7.55k`: Evidence-backed coaching and repeatable wins depth — **landed** (`7.55k.6`/`7.55k.6a` + `7.55k.7`/`7.55k.7a`)
- Phase 8: Real closed history replaces replay patterns

---

## 8. Data Alignment Audit

### User-facing purpose

Expandable panel on Settings screen showing side-by-side comparison of all
data layers for architectural alignment verification.

### Main files

| File | Role |
|------|------|
| `lib/widgets/data_alignment_audit_panel.dart` | Audit display: loads and renders all data layers |

### Current operational truth consumed

- **ActiveTargetProfile** from `SqliteTargetProfileRepository`
- **DemandForecastContext** from `DemandForecastContextService`
- **SchedulePlan** from `SchedulePlanReadService`
- **ShiftDashboardReadModel** from `ShiftService.getShiftDashboard()`
- **WeekData** from `ShiftService.getLiveWeekToDate()`
- **WageStandardContext** from `WageStandardContextService`
- **BaselineData** globals: `derivedTargetCPLH`, `derivedTargetSPLH`, `derivedTargetPPA`, `opzFloorCPLH`, `opzCeilingCPLH` (displayed as "BASELINE" column)
- **MeridianConfig** values: `weeklyCovers`, `targetCPLH`, `targetPPA`, `targetSPLH`, `fohWage`, `bohWage` (displayed as "MERIDIAN" column)

### Freshness needs

- On-demand: loads when panel is expanded
- Reads current state of every data layer

### Future source ownership

All data layers are app-owned. The audit panel is a diagnostic tool that
should remain and should display provenance (which source system each value
came from).

### Target architecture destination

- `TargetCycle` and `WeeklyPlanSnapshot` models now exist (`7.55l` landed). The
  audit panel does not yet expose cycle/week columns — this is a remaining
  migration gap on the audit surface, not a missing model.
- Should expose cycle identity and weekly plan identity when the audit panel
  is next updated.

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| `BaselineData.*` displayed as "BASELINE" column | **Bridge** | 5 direct reads for side-by-side comparison; intentional for audit visibility |
| `MeridianConfig.*` displayed as "MERIDIAN" column | **Bridge** | 6 reads for default comparison; intentional for audit visibility |
| All data comes from replay-seeded SQLite | **Demo** | Audit reflects replay state; Phase 8 will show live-sourced data |

### Owning phase for unresolved migrations

- `7.55l.7`: Audit exposes cycle/week provenance
- `7.55l.8`: BaselineData column may be retired or repurposed once bridge is removed

---

## 9. Settings / App Data Status

### User-facing purpose

App settings, mock replay scenario controls, data reseed/clear, and data
status evaluation.

### Main files

| File | Role |
|------|------|
| `lib/screens/settings_screen.dart` | Settings display: status, mock replay date, reseed, clear, wage setup, audit panel |
| `lib/data/app_data_status_service.dart` | Evaluates: no data / historical only / stale / current / failed import |

### Current operational truth consumed

- **AppDataStatus**: evaluated from import_runs, week_records, open_shift_snapshots
- **MockReplayBusinessDate** from `mock_replay_state` table
- **WageStandardContext** from `WageStandardContextService`
- **WageRoleRows** from `wage_role_rows` table (wage setup section)
- All notifiers refreshed on reseed: `RestaurantScopeNotifier`, `ActiveTargetProfileNotifier`, `WeekDataNotifier`, `ShiftDashboardNotifier`, `DemandForecastContextNotifier`, `ScheduleDistributionWeightsNotifier`

### Freshness needs

- Status: evaluated on screen open and after reseed/clear operations
- Mock replay: persistent mock business date for scenario control

### Future source ownership

| Data | Source |
|------|--------|
| Import status / sync watermarks | App-owned (from connector layer) |
| Connector configs | App-owned (from Phase 8 setup) |
| Wage role setup | Labor (preferred), app fallback |
| Mock replay scenario | Demo-only (not present in production) |

### Target architecture destination

- `TargetCycle` status: should show current cycle identity and remaining days
- `WeeklyPlanSnapshot` status: should show current week plan state
- Connector status: Phase 8 will add connector health visibility

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| `MockIntegrationReplaySeed` scenario controls | **Demo** | Advance/reset business date for replay; not present in production |
| `ShiftService.reseedDemo()` and `clearAllData()` | **Demo** | Demo data lifecycle management |
| `WageStandardContextService` wage setup | **Correct** | Integration-first wage path with fallback; already correct architecture |
| `AppDataStatusService` reads `import_runs` | **Correct** | Import tracking already uses real schema |

### Owning phase for unresolved migrations

- `7.55l.7`: Settings should expose cycle/week status
- Phase 8: Live connector status replaces demo import status

---

## 10. Reservation — "In the Books"

### User-facing purpose

Show unseated reservation covers on the Shift dashboard as the "In the books"
signal.

### Main files

| File | Role |
|------|------|
| `lib/domain/models/reservation_book_snapshot.dart` | Aggregate reservation state per shift slot |
| `lib/domain/repositories/reservation_book_snapshot_repository.dart` | Repository interface |
| `lib/infrastructure/persistence/sqlite/repositories/sqlite_reservation_book_snapshot_repository.dart` | SQLite implementation |
| `lib/infrastructure/persistence/sqlite/dao/reservation_book_snapshot_dao.dart` | DAO for reservation table |
| `lib/data/shift_dashboard_notifier.dart` | Aggregates unseated covers into ShiftDashboardReadModel |
| `lib/data/shift_service.dart` (`getShiftDashboard()`) | Loads and sums reservation snapshots for the day |

### Current operational truth consumed

- **ReservationBookSnapshot**: `unseatedCovers`, `unseatedPartyCount` per restaurant/businessDate/daypart
- Stored in `reservation_book_snapshots` table
- Aggregated to whole-day `inTheBooksCovers` in ShiftDashboardReadModel

### Freshness needs

- Near-real-time during service: reservation status changes should propagate quickly
- Currently static: seeded once from replay and not updated during runtime

### Future source ownership

| Data | Source |
|------|--------|
| Reservation party size / status / time | Reservation vendor (Phase 8R) |
| Unseated covers aggregation | App-owned |

### Target architecture destination

- Reservation data remains contextual (Shift signal, optional History context)
- Not promoted into demand forecast unless a future product decision explicitly does so
- Schema is already Phase 8R-ready (sourceSystem, sourceServiceId, lastEventAt fields)

### Current bridge/demo dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| Replay-seeded `reservation_book_snapshots` | **Demo** | Static snapshot from replay seeder; Phase 8R replaces with live vendor |
| No live reservation webhook/poll | **Demo** | Data never updates during runtime; Phase 8R adds live sync |

### Owning phase for unresolved migrations

- Phase 8R: Live reservation vendor integration
- Phase 7.56 (complete): App-side demo path for reservation signal

---

## 11. Bootstrap / Transport / Replay / Fixture Truth Path

### User-facing purpose

Not directly user-facing. This is the data lifecycle that populates SQLite
operational tables on app start and reseed.

### Main files

| File | Role |
|------|------|
| `lib/forge_flow_bootstrap.dart` | App start: primes BaselineData from persisted selection |
| `lib/data/mock_integration_replay_seed.dart` | Deterministic mock POS/labor replay generator |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | Schema creation, demo seeding, migration, reseed |
| `lib/data/legacy_fixture_data.dart` | `BaselineData`, `MeridianConfig`, `DemoData`, `LeverCards`, `ShiftSnapshot` |
| `lib/data/fixture_seed_data.dart` | Static fixture seed data (pre-replay era; still used by some test paths) |

### Current operational truth path

```text
MockIntegrationReplaySeed.generateForDate(businessDate)
-> MockReplayOutput (shifts, weeks, scenario)
-> SqliteDatabase._seedDemoDataFromReplay(db, replay)
  -> shift_records table
  -> week_records table (with locked target backfill)
  -> open_shift_snapshots table
  -> reservation_book_snapshots table
  -> active_target_profiles table
  -> import_runs + raw_import_records tables
```

Additionally:
```text
BaselineManagerService.primeManagerOverride()
-> loads candidates from shift_records (60-day window)
-> primes BaselineData in-memory globals
-> persists ActiveTargetProfile
```

### Current transport assumptions

| Assumption | Status | Notes |
|------------|--------|-------|
| `MockIntegrationReplaySeed` generates all operational data | **Demo** | Replaces real POS/labor/reservation ingestion |
| `sourceSystem = 'mock_pos_labor_replay'` | **Demo** | Marks all seeded data as mock-sourced |
| `mock_replay_state` table holds current business date | **Demo** | Anchor for date-parameterized scenario |
| `BaselineData` primed at bootstrap from persisted selection | **Bridge** | Temporary compat; canonical authority is persisted ActiveTargetProfile |
| `MeridianConfig` provides static default constants | **Bridge** | Compatibility defaults; should be replaced by TargetCycle or app configuration |
| `DemoData` (legacy) still referenced by `fixture_seed_data.dart` | **Bridge** | Pre-replay fixture data; used by some test harnesses |

### Owning phase for transport replacement

- Phase 8: Live POS + Labor adapters replace `MockIntegrationReplaySeed`
- Phase 8R: Live reservation vendor replaces replay reservation seeding
- `7.55l.8`: Retirement of BaselineData bridge and demo/replay path isolation

---

## Summary: Bridge/Demo Dependency Map

### BaselineData bridge reads (to be retired by 7.55l)

| File | Read | Count |
|------|------|-------|
| `baseline_tracker.dart` | All display values, daypart ranges, range graph, validation | ~15 reads |
| ~~`learn_teaching_analyzer.dart`~~ | **Retired (7.55l.8a).** Now reads injected `LearnBenchmarkContext`. | 0 reads |
| `schedule_builder.dart` | target CPLH/PPA/SPLH fallback | 3 reads |
| `data_alignment_audit_panel.dart` | targets, OPZ (audit display) | 5 reads |
| `sqlite_database.dart` | `buildActiveTargetProfileFromBaseline()` | 6 reads |
| `baseline_manager_service.dart` | primeManagerOverride in-memory compat | 4 calls |
| `shift_data_source.dart` (StaticShiftDataSource) | target/theoretical fields | 8 reads |
| `target_snapshot_builder.dart` | bridge `fromBaselineData()` method | 6 reads |
| `legacy_fixture_data.dart` (ShiftSnapshot) | shift detail cards | 8 reads |

### MeridianConfig bridge reads (to be retired or moved to config)

| File | Read | Count |
|------|------|-------|
| `schedule_builder.dart` | fohWage, bohWage fallback | 2 reads |
| `baseline_tracker.dart` | fohWage, bohWage fallback | 2 reads |
| `baseline_manager_screen.dart` | fohWage, bohWage for preview | 2 reads |
| `shift_data_source.dart` (StaticShiftDataSource) | all target defaults | 9 reads |
| `shift_service.dart` | zero-hour wage fallback | 2 reads |
| `week_record.dart` | constructor/fromMap defaults | 4 reads |
| `shift_record.dart` | labor dollar fallback | 3 reads |
| `wage_standard_context_service.dart` | config fallback | 2 reads |
| `data_alignment_audit_panel.dart` | Meridian column display | 6 reads |
| `target_snapshot_builder.dart` | bridge method | 4 reads |
| `mock_integration_replay_seed.dart` | target standards | 5 reads |

### Demo/replay dependencies (to be replaced by Phase 8 / 8R)

| Component | Notes |
|-----------|-------|
| `MockIntegrationReplaySeed` | All current operational data originates here |
| `mock_replay_state` table | Business date scenario control |
| `_seedDemoDataFromReplay()` | SQLite bootstrap from replay output |
| `reseedDemo()` / `reseedMockReplayForBusinessDate()` | Demo lifecycle controls |
| Static `open_shift_snapshots` | No live clock or POS feed |
| Static `reservation_book_snapshots` | No live reservation feed |

---

## Cross-Reference: Architecture Destination Map

| Architecture Model | Current Status | Owning Phase |
|-------------------|----------------|--------------|
| `TargetCycle` | **Landed** — persisted 60-day locked cycle with auto-refresh | `7.55l.1`–`7.55l.2` |
| `ActiveTargetProfile` as cycle projection | **Landed** — projected from `TargetCycle` | `7.55l.4` |
| `DemandForecastContext` v2 (baseline + 3-week trend) | **Landed** — baseline + fixed 3-week recent trend | `7.55l.5` |
| `WeeklyPlanSnapshot` | **Landed** — auto-generated and locked per business week | `7.55l.6` |
| Consumer migration (Schedule, Shift, Variance, History) | **Landed** | `7.55l.7` |
| Learn bridge retirement | **Landed** (7.55l.8a–8d1) — production runtime uses persisted cycle/profile/summary | `7.55l.8` |
| Evidence-backed History / Learn daypart depth | **Landed** (7.55k.4–7.55k.7a) — benchmark dayparts, repeatable wins, visibility policy | `7.55k` |
| App-owned service-period definitions | Direction confirmed; runtime implementation queued | `7.55n` |
| Live POS/Labor transport | Not connected | Phase 8 |
| Live Reservation transport | Not connected | Phase 8R |

---

## UX Guardrail Compliance

All surfaces inventoried above operate under the rule:

- No intended manager-facing UX change in Benchmark, Schedule, History, or Learn
- All planned architecture work (TargetCycle, WeeklyPlanSnapshot, bridge retirement) is internal
- No draft/publish state in the UI
- No new manager workflow
