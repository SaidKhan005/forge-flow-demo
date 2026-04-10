# Phase 7.55e - Distribution + Mock Integration Replay Plan

Updated: 2026-04-10

## Status

Phase 7.55e is active, not closed.

Verified:

- `7.55e.1` - `ScheduleDistributionWeights` model and `DistributionWeightBuilder`
- `7.55e.2` - `SchedulePlanResolver` accepts distribution weights
- `7.55e.3` - Schedule daypart subrows consume day x daypart weights
- `7.55e.4` - runtime distribution weights load from closed `ShiftRecord`s into Schedule

Remaining before closeout:

- `7.55e.5` - deterministic mock POS/labor integration replay into SQLite
- `7.55e.6` - retire production runtime dependence on hardcoded `DemoData` operational lists

## Purpose

Make day-of-week and day x daypart planning distribution come from closed operational history, not hardcoded Schedule constants or flat Baseline daypart averages.

This phase is the bridge between fixture/demo data and Phase 8 live adapters:

```text
mock POS/labor integration replay
-> canonical SQLite operational facts
-> distribution weights from closed ShiftRecords
-> SchedulePlan
-> Schedule day rows and daypart subrows
```

Phase 8 should then replace mock transport with official vendor transport without creating a second UI-facing truth path.

## Current Architecture After 7.55e.4

```text
closed ShiftRecords
-> ScheduleDistributionWeightsNotifier
-> DistributionWeightBuilder.fromClosedShifts(...)
-> ScheduleDistributionWeights
-> ScheduleForecastNotifier
-> SchedulePlanResolver
-> Schedule day plans
-> Schedule daypart subrows
```

Current implementation details:

- `ScheduleDistributionWeights` carries raw day and day x daypart cover weights.
- `DistributionWeightBuilder` filters to closed shifts, counts distinct business days by `weekId|dayLabel`, and requires at least 14 distinct closed business days.
- `SchedulePlanResolver` uses available day weights for weekly-to-day allocation and falls back to `_defaultDayWeights` when weights are unavailable.
- `ScheduleForecastNotifier.adjustedDayViews` uses day-specific daypart weights when available and falls back to `WeekDayOrder.daypartsFor(...)` plus `_daypartCoverWeight`.
- Largest-remainder allocation keeps day and subrow totals reconciled exactly.
- Runtime loading currently uses the most recent 8 `weekId`s as a temporary pre-7.55f approximation of a 60-day window.

## Remaining Gap

The app can now consume closed-shift-derived distribution weights, but SQLite startup still seeds operational history from hardcoded fixture lists:

- `DemoData.currentWeekShifts`
- `DemoData.historicalClosedShifts`
- `DemoData.weekHistory`

That means 7.55e is not fully closed yet. The distribution architecture is real, but the seeded operational source should move from hand-authored fixture arrays to deterministic mock integration replay.

## 7.55e.5 - Mock Integration Replay Seed

Goal:

Replace hardcoded historical/current operational seed rows with a deterministic mock POS/labor integration replay that writes into SQLite as if official adapters imported the data.

Expected replay output:

- roughly 60 business days of closed day x daypart `ShiftRecord`s
- current-week open/projected snapshots generated from the same mock source
- `WeekRecord`s derived from closed shifts, not separately hand-authored
- coherent covers, sales, FOH hours, BOH hours, labor dollars, PPA, CPLH, SPLH, and lever fields
- realistic variation:
  - slow Mondays
  - midweek build
  - stronger Friday and Saturday dinner
  - late-night where applicable
  - softer Sunday
  - small deterministic noise for weather/event-like swings
- source provenance such as `mock_pos` and `mock_labor`
- import metadata where useful, without pretending to be a live vendor connector

Guardrails:

- This is mock transport only.
- Do not add live vendor credentials, scraping, or unofficial APIs.
- Keep data deterministic so tests and screenshots are stable.
- Keep target/profile math unchanged.
- Keep Schedule fallback behavior for insufficient history.
- Do not start true `business_date` persistence unless explicitly pulled forward from 7.55f.

## 7.55e.6 - Retire Fixture Runtime Dependence

Goal:

Make the app runtime prove that operational screens are reading mock-imported SQLite state, not `DemoData` fixture lists.

Expected outcome:

- SQLite bootstrap uses the mock replay path for operational history/current state.
- Runtime Schedule distribution, Baseline candidate loading, Shift, Variance, and Learn history paths read repository-backed state.
- `DemoData` or static fixtures may remain only as tests, preview data, or explicitly marked compatibility bridges.
- Any remaining `DemoData` runtime references are documented with a reason and a follow-up owner.

Guardrails:

- Do not remove compatibility bridges prematurely if tests or preview-only paths still require them.
- Do not make `BaselineData` the production source for operational history.
- Do not conflate this work with 7.55i canonical demand/read-service cleanup.
- Do not conflate this work with 7.55f true date-window querying.

## Relationship To 7.55f

7.55e can continue using the current `weekId + dayLabel + daypart` model for mock replay.

7.55f owns:

- persisting true `business_date` on `ShiftRecord`
- replacing the recent-8-week approximation with true rolling 60-day date-window queries
- Manager Override calendar navigation based on real business dates

Once 7.55f lands, the mock replay and distribution loader should migrate from week approximation to business-date windows.

## Relationship To Phase 8

Phase 8 should swap transport only:

```text
official POS/labor adapter
-> same canonical SQLite facts
-> same repositories
-> same DistributionWeightBuilder
-> same SchedulePlan/Schedule path
```

Phase 8 should not introduce screen-specific forecast/distribution logic.

## Architectural Decisions

- Forecast covers remain demand context, not a Schedule screen input.
- Forecast sales remains app-derived as forecast covers x target PPA.
- FOH planning remains covers / target CPLH.
- BOH planning remains forecast sales / target SPLH.
- Distribution weights shape how weekly demand is allocated across days and dayparts.
- Distribution weights do not change weekly forecast covers or weekly forecast sales.
- Reservation `In the books` remains contextual and does not mutate Schedule forecast covers.
- Live daypart-aware Shift views remain Phase 10.5.

## Key Files

| File | Role |
| --- | --- |
| `lib/domain/models/schedule_distribution_weights.dart` | Distribution weight read model |
| `lib/domain/services/distribution_weight_builder.dart` | Builds weights from closed shifts |
| `lib/domain/services/schedule_plan_resolver.dart` | Applies day weights to SchedulePlan |
| `lib/screens/schedule_builder.dart` | Applies daypart weights to Schedule rows |
| `lib/data/schedule_distribution_weights_notifier.dart` | Runtime loader for distribution weights |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | Current seed/bootstrap path; remaining 7.55e.5/e.6 target |
| `lib/data/fixture_seed_data.dart` | Current hand-authored fixture data; should stop being production runtime truth |
| `lib/data/shift_data_source.dart` | Static/live data-source split; remaining compatibility bridge |

## Closeout Criteria

7.55e can close only when:

- day and daypart distribution weights are built from closed operational history
- runtime Schedule consumes those weights
- SQLite demo/bootstrap operational data is generated by deterministic mock integration replay, not copied from hand-authored operational fixture lists
- app runtime paths use repository-backed SQLite state for operational history/current state
- remaining fixture/static paths are explicitly documented as tests, preview, or temporary compatibility only
- fallback behavior remains safe when history is unavailable
- tests cover the mock replay and fixture-runtime-retirement guardrails
