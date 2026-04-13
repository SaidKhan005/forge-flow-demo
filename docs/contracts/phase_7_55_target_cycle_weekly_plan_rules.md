# Phase 7.55 - TargetCycle + WeeklyPlanSnapshot Rules

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Active architecture rule

## Why This Exists

The app needs one clear answer to two different kinds of change:

1. what stays stable long enough for coaching and accountability
2. what must keep moving to reflect real operations

The answer is:

```text
targets lock on a 60-day cycle
forecast demand rolls
weekly plan locks for the week
actuals keep arriving continuously
```

For the detailed business-date, week-boundary, cycle-boundary,
service-period, and close/finalization timing rules that sit underneath
these model rules, see:

- `docs/contracts/phase_7_55_time_boundary_contract.md`

For the broader product/system architecture contract and the plain-English
version of the same story, see:

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`

## Core Model

### 1. Canonical Operational Facts

POS, labor, and reservation systems import operational facts:

- closed shifts
- open/live snapshots
- reservation snapshots
- later: timestamped facts for day/daypart bucketing

These are stored as canonical raw truth and continue to grow over time.

### 2. Benchmark Snapshot

The app maintains a rolling 60-day benchmark snapshot from closed history.

This is calibration evidence, not the live operating target itself.

It provides:

- total covers last 60 days
- average weekly covers from the last 60 days
- recommended CPLH / SPLH / PPA
- baseline demand evidence for future weekly forecasting

### 3. TargetCycle

Manager can accept the recommendation or override it once per cycle.

That decision creates one locked 60-day `TargetCycle`.

Minimum intended contents:

- target CPLH
- target SPLH
- target PPA
- FOH wage
- BOH wage
- OPZ bounds
- source metadata (`recommended` or manager override)
- effective start
- effective end
- calibration window start
- calibration window end

### 4. ActiveTargetProfile

`ActiveTargetProfile` is the runtime standards projection of the current
`TargetCycle`.

It owns:

- CPLH
- SPLH
- PPA
- wages
- OPZ bounds
- theoretical labor percentages

### 5. DemandForecastContext

Demand is separate from standards.

`DemandForecastContext` is rolling and should be built from:

1. 60-day weekly average covers baseline
2. fixed 3-week recent trend

Forecasting guardrail:

- keep the demand stack explicit
- no manager forecast adjustments in the first architecture cut
- do not let forecast-side changes mutate standards
- do not let weekly snapshot generation become ambiguous

### 6. SchedulePlan

`SchedulePlan` combines:

- locked standards from `ActiveTargetProfile`
- rolling demand from `DemandForecastContext`
- weekly demand/day allocation logic

Day-allocation guardrail:

- start from the 60-day day-of-week baseline share
- lightly blend in the fixed 3-week recent trend
- keep the spread stable enough that it does not feel random week to week
- reconcile daily rows exactly back to the generated weekly total

### 7. WeeklyPlanSnapshot

The app auto-generates one locked 7-day `WeeklyPlanSnapshot` for the week in
force.

Minimum intended contents:

- week id / business-date span
- target cycle id
- forecast covers
- forecast sales
- FOH hours
- BOH hours
- day-level allocation
- later: daypart allocation
- generated timestamp

## Core Rules

### Rule A - Target cycles lock for 60 days

- Standards do not drift daily.
- Manager override is allowed once per 60-day cycle.
- Only admin can unlock or replace a locked cycle before expiry.

### Rule B - Weekly demand can keep rolling before auto-lock

- Covers are not fixed by the 60-day cycle.
- Forecast demand should reflect current operating reality.
- Anything driven by covers can change before the weekly plan auto-locks.
- Forecasting complexity must stay disciplined:
  - keep each demand layer explicit
  - keep the forecast limited to level 1 baseline + fixed 3-week recent trend
  - do not let forecast-side changes rewrite `TargetCycle` standards
  - do not allow more than one ambiguous weekly generated truth for the same week
  - smooth day allocation so recent trend refines the baseline rather than
    replacing it wholesale

### Rule C - Weekly plan locks for the week

- At the start of each business week, the app auto-generates and locks that
  week's plan.
- Once generated, that weekly plan becomes the comparison truth.
- Variance and History should compare against the locked weekly plan, not a
  forecast that kept changing after the week started.

### Rule D - Actuals lock, targets do not mutate mid-cycle

- Closed actuals are preserved as actual truth.
- The current target cycle remains stable for its 60-day window.
- New closed shifts feed the next benchmark snapshot, not the current cycle.

### Rule E - Weekly plan stays stable even if the target cycle refreshes

- The current week's locked plan does not rewrite midweek.
- If the 60-day target cycle refreshes during a week, the new target influences
  the next generated week, not the already locked week in force.

### Rule F - History must preserve cycle and week context

- History should show which target cycle each week belonged to.
- Old-cycle vs new-cycle weeks must be visually distinguishable.

## Product Flow

```text
Canonical Operational Facts
-> 60-Day Benchmark Snapshot
-> manager accept/override
-> locked 60-Day TargetCycle
-> ActiveTargetProfile
-> rolling DemandForecastContext
-> SchedulePlan
-> locked WeeklyPlanSnapshot
-> Shift
-> Variance
-> History
-> Learn
```

## UX Guardrails

- No intended manager-facing UX change in Benchmark, Schedule, History, or
  Learn.
- Keep Benchmark as the target override surface.
- Keep Schedule as the current week's plan surface.
- Do not introduce draft/publish state language into the main UI.
- Keep cycle/week complexity internal unless a later product decision explicitly
  chooses to expose it.
- Use passive visibility rather than new workflow when important automation
  happens:
  - new 60-day target becomes active
  - manager override has already been used for the cycle
  - app is running on demo/replay-backed transport

## What This Means For Current Planning

- `7.55j` should inventory which vendor capabilities improve rolling demand
  inputs, not just benchmark calibration inputs.
- `7.55j.gate` should explicitly record whether the app is simple-swap ready
  yet and which blockers remain.
- `7.55l` is the implementation owner for:
  - `TargetCycle`
  - rolling `DemandForecastContext`
  - weekly demand/day allocation logic
  - `WeeklyPlanSnapshot`
- `7.55k` should assume Variance and History compare against a locked weekly
  plan, not a continuously moving forecast.
- Shift remains whole-business-day until Phase 10.5.
