# Outcome-engineering surface audit — Levers, Learn, History, Productivity

Date: 2026-05-05
Owner: Phase 7.58 + Phase 11b advisor closeout audit
Authority:

- `docs/Knowledge_graph_docs/Bold By Design.md` (chapters 2 / 5 / 8 / 9 / 10 / 11 / 12 / 13 — three-lever framework, OPZ, EWF, productivity curve)
- `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` (chapters 4 / 6 / 7 / 8 / 9 — CPLH × SPLH 2x2, theoretical labor, 60-day discipline)
- `docs/Knowledge_graph_docs/OE MASTERING THE METRICS.md` (AGC / CPLH cross-axis red-flag rule)
- `docs/contracts/phase_7_58_primary_driver_contract.md`

This audit reads the operator-facing **outcome-engineering and teaching surfaces** end-to-end (lever catalog, dollar attribution, Learn tab, History tab, Variance > This Week, Week Detail, Shift Dashboard whole-day OPZ tile) against the depth in the Bold by Design + Jim Taylor + OE corpus. The engine math is rigorous; the **teaching surface narrates depth in copy but doesn't structurally surface it as signals operators can act on without doing the cognitive work themselves.**

## Verdict

**Engineering is solid; teaching surface has 7 named depth gaps.**

| Layer                                                                       | Status                                                                                                                                                                                                                                                                                                  |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Engine math** (`LaborModel.determineLever`, `attributeDollarImpactByAxis`) | ✅ Rigorous. Three-lever framework decomposes cleanly into the 16 lever ids; per-axis sum equals dollar gap.                                                                                                                                                                                            |
| **Lever catalog copy** (`LeverCards`, `lib/data/app_defaults.dart`)         | ✅ Rich. Cards cite OPZ ceiling, cross-axis cross-references, Jim Taylor scheduling math. Operators get Bold by Design depth when they read the cards.                                                                                                                                                  |
| **Pattern detection** (`HistoryTeachingAnalyzer`, `LearnTeachingAnalyzer`)  | ⚠ Single-axis only. Counts leverId frequency. **Cross-axis patterns (CPLH × SPLH 2x2, PPA-down + CPLH-up, OPZ-ceiling crossings) are invisible to the engine** — operator must do the cognitive work from narrative copy.                                                                                |
| **OPZ wiring**                                                              | ⚠ Asymmetric. Live whole-day Shift Dashboard surfaces OPZ status (below / in / above) with sub-label. **Variance / History / Learn / Week Detail surfaces do not surface OPZ status at all** — even though `ShiftRecord.opzFloorCPLH` / `opzCeilingCPLH` are persisted on every closed row.            |
| **EWF (Employee Workload Factor)**                                          | ❌ Not modeled. Bold by Design ch. 8 + 13 name EWF as the human-side concept that pairs with productivity. Code has no EWF signal, no "team stress" indicator, no turnover/error rate input. Live shifts have no "you crossed the workload threshold" surface.                                          |
| **CPLH × SPLH pair view**                                                   | ❌ Not surfaced. Jim Taylor ch. 7 names a 4-cell matrix (on/below × on/below) with explicit diagnoses ("CPLH below + SPLH above → fix forecast, not the team"). Engine computes both; teaching surface shows them independently.                                                                       |
| **Theoretical labor floor**                                                 | ⚠ Persisted (`ShiftRecord.theoreticalLaborPct`); not surfaced as **the operator's mathematical floor.** Jim Taylor's "walk-in tears story" (ch. 8) is the canonical depth: a manager evaluated against a target below her wage-rate floor was being held to impossible math. App doesn't flag this.    |
| **Coverage denominator** (7.58.3 data, no UX yet)                           | ⚠ `LearnTeachingSummary.coverageCount` lands as a field but no Learn / History tab renders it. Repeat counts surface without their denominator.                                                                                                                                                         |

## 7 named depth gaps

### Gap 1 — OPZ status invisible on Variance / History / Learn / Week Detail

**Bold by Design depth.** Chapter 9 names the Optimal Productivity Zone as a *range* (floor + ceiling). Beyond ceiling: "service quality declines, guest behavior begins to shift, team stability weakens" (ch. 10). Below floor: "labor underutilized, profitability declines" (ch. 9).

**Current wiring.**

- `lib/models/shift_dashboard_read_model.dart:464–488` — `_computeOpzStatus(currentCplh, floor, ceiling) → 'below' | 'in' | 'above'` + label + sub-label.
- `lib/screens/shift_dashboard.dart:199–204` — whole-day Shift renders the OPZ tile.
- `lib/models/shift_record.dart:74–75, 365–366` — `opzFloorCPLH` + `opzCeilingCPLH` persisted on every closed row + serialized to/from SQLite.
- `lib/screens/variance/{this_week,history,learn}_tab.dart`, `lib/screens/week_detail_screen.dart` — **zero references to `opz`**. Operator hopping from Shift to Variance loses the OPZ context entirely.

**Symptom.** A `cplh_up` shift renders `+$32` favorable green on the new dollar-attribution breakdown (`7.58.UX.1`) regardless of whether actual CPLH crossed the ceiling. The lever card body copy *says* "Check your OPZ position. If CPLH pushed above the ceiling, the team was stretched and service likely felt it." — but the operator has to do the cross-reference manually in their head against a number that is not on the screen.

**Closing slice (recommended).** `7.58.UX.4` — surface OPZ position on every consumer of `ShiftRecord` / `WeekRecord`. Three-state badge (`BELOW OPZ` / `IN OPZ` / `ABOVE OPZ`) on:

- Week Detail PRIMARY DRIVER section.
- Variance > This Week PRIMARY DRIVER section.
- Variance > History leak evidence card.
- Variance > Learn leak snapshot card (the one that already names the lever).

When status = `above`, render the sub-label *"Service quality may suffer."* (already exists in `_computeOpzSubLabel`). Engine is unchanged — only the renderer reads the persisted floor/ceiling/cplh and computes the badge.

**Effort.** ~250 LOC (1 helper extracted from `shift_dashboard_read_model.dart` + 4 renderer wire-ups + walkthrough).

---

### Gap 2 — OPZ-aware sign on dollar-attribution rows

**Bold by Design depth.** Chapter 10: when productivity rises above the OPZ ceiling, "the first signals are often positive. Labor percentage improves. Output per hour increases. ... But these metrics capture only one dimension of performance. They reflect output, not the conditions required to produce that output."

**Current wiring.** `7.58.UX.1` renders `cplh_up` rows as `+$N` green when the per-axis dollar contribution is favorable. Sign convention is pure-dollar; OPZ position not consulted.

**Closing slice.** `7.58.UX.5` — when `cplh_up` (or `splh_up`) row is non-zero AND `actualCPLH > opzCeilingCPLH`, render an `⚠ above OPZ ceiling` adornment beside the `+$N` line. Tooltip on tap: *"Productivity gain crossed the OPZ ceiling. Service quality may suffer; this 'savings' may not be sustainable."* Authority: Bold by Design ch. 10–11.

**Effort.** ~150 LOC (extends `_DollarAttributionSection` row renderer in `lib/widgets/lever_card.dart` + widget tests + walkthrough).

---

### Gap 3 — Cross-axis pattern detection (CPLH × SPLH 2x2)

**Jim Taylor depth.** Ch. 7: explicitly names a 4-cell matrix:

| CPLH      | SPLH      | Diagnosis                                         | Action                                |
| --------- | --------- | ------------------------------------------------- | ------------------------------------- |
| On target | On target | Everything working                                | Document + replicate                  |
| On target | Below     | PPA dropped — upselling issue or rushed service   | Drill into FOH execution              |
| Below     | On target | Volume problem, not execution. **Forecast wrong** | Fix forecast; team had a good night   |
| Below     | Below     | Fewer covers AND less spend                       | Check external cause (weather, event) |

OE Mastering the Metrics adds: **"AGC declining while CPLH rising → understaffed."** That's PPA-down + CPLH-up, the workload-threshold pattern.

**Current wiring.** `LaborModel.determineLever` returns one lever id per call (the dominant axis by `|delta|`). `HistoryTeachingAnalyzer` counts that single id. There is no cross-axis pair detection. A `cplh_below + splh_above` shift surfaces as `cplh_down` ("more FOH hours were scheduled than the covers required") — which is technically correct but misses the Jim Taylor depth: "fix the forecast, the team had a good night."

**Closing slice.** `11b.cross-axis-pattern.0` — extend `HistoryTeachingAnalyzer` to detect cross-axis pairs alongside single-axis patterns. New return field `crossAxisPatterns: List<CrossAxisPattern>` where each carries `{primaryLeverId, secondaryLeverId, jointDiagnosis, jointTeachingNote}`. Lever catalog gains a `crossAxisPairings` map (4 cells of the CPLH × SPLH matrix; PPA-down + CPLH-up combo; PPA-down + CPLH-down; etc.). Learn tab gains a "Look at this pair" card when the cross-axis count exceeds threshold.

**Effort.** ~600 LOC (analyzer extension + cross-axis catalog + Learn tab card + walkthrough). This is its own slice family — not a single lane.

---

### Gap 4 — EWF (Employee Workload Factor) is not modeled

**Bold by Design depth.** Chapters 8 + 13 introduce EWF as the human-side limit that pairs with productivity. Above EWF threshold: "service interactions become shorter, communication becomes louder, mistakes occur more frequently, ticket times become inconsistent, employees experience constant stress, fatigue accumulates, morale declines, turnover increases." (ch. 13 line 1562)

**Current wiring.** OPZ ceiling is the proxy for EWF in the current code (it caps "sustainable productivity"). But EWF as Bold by Design defines it includes signals beyond CPLH: ticket times, remake rate, turnover rate, server-tables-per-hour, kitchen-tickets-per-hour. None of these are ingested today.

**This is not a defect**: the V1 spine is closed-shift truth from POS + labor + reservation vendors, which don't expose ticket-time / remake / turnover. EWF is a Phase 11b advisor / 12 workflow concern.

**Closing slice (post-V1).** `12.ewf.0` — model EWF as a derived metric from vendor-supplied ticket times (when adapter exposes the field — Toast, Lightspeed do; Square / Clover do not). Pair with turnover rate from labor-system data. Render as a third axis on the Shift Dashboard alongside OPZ position. Bold by Design ch. 13 is the binding contract.

**Effort.** Out of V1 scope. Document the gap; defer.

---

### Gap 5 — CPLH × SPLH pair view on Shift Dashboard

**Jim Taylor depth.** Ch. 7: "When CPLH and SPLH move in different directions, something specific happened." The 4-cell matrix is the operator's diagnostic tool.

**Current wiring.** `ShiftDashboardReadModel.buildWholeDay` exposes both `currentCplh` and `currentSplh` as separate `InputMetric` cards. They render side by side but with no joint diagnosis. Operator must mentally cross-reference them.

**Closing slice.** `10.5.6` (or a sibling daypart slice) — add a *"CPLH × SPLH"* tile to the Shift Dashboard that surfaces the joint diagnosis when both axes have signal:

- Both on target → "EVERYTHING WORKING — document this shift."
- CPLH below + SPLH above → "FORECAST WAS LOW — team had a good night."
- CPLH on + SPLH below → "PPA DROPPED — investigate upselling / rushed service."
- Both below → "DEMAND PROBLEM — check external causes first."

**Effort.** ~200 LOC (new tile widget + matrix lookup + walkthrough). Reuses existing CPLH/SPLH metric inputs.

---

### Gap 6 — Theoretical labor as the operator's mathematical floor

**Jim Taylor depth.** Ch. 8 — the "walk-in tears story": *"Their labor was running 31%. Target was 27%. ... But the corporate target was 27% — a number that sat 2.4 points below her mathematical floor. She could not hit 27%. The math made it impossible."*

**Current wiring.** `ShiftRecord.theoreticalLaborPct` and `theoreticalFohLaborPct` / `theoreticalBohLaborPct` are persisted on every closed row. Variance shows actual labor % vs. target labor %. **The theoretical labor % (the operator's mathematical floor) is not visualized as a floor.**

The Variance > This Week PRIMARY DRIVER card explains why the gap exists, but operators evaluating themselves against a target below their theoretical floor will see a permanent leak that they cannot fix without changing wage rates.

**Closing slice.** `7.58.UX.6` — add a "MATHEMATICAL FLOOR" caption to the DOLLAR IMPACT card showing `theoreticalLaborPct` alongside actual + target. When `targetLaborPct < theoreticalLaborPct`, render a warning banner: *"This week's target sits below your mathematical floor at the current wage rate. The gap can't be closed with execution alone."* Authority: Jim Taylor ch. 8.

**Effort.** ~120 LOC (extends `DollarImpactCard` + walkthrough).

---

### Gap 7 — Coverage denominator surfaced in Learn copy

**Bold by Design depth.** Ch. 11 line 1494: *"Every restaurant has its own productivity range. ... It must be discovered through measurement and observation."* Pattern detection is honest only against a sample size.

**Current wiring.** `7.58.3` lands `LearnTeachingSummary.coverageCount` as data. No Learn tab surface renders it.

**Closing slice.** `7.58.UX.3a` — add a one-line caption under the Learn tab's leak snapshot: *"6 of 12 same-daypart shifts in the last 60 days."* Honors the 60-day discipline Jim Taylor ch. 9 binds.

**Effort.** ~50 LOC (extend `_LeakSnapshotCard` + widget test + walkthrough).

---

## Where the engineering already honors the depth (worth naming)

These surfaces are wired correctly; not gaps.

1. **Lever catalog body copy.** Every `LeverCardData` in `app_defaults.dart` carries `whatHappened` + `whatToDo` + `teachingNote` written in Bold by Design + Jim Taylor language. `ppa_down` literally says *"Cross-reference your CPLH. If it was above the OPZ ceiling, the fix is a staffing level adjustment, not a training conversation."* — this is the depth.
2. **Dollar attribution math (`7.58.1`).** Six-step variable-rotation walk decomposes the dollar gap into the three Bold by Design forces (wage / productivity / PPA) plus volume, with sum-equals-gap rigor.
3. **Single Source of Truth (`7.58.2`).** `VarianceDriverPatternReadService` reconciles Learn + History on the same lever id + LeverCardData copy. Two surfaces cannot disagree on diagnosis for the same scope.
4. **Concern A — TPV preservation.** Closed-shift history is immutable; vendor corrections never re-grade past shifts under a newer cycle. Honors Jim Taylor's "60-day discipline" by keeping the historical baseline fixed.
5. **OPZ on Shift Dashboard whole-day.** The live tile reads OPZ floor/ceiling and renders the right sub-label (below / in / above). Just not propagated to the post-shift teaching surfaces.
6. **Lever priority order.** `priorityOrder` in `labor_model.dart:131` puts volume axes first, then productivity, then wages, then hours-flex. Matches Bold by Design ch. 5: *"hours are only one piece of a three-variable system"* — wages and productivity get earlier priority because hours-flex is downstream of both.

---

## Outcome-based engineering — what's missing

The phrase "outcome-based engineering" implies wiring app behavior to operator-actionable outcomes (replicate the win, fix the leak, protect the OPZ). Today:

| Outcome                                       | Current surface                                                                                  | Depth gap                                                                                                                                 |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Replicate a benchmark shift                   | Learn > Repeatable Wins carousel (`variance_learn_tab.dart`); benchmark dayparts surfaced.      | ✅ Wired — operator sees the dayparts + the lever id.                                                                                    |
| Fix a recurring leak                          | Learn > Recurring Leak carousel; `whatToDo` from lever catalog.                                  | ⚠ Single-axis only. Cross-axis depth (e.g. PPA-down + CPLH-up) hidden in copy.                                                            |
| Protect the OPZ                                | Live Shift Dashboard tile.                                                                       | ❌ Not surfaced on closed-shift teaching path. Operators learn from history without OPZ context.                                          |
| Tune scheduling against the math floor       | Variance dollar gap; primary driver attribution.                                                | ❌ Theoretical labor (the floor) not visualized as a floor.                                                                               |
| Spot the workload threshold being crossed     | (none)                                                                                           | ❌ EWF not modeled. CPLH-up + PPA-down combo not surfaced as a structural signal.                                                         |
| Document benchmark patterns for replication   | `benchmarkDayparts` field; benchmark card in Learn.                                              | ✅ Wired.                                                                                                                                 |
| Stop emotional reactions to a single bad shift | `7.58.3` coverage denominator data field.                                                       | ⚠ Data is there; no surface renders it.                                                                                                   |

Outcome-based engineering for an operator running through Learn / History / Variance should answer four questions on the same screen:

1. **What was the dominant lever?** ✅ done by 7.58.UX.1.
2. **How big was it in dollars?** ✅ done by 7.58.1 + 7.58.UX.1.
3. **Did productivity cross the OPZ ceiling?** ❌ Gap 1 + Gap 2.
4. **Is this a real pattern or one-week noise?** ⚠ Gap 7 (denominator data lands; surface doesn't).

---

## Recommended slice family

**Phase 7.58.UX advisor depth wave** — 4 slices, file-disjoint, ~700 LOC total + walkthroughs:

| Slice          | Owns                                                                   | Effort   |
| -------------- | ---------------------------------------------------------------------- | -------- |
| `7.58.UX.3a`   | Coverage denominator caption in Learn (Gap 7).                         | ~50 LOC  |
| `7.58.UX.4`    | OPZ status badge on Variance / History / Learn / Week Detail (Gap 1). | ~250 LOC |
| `7.58.UX.5`    | OPZ-aware adornment on dollar-attribution rows (Gap 2).               | ~150 LOC |
| `7.58.UX.6`    | Theoretical labor floor caption on DOLLAR IMPACT card (Gap 6).        | ~120 LOC |
| `10.5.6` (sib) | CPLH × SPLH pair tile on Shift Dashboard (Gap 5).                     | ~200 LOC |

**Phase 11b advisor wave** — 1 slice (post-V1):

| Slice                          | Owns                                                                                          | Effort   |
| ------------------------------ | --------------------------------------------------------------------------------------------- | -------- |
| `11b.cross-axis-pattern.0`     | Cross-axis pattern detection (CPLH × SPLH 2x2; PPA-down + CPLH-up workload signal). Gap 3.    | ~600 LOC |

**Phase 12 EWF wave** (out of V1; deferred per CLAUDE.md):

| Slice        | Owns                                                                            | Effort   |
| ------------ | ------------------------------------------------------------------------------- | -------- |
| `12.ewf.0`   | EWF model from vendor ticket times + remake rate + turnover. Gap 4.              | TBD      |

---

## Honest summary

**The engineering surface is correct.** Lever math, dollar attribution, parity service, and Concern A all honor Bold by Design + Jim Taylor depth structurally.

**The teaching surface narrates depth in body copy but doesn't structurally surface it.** OPZ status, cross-axis patterns, theoretical labor floor, and coverage denominator are all either persisted-but-not-rendered (OPZ on closed records; coverage denominator on `LearnTeachingSummary`) or computable-but-not-computed (cross-axis 2x2; theoretical labor as floor).

**The 7 gaps are surface-layer fixes, not engine rewrites.** Engine + persistence are unchanged in every recommended slice. Effort: 5 V1 slices ~770 LOC + walkthroughs; one Phase 11b advisor slice ~600 LOC; one Phase 12 EWF slice deferred.

**The gap with the highest leverage is Gap 1 (OPZ status badge across teaching surfaces).** Bold by Design's central thesis is that productivity above the OPZ ceiling looks favorable in numbers but destabilizes the system over time. Today operators learn from history with the OPZ context stripped out — exactly the depth Bold by Design says they need to see.
