# Data Alignment Tracker

Updated: 2026-04-25
Owner: You
Purpose: keep live POS, labor, reservation, Plan, Benchmark, Shift, Variance,
History, and Learn aligned before Phase 8 / 8R.

## North Star

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

## Current Truth

- Transport is still replay/demo-backed.
- The app path is canonical model -> SQLite -> app state/read models -> UI.
- Phase 8 replaces transport only; it must not create a second UI-facing truth
  path.
- Live/actual values and target/comparison values are audited separately.
  Do not compare live operating results against targets as architectural drift.
- The dev-only data-alignment audit now answers both questions:
  - where live/actual values came from
  - where Plan/Benchmark targets came from

## Alignment Guardrails

- 60-day benchmark snapshot is calibration evidence.
- `TargetCycle` locks standards for 60 days.
- `DemandForecastContext` can roll from level-1 baseline plus fixed 3-week
  recent trend.
- `WeeklyPlanSnapshot` locks the current week for comparison surfaces.
- The locked weekly plan is the current-week Plan authority; no second live
  plan should compete for the in-force week.
- Benchmark sets the standard. Plan decides the week. Shift manages right now.
  Variance compares plan vs actual. History preserves closed truth. Learn
  teaches repeated closed results.
- Non-closed Variance rows inherit benchmark targets and locked-plan targets
  1:1; they should not recompute target truth per surface.
- Non-closed Full Week daypart plan targets come from the same shared daypart
  allocation used by Schedule.
- Closed Full Week rows stay locked historical truth.
- Blended wage comes from one shared benchmark target value.
- Whole-day Shift target alignment is landed; Phase 10.5 owns additive
  service-period/daypart Shift behavior and driver teaching.
- History stays closed-truth only.
- Learn is teaching, not another source-truth surface.

## Source Ownership

POS owns:

- sales
- checks/tickets
- covers when exposed reliably
- close/finalization semantics where available
- business date when POS is the sales authority

Labor owns:

- schedules
- punches/timecards
- actual worked hours
- role assignments
- labor dollars or wage truth when exposed

Reservation owns:

- reservation party size
- reservation time
- reservation status and status timestamps

App owns:

- benchmark snapshot
- `TargetCycle`
- `DemandForecastContext`
- weekly plan snapshot
- app-side service-period mapping
- reservation-book aggregation
- whole-day Shift behavior until Phase 10.5

## Active Planning Docs

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_current_state_freshness_contract.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phases/post_11a7_stabilization_plan.md`
- `docs/phases/phase_8_gate/`

## Archive And Reference

- Full prior tracker: `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_2026-04-25_PRE_TRIM.md`
- Deep old-ask ledger:
  `docs/archive/internal/status_ledger_post_7_55p_deep_check.md`
- Completed history:
  `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`
