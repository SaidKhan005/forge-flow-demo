# Data Alignment Tracker

Updated: 2026-05-22 (trim — closed status notes removed; durable
alignment rules retained.)
Owner: You
Purpose: durable rules that keep live POS, labor, reservation, Plan,
Benchmark, Shift, Variance, History, and Learn aligned. Status of
phases lives in `PROJECT_TRACKER.md`.

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

## Current Truth (durable)

- The app path is canonical model -> SQLite -> app state/read models
  -> UI.
- Phase 10.5 added a per-service-period read service as an additive
  lens; Phase 8 owns the real POS/Labor/Reservation canonical-fact
  transport that replaced the demo synthesizer.
- Live/actual values and target/comparison values are audited
  separately. Do not compare live operating results against targets as
  architectural drift.
- The dev-only data-alignment audit answers both questions:
  - where live/actual values came from
  - where Plan/Benchmark targets came from

## Alignment Guardrails (durable)

- 60-day benchmark snapshot is calibration evidence.
- `TargetCycle` locks standards for 60 days.
- `DemandForecastContext` can roll from level-1 baseline plus fixed
  3-week recent trend.
- `WeeklyPlanSnapshot` locks the current week for comparison surfaces.
- The locked weekly plan is the current-week Plan authority; no second
  live plan should compete for the in-force week.
- Benchmark sets the standard. Plan decides the week. Shift manages
  right now. Variance compares plan vs actual. History preserves
  closed truth. Learn teaches repeated closed results.
- Non-closed Variance rows inherit benchmark targets and locked-plan
  targets 1:1; they should not recompute target truth per surface.
- Non-closed Full Week daypart plan targets come from the same shared
  daypart allocation used by Schedule.
- Closed Full Week rows stay locked historical truth.
- Blended wage comes from one shared benchmark target value.
- Whole-day Shift target alignment is authoritative; Phase 10.5 added
  the additive daypart toggle, bucketing engine, per-period read
  service, Shift service-period cards, time-into-service, and Variance
  daypart lens.
- History stays closed-truth only.
- Learn is teaching, not another source-truth surface.
- Driver-key shape is pinned by the Phase 7.61 contract. Unknown
  History/Learn analyzer ids degrade to explicit empty states (7.61.1)
  and the empty-leak default is flipped (7.61.2) so unknown ids do not
  silently materialize `covers_down` / `ppa_up` cards.

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
- whole-day Shift authority plus the additive service-period/daypart
  lens introduced by Phase 10.5

## Active Planning Docs

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_current_state_freshness_contract.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/contracts/phase_7_61_driver_key_contract.md`
- `docs/contracts/slice_runtime_acceptance_contract.md`
- `docs/contracts/mobile_core_star_target_truth_contract.md`
- `docs/contracts/mobile_core_weekly_plan_server_truth_contract.md`
- `docs/contracts/mobile_core_business_scope_contract.md`
- `docs/contracts/mobile_core_first_connection_backfill_contract.md`
- `docs/archive/_walkthroughs/10.5.2.md`

## Archive And Reference

- Full prior tracker: `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_2026-04-25_PRE_TRIM.md`
- Deep old-ask ledger:
  `docs/archive/internal/status_ledger_post_7_55p_deep_check.md`
- Completed history:
  `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`
- Phase 10.5.2 closeout:
  `docs/archive/phases/phase_10_5/10_5_2_per_period_read_service_closeout.md`
- Phase 7.61 audit plan:
  `docs/archive/phases/phase_7_61/phase_7_61_audit_plan.md`
- Phase 8 gate archive: `docs/archive/phases/phase_8_gate/`
