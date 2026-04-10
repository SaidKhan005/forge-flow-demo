# Phase 7.55e.6 — Runtime Fixture Retirement Audit

Date: 2026-04-10
Status: Complete

## Removed / Converted Operational Fixture Reads

| File | Before | After |
|------|--------|-------|
| `lib/data/shift_data_source.dart` | `StaticShiftDataSource` read `DemoData.weekHistory`, `DemoData.historicalClosedShifts`, `DemoData.currentWeekShifts`, and `WeekToDate` constants | Now reads `MockIntegrationReplaySeed.output` for all operational data |
| `lib/data/shift_data_source.dart` | Imported `fixture_seed_data.dart` | Import removed; replaced with `mock_integration_replay_seed.dart` |
| `lib/widgets/data_alignment_audit_panel.dart` | `DemoData.currentWeekShifts.length` in demo seed section | Now reads `MockIntegrationReplaySeed.output.currentWeekShifts.length` |
| `lib/widgets/data_alignment_audit_panel.dart` | Imported `fixture_seed_data.dart` | Import removed; replaced with `mock_integration_replay_seed.dart` |

After 7.55e.6, `fixture_seed_data.dart` has zero `lib/` consumers. It is only imported by test files.

## Remaining Allowed Fixture / Static References

### 1. `legacy_fixture_data.dart` — BaselineData, MeridianConfig, LeverCards

**Status:** Allowed — target/baseline compatibility bridge.
**Reason:** `BaselineData` provides derived target values (CPLH, SPLH, PPA, OPZ, labor %) and historical context for the active target profile bridge. `MeridianConfig` provides restaurant config defaults and wage constants. `LeverCards` provides lever card definitions. None of these are operational shift/week data.
**Owner:** Phase 7.55i — Canonical Demand + Shared SchedulePlan Authority.

Consumers in `lib/`:
- `shift_data_source.dart` — `StaticShiftDataSource` uses `BaselineData`/`MeridianConfig` for target fields only
- `shift_service.dart` — `MeridianConfig` for blended-wage zero-hour fallback
- `shift_dashboard_notifier.dart` — `BaselineData` for fallback profile build
- `baseline_manager_service.dart` — `BaselineData` for override priming
- `schedule_builder.dart` — `BaselineData` for demand context
- `learn_teaching_analyzer.dart` — `BaselineData` for benchmark context
- `data_alignment_audit_panel.dart` — `BaselineData`/`MeridianConfig` for audit display
- Various screens/widgets — `LeverCards` for lever definitions, `MeridianConfig` for display constants

### 2. `legacy_fixture_data.dart` — WeekToDate, WeeklyVariance, ShiftSnapshot, WtdSnapshot

**Status:** Allowed — internal legacy fixture definitions. No production runtime consumers.
**Reason:** These classes exist inside `legacy_fixture_data.dart` itself. After 7.55e.6, no code in `lib/` reads `WeekToDate.`, `ShiftSnapshot.`, or `WeeklyVariance.` except within the legacy fixture data file. `WtdSnapshot` delegates to `WeekToDate`.
**Owner:** Can be cleaned up opportunistically. Not blocking.

### 3. `fixture_seed_data.dart` — DemoData class

**Status:** Allowed — test-only. Zero `lib/` consumers after 7.55e.6.
**Reason:** Tests use `DemoData` as local fixtures for lever logic, history analysis, and teaching analyzer tests. These do not claim production runtime truth.
**Files:** `test/lever_logic_test.dart`, `test/variance_history_widget_test.dart`, `test/learn_teaching_analyzer_test.dart`, `test/history_teaching_analyzer_test.dart`

### 4. StaticShiftDataSource

**Status:** Allowed — test/preview compatibility. NOT wired into app runtime.
**Reason:** `ForgeFlowScope` provides `LiveShiftDataSource` for production runtime. `StaticShiftDataSource` is used by widget tests that need a non-SQLite fixture source (avoids sqflite I/O and google_fonts/runAsync incompatibility). Now backed by `MockIntegrationReplaySeed` instead of `DemoData`.
**Consumers:** `test/variance_visual_widget_test.dart`, `test/learn_layer_widget_test.dart`, `test/wtd_variance_logic_test.dart`

## Production Runtime Data Flow (after 7.55e.6)

```
MockIntegrationReplaySeed (deterministic mock POS/labor replay)
  -> SQLite seed (shift_records, week_records, open_shift_snapshots)
  -> Repository layer (SqliteShiftRecordRepository, etc.)
  -> ShiftService / LiveShiftDataSource
  -> ForgeFlowScope -> Screen notifiers -> UI
```

No production runtime screen reads `DemoData`, `WeekToDate`, `ShiftSnapshot`, or `StaticShiftDataSource`.

## Handoff

- **7.55f:** `business_date` persistence, true 60-day date-range queries, calendar navigation.
- **7.55i:** Retire `BaselineData` reads from production surfaces. Canonical Demand Forecast Context. Shared SchedulePlan authority. Learn migration.
