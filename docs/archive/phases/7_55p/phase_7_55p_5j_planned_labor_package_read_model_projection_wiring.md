# Phase 7.55p.5j - Planned Labor Package Read Model + Projection Wiring

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Implement the `7.55p.5i` scope-aware planned labor package as one
app-owned read model/service seam and wire it into planning-facing
Schedule surfaces, while preserving the `7.55p.5c` / `7.55p.5d` split
that keeps Benchmark and Variance on the theoretical package.

## Scope

- In: `PlannedLaborPackage` value type + `PlannedLaborPackageReadService`
  (pure, no DB); Schedule Builder weekly-summary card; Schedule
  Builder day/daypart planning table; honest degradation where same-
  scope inputs are missing; focused tests; phase doc
- Out: Variance WTD / Variance Full Week / `WeekData` / Benchmark —
  all stay on the theoretical package (`7.55p.5c` / `7.55p.5d`)
- Out: Shift redesign — Shift's existing whole-day planned package in
  `ShiftDashboardReadModel` already produces the same formula
  (`(planHours × wages) / forecastSales`); this slice does not unify
  or refactor Shift
- Out: per-daypart OPZ / daypart-aware runtime work (Phase 10.5)
- Out: recommendation-engine work (`7.55p.5g` / `5h` lanes)
- Out: schema churn — no new persistence columns

## Runtime seam

```
SchedulePlan (existing authority, still the weekly planning model)
   │
   │  plus ActiveTargetProfile wages
   v
PlannedLaborPackageReadService  ←  one seam for planning-facing consumers
   │
   ├── forWeek(plan, wages)                → PlannedLaborPackage (week)
   ├── forDay(dayPlan, wages)               → PlannedLaborPackage (day)
   ├── forDaypart(fohHrs, bohHrs, sales,…)  → PlannedLaborPackage (daypart)
   └── aggregate(parentScope, children)     → PlannedLaborPackage
       (sums dollars + sales, recomputes %; never averages child %)
   │
   v
ScheduleForecastNotifier.adjustedDayViews
   - each ScheduleDayView carries a day-scope PlannedLaborPackage
   - each ScheduleDaySubrow carries a daypart-scope PlannedLaborPackage
   │
   v
Schedule Builder UI
   - WEEKLY PLAN SUMMARY "PLANNED LABOR %" card
     reads notifier.plannedLaborPackageForWeek
   - DAY-BY-DAY PLAN table
     header: PLANNED LABOR % column
     day rows: day-scope %
     daypart subrows: daypart-scope %
     total row: aggregate package % (cover-weighted, not mean)
```

## Package meaning

The planned labor package follows the `7.55p.5i` contract verbatim:

```
planned labor dollars(scope) =
    planFohHours(scope) × fohWage
  + planBohHours(scope) × bohWage

planned labor %(scope) =
    planned labor dollars(scope)
  / forecast sales(scope)
  × 100
```

`forecastSales` and `planFohHours`/`planBohHours` must come from the
same scope. `PlannedLaborPackage.plannedLaborPct` returns null when
either input is missing or zero at that scope. Surfaces render `—` in
that case instead of fabricating a number.

## Aggregation rule (no mean-of-percentages)

`PlannedLaborPackageReadService.aggregate(parentScope, children)`
enforces the `7.55p.5i §2` rule:

1. Sum `planFohHours`, `planBohHours`, `forecastSales` across children
2. Recompute the parent % from those totals
3. Never average child percentages

The new test
`test/planned_labor_package_read_service_test.dart` proves this with
fixture data where the aggregate differs from the raw mean of child
percentages by nearly a full percentage point — so a regression toward
"average of %s" would be caught. `test/schedule_builder_widget_test.dart`
group C extends that proof through the real notifier + widget path by
asserting the aggregated total % differs materially from the raw day
mean.

## Files touched

| File | Change |
|---|---|
| `lib/domain/models/planned_labor_package.dart` | **New** value type carrying same-scope inputs and derived planned labor dollars + % with null-degrading semantics |
| `lib/data/planned_labor_package_read_service.dart` | **New** pure service with `forWeek` / `forDay` / `forDaypart` / `aggregate` methods; no DB access |
| `lib/screens/schedule_builder.dart` | Added `plannedLaborPackageForWeek` getter on the notifier; `adjustedDayViews` now builds day-scope and daypart-scope packages via the service; `_DerivedSummaryCards` "LABOR %" card renamed to "PLANNED LABOR %" and routes through the notifier's week package; `_DayTable` passes packages to `ScheduleDayRow` and builds the total row via `service.aggregate(...)` |
| `lib/widgets/schedule_day_row.dart` | Added optional `plannedLabor: PlannedLaborPackage?` param; header gains a `PLANNED LABOR %` column; data rows render `plannedLaborPct` or `—` |
| `test/planned_labor_package_read_service_test.dart` | **New** — groups A (week), B (day), C (daypart), D (aggregation), E (unavailable factory) |
| `test/schedule_builder_widget_test.dart` | Added group C — weekly summary label, day-table header, package presence on views, total-vs-mean aggregation |

## Files intentionally untouched

| File | Why |
|---|---|
| `lib/services/variance_week_projection_read_service.dart` | Variance stays on theoretical package (`7.55p.5d`) |
| `lib/models/week_data.dart` | Variance WTD source stays on theoretical |
| `lib/screens/variance_report.dart` | Same |
| `lib/screens/baseline_tracker.dart` | Benchmark stays on theoretical |
| `lib/data/target_cycle_service.dart` | Cycle writes stay unchanged |
| `lib/models/shift_dashboard_read_model.dart` | Shift's existing whole-day planned package already produces the same formula; no shared seam was clearly warranted in this slice, and broadening would drift the scope |
| `lib/data/schedule_plan_read_service.dart` | `SchedulePlan` math and provenance are untouched; the new planned package is a parallel honest view over the same inputs |

## Honest degradation

- **Zero forecast sales at scope** → package `plannedLaborPct` is null;
  widgets render `—`
- **Zero planned hours at scope** → package `plannedLaborPct` is null;
  widgets render `—`
- **Mismatched wages across aggregation children** → service throws
  `ArgumentError` instead of silently averaging; surfaces wage drift
  instead of masking it (important when a wage authority change happens
  mid-plan)

## Surface ownership (7.55p.5i §4 enforced in code)

| Surface | Consumes planned package | Label seen by user |
|---|---|---|
| Schedule weekly-summary card | Yes (week scope) | `PLANNED LABOR %` |
| Schedule day-by-day table — day rows | Yes (day scope) | `PLANNED LABOR %` column |
| Schedule day-by-day table — daypart subrows | Yes (daypart scope, same-scope inputs exist today) | `PLANNED LABOR %` column |
| Schedule day-by-day total row | Yes (service aggregate, cover-weighted) | `PLANNED LABOR %` column |
| Shift | Yes (existing `ShiftDashboardReadModel`) | `Target x.x%` — existing "target" here semantically means "plan target for today", not "theoretical calibration target" |
| Benchmark (`_BaselineTargetsCard`) | **No** | Keeps `TOTAL THEORETICAL %` |
| Variance WTD | **No** | Keeps theoretical target column |
| Variance Full Week | **No** | Keeps theoretical target column |

## What this slice does NOT do

- **Does not rename `SchedulePlan.theoreticalLaborPct`.** That field
  still exists and still computes the same number. The planned package
  is a parallel honest view with planning-facing vocabulary — not a
  rename. Renaming would cascade into `WeeklyPlanSnapshot`-projected
  surfaces, which is outside this slice.
- **Does not touch Shift.** `ShiftDashboardReadModel` already computes
  `targetLaborDollars = planFohHours × fohWage + planBohHours × bohWage`
  and `targetLaborPct = targetLaborDollars / forecastSales × 100` — the
  identical planned-package formula. A shared seam would be a bigger
  refactor than this slice warrants and the prompt explicitly said not
  to broaden into Shift unless the shared seam is clearly useful.
- **Does not add per-daypart persistence.** Daypart-scope planned %
  consumes values that already flow through `ScheduleDaySubrow`. No
  new tables, no new columns.
- **Does not rewire Variance.** Variance stays on
  `WeekData.theoreticalLaborPct` + `VarianceWeekProjectionRow.theoreticalLaborPct`
  as verified by `7.55p.5d`.

## Remaining gaps

- **Shift shared seam (optional)** — if a future slice wants one
  `PlannedLaborPackage` shape powering both Shift and Schedule, the
  read service already supports it. Today Shift and Schedule compute
  the same math through different classes; no regression risk, but a
  unification opportunity exists if a tiny shared-seam justification
  shows up.
- **Daypart-scope planned package beyond Schedule** — `10.5` daypart
  surfaces can consume `service.forDaypart(...)` or
  `service.aggregate(...)` directly when daypart-aware Shift /
  Variance screens land.
- **Planned vs actual side-by-side on Variance** — out of scope here;
  `7.55p.5c` intentionally keeps Variance on the theoretical package.
  If a future "planned-vs-actual" comparison is wanted, it would be a
  separate Variance-facing slice with explicit label guidance
  (`7.55p.5i §4`).
- **Copy polish / labeling audit across other screens** — the
  `7.55o.*` lane owns the full labeling pass. This slice only changes
  the Schedule labels that were demonstrably borrowing theoretical
  vocabulary.
