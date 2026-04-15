# Phase 7.55q.6 - Kill Planned Labor Package

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Kill the planned labor package completely. The app should no longer
carry "planned labor %" as a live concept. Any surviving labor-target
metric is theoretical labor % only.

## Scope

- In: delete `PlannedLaborPackage` + `PlannedLaborPackageReadService`
  and their unit tests; strip planned-package wiring from
  `ScheduleForecastNotifier`, `ScheduleDayView`, `ScheduleDaySubrow`,
  the `_DerivedSummaryCards` weekly summary, the `_DayTable` total row,
  and `ScheduleDayRow` (column removed); rewrite the Schedule weekly
  summary "labor %" card to read **theoretical labor %** from the
  current `ActiveTargetProfile` (Rule 3) instead of the planned-package
  formula; repoint Shift `targetLaborPct` to `profile.theoreticalLaborPct`
  and Shift's blended-wage card target to the `7.55q.3` shared seam;
  drop `ShiftDashboardReadModel.targetLaborDollars` (planned-package-
  derived); rename the audit-panel SCHEDULE PLAN labor row label;
  update the affected tests; this phase doc.
- Out: redesigning Schedule or Shift visuals beyond the column / card
  edits required to remove planned labor.
- Out: introducing day/daypart theoretical labor % derivation. Schedule's
  day/daypart planned-labor column is REMOVED, not replaced — the repo
  has no honest same-scope theoretical day/daypart truth today.
- Out: Variance / History / `WeekData` / `WeekRecord` semantics —
  unchanged.
- Out: any new benchmark math or new daypart-theoretical derivation.

## Runtime rule

The app now carries one labor-target concept:

> **theoretical labor %** — sourced from the current
> `ActiveTargetProfile.theoreticalLaborPct`, the same value Benchmark
> renders and Variance compares against.

There is no "planned labor %" anywhere in the active runtime. Any
surface that previously displayed planned labor either:

1. Now displays **theoretical labor %** (where theoretical truth at
   that scope is honest), or
2. Removed the labor-% display entirely (where there is no honest
   same-scope theoretical truth and fabricating one would mislead).

| Surface | Before | After |
|---|---|---|
| Schedule weekly summary card | `PLANNED LABOR %` from `PlannedLaborPackageReadService.forWeek(plan, wages)` (week-aggregate planned formula) | `THEORETICAL LABOR %` from `notifier.theoreticalLaborPct`, the current benchmark target seam (current `ActiveTargetProfile` in locked mode; same explicit target inputs in live/preview mode) |
| Schedule day-by-day table — day column | `PLANNED LABOR %` per day from `PlannedLaborPackageReadService.forDay(...)` | **column removed**. The repo has no honest same-scope theoretical day-level value; backfilling with whole-week % would mislead. |
| Schedule day-by-day table — daypart subrow column | `PLANNED LABOR %` per daypart from `PlannedLaborPackageReadService.forDaypart(...)` | **column removed**. Same reason. |
| Schedule day-by-day table — total row | Aggregate planned package via `service.aggregate(week, dayPackages)` | **column removed** alongside the day/daypart cells; the total row carries Plan-owned columns only (covers / sales / FOH / BOH hours). |
| Shift `LABOR %` card target line | `Target X.X%` from `ShiftDashboardReadModel.targetLaborPct` (planned-package formula: `(planFohHours × fohWage + planBohHours × bohWage) / forecastSales × 100`) | `Target X.X%` from `profile.theoreticalLaborPct` (theoretical truth, same number Benchmark + Variance non-closed show) |
| Shift `BLENDED WAGE` card target line | `Target $X.XX` from a local hour-mix-weighted derivation (planned-package style) | `Target $X.XX` from the `7.55q.3` `profile.targetBlendedWage` shared seam |
| `ShiftDashboardReadModel.targetLaborDollars` | Planned-package-derived dollar field | **field removed**. No honest theoretical dollar form at whole-day scope, and no consumer requires it after `targetLaborPct` repoints to theoretical truth. |
| Audit panel `SCHEDULE PLAN > LABOR %` row | "LABOR %" — read from `SchedulePlan.theoreticalLaborPct` (snapshot-locked value) | "THEORETICAL LABOR % (LOCKED)" — same source, label clarified to flag it as the snapshot's locked theoretical % |

## Removed code

| Path | Disposition |
|---|---|
| `lib/domain/models/planned_labor_package.dart` | **deleted** |
| `lib/data/planned_labor_package_read_service.dart` | **deleted** |
| `test/planned_labor_package_read_service_test.dart` | **deleted** |
| `ScheduleForecastNotifier.plannedLaborPackageForWeek` getter | **deleted** |
| `ScheduleDayView.plannedLabor` field | **deleted** |
| `ScheduleDaySubrow.plannedLabor` field | **deleted** |
| `ScheduleDayRow.plannedLabor` parameter + PLANNED LABOR % column header + data cell | **deleted** |
| `ShiftDashboardReadModel.targetLaborDollars` field | **deleted** |
| `_buildMetricCards` local `wageTotalModelHours` / `targetBlendedWage` derivation | **deleted** — replaced with `profile.targetBlendedWage` from the `7.55q.3` shared seam |
| `_DerivedSummaryCards` planned-package label "PLANNED LABOR %" | **deleted** — replaced with `THEORETICAL LABOR %` |

## What this slice does NOT do

- **Does not invent same-scope theoretical day/daypart values.** The
  Schedule day/daypart labor % column is removed cleanly. Any future
  daypart-aware theoretical derivation belongs to `Phase 10.5`.
- **Does not touch Variance / History / `WeekData`.** Those surfaces
  use theoretical labor % from `WeekData.theoreticalLaborPct` (already
  injected from the active profile per `7.55q.3` / `7.55q.4`) or
  per-shift locked truth (Rule 4).
- **Does not redesign Schedule or Shift visuals beyond the labor-%
  column / card edits required to remove planned labor.**
- **Does not rename `notifier.theoreticalLaborPct`.** The getter
  already exists; this slice only repoints the `_DerivedSummaryCards`
  weekly card label from PLANNED LABOR % to THEORETICAL LABOR % and
  routes it through the canonical source.

## Honest degradation

- Schedule weekly summary card: the benchmark-owned
  `notifier.theoreticalLaborPct` is only rendered when both the locked
  plan and the benchmark target are resolved. Otherwise the card shows
  `—` instead of implying a real weekly labor target where none is
  currently available.
- Schedule day/daypart: the column is gone — nothing to degrade.
- Shift LABOR % card: when no profile is loaded, `profile.theoreticalLaborPct`
  is unavailable. The read-model construction always has a profile in
  scope (it's a required constructor parameter), so this is not a
  runtime concern.
- Shift BLENDED WAGE card: same — the read model always has a profile;
  `profile.targetBlendedWage` returns `0.0` when CPLH/SPLH inputs are
  non-positive (per `7.55q.3` zero-input boundary), at which point the
  card renders `Target $0.00` honestly.

## Tests rewritten / removed

| Test | Disposition |
|---|---|
| `test/planned_labor_package_read_service_test.dart` | **deleted** entirely |
| `test/schedule_builder_widget_test.dart` group A "notifier plan matches resolveFromInputs" | unchanged — does not reference planned package |
| `test/schedule_builder_widget_test.dart` group B "section labels" | unchanged |
| `test/schedule_builder_widget_test.dart` group C "Planned labor package wiring (7.55p.5j)" | **deleted** entirely (4 tests) — the surface it covered is gone |
| `test/schedule_builder_widget_test.dart` group D D3 "honest degradation" | updated to drop the `plannedLaborPackageForWeek.plannedLaborPct` assertion (the getter no longer exists); the rest of the test (plan null + load state unavailable) stays |
| `test/schedule_builder_widget_test.dart` new group E "labor % is theoretical from active benchmark" | **added** — verifies the weekly summary card label is "THEORETICAL LABOR %" and that the rendered value comes from the `notifier.theoreticalLaborPct` source (which after this slice is the canonical theoretical % path) |
| `test/shift_visual_widget_test.dart` "LABOR % card shows read-model targetLaborPct" | unchanged in shape — `targetLaborPct` is still the field name; what changed is its source (now theoretical). The assertion `Target X.X%` still passes because the read model still exposes `targetLaborPct`. |
| `test/shift_whole_day_alignment_test.dart` group J "labor dollars, percentages, and variance all consistent" | updated — drop the `targetLaborDollars` assertion (field removed) and update the `targetLaborPct` expected value to `profile.theoreticalLaborPct`. Variance pts assertion `actual − target` still holds. |
| `test/shift_whole_day_alignment_test.dart` group C "changing target PPA changes plan sales and targetLaborPct but not actuals" | updated — the assertion that `targetLaborPct` changes when target PPA changes is dropped, because `targetLaborPct` now comes from `profile.theoreticalLaborPct` which is a stored cycle field, not derived from PPA at the read-model layer. The actuals-not-rewritten assertions stay. |

## Files touched

| File | Change |
|---|---|
| `lib/domain/models/planned_labor_package.dart` | **deleted** |
| `lib/data/planned_labor_package_read_service.dart` | **deleted** |
| `lib/screens/schedule_builder.dart` | Removed `import` of planned package + service; removed `plannedLaborPackageForWeek` getter; removed `plannedLabor` fields from `ScheduleDayView` + `ScheduleDaySubrow`; removed `svc.forDay` / `svc.forDaypart` calls in `adjustedDayViews`; removed planned-package construction in `_DerivedSummaryCards` and renamed the third card to `THEORETICAL LABOR %` reading `notifier.theoreticalLaborPct` (the current benchmark target seam rather than a plan-owned percentage); removed planned-package aggregate in `_DayTable` total row; removed `plannedLabor:` argument from all `ScheduleDayRow(...)` instantiations |
| `lib/widgets/schedule_day_row.dart` | Removed planned-labor import; removed the `plannedLabor` parameter; removed the PLANNED / LABOR % header column; removed the `plannedText` cell. The row is now Plan-owned columns only: day / covers / sales / FOH HRS / BOH HRS |
| `lib/models/shift_dashboard_read_model.dart` | `targetLaborPct` now sources from `profile.theoreticalLaborPct` (passed as constructor input from `buildWholeDay`). Removed `targetLaborDollars` field entirely (no honest theoretical dollar form at whole-day scope; no consumer required it). `_buildMetricCards` BLENDED WAGE now reads `profile.targetBlendedWage` (the `7.55q.3` shared seam) instead of computing locally from plan hours × wages. |
| `lib/screens/shift_dashboard.dart` | No widget code change — `_LaborVarianceSection` already reads `readModel.targetLaborPct`. After the read-model repoint, the same widget renders the theoretical truth. |
| `lib/widgets/data_alignment_audit_panel.dart` | Renamed the SCHEDULE PLAN section's "LABOR %" row to "THEORETICAL LABOR % (LOCKED)" to clarify it's the snapshot-locked theoretical %, not a planned-labor metric |
| `test/planned_labor_package_read_service_test.dart` | **deleted** |
| `test/schedule_builder_widget_test.dart` | Removed group C entirely; updated D3 to drop the planned-package fallback assertion; added new group E proving the weekly summary card renders THEORETICAL LABOR % from the active benchmark target object |
| `test/shift_visual_widget_test.dart` | Existing E group "LABOR % card shows read-model targetLaborPct" assertion still passes (field name unchanged); added a focused assertion that the rendered value matches `profile.theoreticalLaborPct` rather than the old planned-package formula |
| `test/shift_whole_day_alignment_test.dart` | Updated group J to drop the `targetLaborDollars` assertion and re-anchor `targetLaborPct` to `profile.theoreticalLaborPct`; updated group C to drop the now-invalid "PPA change moves targetLaborPct" assertion (still asserts actuals are not rewritten) |
| `docs/phases/7_55q/phase_7_55q_6_kill_planned_labor_package.md` | **New** — this doc |

## Files intentionally untouched

| File | Why |
|---|---|
| `lib/screens/variance_report.dart` | Uses theoretical labor % from `WeekData` (already conformant after `7.55q.4`); no planned-package references |
| `lib/models/week_data.dart` | Theoretical-only; no planned-package references |
| `lib/models/week_record.dart` | History — out of scope (Drift 6 belongs to a future history slice) |
| `lib/screens/week_detail_screen.dart` | History — same |
| `lib/domain/models/active_target_profile.dart` | The shared `theoreticalLaborPct` field + the `7.55q.3` blended-wage seam are exactly the destinations this slice points at |
| Tracker markdown files | Per prompt, no tracker updates in this run |

## Remaining gaps

- **Daypart-aware theoretical labor %** — out of scope here. If `Phase 10.5`
  introduces honest per-daypart theoretical truth, the Schedule day-by-day
  table can grow back a labor % column then. Today there is no such
  truth and the column is removed cleanly.
- **History / `WeekRecord` cleanup** — Drift 6 + 7 from `7.55q.1`
  remain. Future history slice owns those.
- **Renaming `targetLaborPct` on `ShiftDashboardReadModel`** — kept the
  field name so the widget code (and the `shift_visual_widget_test`
  assertions) don't have to churn. The semantics changed under it
  (now theoretical truth from the profile). A future polish pass may
  rename it to `theoreticalLaborPct` for full naming consistency, but
  the smallest-clean-kill principle is to repoint, not rename.
- **`ShiftDashboardReadModel.targetLaborDollars` removal blast radius**
  — verified: no consumers outside the model itself in the active
  runtime. The `shift_whole_day_alignment_test.dart` group J assertion
  is the only place that referenced it; updated.
