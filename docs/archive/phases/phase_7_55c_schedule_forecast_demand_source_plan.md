# Phase 7.55c - Schedule Forecast Demand Source Model

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Historical, partially superseded by newer cycle/week architecture

## Purpose

Phase `7.55c` was the earlier demand-source cleanup phase for Schedule.

It was useful because it separated:

- demand inputs
- target standards
- plan math

That separation still matters.

## What 7.55c Got Right

`7.55c` correctly pushed the app away from treating vendor forecast values as
the main planning truth.

It also helped establish these still-valid ideas:

- demand and standards are different concepts
- forecast sales can be derived inside the app
- plan math should not live in widgets
- the app should own planning logic rather than mirror vendor UI concepts

## What Has Changed Since 7.55c

The newer architecture is now:

```text
Canonical Operational Facts
-> 60-Day Benchmark Snapshot
-> TargetCycle
-> ActiveTargetProfile + rolling DemandForecastContext
-> SchedulePlan
-> WeeklyPlanSnapshot
-> Shift
-> Variance
-> History
-> Learn
```

That means `7.55c` is no longer the full planning truth by itself.

## What Is Now Partially Superseded

The older `7.55c` assumptions are no longer the active end state:

- forecast demand is no longer just "60-day average covers"
- manager forecast input is no longer assumed to be permanently absent
- distribution should no longer be treated as a separate live rolling runtime
  lookup
- benchmark/standards and rolling demand are no longer described as one
  combined baseline-owned package

## Current Correct Rule

Use this split now:

```text
60-Day Benchmark Snapshot = calibration evidence
TargetCycle = locked 60-day standards
DemandForecastContext = rolling forecast demand
SchedulePlan = standards + demand + distribution
WeeklyPlanSnapshot = locked weekly operating plan
```

## Relationship To Newer Docs

`7.55c` should now be read together with:

- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md`
- `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`

Those newer docs own the current architecture direction.

## What Still Carries Forward

The spirit of `7.55c` still matters:

- keep demand separate from standards
- keep formulas out of widgets
- keep the app as the planning authority
- keep forecast math explainable

## Handoff Note

If a future prompt references `7.55c`, treat it as historical context for the
early demand-source cleanup only.

Do not use it by itself as the active runtime architecture contract.
