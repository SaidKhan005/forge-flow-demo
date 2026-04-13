# Data Alignment Tracker

Updated: 2026-04-12
Owner: You
Purpose: keep the app aligned for live POS, labor, and official reservation integrations before Phase 8 / 8R

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Desired Separation

Vendor APIs / Fixture Replays
-> Adapter DTOs
-> Canonical source facts
-> Domain services / use cases
-> Repositories
-> SQLite persistence
-> In-memory app state
-> UI

In plain terms:

- adapters pull source data
- the app reshapes it into canonical facts immediately
- SQLite holds the rolling restaurant truth plus active planning state
- providers/notifiers expose repository-backed app state
- UI renders app state without knowing vendor payload shape

## Active Alignment Baseline

- transport is still fixture/replay/demo-backed
- the internal app path is already canonical-model -> SQLite -> app state -> UI
- Phase 8 should replace transport, not create a second UI-facing truth path

## Delivered Foundations

- `7.55l` complete:
  - `TargetCycle`, `DemandForecastContext`, and `WeeklyPlanSnapshot` runtime architecture landed
- `7.55m` complete:
  - runtime-truth cleanup landed
  - date/business-date authority
  - replay drift contract
  - truthful Shift time behavior
  - driver/OPZ audits
  - Plan / Benchmark / Settings cleanup
- `7.55k.1` complete:
  - daypart scope audit
- `7.55k.2` complete:
  - service-period decoupling plan
- `7.55k.3` complete:
  - daypart pattern summary model
  - `7.55k.3a` evidence-contract cleanup
- `7.55k.4` complete:
  - Variance Full Week projection semantics
  - `7.55k.4a` mixed-row / open-header honesty cleanup
- `7.55k.5` complete:
  - History benchmark dayparts upgraded to evidence-backed closed-truth summaries
  - `7.55k.5a` sample-depth / deterministic-ranking cleanup
- `7.55k.6` complete:
  - Learn Repeatable Wins upgraded to evidence-backed closed-truth summaries
  - `7.55k.6a` teaching-scope / per-row lever honesty cleanup
- `7.55k.7` complete:
  - interim visibility rules landed
  - `7.55k.7a` strong-first / empty-state honesty cleanup

## Current Next Steps

- Current:
  - `7.55n.1` restaurant timing config persistence seam
- Then:
  - `7.55n.2` through `7.55n.6`
  - `7.55p.1` Shift driver trust audit
  - `7.55p.2` Variance WTD / Full Week alignment
  - `7.55p.3` Dollar Impact accumulation model
  - `7.55p.4` refresh / replay integrity / notifications
  - `7.55p.5` Benchmark OPZ and graph honesty audit
  - `7.55o.1` through `7.55o.6`
  - then resume `7.55j.3` and `7.55j.4`

## Alignment Guardrails

- 60-day benchmark snapshot is calibration evidence
- `TargetCycle` locks standards for 60 days
- `DemandForecastContext` can roll from level 1 baseline + fixed 3-week recent trend
- `WeeklyPlanSnapshot` auto-generates and locks the week for comparison surfaces
- app-owned service-period definitions + timestamp bucketing remain the preferred direction
- restaurant timing + service-period runtime implementation is now queued in `7.55n`
- post-`7.55n` product/alignment work is queued in `7.55p` before engineering hygiene
- file extraction / engineering hygiene is queued in `7.55o` after `7.55p`
- Shift stays whole-day until Phase 10.5
- History stays closed-truth only
- Learn is partially migrated today:
  - Repeatable Wins is evidence-backed closed truth
  - Benchmark Set / Recurring Leak / Coach Next Week still use compatibility seams
- no new manager workflow
- no draft/publish language in the UI
- fixed `14 shifts` debt spans:
  - runtime
  - replay seeding
  - tests
  - UI copy
  - active integration docs
- internal SQL-backed simulation is not the same thing as full integration readiness

## Current Source Ownership Guardrails

- POS owns:
  - business date when POS is the sales authority
  - sales
  - checks/tickets
  - covers when exposed reliably
  - close/finalization semantics where available
- Labor owns:
  - schedules
  - punches/timecards
  - actual worked hours
  - role assignments
  - labor dollars or wage truth when exposed
- Reservation platform owns:
  - reservation party size
  - reservation time
  - reservation status and status timestamps
- App owns:
  - benchmark snapshot
  - `TargetCycle`
  - `DemandForecastContext`
  - weekly plan snapshot
  - app-side service-period mapping
  - reservation-book aggregation
  - whole-day Shift behavior until Phase 10.5

## Active Planning Docs

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- `docs/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md`
- `docs/phases/7_55k/phase_7_55k_1_daypart_scope_audit.md`
- `docs/phases/7_55k/phase_7_55k_2_service_period_decoupling_plan.md`
- `docs/phases/7_55k/phase_7_55k_3_daypart_pattern_summary_model.md`
- `docs/phases/7_55k/phase_7_55k_4_variance_full_week_projection_semantics.md`
- `docs/phases/7_55n/phase_7_55n_restaurant_timing_service_period_runtime_foundation.md`
- `docs/phases/7_55o/phase_7_55o_deep_extraction_followup.md`

## Archive And Reference

- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`
- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`
- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`

## Notes

- Detailed completed-slice sequencing was archived to `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`.
- Completed `7.55l` and `7.55m` docs now live under `docs/archive/phases/7_55l/` and `docs/archive/phases/7_55m/`.
- Active architecture authority docs now live under `docs/contracts/`.
- Keep this file focused on current alignment rules, delivered foundations, and next seams only.
