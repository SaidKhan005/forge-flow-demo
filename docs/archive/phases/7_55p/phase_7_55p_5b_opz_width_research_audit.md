# Phase 7.55p.5b - OPZ Width Research / Benchmark-Range Tightening Audit

Updated: 2026-04-13
Owner: Claude research
Status: Landed (research/doc only — no code changes)

## Goal

Answer the user's unresolved trust question with evidence: should the
Benchmark OPZ / benchmark range actually be tighter, or is the current
width correct selected-range truth that only feels too wide because of
presentation?

## Scope

- In: research-first audit of OPZ width derivation, Jim Taylor source
  authority comparison, explicit classification of the concern
- Out: OPZ threshold retune, benchmark selection redesign, code changes
  (none justified by evidence)

## Audit Question

> Should the Benchmark OPZ floor/ceiling band actually tighten?

## Evidence

### 1. Current OPZ width derivation

The OPZ floor and ceiling are the min/max CPLH of the selected benchmark
records (`_opzSourceRecords`). With the default demo selection:

| Metric | Value |
|---|---|
| Selected records | 11 (5 lunch + 6 dinner) |
| Selected CPLH range | 4.2 — 4.8 |
| **OPZ width** | **0.6 CPLH** |
| Target CPLH (average) | 4.53 |
| Headroom (ceiling - target) | 0.27 |
| 60-day historical range | 3.4 — 4.8 |
| Historical width | 1.4 CPLH |
| Inner / outer ratio | 43% of bar |

The range-quality assessment evaluates this 0.6 width as `GOOD OPZ RANGE`
(between the 0.15 narrow threshold and the 1.25 wide threshold).

### 2. Jim Taylor's source authority

From the Jim Taylor deep-dive (repo authority at
`docs/internal/barrio/jim_taylor_labor_model_deep_dive.html`):

**Chapter 11 — The Optimal Productivity Zone:**

Jim's own example restaurant data shows an OPZ of 6.5 to 7.5 CPLH,
which is a **width of 1.0 CPLH**. His table:

| CPLH | FOH Labor % | Zone |
|---|---|---|
| 5.3 | 8.2% | Below OPZ |
| 6.5 | 7.4% | OPZ |
| 7.0 | 7.1% | OPZ |
| 7.5 | 6.8% | OPZ |
| 8.0 | 6.6% | Ceiling |

**Chapter 12 — Reading the Full Story:**

Jim says: *"From your 60 days of CPLH data, identify the range where
labor % declines and service holds. Below it you are bleeding hours.
Above it you are burning your team. Stay inside it."*

The OPZ is explicitly defined as a **range**, not a point. It is the
sustainable operating band — not a precision target. Jim's own example
has a wider OPZ (1.0 CPLH) than the app's default demo data (0.6 CPLH).

### 3. The range-quality thresholds

The current thresholds enforce teachability:

| Condition | Status | What it means |
|---|---|---|
| < 2 selected | TOO NARROW | Not enough data to define a band |
| width < 0.15 | TOO NARROW | Selection too tightly clustered for flex |
| 0.15 ≤ width ≤ 1.25 | GOOD | Teachable range with room to flex |
| width > 1.25 | TOO WIDE | Selection too spread for one clean standard |

The upper threshold (1.25) is above Jim's own 1.0 example, which is
reasonable — a slightly wider band is possible depending on the
restaurant's volume variability. The lower threshold (0.15) prevents
a degenerate point-target. These thresholds are not the issue.

## Classification

**The current OPZ width is correct selected-range truth. The "feels too
wide" concern is presentation ambiguity, not math error.**

Evidence supporting this classification:

1. **The width is 0.6 CPLH** — narrower than Jim Taylor's own published
   OPZ example (1.0 CPLH). The app's OPZ is already tighter than the
   source authority's reference example.

2. **The inner highlight fills ~43% of the graph bar** because the
   selected shifts span ~43% of the 60-day historical range. This is
   proportionally honest. The position normalization was verified
   correct in `7.55m.5`.

3. **The range-quality system already handles genuinely too-wide
   selections** — if the manager selects shifts with CPLH spread > 1.25,
   the badge shows `OPZ RANGE TOO WIDE` and warns them to tighten.
   The current 0.6 correctly evaluates as `GOOD OPZ RANGE`.

4. **The graph explicitly labels both layers** — outer endpoints say
   "LOWEST CPLH LAST 60 DAYS" / "HIGHEST CPLH LAST 60 DAYS" and the
   inner box says "BENCHMARK RANGE" or "STAR SHIFT RANGE". The visual
   distinction exists. The title was tightened to "CPLH RANGE & TARGET"
   in 7.55p.5.

5. **No OPZ derivation math error was found.** OPZ floor = min selected
   CPLH, OPZ ceiling = max selected CPLH. This matches the Ch. 11
   definition: "identify the range where labor % declines and service
   holds."

## Why It Feels Too Wide

The feeling likely comes from two presentation factors, not from the
data being wrong:

1. **The graph compresses a 1.4 CPLH range into a small bar.** At 43%
   fill, the inner highlight looks large. But 0.6 out of 1.4 IS large —
   the restaurant's best shifts are genuinely clustered in the upper
   third of its operating range. That is what good benchmark selection
   looks like.

2. **The OPZ is a coaching band, not a precision target.** A manager
   expecting a single-number target will read any range as "too
   permissive." But Jim Taylor's framework explicitly defines the OPZ
   as a band with floor, ceiling, and headroom. A 0.6-wide band is
   the design intent.

## Verdict

| Question | Answer |
|---|---|
| Is the OPZ width mathematically wrong? | **No.** min/max CPLH of selected records is the correct derivation per Ch. 11. |
| Is the OPZ width structurally too permissive? | **No.** The current 0.6 is narrower than Jim Taylor's own 1.0 example. |
| Are the range-quality thresholds wrong? | **No.** GOOD at 0.6 is correct; the 1.25 TOO WIDE threshold is above Jim's example. |
| Is the graph misleading? | **Mildly.** The proportional fill is honest, but a manager unfamiliar with the OPZ concept may misread the inner highlight as "target precision" rather than "sustainable operating band." |
| Should the OPZ tighten? | **No.** Tightening would move the app further from Jim Taylor's published framework than the current implementation. |

## What Should NOT Change

- OPZ floor/ceiling derivation (min/max of selected CPLH)
- Range-quality thresholds (0.15 / 1.25)
- Position normalization math (bounded [0,1])
- Selected-record source semantics

## What Could Improve Later (Not This Slice)

- **Graph explainer copy could be more educational.** The "GOOD OPZ RANGE"
  message says "Target sits in a usable range with room to flex" but does
  not explain that the OPZ IS the range — not a margin around the target.
  A one-line educational addition could say something like "The OPZ is your
  sustainable operating band — the range where productivity holds and
  service quality stays high." This is a copy improvement, not a math fix.
  
- **Daypart-aware OPZ** (Phase 10.5). Jim discusses CPLH per daypart.
  A lunch OPZ and a dinner OPZ would be tighter individually than the
  combined cross-daypart band. This is the strongest legitimate reason
  the current OPZ feels wider than expected — lunch and dinner have
  different natural CPLH levels. But daypart-aware OPZ is Phase 10.5
  work, not this slice.

## Research Sources

| Source | Location | What it established |
|---|---|---|
| Jim Taylor deep-dive Ch. 11 | `docs/internal/barrio/jim_taylor_labor_model_deep_dive.html` lines 1069-1131 | OPZ is a range (not a point); Jim's example OPZ width is 1.0 CPLH; the OPZ is "the range where labor % declines and service holds" |
| Jim Taylor deep-dive Ch. 12 | same file, lines 1134-1197 | "identify the range where labor % declines and service holds. Below it you are bleeding hours. Above it you are burning your team." |
| `7.55m.5` audit | `docs/archive/phases/7_55m/phase_7_55m_5_benchmark_opz_truth_audit_cleanup.md` | Graph normalization correct; three OPZ concepts separated; source-set fallback split documented |
| Current code | `lib/data/legacy_fixture_data.dart` lines 1093-1167 | OPZ floor = min selected CPLH; ceiling = max selected CPLH; headroom = ceiling - target; range-quality thresholds at 0.15/1.25 |
| Default demo data | same file, lines 970-996 | 11 selected records; CPLH 4.2-4.8; width 0.6 |

## Remaining Gaps

- **Target-package unification** (7.55p.5c) — not this slice
- **Variance package wiring** (7.55p.5d) — not this slice
- **Blended wage refinement/testing** (7.55p.5e) — not this slice
- **Daypart-aware OPZ** (10.5) — the strongest legitimate avenue for
  tighter OPZ bands, but requires per-daypart benchmark selection
