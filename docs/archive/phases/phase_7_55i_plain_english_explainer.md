# Phase 7.55i - Plain English Explainer

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Historical companion to retired `7.55i`

## What 7.55i Is

Phase 7.55i is the cleanup phase that makes the app's planning architecture trustworthy before live POS, labor, and reservation integrations arrive.

In simple terms:

- the formulas are mostly already right
- the screens mostly already look right
- but some important values are still being pulled from temporary bridge code in more than one place

7.55i fixes that.

It makes sure the app has one clear source for:

- demand
- planning targets
- wage standards
- and the handoff point for later WTD / History / Learn semantics

Important now:

- `7.55i` is retired after `7.55i.3a`
- it delivered the demand, plan, and wage authority seams
- the newer runtime architecture now continues under:
  - `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
  - `docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md`
  - `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`

## The Problem Today

Right now, parts of the app still get planning inputs from `BaselineData`, which is acting like a compatibility bridge.

That has been okay for stabilization, but it is not the final architecture.

The risk is not "the app is broken." The risk is:

- Schedule can build demand one way
- Shift can build demand another way
- Audit can show a third path
- Manager Override preview can still lean on the bridge
- Learn can still read benchmark context from mutable fixture-style state

So even if the math formulas are correct, the app can still drift because the inputs are not fully owned in one place yet.

## What Good Architecture Looks Like

This is the clean shape we are aiming for:

```text
POS / labor / reservation integrations
-> canonical operational facts
-> 60-Day Benchmark Snapshot
-> TargetCycle + ActiveTargetProfile + wage context
-> rolling DemandForecastContext
-> shared SchedulePlan
-> WeeklyPlanSnapshot
-> Schedule / Shift / Audit
-> Variance / History / Learn
```

The key separation is:

```text
Benchmark builds standards.
Demand context builds demand.
SchedulePlan combines both.
```

That means:

- the benchmark does not own forecast covers
- the target profile does not secretly own weekly average covers
- the schedule screen does not invent its own demand rules
- the shift screen does not build a slightly different plan from the schedule screen

## The Most Important Rule

There are three different things that need to stay separate:

### 1. Benchmark / Active Targets

This is the standard we want to run:

- target CPLH
- target SPLH
- target PPA
- FOH wage standard
- BOH wage standard
- OPZ floor / ceiling
- theoretical labor standards

This is "what good looks like."

### 2. Demand Forecast Context

This is the amount of business we expect:

- total covers in the 60-day window
- weekly average covers
- where those covers came from
- whether the number is real, fallback, or unavailable

This is "how much volume we are planning for."

### 3. SchedulePlan

This is what happens when we combine the first two:

- forecast covers
- forecast sales
- required FOH hours
- required BOH hours
- theoretical labor dollars
- theoretical labor percent
- target blended wage
- day rows and daypart distribution

This is the actual operating plan.

## How This Fits the Product Flow

Here is the plain-English flow we want across the product:

### Benchmark

Uses closed history to establish standards.

It should answer:

- what does good performance usually look like here?
- what target CPLH / SPLH / PPA should we use?
- what wage standards are in force?

### Plan

Uses demand + benchmark standards to build the weekly operating plan.

It should answer:

- how many covers are we planning for?
- what sales does that imply?
- how many FOH and BOH hours does that require?

### Shift

Uses live actuals against the plan.

It should answer:

- how are we doing today against the plan?
- are we over or under on covers, sales, and hours?

### Variance

Uses closed truth.

It should answer:

- once the shift or week is closed, what actually happened?

### Learn

Uses closed history + benchmark context.

It should answer:

- what patterns repeat?
- what good habits repeat?
- what leaks repeat?

## What 7.55i Specifically Adds

### 7.55i.1 - Canonical Demand Context

This moves demand out of temporary direct `BaselineData` reads and into one real app-side authority.

In plain terms:

- one service computes the 60-day covers context
- one service decides the anchor date
- one service decides the weekly average covers
- screens stop pulling that number ad hoc

This does not change the formula.

It changes who owns the number.

### 7.55i.2 - Shared SchedulePlan Authority

This makes Schedule, Shift, Audit, and Manager Override preview all consume the same resolved plan.

In plain terms:

- no more "same math in multiple places"
- no more separate plan-building seams per screen
- one shared authority builds the plan

This does not mean rewriting the formulas.

It means centralizing the inputs and outputs.

### 7.55i.3 - Wage Standard Authority + Fallback Generator

This creates one clean wage-source seam.

Long term:

- labor integration should provide wage truth when possible

Short term:

- the app can provide a lightweight fallback wage setup / generator in Settings

That fallback should not create a second architecture.
It should feed the same wage authority path the live integration will use later.

Important rule:

- FOH wage and BOH wage are standards
- blended wage is always derived

### 7.55i.4 - Dropped

`7.55i.4` is intentionally not active anymore.

Those remaining architecture questions now live under the newer cycle/week
lane, not inside `7.55i`.

## What 7.55i Does Not Do

7.55i is not:

- a visual redesign
- new labor math
- new schedule math
- a new forecast formula
- live POS integration
- live labor integration
- live reservation integration

It is mainly an ownership and authority cleanup phase.

The question is not:

"What is the formula?"

The question is:

"Where is the authoritative place that this formula's inputs come from?"

## Why This Matters Before Live Integrations

If we skip this cleanup and go straight to live integrations, we risk doing the live adapter work on top of blurry app-side ownership.

That creates avoidable problems:

- screens disagree even with good vendor data
- changes get patched in one place but not another
- debugging gets harder
- future vendor swaps become messier

7.55i gives us one clean shape first, so Phase 8 can mostly replace transport, not architecture.

That is the real point.

## The Wage Piece in Plain English

This deserves its own simple explanation.

We now know:

- wage standards should really come from labor data when possible
- but we do not yet know exactly what every labor API will expose

So the architecture needs to support both:

### Preferred path

Use labor integration data to derive:

- FOH wage
- BOH wage
- reference blended wage

### Fallback path

Use an app-owned wage setup / generator in Settings.

That setup can be role-based and lightweight:

- role
- FOH / BOH / manager classification
- hourly rate
- weighting input

Then derive:

- FOH wage
- BOH wage
- blended wage

The important architectural rule is:

- both paths must feed the same wage authority seam

Not:

- one path for live integrations
- another totally separate path for fallback mode

## What Success Looks Like

When 7.55i is done, we should be able to say:

- demand comes from one real app-side demand authority
- plan values come from one real app-side plan authority
- wage standards come from one real wage authority
- remaining WTD / History / Learn semantics are explicitly handed off instead
  of being half-owned
- remaining `BaselineData` usage is either retired or explicitly documented as temporary bridge scope

## Short Version

If you want the shortest possible summary:

```text
7.55i is the phase where we stop "kind of" having one architecture
and actually make the planning side of the app authoritative.
```

Or even shorter:

```text
7.55i makes the app's planning truth live in one place before live integrations arrive.
```
