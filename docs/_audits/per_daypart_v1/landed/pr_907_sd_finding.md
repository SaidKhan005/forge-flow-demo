# Audit + FINDING — PR #907 (Wave 3 / SD acceptance gate)

Branch `claude/per-daypart-v1-sd-acceptance` → `master`. Test-only.
Verdict: **SD work is correct and complete. It surfaced a real end-to-end
FINDING. #907 must NOT merge until the finding is fixed and §5.7 goes green.**

## What SD proved against the REAL reworked service (6/7 PASS)
- §5.3 determinism: 250 reshuffles × 3 datasets → 1 signature + 1 operationVerdict each. The old `List.sort` instability is dead.
- §5.4/§6a Jim self-defeat: 600 randomized datasets (941 teachable / 228 building / 0 running-hot dayparts) → **0** sub-kept-median-PPA shifts in any teachable band; 0 band-shape; 0 target-outside-band.
- §6b cruel-data: 14 pathological inputs (empty…huge-N 6000) never throw; spike → `building_flat` (no fake point); outlier MAD-dropped; deterministic.
- §5.5 per-daypart independence: dropping late_night leaves lunch/dinner byte-identical.
- §8 two-signal running-hot: both signals → `running_hot` with real band; one-only → not.
- §9 verdict→copy via the REAL SC seam: verbatim spec §9, no em-dash.

## §5.7 FAILS — demo not teachable end-to-end (held hard, not weakened)
The real post-SA demo pipeline (`_demoSeedCandidates()` byte-identical to
production `sqlite_database_seed.dart:_seedRecommendationCandidates`) yields
**lunch = `building_flat`, dinner = `building_flat`, late_night =
`building_few_strong`** — none teachable; `operationVerdict = building_few_strong`.

**Root cause (quantified by SD):** SA's per-(week,period) zero-sum,
sub-lever-threshold perturbation passes SA's own dispersion test (which
measures the *full unfiltered* 60-day set: window sd lunch 0.218 / dinner
0.245) but does **not survive SB's Phase-1 eligibility gates + Phase-3 MAD
outlier filter**. Post-gate/MAD the kept-cohort CPLH stdev collapses to
**0.019 (lunch) / 0.028 (dinner)** — both below SB's principled
`minKeptStdevCPLH = 0.05` dispersion floor — and late_night's
all-three-strong cohort is **3 < `minBenchmark = 5`**. Therefore SB's
*interim* degenerate-data fallback in
`sqlite_database_seed.dart:_buildDemoSeedDayparts` is **still load-bearing**,
directly contradicting spec §5.7 / lines 393-394.

This is **not a bug** in SA or SB individually — each passed its own audit.
It is an SA↔SB integration/calibration gap: SA's injected variance is too
timid to be visible to SB's (correct, principled) gated+MAD+floored
selection. The acceptance gate caught exactly what the per-slice audits
structurally could not. SB's engine is being *honest*.

## Decision required (operator-gated: demo-seeder + threshold + logic)
1. **Tune SA up (recommended).** Increase the demo seeder's per-shift
   variance so post-gate/MAD kept-cohort CPLH stdev > 0.05 and each daypart
   has ≥5 all-three-strong shifts with real spread. Keep SB's principled
   floor (it correctly rejects unrealistically-flat data — that is the
   entire point of the rework). Real restaurants vary shift-to-shift far
   more than SA's ±2-5%; SA was over-constrained to protect demo goldens.
   Cost: a follow-up SA.1 slice + re-baselining the demo golden tests it
   moves; must keep driver-lever rotation tests green.
2. **Lower SB thresholds.** Reduce `minKeptStdevCPLH` / `minBenchmark`.
   **Not recommended** — re-admits spike-flat data as "teachable",
   re-introducing the original dishonesty the rework exists to kill;
   contradicts the 800-fuzz-validated floor.
3. **Amend the claim.** Accept the honest `building_*` demo states as the
   intended demo experience (SB fallback becomes permanent, not interim).
   Honest, lowest-effort, but the demo card then shows "building", not a
   coached target — contrary to the original operator intent for the card.
4. **1 + keep 2 fixed** = recommended combination: the data *should* have
   real variance; SB's floor is correctly doing its job.

S0/SA/SB/SC are individually correct and merged. Only the end-to-end demo
experience is unmet. Next: an operator-chosen follow-up (SA.1) to close the
gap, then #907 §5.7 turns green and SD merges as the durable gate.
