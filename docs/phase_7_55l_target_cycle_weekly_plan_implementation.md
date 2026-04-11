# Phase 7.55l - TargetCycle + WeeklyPlan Implementation

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Planned, not implemented

## Purpose

Phase `7.55l` is the missing implementation lane between integration inventory
and downstream daypart/history semantics.

Its job is to make the new planning architecture real in code without adding
manager-facing workflow complexity:

```text
60-Day Benchmark Snapshot
-> locked TargetCycle
-> rolling DemandForecastContext
-> locked WeeklyPlanSnapshot
-> Shift
-> Variance
-> History
-> Learn
```

Without `7.55l`, the app stays architecture-aware on paper but not yet
integration-ready in runtime behavior.

## Why This Phase Exists

The planning rules are now clear:

- standards should lock on a 60-day cycle
- demand should be allowed to roll
- the operating week should auto-generate one locked weekly plan
- Variance and History should compare against the locked weekly plan

Current code does not fully implement that yet.

Examples of the remaining gap:

- no persisted `TargetCycle`
- no persisted cycle distribution snapshot
- no persisted `WeeklyPlanSnapshot`
- distribution is still loaded live from recent history
- some runtime planning surfaces still rely on bridge-era assumptions
- Learn still has production benchmark context tied to legacy bridge state

## Planning Inputs

`7.55l` should follow these docs:

- `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phase_7_55j_gate_integration_readiness_pressure_test.md`
- `docs/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`

Important:

- the checkpoint remains valid seam guidance
- the newer cycle/week rules now sit above it

## Scope

In scope:

- `TargetCycle` model, persistence, and auto-refresh rules
- `ActiveTargetProfile` as the runtime projection of the current cycle
- rolling `DemandForecastContext` v2
- weekly demand/day allocation logic
- `WeeklyPlanSnapshot` model, persistence, auto-lock rules, and read path
- migration of Schedule, Shift, Variance, History, Audit, and Learn toward the
  cycle/week architecture
- retirement of remaining runtime bridge dependencies when those new models make
  it possible
- no intended UX change to Benchmark, Schedule, History, or Learn

Out of scope:

- live vendor transport implementation
- daypart settings UI
- Shift daypart-live behavior
- auth enforcement
- multi-location org scope

## Work Breakdown

### 7.55l.0 - Planning Cleanup

- update sequencing after `7.55j.2`
- mark `7.55c` partially superseded by the newer cycle/week model
- lock the rule that distribution snapshots belong to the cycle architecture

### 7.55l.1 - TargetCycle Contract

Define:

- one active cycle only
- cycle effective start and end
- calibration window start and end
- recommended vs manager override source metadata
- once-per-cycle manager override rule
- admin-only early unlock/replace metadata path
- auto-refresh to the new recommendation at the 60-day boundary

### 7.55l.2 - TargetCycle Persistence + Auto-Refresh Rules

Add:

- SQLite table(s)
- repository / DAO
- auto-refresh path that switches to the new recommendation at the 60-day boundary
- override path from Benchmark / Manager Override that writes a locked cycle
  replacement within the active window
- passive notification / visibility hook when a new 60-day target becomes active

### 7.55l.3 - Weekly Demand / Day Allocation Rules

Move day allocation out of the old rolling-weight assumption and into explicit
weekly plan generation rules:

- weekly total covers come from level 1 baseline + fixed 3-week recent trend
- day allocation can recalculate each week from current demand logic
- start from the 60-day day-of-week baseline share
- lightly blend in the fixed 3-week recent trend rather than rebuilding the
  spread from scratch
- keep the spread stable enough that it does not feel random week to week
- day allocation is not treated as a 60-day locked cycle artifact
- once the week is generated, that allocation is locked inside the week's
  `WeeklyPlanSnapshot`
- daily rows must reconcile exactly to the generated weekly total

### 7.55l.4 - ActiveTargetProfile As TargetCycle Projection

Make `ActiveTargetProfile` the runtime standards projection of the current
cycle:

- CPLH
- SPLH
- PPA
- wages
- OPZ bounds
- theoretical labor standards

### 7.55l.5 - Rolling DemandForecastContext v2

Keep demand separate from standards and expand it to support:

1. 60-day weekly covers baseline
2. fixed 3-week recent trend

Important:

- no manager forecast adjustments in this architecture cut
- demand layers should remain explicit rather than blending baseline and trend
  into one opaque number

Implementation guardrail for this slice:

- do not let forecast complexity sprawl
- do not allow weekly snapshot generation to become ambiguous
- preserve one clear weekly truth per week

### 7.55l.6 - WeeklyPlanSnapshot Contract + Auto-Lock Persistence

Add one locked weekly plan object for the week in force.

Minimum intended contents:

- target cycle id
- week/business-date span
- forecast covers
- forecast sales
- FOH hours
- BOH hours
- day allocation
- later-ready daypart allocation seam
- generated timestamp

Required behavior:

- auto-generate at week start
- auto-lock immediately for the week
- if missing unexpectedly, regenerate from the current target cycle plus current
  forecast context rather than exposing a broken manager state
- do this without introducing draft/publish workflow into the UI

### 7.55l.7 - Consumer Migration

Move runtime consumers onto the new cycle/week model:

- Schedule reads the current locked weekly plan
- Shift compares against the current weekly plan and current cycle standards
- Variance compares closed actuals against the weekly plan that was in force
- History preserves cycle and weekly-plan identity
- Audit exposes the new provenance clearly

UX guardrail for this slice:

- no new manager workflow
- no draft/publish labels
- no intended UX change to Benchmark, Schedule, History, or Learn
- use passive visibility only when important automation needs to be surfaced

### 7.55l.8 - Learn Migration + Bridge Retirement

Once cycle/week context exists:

- move Learn off production `BaselineData` benchmark context
- retire remaining runtime bridge dependencies that are no longer justified
- isolate demo/replay paths as demo/replay paths rather than runtime truth

## Sequencing

Recommended order:

1. `7.55j.1`
2. `7.55j.2`
3. `7.55j.gate`
4. `7.55l.0`
5. `7.55l.1`
6. `7.55l.2`
7. `7.55l.3`
8. `7.55l.4`
9. `7.55l.5`
10. `7.55l.6`
11. `7.55l.7`
12. `7.55l.8`
13. `7.55j.3`
14. `7.55j.4`
15. `7.55k`

## Relationship To Other Phases

### 7.55c

`7.55c` remains useful as historical context for early demand-source cleanup,
but it is partially superseded by the newer cycle/week architecture.

### 7.55e

`7.55e` already established history-derived plan distribution. `7.55l` is where
weekly day allocation becomes an explicit weekly-plan rule instead of an opaque
live runtime lookup.

### 7.55j

`7.55j` inventories what official integrations must supply. `7.55l` implements
the runtime architecture those integrations will feed.

### 7.55k

`7.55k` should come after `7.55l` so downstream daypart, Variance, History, and
Learn semantics land on stable cycle/week architecture rather than on drifting
runtime planning assumptions.

## Closeout Criteria

`7.55l` can close when:

- one active `TargetCycle` can be read as the current standards cycle
- one active `TargetCycle` can auto-refresh and still honor the once-per-cycle
  manager override rule
- `ActiveTargetProfile` is a projection of the cycle
- rolling `DemandForecastContext` is separate from standards
- rolling demand remains explicit and limited to baseline + fixed 3-week recent trend
- weekly day allocation is generated from a smoothed baseline-plus-trend rule
  and then locked
  for the week
- one weekly plan can be generated, auto-locked, and read as
  `WeeklyPlanSnapshot`
- Schedule, Shift, Variance, and History read from the cycle/week model
- Learn no longer depends on bridge-era production benchmark context
- remaining demo/replay paths are clearly isolated from runtime planning truth
