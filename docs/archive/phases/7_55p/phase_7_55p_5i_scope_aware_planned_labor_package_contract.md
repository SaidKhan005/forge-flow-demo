# Phase 7.55p.5i - Scope-Aware Planned Labor Package Contract

Updated: 2026-04-14
Owner: Claude contract
Status: Landed (contract/doc only — no code changes)

## Goal

Define the contract for a scope-aware **planned labor package** so
planning-facing surfaces can show honest planned labor % at daypart /
day / week scope without colliding with the Benchmark / Variance
theoretical package.

## Scope

- In: package meaning at daypart / day / week scope; derivation and
  aggregation rules; surface ownership; honest degradation when inputs
  are missing; setup for `7.55p.5j` (read model + projection wiring)
- Out: code changes — no lib/ or test/ touches in this slice
- Out: implementation of the read model (`7.55p.5j`)
- Out: changes to `7.55p.5c` package split — Benchmark and Variance
  stay on the theoretical package
- Out: changes to Benchmark recommendation logic (`7.55p.5g`/`5h`)
- Out: blended-wage redesign (`7.55p.5e` concluded the formula is
  correct; blended wage is a supporting input here, not a redesign)

## Contract question

> How should the app expose planned labor % at daypart, day, and week
> scope so planning surfaces can teach "what labor % are we planning
> to run at this scope?" without either (a) pretending to be the
> Benchmark theoretical % or (b) averaging child row percentages and
> losing cover-weight honesty?

## Answer

**One derivation, three scopes. The planned labor % at any scope is
the ratio of planned labor dollars to forecast sales at that same
scope, always computed from freshly aggregated dollars and sales —
never from averaging child percentages.**

## 1. Package meaning

"Planned labor package" is a **planning metric**. It answers:

> Given the planned hours and the forecast sales at this scope, what
> labor % are we planning to run?

It is explicitly not:

| Other concept | How it differs |
|---|---|
| Theoretical labor % (`ActiveTargetProfile.theoreticalLaborPct`) | Pure continuous math from target CPLH/PPA/SPLH × wages. Independent of demand forecast. Calibration-grade, locked with the cycle. Not a plan-facing metric. |
| Actual labor % (`WeekData.actualLaborPct`) | Closed-truth labor dollars ÷ closed-truth sales. Only exists for periods with finalized shifts. Not a plan-facing metric. |
| Variance-to-theoretical (`WeekData.variancePts`) | `actualLaborPct − theoreticalLaborPct`. A trailing audit metric, not a planning metric. |

The planned package sits alongside these, not in place of them. It
exists so planning/scheduling surfaces can tell a manager *"your plan
is running at X% labor for that daypart / day / week"* without the
other three answering a different question.

## 2. Scope rules

The contract supports three scopes at minimum:

```
daypart  ⊂  day  ⊂  week
```

At **every** scope, planned labor % follows the same formula:

```
planned labor %(scope) =
    planned labor dollars(scope)
  / forecast sales(scope)
  × 100
```

### Never average child percentages

A day's planned labor % is **not** the mean of its daypart planned
labor %. A week's planned labor % is **not** the mean of its day
planned labor %. Averaging row percentages loses cover-weight honesty
and produces misleading numbers when dayparts or days have very
different volumes.

The rule is:

```
1. sum planned labor dollars across the children
2. sum forecast sales across the children
3. recompute the parent % from those two sums
```

This mirrors how the existing `VarianceWeekProjectionReadService`
already handles cover-weighted theoretical % for day rows (see the
`_weightedTheoreticalPct` helper in that service — the planned
package follows the same cover-weighted pattern, just with planned
dollars instead of theoretical %).

### Scope definitions

| Scope | Planned dollars | Forecast sales |
|---|---|---|
| Daypart | `planFohHours(daypart) × fohWage + planBohHours(daypart) × bohWage` | Forecast sales for that daypart |
| Day | Sum of planned dollars across the day's dayparts | Sum of forecast sales across the day's dayparts (matches `WeeklyPlanSnapshotDay.forecastSales` when present) |
| Week | Sum of planned dollars across the week's days (matches `WeeklyPlanSnapshot.requiredFohHours × fohWage + requiredBohHours × bohWage`) | Sum of forecast sales across the week's days (matches `WeeklyPlanSnapshot.forecastSales`) |

Daypart-scoped inputs depend on the `10.5` daypart surface being
built. Until that exists, the **daypart scope is an honest deferral**,
not a silently-faked number. The contract defines what the scope
means so `7.55p.5j` and `10.5` can land it without re-deriving
meaning.

## 3. Derivation contract

### Raw inputs

| Input | Source |
|---|---|
| Planned FOH hours (at scope) | From `WeeklyPlanSnapshot` day rows / existing `ShiftDashboardReadModel.planFohHours` for whole-day; from `10.5` daypart allocation for daypart scope |
| Planned BOH hours (at scope) | Same |
| FOH wage | `ActiveTargetProfile.fohWage` (wage-authority resolved) |
| BOH wage | `ActiveTargetProfile.bohWage` (wage-authority resolved) |
| Forecast sales (at scope) | `WeeklyPlanSnapshotDay.forecastSales` for day; summed over days for week; daypart-level sales from `10.5` once available |

### Rules

- Planned labor dollars at any scope are always
  `(planFohHours × fohWage) + (planBohHours × bohWage)` at that
  scope. No blended-wage shortcut. (Blended wage is a supporting
  display metric per `7.55p.5e`; the planned dollars derivation does
  not depend on it.)
- Forecast sales must be taken from the **same scope** as the planned
  hours. Do not divide day-scope planned dollars by week-scope
  forecast sales, and do not divide daypart-scope planned dollars by
  day-scope forecast sales.
- If the scope lacks either planned hours OR forecast sales, the
  planned labor % for that scope is **unavailable**. Surfaces must
  render it as `—` or hide the cell — never fabricate.
- Plan-hour rounding to integers is an honest, expected characteristic
  of the planned package (`7.55p.5c` flagged this as a legitimate
  reason the planned and theoretical numbers can differ by 0.1–0.5
  pp). It is not a bug.

### Honest degradation table

| Condition | Planned labor %(scope) |
|---|---|
| Planned hours present, forecast sales present | Compute per formula |
| Planned hours present, forecast sales = 0 or missing | Unavailable (`—`) |
| Planned hours missing (scope not allocated yet) | Unavailable (`—`) |
| Both missing | Unavailable (`—`) |

The package should never fall back to the theoretical package when
planned inputs are missing. Degradation is silent on precision, not
silent on source.

## 4. Surface ownership

### Surfaces that SHOULD consume the planned package

| Surface | Scope | Label guidance |
|---|---|---|
| Shift | Day (whole-day today; dayparts at `10.5`) | `Target x.x%` — existing label is fine because Shift's "target" semantically means "plan target for today", not "theoretical calibration target" |
| Day-by-day planning table | Day | `Planned Labor %` — explicit planning vocabulary |
| Daypart planning / coaching table | Daypart | `Planned Labor %` — same |
| Full-week planning/projection row (plan-facing columns) | Week | `Planned Labor %` — same |

### Surfaces that should NOT consume the planned package

| Surface | Why |
|---|---|
| Benchmark (`_BaselineTargetsCard`) | Benchmark shows cycle-locked theoretical %. Swapping in a forecast-dependent planned % would make the calibration surface jitter week-to-week for no teaching value. |
| Variance WTD (`variancePts` column + `Target` column) | Variance teaches `actual vs theoretical`. Swapping the comparison to planned would lose the cycle-locked standard Variance is defined against. |
| Variance Full Week (`ProjectionDayRow.theoreticalLaborPct`) | Same reason — the Variance surface is the `7.55p.5d`-verified theoretical consumer. |

`7.55p.5c` explicitly predicted this split and `7.55p.5d` verified
Variance is already correctly wired. This slice preserves both.

### Surfaces that legitimately show both

When a single surface shows both plan-facing and theoretical concepts
(e.g. a full-week projection that teaches "planned vs theoretical vs
actual" side-by-side), labeling must be explicit:

- Theoretical column → `THEORETICAL %` or `Theoretical Labor %`
- Planned column → `PLANNED %` or `Planned Labor %`
- Actual column → `ACTUAL %` or `Actual Labor %`

The existing Benchmark card already uses the `THEORETICAL %` label
family per `7.55p.5a`. That convention extends here: `PLANNED %` is
the corresponding honest label for the planned package. Any surface
that mixes the two must not let either side borrow the other's word.

## 5. Where this lives in the runtime

The planned package is a **read-model concept**, not a widget-owned
concept. `7.55p.5j` will put the derivation in a single read service
(or extend an existing one), and planning surfaces will consume the
read model.

Rationale:

- The aggregation rule (sum dollars / sum sales, then %) is easy to
  re-derive *once* in a read service and awkward to re-derive *per
  widget*.
- The degradation rule ("unavailable when inputs are missing") is
  easier to enforce in one place than across every planning widget.
- Read-model ownership matches how the theoretical package already
  works: surfaces read `ActiveTargetProfile.theoreticalLaborPct` /
  `WeekData.theoreticalLaborPct` / `VarianceWeekProjection` — they
  do not recompute.

`7.55p.5j` is not pre-solved here. The contract just establishes that
the planned package belongs in a read model.

## 6. What this contract does NOT add

- **No new truth package.** This is the existing `7.55p.5c` planned
  package, made explicit at daypart / day / week scope. The
  theoretical package stays on `ActiveTargetProfile`.
- **No new schema.** Planned hours and forecast sales already exist on
  `WeeklyPlanSnapshot` / `WeeklyPlanSnapshotDay` / `ShiftDashboardReadModel`.
  `7.55p.5j` may add a read-model class; it should not need a new
  persistence table.
- **No widget redesign.** Surface ownership is stated; widget work
  follows the `7.55p.5j` read model.
- **No blended-wage change.** Blended wage is a supporting display
  concept; the planned package does not depend on it.
- **No daypart implementation.** Daypart-scoped planned labor % is
  defined here so `10.5` can land it cleanly, not implemented now.

## 7. What 7.55p.5j should pick up

`7.55p.5j` should:

1. Introduce or extend a read model that exposes:
   - `plannedLaborDollars(scope)`
   - `forecastSales(scope)`
   - `plannedLaborPct(scope)` with null / unavailable semantics
   for each supported scope.
2. Wire the read model into:
   - Shift (whole-day scope today; confirm it still reads the same
     numbers as it does today through `ShiftDashboardReadModel`).
   - The full-week planning/projection surface when rows are
     plan-facing.
   - Any day-by-day or daypart planning table that currently shows
     hours/sales — add the planned labor % column from the same read
     model.
3. Respect aggregation rules:
   - Sum dollars and sales first; recompute % at the parent scope.
   - Never average child percentages.
4. Respect degradation rules:
   - Missing inputs → unavailable, not a fabricated number.
5. Label honestly:
   - `PLANNED %` / `Planned Labor %` — not `THEORETICAL` and not
     `Target` without a scope modifier.

## 8. Jim Taylor / architecture alignment

This contract does not add a new theory. It operationalizes the
existing architecture:

- Jim Taylor Ch. 10 (plan vs actual) already frames labor % as a
  plan-side metric for the floor manager's decisions; Ch. 11/12 frame
  labor % as a theoretical calibration metric. The two-package split
  in `7.55p.5c` encoded that distinction at the package level. This
  slice extends the plan-side package across scopes so planning tables
  can read from it directly.
- The cover-weighted aggregation rule is already in use by
  `VarianceWeekProjectionReadService._weightedTheoreticalPct` for day
  rows. The planned package follows the same cover-weighted pattern
  with planned dollars instead of theoretical %.
- `7.55p.5c` flagged that the planned and theoretical numbers
  legitimately differ; this contract treats that as baked-in, not as
  a bug to be reconciled.

## Remaining gaps

- **Service / read model implementation** (`7.55p.5j`) — the actual
  code path that exposes `plannedLaborPct(scope)` to planning surfaces.
- **Daypart-scope inputs** (`10.5`) — planned FOH/BOH hours per daypart
  and forecast sales per daypart land with daypart-aware surfaces. The
  contract supports this scope; `7.55p.5j` can stub daypart as
  `unavailable` until `10.5`.
- **Widget labels** — `7.55p.5j` should apply the `PLANNED %` label on
  planning tables that don't already use the `Target x.x%` Shift
  label; bigger label / copy audits belong to the `7.55o.*` lane.
- **Historical-actual reconciliation** — planned-vs-actual at day /
  daypart scope is a separate comparison the `7.55o` / `10.5` lanes
  can teach later. This contract only defines the planned side.
