# Phase 10.5 - Shift Daypart-Aware Service Period View + Primary Driver

Updated: 2026-04-14
Status: Planned
Owner: Future live daypart/service-period lane

## Goal

Turn Shift from a whole-day live surface into a live service-period/daypart-aware
surface, with real time-into-service behavior and daypart-live primary-driver
teaching.

## Scope

Phase 10.5 owns:

- `ShiftServicePeriodReadService`
- live daypart-aware / service-period-aware Shift view
- real time-into-service display
- making `localStartRule` / `localEndRule` meaningful for live bucketing
- Shift primary-driver teaching at service-period/daypart scope
- the future live Shift behavior that depends on timestamp bucketing rather
  than synthetic planning dayparts

Adjacent work that may land here or plug into this lane:

- per-daypart OPZ rendering when consumed by daypart-aware Shift/Variance
  surfaces
- broader daypart-scope planned/theoretical comparisons outside the current
  Schedule-only planning seam

Phase 10.5 does not own:

- the whole-day Shift contract that exists today
- connector ingest (`Phase 8` / `8R`)
- auth (`Phase 9`)
- multi-device shared state (`Phase 10`)

## Runtime Contract

Until Phase 10.5 lands, Shift stays whole-day.

After Phase 10.5, the live path should look like:

```text
timestamped current-state facts
-> app-owned service-period definitions
-> live service-period bucketing
-> Shift service-period read model
-> Shift screen + primary-driver teaching
```

The rule carried forward from the architecture docs is:

- use timestamped facts + app-owned service periods
- do not depend on vendor-native daypart labels as the primary truth

## What This Phase Replaces

Today the repo explicitly reserves these concerns for later:

- live service-period-aware Shift behavior
- live time-into-service
- visible daypart-live primary driver

This phase is where those deferred placeholders become real.

## Source Material

This phase is split out from the existing architecture/contracts and archived
daypart planning docs:

- [phase_7_55_architecture_contract.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/contracts/phase_7_55_architecture_contract.md)
- [phase_7_55_time_boundary_contract.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/contracts/phase_7_55_time_boundary_contract.md)
- [phase_7_55_target_cycle_weekly_plan_rules.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md)
- [phase_7_55k_2_service_period_decoupling_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55k/phase_7_55k_2_service_period_decoupling_plan.md)
- [phase_7_55k_daypart_variance_history_learn_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md)

