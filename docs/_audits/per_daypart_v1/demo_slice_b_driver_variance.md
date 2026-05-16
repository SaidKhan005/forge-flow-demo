# Audit — Demo data Slice B: driver variance overhaul

**Slice:** Demo-data Slice B (full_demo_data_spec.md §5 "Slice B").
**Branch:** `claude/demo-slice-b-driver-variance` · **Base:** `master` (#790 merged).
**Authority:** prompt #1 → `docs/_audits/per_daypart_v1/full_demo_data_spec.md` §2a/§2b/§2d/§2g/G7 #2 → `CLAUDE.md` HP #2/#11 #3.

## What changed & why

The demo SQLite proved TWO operator-visible defects with one root — a flat seed:

1. **Benchmark showed identical per-daypart targets.** Cohort large ⇒
   `recommendation.isInsufficient == false` ⇒ `_buildDemoSeedCycle` uses
   `recommendation.perDaypartStats[period]`, but seeded closed shifts had
   near-uniform productivity (CPLH ≈ 4.58 every period) so the engine
   returned ≈ equal per-period stats. Plumbing (#784) correct; data flat.
2. **"All covers covers covers."** Seed moved only covers + PPA, held
   wages/CPLH/SPLH/hours at target ⇒ `LaborModel.determineLever`
   collapsed to `covers_*` / the empty fallback `covers_down`.

Both fixed by making seeded shifts genuinely vary per-period productivity
+ driver axes, deterministically (no RNG).

### Implementation

- **Per-period base productivity** (`mock_integration_replay_seed.dart:196-214`):
  closed/projected shifts are built around their period's own target
  (`_basePeriodCPLH/SPLH/PPA` = the existing `_daypartTarget*` constants:
  lunch 4.40 / dinner 4.80 / late_night 3.90 CPLH; 165/200/150 SPLH;
  40.5/43/38.5 PPA) and the per-shift lever is judged against that SAME
  per-period target — mirroring production
  `shift_fact_builder.dart:72-89` (feeds the per-period target snapshot,
  not a whole-day pooled rate). This is what makes
  `recommendation.perDaypartStats` come back materially differentiated.
- **16-lever per-(day,period) intent table** (`:218-280`): each of the 14
  weekly slots deterministically owns one driver axis spanning 8 families
  (13 distinct lever ids); only `covers_down` (Sun dinner) ≈ 7% of the
  cohort. The owned axis is pushed past its `determineLever` threshold
  with margin; every other axis is held exactly on the period target so
  the engine returns the intended lever deterministically
  (`:560-660` `_generateShift`).
- **§2d 12-week variance** (`:158-166`, `:282-318`): history 8 → 12
  weeks; week-level variation is now a pure function of the week index
  (`_weekVolume` lever-neutral ±8–12% volume + trend + soft week;
  `_weekAmp` owned-axis breathing with a gentle improvement trend),
  scaled by `_periodVolatility` (lunch flatter, late_night noisiest).
  `historicalWeekIds` is now a derived `static final` so it can never
  drift from `historicalWeekCount`.
- **Pool-consistency preserved** (Design Rule 4): `_buildDemoSeedCycle`
  is untouched — whole-day `target_cycles` scalars remain the
  cover-weighted Σ of the per-period rows via
  `TargetCycleDaypartPool.fromDayparts`.
- **wage_role_rows seeding** (`sqlite_database_seed.dart:946-1009`,
  called `sqlite_database.dart:503-509`): seeds a FOH/BOH role cohort
  (blends to MeridianConfig 16.50/21.35 so cycle scalars are unchanged)
  so the cycle wage **waterfall** (`_weightedAvgFromRows`) is exercised
  instead of the empty-rows MeridianConfig fallback (G7).
  **Operator-authority safe (HP #11):** seeds ONLY when the demo
  restaurant has zero wage rows, with `ConflictAlgorithm.ignore` — it
  can never delete or overwrite operator-entered wage authority;
  `reseedDemo` never DELETEs `wage_role_rows`.

## Verification (CI dark — exact local commands + results)

- `flutter pub get` — OK.
- `dart analyze` (3 lib + 9 test files touched) — **No issues found.**
- `flutter test test/demo_slice_b_driver_variance_test.dart` — **+7 all
  passed** (Test 1 ≥6 lever families & covers_down ≤50% + Fri-dinner /
  Tue-lunch recurrence; §2d ≥10 weeks non-flat; Test 2 per-period
  CPLH/SPLH/PPA pairwise materially different; Design-Rule-4 pool;
  §2g/G7 wage waterfall; Test 3 determinism: byte-identical generator
  runs AND byte-identical DB reseeds).
- Consolidated run (required-green trio + Slice B + updated stale-seed
  tests, 9 files): `flutter test test/demo_slice_b_driver_variance_test.dart
  test/per_daypart_v1_demo_seed_per_period_cycle_test.dart
  test/target_cycle_daypart_pool_test.dart test/target_cycle_service_test.dart
  test/mock_integration_replay_seed_test.dart test/business_date_foundation_test.dart
  test/replay_integrity_audit_test.dart test/fixture_lever_roundtrip_test.dart
  test/benchmark_tracker_read_service_test.dart` → **+156 all passed.**
- Broad seed-coupled sweep (~55 files across 3 batches) triaged against a
  **master baseline snapshot** (stash lib, run, compare per-file
  ±counts):

| File | master | with Slice B | verdict |
|---|---|---|---|
| per_daypart_v1_demo_seed_per_period_cycle | +3 | +3 | green |
| target_cycle_daypart_pool | green | green | green |
| target_cycle_service | green | green | green |
| shift_service_close_shift | +11 | +11 (fixed) | green |
| wage_standard_context_service | +25 | +25 (fixed) | green |
| fixture_lever_roundtrip | green | green (fixed) | green |
| benchmark_tracker_read_service | green | green (fixed) | green |
| replay_integrity_audit / mock_integration_replay_seed / mock_replay_scenario / business_date_foundation | green/8wk | green (updated) | green |
| current_state_alignment | +39 **-1** | +39 **-1** | pre-existing latent (NOT this PR) |
| persistence_scope_alignment | +33 **-8** | +33 **-8** | pre-existing latent: `no such table: target_cycle_dayparts` in pre-v8 upgrade path (Slice 1 artifact, NOT this PR) |
| state/restaurant_scope_notifier | +7 **-2** | +7 **-2** | pre-existing latent: Slice A multi-location (#788/#790), NOT this PR |
| mock_replay_scenario "benchmark_selection_summaries survive replay advance" | **-1** | **-1** | pre-existing latent on master (NOT this PR) |
| batch 3 (25 files) | — | +501 all passed | green |

**Net: zero PR-introduced regressions remain.** Every failure the PR
introduced (stale 8-week / flat-seed / lever-roundtrip-model / wage-row
assumptions) was fixed; all still-red tests fail identically on pristine
master (baseline-snapshotted) and are out of this slice's scope.

## Pattern B — 14-lens self-audit (worker)

| # | Lens | Finding | Evidence |
|---|---|---|---|
| 1 | Scope fidelity | Exactly §2a+§2d+§2g implemented; no scope creep | `mock_integration_replay_seed.dart`, `sqlite_database_seed.dart` only lib files |
| 2 | Authority order | Prompt → spec §2a/2d/2g → CLAUDE.md honored; per-period target in lever matches production | `shift_fact_builder.dart:77-84` parity |
| 3 | Determinism (hard) | No RNG; all variation from (weekIndex,dayIndex,slotIndex); two reseeds byte-identical | `_weekVolume/_weekAmp` pure (`:296-318`); test "two DB reseeds … identical" green; header L14 invariant intact |
| 4 | Pool-consistency (Design Rule 4) | `_buildDemoSeedCycle` untouched; parent = Σ per-period | `sqlite_database_seed.dart:876`; pool test + Slice B pool test green |
| 5 | Driver mix (§2a) | 8 families / 13 levers; covers_down ≈ 7% ≤ 50% | `_slotDriverIntent` (`:248-263`); Test 1 green |
| 6 | Per-period unlock (§2b) | lunch/dinner/late_night CPLH/SPLH/PPA pairwise materially differ | Test 2 green; `per_daypart_v1_demo_seed_per_period_cycle` green |
| 7 | §2d variance | 12 weeks, trend + soft week + per-period volatility; non-flat dollar gaps | `_weekVolume/_weekAmp`; "§2d ≥10 weeks non-flat" green |
| 8 | HP #2 | Same tables, no `demo_*`, no `kDemoMode` reader branch | only `shift_records`/`week_records`/`wage_role_rows` written |
| 9 | HP #11 (wage authority) | wage seed never deletes/overwrites operator rows; conditional-on-empty + ignore | `sqlite_database_seed.dart:962-1007`; `wage_standard_context_service` J green |
| 10 | Concurrency | No parallel-owned file touched (shift_dashboard/shift_service_period_notifier/daypart_table/baseline_tracker/Settings); Slice A `_seedDemoRestaurant` untouched | diff scope |
| 11 | Production parity | Lever judged vs per-period target = production `ShiftFactBuilder`; wage blended from stored labor $ | `:625-660` |
| 12 | Backward compat | `DemoScope.restaurantId` unchanged; `defaultBusinessDate` unchanged; stale 8-week tests updated to derived counts not magic numbers | `replay_integrity_audit`/`mock_*` tests green |
| 13 | Test honesty | Updated stale tests assert self-consistent invariants (Σ-based), not new magic numbers; lever-roundtrip re-derives with the SAME inputs the seed fed | `shift_service_close_shift_test.dart:171-181,223-231`; `fixture_lever_roundtrip_test.dart:80-126` |
| 14 | Regression triage | Master baseline snapshot taken; every still-red test fails identically on master | table above |

## Independent audit (executor)

Re-derived the lever math by hand for representative slots against
`labor_model.dart:120-202` thresholds:

- **Sun dinner (slot 13, covers_down, sign −1):** `covers = round(baseCoversF*(1−M))`,
  `forecast = round(baseCoversF)` ⇒ `coversDelta ≈ −M ≤ −0.06 < −0.02`;
  ppa/cplh/splh/wage/hours held on target ⇒ sole candidate ⇒
  `covers_down`. ✔ (`mock_integration_replay_seed.dart:600-660`)
- **Tue lunch (slot 2, ppa_up, +1):** `effPPA = basePPA*(1+M)`,
  `ppaDelta = M ≥ 0.06 > 0.03`; others 0 ⇒ `ppa_up`. ✔ Recurs every
  week (fixed per (day,period)) ⇒ §2e benchmark recurrence; asserted
  green in Test 1.
- **Sat dinner (slot 11, foh_hours_over, +1):** `scheduledFoh =
  round(modelFoh*(1+M))`, `modelFohHours = modelFoh` ⇒ `fohFlexDelta ≈ M ≥
  0.15 > 0.10`; `scheduledBoh = modelBoh` ⇒ boh delta 0 ⇒
  `foh_hours_over`. ✔
- **Worst-case margin check:** min `_weekAmp ≈ −0.0255` × max
  `_periodVolatility` 1.4 = −0.0357; every axis baseMag still clears
  its threshold (covers 0.10−0.036=0.064>0.02; cplh/splh 0.12; wage
  0.07; hours 0.19). ✔
- **Recommendation differentiation:** Phase-4 top-50%-by-CPLH per
  daypart over base 4.40/4.80/3.90 ⇒ pairwise CPLH gap ≥ 0.45 ≫ the
  0.20 acceptance bar; SPLH 165/200/150 and PPA 40.5/43/38.5 likewise.
  ✔ (Test 2 green)
- **Pool unchanged:** `_buildDemoSeedCycle` diff = none ⇒ Design Rule 4
  intact. ✔

**Verdict: approve-for-merge.** No escalations. One operator-visible
note (not a blocker): `mock_replay_scenario_test` "benchmark_selection_
summaries survive replay advance" is a **pre-existing latent master
failure** unrelated to this slice (verified by baseline snapshot); it
is out of scope and left as-is for an orphan-followup, not folded here.
