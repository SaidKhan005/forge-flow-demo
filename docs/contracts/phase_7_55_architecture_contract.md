# Phase 7.55 - Architecture Contract

Updated: 2026-04-12
Owner: Codex architecture
Status: Active authority

## Why This Exists

The repo now has enough real architecture in place that we need one explicit
contract for how the whole product fits together.

This doc is the hard-edged system contract for:

- what source systems own
- what the app owns
- what is raw truth vs locked standards vs rolling demand vs teaching
- what gets locked, what keeps moving, and what never rewrites history
- how Benchmark, Plan, Shift, Variance, History, and Learn are supposed to
  relate to each other

For detailed timing rules, see:

- `docs/contracts/phase_7_55_time_boundary_contract.md`

For the 60-day cycle and locked-week planning rules, see:

- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`

## Core Principle

```text
Source systems provide operational facts.
The app normalizes those facts into one canonical truth shape.
The app then derives standards, demand, plan, variance, history, and teaching
from that canonical truth without rewriting already locked history.
```

## North Star Pipeline

```text
POS + Labor + Reservation Systems
-> Canonical Operational Facts
-> 60-Day Benchmark Snapshot
-> TargetCycle + ActiveTargetProfile
-> DemandForecastContext
-> SchedulePlan
-> WeeklyPlanSnapshot
-> Shift
-> Variance
-> History
-> Learn
```

## Layer Contract

### 1. Source systems

External systems own raw operational events and records.

They may disagree in naming, timing, and shape. The app should not expose
those vendor shapes directly to the UI.

#### POS owns

- sales truth
- ticket / check truth
- covers truth when POS is the reliable source
- close / finalization truth when available
- source timestamps that can later support app-side bucketing

#### Labor owns

- schedules
- published staffing context
- punches / timecards
- worked hours
- labor dollars or wage truth when exposed
- some integrations may expose only hours at close time; in that case the app
  may use the sanctioned wage-authority seam as an operational fallback until
  richer labor truth is available

#### Reservation system owns

- reservation party size
- reservation time
- reservation status
- status timestamps
- booked covers still in the books

### 2. Canonical operational facts

This is the app's normalized truth layer.

In plain English: vendor data, cleaned into app data.

The UI should not read vendor payload shapes directly. The app should reshape
them into stable internal records first.

Current examples in the repo:

- `ShiftRecord` = closed-shift actual truth
- `OpenShiftSnapshot` = live in-progress shift truth
- `ReservationBookSnapshot` = reservation-book truth by business date bucket

Contract:

- canonical facts are the app-facing source truth
- canonical facts can keep growing over time
- canonical facts are not themselves benchmark standards or plan values
- later integrations should replace transport, not create a second UI-facing
  truth path
- if a labor vendor provides richer finalized labor truth after the initial
  close event, the integration may need explicit reconciliation/sync handlers
  around close, approval, payroll-close, or other boundary events rather than
  leaving that follow-up implicit

### 3. 60-day benchmark snapshot

This is calibration evidence built from closed history.

It is not the live plan, and it is not the active standard by itself.

It exists to answer:

- what has good closed performance looked like in the recent benchmark window
- which shifts count as star shifts / calibration evidence
- what recommendation should the next standards cycle use

Contract:

- benchmark evidence is built from closed truth only
- reservation data can help forecast demand later, but does not rewrite the
  benchmark standard by itself
- benchmark is calibration input, not the live operating target

### 4. TargetCycle

`TargetCycle` is the locked 60-day standards window.

It owns:

- target CPLH
- target SPLH
- target PPA
- OPZ bounds
- source provenance for recommended vs override vs replacement

Contract:

- standards lock for 60 days
- manager can override once per cycle
- admin can replace with explicit provenance
- when the cycle expires, the app can auto-refresh to the new recommended
  cycle
- a new cycle affects future comparison context only
- a new cycle does not re-grade already closed history
- cycle provenance and target geometry remain the canonical benchmark
  anchor for the in-force standards window
- wage authority is a sanctioned companion seam:
  - labor integration wage truth should be used when available
  - when integration does not provide usable wage truth, the admin wage
    mix in Settings is the sanctioned manual fallback
  - this manual wage seam is allowed to influence the live benchmark
    profile with the same downstream effect as integrated wage truth;
    it is not treated as an ad hoc competing authority

### 5. ActiveTargetProfile

`ActiveTargetProfile` is the runtime projection of the active `TargetCycle`.

It is the lightweight standards read seam used by current consumers.

Contract:

- `ActiveTargetProfile` is a projection of cycle truth, not an independent
  competing authority
- target standards should be resolved from cycle-backed profile state, not
  ad hoc bridge-era globals
- the canonical wage-authority seam may refresh the profile's wage and
  theoretical-labor fields without being treated as an architecture
  violation, as long as the source is:
  - labor integration wage truth, or
  - the admin-configured wage mix fallback in Settings

### 6. DemandForecastContext

Demand is separate from standards.

`DemandForecastContext` answers expected volume, not target efficiency.

Current runtime direction:

- 60-day weekly average covers baseline
- fixed 3-week recent trend
- later reservation-book signal layered in as current book context

Contract:

- demand may roll as reality changes
- demand must stay explicit about its layers
- demand changes do not mutate locked standards
- reservation data improves demand context; it does not become the standards
  authority

### 7. SchedulePlan

`SchedulePlan` is the resolved operating plan created from:

- locked standards
- rolling demand
- distribution logic

It answers:

- forecast covers
- forecast sales
- required FOH / BOH hours
- labor dollars / labor percent projections
- day allocation
- later service-period allocation

Contract:

- Benchmark sets standards
- demand forecast sets expected volume
- `SchedulePlan` combines the two
- widgets should not recompute their own competing plan logic

### 8. WeeklyPlanSnapshot

`WeeklyPlanSnapshot` is the locked week-in-force comparison plan.

It captures the plan that the current business week should be judged against.

Contract:

- the app auto-generates one weekly snapshot for the business week in force
- one locked weekly snapshot per business week
- once locked, the week comparison plan does not rewrite midweek
- if a 60-day target cycle changes midweek, the next week uses the new cycle;
  the already locked week stays attached to the cycle in force when that week
  was generated

### 9. Shift

Shift is the live operational surface.

It should answer:

- how are we doing right now
- how are live actuals moving against the current plan and targets

Contract:

- Shift is whole-day until Phase 10.5
- Shift can use live open snapshot context
- Shift truth is live operational fact, not closed historical truth
- Shift compares those live facts against benchmark-backed standards and the
  current plan context
- Shift is the "now" surface, not the historical teaching surface
- live time-into-service and live service-period behavior stay reserved for
  Phase 10.5

### 10. Variance

Variance is the comparison surface that mixes locked truth with current-week
context.

It currently has two major jobs:

- WTD summary from closed actuals against locked weekly / target truth
- Full Week projection that mixes:
  - closed truth
  - open in-progress context
  - projected remaining context

Contract:

- WTD closed comparisons should stay locked-truth-first
- Variance compares downstream truth against the locked weekly plan and
  benchmark-backed standards in the roles each one owns
- Full Week projection must be explicit when rows are closed, open, or
  projected
- closed rows are closed truth compared against locked week/standard context
- open rows are live context compared against locked week/standard context
- projected rows are plan/forecast context, not closed truth
- projected and open rows must not overclaim final truth

### 11. History

History is closed truth with preserved provenance.

It should answer:

- what actually happened in already closed weeks
- what cycle / week context those weeks belonged to
- what repeated patterns appear in closed service buckets

Contract:

- history is closed truth only
- History truth is frozen closed fact, not live or projected context
- History compares closed outcomes against the cycle/week context that was in
  force when those facts closed
- history keeps the cycle and week context active at the time the facts closed
- later benchmark changes do not rewrite old history

### 12. Learn

Learn teaches from closed truth plus current benchmark context.

Learn has two layers:

1. current benchmark context
2. repeated evidence from already closed history

It should answer:

- what the current benchmark set is
- what leaks repeat
- what wins repeat
- what the manager should coach next

Contract:

- Learn should not teach from open or projected rows
- Learn truth is repeated closed evidence, not live context
- Learn interprets that closed evidence against benchmark context while keeping
  the historical cycle/week provenance attached to the source facts
- Learn should carry evidence, not just vague repetition
- Learn should keep benchmark context and historical evidence separate
- current benchmark context can change with a new cycle
- historical evidence retains the provenance of the cycle/week in force when
  source shifts closed

## Ownership Rules

### What the app owns

The app owns:

- canonical operational fact shapes
- benchmark snapshot logic
- target cycle logic
- active target profile projection
- demand forecast context
- weekly plan snapshot
- service-period definitions and bucketing rules
- variance / history / learn read seams
- product-facing explanation of what is locked vs rolling

### What the app must not do

The app must not:

- let widgets own source-truth decisions
- let widgets own service-period bucketing rules
- let new standards rewrite already closed weeks
- let weekly forecast movement rewrite a locked weekly snapshot
- let live operational rows masquerade as closed truth

## Separation Rules

These separations are mandatory:

### Standards vs demand

- standards = what good looks like
- demand = how much business is expected

Those are different questions and must stay different layers.

### Closed truth vs live context

- closed truth = locked and historical
- live context = in progress and subject to change

Those are different states and must stay distinguishable.

### Weekly lock vs 60-day lock

- weekly lock = comparison plan for one week
- 60-day lock = standards cycle

Those are different cadences and must stay distinguishable.

### Benchmark evidence vs Learn coaching

- benchmark = calibration evidence for standards
- Learn = repeated operational teaching from closed outcomes

Those are related but not interchangeable.

## Provenance Contract

Every major comparison or teaching surface should eventually be able to answer:

- which restaurant
- which business date or week span
- which cycle was active
- whether the row was closed, open, or projected
- which source facts or exemplar facts support the conclusion

Minimum provenance rules already implied by current architecture:

- `TargetCycle` owns standards provenance
- `WeeklyPlanSnapshot` owns week-level plan provenance
- `ShiftRecord` owns closed actual truth
- `OpenShiftSnapshot` owns live in-progress truth
- `DaypartPatternSummary` is an aggregate summary built from closed facts; it
  is not itself a single business-date fact

## Change Cadence Contract

### Changes every 60 days

- target cycle
- benchmark-backed target standards
- manager override eligibility

### Changes weekly

- weekly plan snapshot
- current week allocation and forecast plan
- week-in-force comparison context

### Changes continuously during operations

- open shift snapshot context
- reservation-book context
- live Shift view

### Changes only when facts close

- closed shift truth
- WTD locked actuals
- history pattern evidence
- Learn evidence

## What Never Rewrites

These rules are non-negotiable:

- already closed shifts do not get regraded under a later cycle
- a locked weekly snapshot does not get regenerated midweek
- old history does not adopt a newer benchmark after the fact
- Learn evidence should remain tied to the truth that existed when its source
  shifts closed

## Notification Contract

The architecture should support passive visibility when important locked state
changes happen.

Examples:

- a new 60-day cycle becomes active
- manager override has already been used for the current cycle
- a new weekly plan snapshot becomes the week in force
- forecast plan changes for the upcoming week
- timing settings change in a way that affects future boundaries

This is visibility, not a new workflow.

## Current Repo Reality

These architecture pieces are already materially landed:

- `TargetCycle`
- `ActiveTargetProfile` projection from cycle writes
- `DemandForecastContext` with explicit baseline + recent trend
- `WeeklyPlanSnapshot`
- business-date planning anchor authority
- timing boundary contract
- downstream daypart/history semantics audit and decoupling plan

These seams are still incomplete and intentionally deferred:

- persisted restaurant timing configuration beyond timezone
- app-owned service-period definition resolver
- richer Full Week projection provenance in Variance
- upgraded History daypart semantics
- upgraded Learn repeatable-wins semantics
- live Shift service-period behavior and time-into-service

## Phase Ownership

### Already landed

- `7.55l`:
  - target-cycle and weekly-plan runtime architecture
- `7.55m`:
  - runtime-truth cleanup
  - business-date authority and timing cleanup
- `7.55k.1`:
  - daypart scope audit
- `7.55k.2`:
  - service-period decoupling plan
- `7.55k.3`:
  - daypart pattern summary seam

### Current and next

- `7.55k.4`:
  - Variance Full Week projection semantics
- `7.55k.5`:
  - History benchmark-daypart upgrade
- `7.55k.6`:
  - Learn repeatable-wins upgrade
- `7.55k.7`:
  - visibility rules / early-signal policy
- `7.55k.8`:
  - integration implications

### Reserved for 10.5

- live Shift service-period behavior
- live time-into-service
- live service-period tracking during the shift
- Shift primary-driver teaching that depends on daypart-live truth

## One-Sentence Contract

```text
Source systems provide operational facts, the app locks standards on a
60-day cycle, locks plan on a weekly snapshot, compares live and closed truth
honestly, preserves historical provenance, and teaches only from closed
evidence without rewriting already locked reality.
```
