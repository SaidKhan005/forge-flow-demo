# Phase 7.55p.5c - Target-Labor Package Contract

Updated: 2026-04-13
Owner: Claude research / contract
Status: Landed (contract/doc only — no code changes)

## Goal

Define one explicit, honest target-labor package contract across
Benchmark, Shift, and Variance so the app stops drifting between
formula paths surface by surface.

## Scope

- In: contract definition for which labor-target package each surface
  should use and why; explicit ownership audit of current runtime paths
- Out: code changes (none needed — architecture is already correct),
  Variance UI wiring (7.55p.5d), blended wage refinement (7.55p.5e)

## Contract Question

> Should the app carry one labor-target package or two?

## Answer

**Two packages. Both are correct. They answer different questions.**

### Package 1: Theoretical Labor Package

**Source:** `ActiveTargetProfile`

**Fields:**
- `theoreticalFohLaborPct` — `fohWage / (targetCPLH × targetPPA) × 100`
- `theoreticalBohLaborPct` — `bohWage / targetSPLH × 100`
- `theoreticalLaborPct` — sum of FOH + BOH theoretical %

**What it answers:** "Given these targets (CPLH, SPLH, PPA) and these
wages, what is the mathematical labor % at perfect efficiency?"

**Characteristics:**
- Pure continuous math — no integer rounding
- Independent of weekly demand/forecast — uses target PPA directly
- Stable across weeks — changes only when the TargetCycle refreshes
- Locked for 60 days with the cycle

**Consumers:**
- **Benchmark** — shows as `FOH THEORETICAL %` / `BOH THEORETICAL %` /
  `TOTAL THEORETICAL %` in the targets card
- **Variance WTD** — `WeekData.theoreticalLaborPct` used for
  `variancePts = actualLaborPct - theoreticalLaborPct`
- **Variance Full Week** — `VarianceWeekProjectionRow` uses
  `theoreticalLaborPct` from the shift/projected row
- **Schedule** — `SchedulePlan.theoreticalLaborPct` for the plan's
  theoretical benchmark

### Package 2: Planned Target Labor Package

**Source:** `ShiftDashboardReadModel.buildWholeDay()`

**Fields:**
- `targetLaborDollars` — `planFohHours × fohWage + planBohHours × bohWage`
- `targetLaborPct` — `targetLaborDollars / forecastSales × 100`
- `laborVariancePts` — `actualLaborPct - targetLaborPct`

**What it answers:** "Given this week's locked plan hours and this
week's forecast sales, what is the planned labor % for today?"

**Characteristics:**
- Uses integer plan hours (rounded from model-hour formula)
- Uses weekly forecast sales (from locked `WeeklyPlanSnapshot`)
- Changes week to week as demand forecast rolls
- Incorporates the specific day's plan hours, not a weekly average

**Consumers:**
- **Shift** — shows as `Target x.x%` in the labor variance section

## Why They Differ

The two numbers can differ by 0.1–0.5 percentage points because:

1. **Integer hour rounding:** The planned package uses
   `LaborModel.modelFohHours()` and `.modelBohHours()` which return
   integers. The theoretical package uses the continuous formula
   `fohWage / (CPLH × PPA)` which does not round.

2. **Different sales denominator:** The planned package divides by
   `forecastSales` (weekly forecast for the specific day). The
   theoretical package divides by `targetCPLH × targetPPA × covers`
   (target-derived, not forecast-specific).

3. **Weekly demand variation:** The planned package reflects this
   specific day's plan allocation. The theoretical package is the
   cycle-locked baseline.

## Why Unification Would Be Wrong

Forcing both surfaces to show the same number would require either:

- **Degrading Shift** to show the theoretical number — losing the
  plan-based context that makes Shift useful for intraday comparison
- **Degrading Benchmark/Variance** to show the planned number — making
  the theoretical calibration surface dependent on weekly forecast
  noise

Both would be dishonest. The current architecture is correct.

## Surface Ownership Matrix

| Surface | Package | Label | Formula path | Source |
|---|---|---|---|---|
| Benchmark | Theoretical | `TOTAL THEORETICAL %` | `fohWage / (CPLH × PPA) + bohWage / SPLH` | `ActiveTargetProfile` |
| Benchmark | Theoretical | `FOH THEORETICAL %` | `fohWage / (targetCPLH × targetPPA) × 100` | `ActiveTargetProfile` |
| Benchmark | Theoretical | `BOH THEORETICAL %` | `bohWage / targetSPLH × 100` | `ActiveTargetProfile` |
| Shift | Planned | `Target x.x%` | `(planHours × wages) / forecastSales` | `ShiftDashboardReadModel` |
| Variance WTD | Theoretical | `Target` column | `theoreticalLaborPct` | `WeekData` (from profile) |
| Variance Full Week | Theoretical | `Target` column | `theoreticalLaborPct` | `VarianceWeekProjectionRow` |
| Schedule | Theoretical | `Theoretical Labor %` | `theoreticalLaborPct` | `SchedulePlan` |

## Why No Shared Model Is Needed

The two packages already live in the right places:

1. **Theoretical package** lives on `ActiveTargetProfile` — already
   persisted, already consumed by Benchmark/Variance/Schedule.
2. **Planned package** is computed at read-model build time in
   `ShiftDashboardReadModel.buildWholeDay()` — already uses profile
   wages + snapshot plan hours + forecast sales.

Adding a `TargetLaborPackage` model would only duplicate what already
exists. The contract is the deliverable — the fields and formulas are
already correct.

## What This Means for 7.55p.5d

Variance already uses the theoretical package. `7.55p.5d` should:

1. Verify that Variance WTD and Full Week consistently show
   `theoreticalLaborPct` from the profile/cycle authority
2. Ensure FOH/BOH breakdown is available where Variance needs it
3. Not attempt to unify Variance with Shift's planned package

## What This Means for 7.55p.5e

Blended wage refinement should:

1. Not confuse the two packages — blended wage is an input to both
   formulas, not a formula itself
2. Focus on whether the blended wage computation (model-hour-weighted
   average) is the right derivation, not on which package consumes it

## Remaining Gaps

- **Variance wiring verification** (7.55p.5d) — confirm that Variance
  renders theoretical labor % consistently and that FOH/BOH breakdown
  is available
- **Blended wage refinement/testing** (7.55p.5e) — the blended wage
  formula itself, not the package contract
- **Daypart-aware theoretical labor** (10.5) — per-daypart theoretical
  output would make the theoretical package more granular
