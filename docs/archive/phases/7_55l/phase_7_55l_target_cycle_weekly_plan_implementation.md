# Phase 7.55l - TargetCycle + WeeklyPlan Implementation

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: In progress

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

- `TargetCycle` now exists with persistence, auto-refresh, and override/replacement write paths, but downstream consumers are not migrated yet
- `ActiveTargetProfile` is now projected from cycle writes, but transitional bridge-era profile writes still coexist
- rolling `DemandForecastContext` v2 now exists with explicit 60-day baseline + fixed 3-week trend
- weekly day allocation now uses smoothed baseline-plus-trend business-date windows
- persisted `WeeklyPlanSnapshot` now exists with current-week auto-lock, but downstream consumers are not migrated yet
- Learn still has production benchmark context tied to legacy bridge state

## Planning Inputs

`7.55l` should follow these docs:

- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md`
- `docs/archive/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`

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

Status:

- complete

### 7.55l.1 - TargetCycle Contract

Define:

- one active cycle only
- cycle effective start and end
- calibration window start and end
- recommended vs manager override source metadata
- once-per-cycle manager override rule
- admin-only early unlock/replace metadata path
- auto-refresh to the new recommendation at the 60-day boundary

Status:

- complete through `7.55l.1a`

### 7.55l.2 - TargetCycle Persistence + Auto-Refresh Rules

Add:

- SQLite table(s)
- repository / DAO
- auto-refresh path that switches to the new recommendation at the 60-day boundary
- override path from Benchmark / Manager Override that writes a locked cycle
  replacement within the active window
- passive notification / visibility hook when a new 60-day target becomes active

Status:

- complete through `7.55l.2c`
- persisted `TargetCycle` exists
- service auto-refresh is date-anchored to the requested benchmark window

### 7.55l.3 - TargetCycle Override / Replacement Write Path

Make the cycle layer able to record all target provenance states:

- recommended cycle
- manager override cycle
- admin replacement cycle
- one-active-cycle historical retention
- honest replacement provenance metadata

Status:

- complete through `7.55l.3b`
- manager override and admin replacement write paths exist
- replacement provenance now matches the actual rebuild window
- repeated same-day replacements preserve historical rows

### 7.55l.4 - ActiveTargetProfile As TargetCycle Projection

Make `ActiveTargetProfile` the runtime standards projection of the current
cycle:

- CPLH
- SPLH
- PPA
- wages
- OPZ bounds
- theoretical labor standards

Status:

- `7.55l.4a` complete
- cycle writes now sync a projected persisted `ActiveTargetProfile`
- bridge-era direct profile writes still coexist and are deferred to later cleanup

### 7.55l.5 - Rolling DemandForecastContext v2 + Weekly Demand / Day Allocation Rules

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
- generate weekly day allocation from a smoothed baseline-plus-trend rule
- keep day allocation stable enough that it does not feel random week to week
- daily rows must reconcile exactly to the generated weekly total

Status:

- complete through `7.55l.5g`
- `DemandForecastContext` v2 now carries explicit 60-day baseline, fixed 3-week trend, and resolved weekly forecast covers
- zero-demand truth now propagates through service, model, and resolver layers
- weekly day allocation now uses smoothed 60-day baseline share + fixed 3-week recent trend
- Schedule runtime weight loading now uses mock replay business date first, latest closed date fallback
- audit/debug demand terminology now reflects rolling-demand v2 truth

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

Status:

- `7.55l.6a` / `7.55l.6a1` complete: contract, model, repository interface,
  policy, tests, and week-key invariant cleanup
  - see `docs/archive/phases/7_55l/phase_7_55l_6a_weekly_plan_snapshot_contract.md`
- `7.55l.6b` / `7.55l.6b1` / `7.55l.6b2` / `7.55l.6b3` complete:
  - SQLite `weekly_plan_snapshots` persistence exists
  - current-week auto-generate + auto-lock service exists
  - same-week mock replay advance preserves the locked snapshot
  - same-week mock replay advance preserves target-cycle linkage
  - same-week mock replay advance preserves cycle-projected active profile truth
  - see `docs/archive/phases/7_55l/phase_7_55l_6b_weekly_plan_snapshot_persistence_autolock.md`
- later `7.55l.6c+` only if regeneration/backfill cleanup is still needed after
  consumer migration pressure

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

Status:

- `7.55l.7a` complete:
  - pure `WeeklyPlanSnapshot -> SchedulePlan` projector exists
  - `SchedulePlanReadService` exposes a locked current-week read seam
  - Shift dashboard readers and the data-alignment audit now consume the locked weekly plan when available
  - Schedule Builder preview/edit flows remain on the live/input path
  - see `docs/archive/phases/7_55l/phase_7_55l_7a_first_consumer_migration_slice.md`
- `7.55l.7b` / `7.55l.7b1` complete:
  - current-week `WeekData` / Variance WTD now uses the locked `WeeklyPlanSnapshot` for weekly forecast truth
  - current-week target standards now come from the snapshot-linked `TargetCycle`
  - locked WTD forecast now comes from snapshot day rows through the last closed business-day boundary
  - Variance wording is honest about locked-plan comparison
  - historical-week behavior remains on the existing path
  - see `docs/archive/phases/7_55l/phase_7_55l_7b_current_week_variance_migration.md`
- `7.55l.7c` / `7.55l.7c1` complete:
  - current-week `CurrentWeekState` now uses locked WTD truth
  - current-week open/projected Full Week rows now use snapshot-linked cycle target standards
  - locked-cycle Full Week target adoption is scoped to the current week only
  - non-current full-week reads remain on the legacy/live path without snapshot side effects
  - see `docs/archive/phases/7_55l/phase_7_55l_7c_current_week_full_week_migration.md`
- `7.55l.7d` / `7.55l.7d1` complete:
  - History / Week Detail wording now reflects locked targets instead of generic baseline language
  - `WeekRecord` provenance labels now surface both legacy and cycle-era target-source types honestly
  - see `docs/archive/phases/7_55l/phase_7_55l_7d_historical_week_provenance_migration.md`
- next: `7.55l.8a` Learn benchmark-context migration off production `BaselineData`

### 7.55l.8 - Learn Migration + Bridge Retirement

Once cycle/week context exists:

- move Learn off production `BaselineData` benchmark context
- retire remaining runtime bridge dependencies that are no longer justified
- isolate demo/replay paths as demo/replay paths rather than runtime truth

Status:

- `7.55l.8a` / `7.55l.8a1` complete:
  - Learn source label and target CPLH / SPLH / PPA now resolve through
    `LearnBenchmarkContextService` from persisted cycle/profile authority
  - `LearnTeachingAnalyzer` no longer reads production `BaselineData` directly
  - bridge fallback is now limited to explicit bridge-only mode and genuine
    no-profile bootstrap; unexpected repository failures propagate
  - see `docs/archive/phases/7_55l/phase_7_55l_8a_learn_source_target_migration.md`
- `7.55l.8b` / `7.55l.8b1` complete:
  - Learn selected-shift count and range-quality analytics now use a
    dedicated selection-analytics seam
  - override-driven profiles use persisted selected-key analytics
  - default recommended/system profiles no longer misread an empty
    override-selection table as `0` selected / too narrow
  - see `docs/archive/phases/7_55l/phase_7_55l_8b_learn_selection_analytics_migration.md`
- `7.55l.8c` / `7.55l.8c1` complete:
  - benchmark-selection summary is now persisted at target-cycle build time
  - Learn canonical reads now use the persisted summary tied to the active cycle
  - missing-summary state now triggers a one-time backfill instead of transient compatibility fallback
  - see `docs/archive/phases/7_55l/phase_7_55l_8c_benchmark_selection_summary_persistence.md`
- `7.55l.8d` / `7.55l.8d1` complete:
  - profile-without-cycle state is now treated as explicit cycle recovery instead of ordinary compatibility fallback
  - Learn recovers the active cycle from the current benchmark anchor, then re-reads the canonical active profile
  - post-recovery missing-profile state now fails explicitly instead of silently proceeding with stale pre-recovery values
  - see `docs/archive/phases/7_55l/phase_7_55l_8d_learn_profile_cycle_recovery.md`
- `7.55l.8` complete:
  - Learn bridge-retirement closeout docs now reflect post-8d production truth
  - compatibility inventory and gate-facing Learn bridge claims now mark runtime Learn as retired from production `BaselineData`
  - see `docs/archive/phases/7_55l/phase_7_55l_8_learn_bridge_closeout.md`
- next: `7.55j.3` Vendor Endpoint Checklist Template

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
- `ActiveTargetProfile` is a projection of the cycle and remaining direct bridge writes are retired
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
