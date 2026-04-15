# Phase 7.55p.1 â€” Shift Driver Trust Audit

Updated: 2026-04-13
Owner: Codex planning / tracker truth
Status: Landed

## What This Slice Establishes

An explicit, testable contract for how the Shift screen's primary driver
behaves today â€” which Chapter 10 lever families are reachable, which are
not, what hero-card and color emphasis the operator sees, and what
remains deferred.

This is the Shift-first audit. Variance alignment is a separate follow-up.

## Reference

- Jim Taylor Chapter 10: Variance â€” model hours vs actual, dollar gap,
  lever identification
- `LaborModel.determineLever(...)` â€” shared engine
- `ShiftDashboardReadModel.buildWholeDay()` â€” Shift caller
- `InputMetricCard` â€” visual rendering of emphasis semantics
- `phase_7_55m_4_driver_parity_audit_cleanup.md` â€” prior audit establishing
  that Shift and Variance can legitimately differ

## Shift Scope Today

- **Whole-day, current-state**: aggregates closed + open snapshots for
  the current business day
- **Not daypart-live**: Phase 10.5 owns service-period-level driver
- **Visible driver surface**: hero metric card with DRIVER badge
- **Hidden driver surface**: full PRIMARY DRIVER teaching section is
  commented out, deferred to Phase 10.5

## Shift Call Shape

`ShiftDashboardReadModel.buildWholeDay()` calls `LaborModel.determineLever`
with the following parameters (lines 209â€“222 of
`shift_dashboard_read_model.dart`):

| Parameter | Passed? | Source |
|---|---|---|
| `actualCovers` | yes | closed + open snapshot aggregate |
| `forecastCovers` | yes | SchedulePlan day-row forecast |
| `avgCPLH` | yes | totalCovers / actual-to-date FOH hours |
| `avgPPA` | yes | totalSales / totalCovers |
| `targetCPLH` | yes | ActiveTargetProfile |
| `targetPPA` | yes | ActiveTargetProfile |
| `avgSPLH` | yes | totalSales / actual-to-date BOH hours |
| `targetSPLH` | yes | ActiveTargetProfile |
| `avgFohBlendedWage` | **not passed** | â€” |
| `targetFohWage` | **not passed** | â€” |
| `avgBohBlendedWage` | **not passed** | â€” |
| `targetBohWage` | **not passed** | â€” |
| `scheduledFohHours` | yes | full-day scheduled (closed + open + projected) |
| `modelFohHours` | yes | SchedulePlan planFohHours |
| `scheduledBohHours` | yes | full-day scheduled (closed + open + projected) |
| `modelBohHours` | yes | SchedulePlan planBohHours |

## Chapter 10 Family Reachability on Shift

### Reachable Chapter 10 families (8 of 12)

| Family | Direction | Hero card | Threshold |
|---|---|---|---|
| `covers_down` | unfavorable | COVERS | > 2% below forecast |
| `covers_up` | favorable | COVERS | > 2% above forecast |
| `ppa_down` | unfavorable | PPA | > 3% below target |
| `ppa_up` | favorable | PPA | > 3% above target |
| `cplh_down` | unfavorable | CPLH | > 5% below target |
| `cplh_up` | favorable | CPLH | > 5% above target |
| `splh_down` | unfavorable | SPLH | > 5% below target |
| `splh_up` | favorable | SPLH | > 5% above target |

### Not reachable on Shift today (4 of 12)

| Family | Why not reachable |
|---|---|
| `foh_wage_up` | Shift does not pass `avgFohBlendedWage` / `targetFohWage` |
| `foh_wage_down` | Shift does not pass `avgFohBlendedWage` / `targetFohWage` |
| `boh_wage_up` | Shift does not pass `avgBohBlendedWage` / `targetBohWage` |
| `boh_wage_down` | Shift does not pass `avgBohBlendedWage` / `targetBohWage` |

The engine supports wage levers when the optional parameters are provided.
Shift does not provide them today. This is intentional â€” Shift is a
whole-day current-state surface and does not currently carry per-snapshot
wage actuals. Variance WTD does pass wages and can fire wage levers.

### Reachable non-Chapter-10 families (4 extra)

| Family | Direction | Threshold | Source |
|---|---|---|---|
| `foh_hours_over` | unfavorable | scheduled > model by > 10% | hours-flex lever |
| `foh_hours_under` | favorable | scheduled < model by > 10% | hours-flex lever |
| `boh_hours_over` | unfavorable | scheduled > model by > 10% | hours-flex lever |
| `boh_hours_under` | favorable | scheduled < model by > 10% | hours-flex lever |

These are **not Chapter 10 lever families**. They are hours-flex families
added to the engine for schedule-vs-model deviation detection. Shift
passes full-day scheduled hours and plan hours, so these families **can
fire** on the Shift screen.

**Current risk**: if a schedule-vs-model deviation is > 10% and is the
largest deviation, the hours-flex lever wins over a Chapter 10 family.
The hero card mapping for hours-flex falls through to the default
`'COVERS'` card because `_heroMetricNameForLever` does not have a
branch for `foh_hours_*` / `boh_hours_*` prefixes.

**Status**: this is documented as a follow-up gap â€” not resolved in this
slice. Product should decide whether hours-flex families should:
- have their own hero card (e.g., `FOH HOURS` / `BOH HOURS`)
- map to an existing card
- be excluded from the Shift call

## Shift Driver Trust Matrix

Each row is a scenario with a single dominant deviation. All other inputs
are at target.

### Unfavorable scenarios (red emphasis)

| Scenario | Input delta | Expected lever | Hero card | deltaUnfavorable | Status color |
|---|---|---|---|---|---|
| Covers light | actual 160, forecast 200 (âˆ’20%) | `covers_down` | COVERS | true (actual < forecast) | red |
| PPA below target | avgPPA = target Ã— 0.90 (âˆ’10%) | `ppa_down` | PPA | true (actual < target) | red |
| CPLH below target | avgCPLH = target Ã— 0.85 (âˆ’15%) | `cplh_down` | CPLH | true (actual < target) | red |
| SPLH below target | avgSPLH = target Ã— 0.85 (âˆ’15%) | `splh_down` | SPLH | true (actual < target) | red |

### Favorable scenarios (green emphasis)

| Scenario | Input delta | Expected lever | Hero card | deltaUnfavorable | Status color |
|---|---|---|---|---|---|
| Covers heavy | actual 250, forecast 200 (+25%) | `covers_up` | COVERS | false (actual > forecast) | green |
| PPA above target | avgPPA = target Ã— 1.10 (+10%) | `ppa_up` | PPA | false (actual > target) | green |
| CPLH above target | avgCPLH = target Ã— 1.15 (+15%) | `cplh_up` | CPLH | false (actual > target) | green |
| SPLH above target | avgSPLH = target Ã— 1.15 (+15%) | `splh_up` | SPLH | false (actual > target) | green |

## Hero-Card and Emphasis Behavior

### How the hero card is selected

1. `LaborModel.determineLever(...)` returns the lever id with the
   largest absolute deviation from target
2. `_heroMetricNameForLever(leverId)` maps the lever id to a metric
   card name: `COVERS`, `PPA`, `CPLH`, `SPLH`, or `BLENDED WAGE`
3. Exactly one metric card gets `isHero = true`
4. The hero card renders with a DRIVER badge, stronger border, and
   sunset accent gradient

### How positive vs negative emphasis works

Each metric card computes its own `deltaUnfavorable` independently:

| Card | deltaUnfavorable when... | Status color |
|---|---|---|
| COVERS | actualCovers < forecastCovers | red when light, green when heavy |
| PPA | actualPPA < targetPPA | red when below, green when above |
| CPLH | actualCPLH < targetCPLH | red when below target |
| SPLH | actualSPLH < targetSPLH | red when below, green when above |
| BLENDED WAGE | blendedWage > targetBlendedWage | red when over (overtime), green when under |

In `InputMetricCard`:
- `deltaColor` = `AppColors.negative` (red) when `deltaUnfavorable`,
  `AppColors.positive` (green) otherwise
- Arrow icon: `arrow_downward` when unfavorable, `arrow_upward` otherwise
- Status dot + text: uses `statusFavorable ?? !deltaUnfavorable`

**CPLH special case**: CPLH uses OPZ status for the status line color
independently of the delta color. `statusFavorable` is set from
`opzStatus == 'in'`, so the status dot can be green (in OPZ) even when
the delta pill is red (below target CPLH). This is correct â€” OPZ
acceptability and raw target deviation are different questions.

### Favorable lever = green hero card

When the lever is favorable (e.g., `covers_up`, `ppa_up`, `cplh_up`,
`splh_up`), the hero card's delta pill is green and the arrow points up.
Positive drivers receive equal emphasis â€” there is no asymmetry that
suppresses green highlighting.

## What This Slice Does NOT Do

- Does not fix Variance WTD / Full Week driver alignment
- Does not add wage-lever support to the Shift call shape
- Does not add hero-card mapping for hours-flex families
- Does not redesign the lever engine
- Does not touch Phase 10.5 daypart-live teaching behavior
- Does not add visual polish

## Follow-Up Gaps

### Gap 1: Hours-flex hero-card mapping

Hours-flex levers (`foh_hours_over`, `boh_hours_over`, etc.) can fire on
Shift but fall through to the COVERS card default in
`_heroMetricNameForLever`. Product decision needed on whether these should
have their own card, map to an existing card, or be excluded.

### Gap 2: Wage lever reachability on Shift

Shift does not pass per-snapshot wage actuals. If product wants wage
levers on Shift, a data-side change is needed to aggregate blended
FOH/BOH wages from snapshots and pass them separately. This is not
blocked by the engine.

### Gap 3: Default lever when nothing fires

When no lever exceeds its threshold, `determineLever` returns
`'covers_down'` as the default. This is a safe fallback but
technically claims covers are the driver even when all metrics are on
target. Product may want a neutral `'on_model'` default for the
all-at-target case on Shift.

## Files Created

- `docs/archive/phases/7_55p/phase_7_55p_1_shift_driver_trust_audit.md`
- `test/shift_driver_trust_audit_test.dart`

## Phase Ownership

- `7.55p.1` owns the Shift driver trust audit against Chapter 10
- Variance driver alignment is a separate follow-up
- Hours-flex and wage-lever product decisions are follow-up gaps
- Phase 10.5 owns daypart-live driver teaching
