# Slice spec — Jim-faithful benchmark selection + realistic demo variance + honest range states

Status: **DRAFT FOR OPERATOR REVIEW. No code written. Not yet a dispatched slice.**
Author: Claude (pressure-test investigation, 2026-05-16)
Authority: subordinate to `CLAUDE.md` order + `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`.
Evidence harness: `test/diag_benchmark_selection_pressure_test.dart` (read-only, 16/16 pass).

## 1. Why this slice exists (proven, not asserted)

The operator's "RANGE UNCERTAIN" screenshot was pressure-tested against the **real**
demo dataset (`MockIntegrationReplaySeed.output`, 192 closed shifts) and against a
realistic-variance dataset. Findings, each backed by a passing harness test:

- **DIAG-0 — the demo data is degenerate.** lunch 86% / dinner 86% / late_night
  **100%** of shifts sit at one CPLH value; late_night sd(CPLH)=0.000,
  sd(PPA)=0.000. `MockIntegrationReplaySeed._generateShift` pins every
  non-driver-intent shift to the exact per-daypart target. **An OPZ is a
  *range* (Jim Ch.11); this data is a *spike*.** No honest algorithm can
  derive a band from it, and "let more shifts close" can never clear it.
- **DIAG-1 — current engine.** lunch & late_night selected-band width `0.00`
  → "CPLH range too narrow" → `weak`; overall `weak` → "RANGE UNCERTAIN".
  The too-narrow gate fires for a **data** reason, not an operations reason.
- **DIAG-2 — Bug #1 real & active.** 300 shuffles of identical demo data →
  300 different selected sets (Dart `List.sort` not stable + tied CPLH).
  Persisted recommended SPLH/PPA wobble run-to-run. (ENGINE-R shows this is
  specifically a tied-CPLH effect — the degenerate seeder guarantees ties.)
- **DIAG-3 — sample-size contamination.** dinner band width 0.21 → 0.73 when
  N halved (Phase-4 `clamp(3,10)` effective-fraction swing).
- **DIAG-4 — self-defeat.** Engine ranks high-CPLH/low-PPA shifts in by CPLH
  (`recommended_benchmark_selection_service.dart:187`), then flags the cohort
  `weak` for "PPA notably below daypart median" (`:243-249`). Selection
  objective fights the quality gate.
- **ENGINE-R — not just the data.** On *realistic* data with a true range the
  current engine still returns `weak` on all three dayparts.

**Root cause is two-pronged: (A) degenerate demo data, (B) the selection
algorithm. Both must be fixed or the screenshot recurs.**

The Jim-faithful prototype in the harness (joint CPLH∧SPLH∧PPA selection,
robust P25–P75 band, per-daypart verdict, stable compound sort) passes every
fidelity/stability/render test on realistic data and **survives the exact
adversarial cluster the current engine fails** (PROTO-5: stretched shifts
excluded, teachable band 4.81–4.92, ceiling < 5.0).

## 2. Jim methodology this slice must honor

`docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`:

- **Ch.09 / Ch.12 Step 3** — select shifts where **CPLH, SPLH and PPA are
  high *together***, not CPLH ranked then PPA vetoed.
- **Ch.09** — target comes from "the range where your team was *consistently*
  comfortable", and "too few good days = your best Wednesday disguised as a
  standard." → minimum benchmark count + a **dispersion floor** (a spike is
  not a range).
- **Ch.11** — the OPZ is a **band with floor, ceiling, headroom**; Jim's own
  reference width ≈ 1.0 CPLH. Target sits *inside* with usable headroom.
- **Ch.09 "Lunch and dinner are different businesses"** — grade each daypart
  independently; one bad period must not poison the others.

## 3. Scope (four prongs, one slice)

### Prong A — Realistic demo-seeder variance
`lib/dev/mock_integration_replay_seed.dart` (`_generateShift`, driver-intent
engine ~`:326-411`,`:627-832`). Replace "pin every non-driver shift to the
exact per-daypart target" with deterministic, seeded, **correlated**
shift-to-shift variation: a good core where CPLH/SPLH/PPA rise together, a
stretched cluster (high CPLH, collapsed PPA — Ch.11 ceiling), and
soft/overstaffed shifts. Per-daypart target/floor/ceiling envelopes stay as
documented in `DEMO_DATASET_FULL_SPEC.md`; only the per-shift realism changes.
Must remain deterministic (seeded RNG) so `output`/`generateForDate` stay
byte-stable for existing tests. Coordinate with **Slice 1 demo reseed**
(plan Decision 4; Gaps 22/23) — same reseed, do not double-wipe.

### Prong B — Jim-faithful selection (`RecommendedBenchmarkSelectionService`)
Rework `lib/domain/services/recommended_benchmark_selection_service.dart`:

1. **Phase 4 replacement.** Drop "rank by CPLH desc, take top-N"
   (`:186-201`). Per daypart, after gates+MAD, compute kept-cohort medians
   of CPLH, SPLH, PPA; the **benchmark set = shifts at/above all three
   medians** (Ch.09 "all three high together").
2. **Stable compound sort everywhere** — `(cplh desc, recordKey asc)`. Kills
   Bug #1. Deterministic output map ordering (daypart key asc).
3. **Robust band (Ch.11).** OPZ floor/ceiling = **P25/P75** of benchmark-set
   CPLH (not min/max of a skewed slice — `:220-221`). Target = median (or
   10% trimmed mean) of benchmark CPLH → sits inside with headroom by
   construction.
4. **Dispersion floor + minimum evidence.** If benchmark-set count <
   `minBenchmark` OR kept-cohort dispersion ≈ 0 (degenerate/spike) →
   per-daypart verdict `building` (honest "not enough real variation yet"),
   **never** a fake point target and **never** "too narrow".
5. **Per-daypart verdict, no global poisoning.** Replace
   `:341-353` `any weak → overall weak`. Each daypart returns
   `teachable | building | inconsistent`. Operation rollup: teachable if any
   daypart teachable; building only if none are. Remove dead
   `qualifyingDayparts != 'insufficient'` condition (`:336`).
6. Keep `RecommendedBenchmarkSelection` wire-shape (no schema/model break);
   per-period stats already consumed by `target_cycle_service` (plan Gap 1,
   `:305-332`, Slice 1). This slice supplies the *correct* per-period stats
   Slice 1 persists.

### Prong C — Honest range-state copy + render
`lib/services/baseline_authority_service.dart` `_resolveGraphHonesty`
(`:723-800`) and `lib/services/target_cycle_service.dart`
`_recommendationAnalytics` (`:685-723`):

- Map the new per-daypart verdicts to honest badges. `building` →
  **"RANGE BUILDING"** with copy that states the real cause (*not enough
  shifts where covers, sales-per-hour and spend were all strong together*)
  — **delete the misleading "let more shifts close … will settle"** line,
  which promises a remedy that cannot work on degenerate/structural cases.
- `inconsistent` → genuine "too wide to teach" (per daypart, not via the
  cross-daypart union recompute).
- Resolve Bug #6/#8: the Learn-chip summary label
  (`_recommendationAnalytics`) and the Benchmark-graph badge must derive
  from the **same** per-daypart verdict — no contradictory labels.
- Make the displayed range numbers and the gated number the **same number**
  (Bug #7) — coordinate with Slice 2 Benchmark tab redesign (Gap 15/17).

### Prong D — Promote the harness to the acceptance gate
Convert `test/diag_benchmark_selection_pressure_test.dart` into the slice's
regression suite (keep the DIAG/ENGINE A-B tests as documentation, make the
PROTO-* invariants assert against the **real** reworked service, not a local
prototype). CI per `feedback_ci_dark_until_2026_06_01` — worker discloses
local `flutter test` + `dart analyze`.

## 4. Out of scope

- No `RecommendedBenchmarkSelection`/`TargetCycle` schema changes (Slice 1
  owns persistence shape).
- No Benchmark-tab visual redesign (Slice 2 owns it; Prong C only feeds it
  honest verdicts + copy).
- No manager-override path change — override is balanced by construction and
  was never the failing path (confirmed: DIAG-* are all recommended-path).
- No variance/audit read-seam changes (Slices 5/6).

## 5. Acceptance criteria

1. DIAG-0 still proves old seeder degenerate **only on the pre-Prong-A
   fixture**; post-Prong-A demo data has per-daypart sd(CPLH) > 0 and < 50%
   of shifts at modal CPLH for every daypart.
2. Reworked service on real (post-A) demo data → every daypart `teachable`
   with width ∈ (0, 1.25], target strictly inside band with headroom > 0.
3. 300-shuffle determinism: exactly **1** distinct verdict + band signature
   (both demo and realistic data).
4. Adversarial high-CPLH/low-PPA cluster → stretched shifts **excluded**,
   teachable band forms, ceiling not dragged up (PROTO-5 parity).
5. Per-daypart independence: dropping one daypart's shifts does not change
   another daypart's verdict/band (PROTO-4 parity).
6. Degenerate input (zero dispersion) → `building` + honest copy, **never**
   "too narrow" and never a zero-width "teachable" point.
7. Learn-chip label == Benchmark-graph badge for the same cycle.
8. `dart analyze` clean; full `flutter test` green (no regression in
   `recommended_benchmark_selection_service_test.dart`,
   `target_cycle_service_test.dart`, `baseline_range_logic_test.dart`,
   `benchmark_tracker_read_service_test.dart` — expect intentional
   updates to assertions that pinned the old behavior; call those out
   explicitly in the PR Pattern-B table).

## 6. Risk & gating

- **Logic-deciding** (changes recommended targets operators are coached to)
  **and demo-seeder-touching.** Per `CLAUDE.md` Hard Promises #3 and the
  workflow gates, requires **explicit operator approval before merge**,
  regardless of audit verdict. No proxy/RLS/schema surface touched.
- Must land **after or with Slice 1** (per-period persistence + demo reseed)
  so the corrected per-period stats have a place to persist; Prong C
  coordinates with **Slice 2** copy. Recommend: dispatch as **Slice 1.6**,
  sequenced immediately after Slice 1, before Slice 2 closes.
- Existing tests asserting the old "top-N / any-weak / min-max band"
  behavior will need rewrites — this is expected behavior change, not
  regression; each must be itemized with file:line in the PR.

## 6a. Pressure-test evidence (design validated, not yet the prod service)

Harness `test/diag_benchmark_selection_pressure_test.dart` — **18/18 pass**,
`dart analyze` clean except expected `avoid_print` infos (diagnostic only;
Prong D suite will not print).

Proven on the Jim-faithful prototype (with the dispersion floor added):

- **No crash on cruel input:** empty, single, all-fail-gates, zero/negative,
  `NaN`/`Infinity`, duplicate record keys, 6000-row N. All return an
  in-enum verdict.
- **Degenerate honesty:** spike / two-value / all-soft / real demo data →
  honest **`building`**, never a fake point, never "too narrow", never the
  misleading "wait and it'll settle". The dispersion-floor hole is closed
  and tested.
- **Robustness:** an extreme outlier (CPLH 999) is dropped by MAD and never
  widens a band.
- **Determinism:** ~12,000+ reshuffle checks (cruel + fuzz) — **zero**
  non-deterministic results. Duplicate keys included.
- **Jim Ch.09 universal alignment:** across **800 randomized datasets**
  (random regimes, N 3–~360, good/stretched/soft mixes) a teachable band
  contained a sub-daypart-median-PPA shift **0 times**. The exact
  self-defeat that breaks the current engine is provably eliminated, not
  anecdotally.
- **Quantified improvement:** in **719 / 800** fuzz datasets the prototype
  yields a teachable band where the current engine returns `weak`.

## 6c. Wide-branch test result (limitation 2 resolved into a finding)

Targeted tests added (`WIDE-1/2/2b/3`, `LIM-1`) — **23/23 pass**:

- A good cohort deliberately scattered across a **3.0 CPLH** raw span still
  produces a **1.24-wide teachable band** → "GOOD OPZ RANGE". A 2.2 raw
  span → 0.91 band. The P25–P75 band **plus** the all-three-high filter
  compress raw spread roughly 4×.
- The `inconsistent` / "RANGE TOO WIDE TO TEACH" verdict is reachable in
  code but **operationally unreachable**: it required an impossible cohort
  (a single daypart whose *good* shifts uniformly span 3.0–9.0 CPLH with
  flat SPLH/PPA) to trip it.
- **Conclusion:** under a robust-band design the realistic operator-facing
  states are just **teachable** and **building**. Shipping a
  "RANGE TOO WIDE TO TEACH" state would be **dead UX** — the operator would
  never see it on real data.

This collapses limitations 1 and 2 into **one** product decision (see §7
Decision 1, now mandatory before implementation).

## 6b. Residual limitations — operator must see these

1. **Relative, not absolute, quality.** A *uniformly stretched* operation
   (every shift high-CPLH/low-PPA) still returns `teachable` — the
   algorithm teaches to the restaurant's own best-consistent band and
   cannot declare "the whole operation is above the OPZ ceiling" without an
   external standard. Per Jim ("no universal correct CPLH; targets come
   from your own 60 days") this is defensible, and it is **not a
   regression** (the current engine's PPA-vs-median guard is also
   relative). But whether F&F wants an absolute guardrail (e.g. flag when
   the whole cohort's PPA/labor-% is structurally poor) is a **product
   decision**, not covered by this slice unless you ask.
2. **`inconsistent` (too-wide) path is operationally vestigial — RESOLVED
   into a finding (§6c).** Now tested (WIDE-1/2/2b). Under a robust band it
   cannot fire on realistic data. Do **not** ship a "RANGE TOO WIDE TO
   TEACH" UX state; states are `teachable` / `building` only — unless
   Decision 1 adds an absolute guardrail, which would *replace* it with a
   meaningful "structurally poor operation" state.
3. **Design, not production.** This validates the prototype/algorithm
   design. Prong D re-asserts every invariant against the *real* reworked
   `RecommendedBenchmarkSelectionService`, not a local copy.
4. **Thresholds are defaults, not calibrated.** `minBenchmark=5`,
   `minKeptStdevCPLH=0.05`, `minTeachableWidthCPLH=0.03`, `tooWide=1.25`
   are reasonable but not tuned against real vendor data — see §7.

## 7. Open decisions for the operator

1. **MANDATORY (merges limitations 1 + 2).** Pick the operator-facing
   model:
   - **(1a) Relative-only.** UX states are just **teachable** /
     **building**. Drop "RANGE TOO WIDE TO TEACH" entirely (proven dead UX).
     Simplest, fully validated, ships now. Accepts the blind spot: a
     uniformly badly-run restaurant still sees a normal "GOOD" target.
   - **(1b) Add an absolute guardrail.** New state when the good cohort's
     PPA / labor-% is structurally poor (using the source-backed
     labor-truth already on the candidates), e.g. *"These are your best
     shifts, but spend/labor say the whole operation is running hot —
     stabilize before coaching to this."* Closes the blind spot AND gives a
     *meaningful* third state to replace the vestigial "too wide". Extra
     scope (new threshold + copy + tests).
2. `minBenchmark` count + dispersion floor (proposed: minBenchmark = 5;
   building if kept sd(CPLH) < 0.05 or good-band width < 0.03).
3. Target statistic: median vs 10% trimmed mean of benchmark CPLH.
4. Exact `building` (and, if 1b, `structurally-poor`) operator copy
   (UX-writing-standard, plain English, reads as training).
5. If 1b: the absolute PPA/labor-% threshold + whether Prong A demo data
   should include one deliberately structurally-poor daypart for
   walkthrough coverage.

## 8. Operator decisions locked (2026-05-16)

- **Decision 1 → 1b chosen.** Ship the absolute guardrail
  (`OPERATION RUNNING HOT`). The vestigial cross-daypart "too wide" state
  is removed; states are `teachable` / `building` / `running-hot`.
- Visual + copy approved against a theme-faithful mockup:
  `docs/f&f Coaching/benchmark_states_mockup.html` (no app code; same
  widget chrome — IBM Plex Mono, sunset `#CC7A3E`, cream card).
- No em-dashes in any operator-facing string.

## 9. Final operator copy (verbatim — build prompt uses these exactly)

| State | Badge | Line 1 | Line 2 / sub |
|---|---|---|---|
| teachable | `GOOD OPZ RANGE` | Covers, sales per hour and spend were all strong together on this range. | **Coach the team to this number.** |
| building — early | `NOT ENOUGH SHIFTS YET` | We need more closed shifts before we can set a number you can coach to. | *Keep running the period as usual. We are just watching for now.* |
| building — flat | `RANGE BUILDING` | There is not enough real variation between shifts yet to define a band. | *For now, pick the shifts that felt best for team productivity by hand while we keep building.* |
| building — few strong | `NOT ENOUGH STRONG SHIFTS` | Only a handful of shifts had covers, sales per hour and spend all strong together. We need more before coaching to a number. | *For now, pick the shifts where the floor felt good, ticket times stayed clean and checks held. Those are the ones we need more of.* |
| running-hot | `OPERATION RUNNING HOT` | Your best shifts show the team running hot: high covers per hour, weaker spend and labor. Fix the staffing pressure before holding the team to this. | — |
| manager override | `YOUR CHOSEN SHIFTS` | You are coaching to a hand-picked set of shifts. Make sure they represent good shifts. | — |
| per-period rollup (Scenario 7) | — | Each period is graded on its own. Coach to the periods marked ready; leave the others until they settle. One period not being ready does not hold back the others. | — |

Target value when not teachable: render `not set` (muted), never `0`
(Design Rule 2). `building`/`few-strong` keep the CHOOSE STAR SHIFTS
button solid (copy steers to manual pick); `early` de-emphasizes it.

## 10. Scenario 7 wiring — bind to the EXISTING daypart-table seam (beware)

Scenario 7 (per-period DAYPART BREAKDOWN badges + targets) MUST reuse the
existing seam, not a parallel computation.

### Reuse, do not re-derive

- Per-period **target** numbers already flow correctly:
  `recommendation.perDaypartStats` → `TargetCycleDaypart` rows
  (`lib/services/target_cycle_service.dart:496-512`) →
  `ActiveTargetProfileDaypart` → `ActiveTargetProfile.daypartFor(id)` →
  consumed verbatim by `lib/widgets/daypart_table.dart:101-116`. Prong B
  only makes those stats correct; **no new plumbing for the numbers.**
  Scenario 7 reads through `profile.daypartFor(range.id)` with the **same
  Gap-42 whole-day-pool fallback** the table already implements
  (`daypart_table.dart:110-116`). Copy that logic; do not invent another.
- Period set comes from `BenchmarkTrackerView.servicePeriodDefinitions`
  (timing-config resolved via `RestaurantTimingConfigReadService`,
  `benchmark_tracker_read_service.dart:86-90`), iterated via
  `ServicePeriodDefinitionResolver.ordered(defs)`. **NEVER** hardcode
  `['lunch','dinner','late_night']` — that is the legacy
  `baseline_authority_service.dart:550` (Gap 15) path and is NOT the
  source the table uses.
- Whole-day parent stays the cover-weighted rollup
  `TargetCycleDaypartPool.fromDayparts` (Design Rule 4 — pool derives from
  periods, never the reverse): `target_cycle_service.dart:515`.

### The real gap Scenario 7 introduces (new scope — coordinate with Slice 1)

- **Per-period VERDICT/badge is not persisted today.** Only a single
  whole-operation `overallQuality` rides on `BaselineRecommendationSignals`
  (`baseline_authority_service.dart` + `target_cycle_service.dart:773-784`).
  The per-period rows (`TargetCycleDaypart`) carry **targets only**, no
  quality tier or reason. Scenario 7's per-period badges
  (GOOD / BUILDING / NOT ENOUGH STRONG / RUNNING HOT) therefore require a
  **per-period quality tier + reason persisted alongside the per-period
  target rows** — extend the per-period shape, do not re-grade at read
  time (re-grading is the parallel computation we are explicitly avoiding).
  This extends the persisted per-period schema/shape → **must coordinate
  with Slice 1** (per-period persistence foundation, plan Gap 1-4) and is a
  schema-touching change → operator approval gate.

### Hazards to beware (verified file:line)

1. **Two different sources already feed the table — keep them separate.**
   The `DaypartRange` *context* columns (lowest/highest/avg CPLH) come from
   candidate aggregation in `BenchmarkTrackerReadService._buildDaypartRanges`
   (`benchmark_tracker_read_service.dart:122-180`) — seed/candidate-derived.
   The *target/OPZ* columns come from `ActiveTargetProfile.daypartFor`
   (recommendation-backed cycle). Scenario 7 must keep the lowest/highest
   endpoints from the candidate aggregation and the target+verdict from the
   cycle per-period rows — exactly the split the table already makes. Do
   not conflate them or recompute targets from candidate averages.
2. **`coverCount` is `stats.selectedCount`, not real covers**
   (`target_cycle_service.dart:510`). The pool "cover-weighted" rollup is
   actually weighted by selected-shift count. The mockup caption says
   "cover-weighted"; the code weights by selected count. Either correct the
   weight in Prong B or correct the caption — flag, do not silently ship
   the mismatch.
3. **Pool rolls up ALL periods, including not-ready ones.** Scenario 7's
   parent "whole day" implies a rollup of *ready* periods only, but
   `TargetCycleDaypartPool.fromDayparts` (`target_cycle.dart:102-149`)
   weights every period (building ones included, with their selectedCount
   weight). Whether the whole-day target should exclude `building` /
   `running-hot` periods is a **behavior decision** — calling it out, not
   assuming. Default per Design Rule 4 today = include all.
4. **Gap-42 null path is honest fallback, not a bug.** When
   `daypartFor(period)` is null the table falls back to the whole-day pool
   (`daypart_table.dart:110-116`). Scenario 7 must mirror this and must
   NOT fabricate a per-period verdict when there is no per-period row;
   render the rollup/pool honestly.
5. **Design Rule 2 (no sentinel 0).** `daypartFor` returns `null`, never
   `0` (`active_target_profile.dart:106-114`). Not-teachable periods render
   `not set`, never `0.00`. `shift_service_period_read_service.dart:421-430`
   shows the canonical per-period-with-whole-day-fallback pattern to mirror.
