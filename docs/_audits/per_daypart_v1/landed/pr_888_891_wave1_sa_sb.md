# Audit — Wave 1: PR #888 (SA seeder) + PR #891 (SB algorithm)

Audited by: orchestrator (independent), against spec + validated prototype + CLAUDE.md
Verdict: **APPROVE both, pending (a) operator merge sign-off (logic/seeder gate) and (b) explicit operator blessing of the running-hot semantic resolution in SB.**

## Integration check (done before this audit)
Scratch worktree = `origin/master` + SA + SB merged: **no conflicts**. Combined
suites `recommended_benchmark_selection_service_test.dart` (SB rewrite) +
`demo_slice_sa_seeder_variance_test.dart` (SA) + `target_cycle_service_test.dart`
(incl. **Design Rule 4 pool-consistency invariant**) + `per_daypart_v1_demo_seed_per_location_data_test.dart`
→ **105/105 passed**.

## SA — PR #888 (`lib/dev/mock_integration_replay_seed.dart` + 1 new test)
| Check | Result |
|---|---|
| Scope | 2 files only; no algorithm/model/migration/widget/copy touch. OK |
| Determinism | Pure function of (weekIndex, period-membership index); no RNG/`DateTime.now`. Byte-stable. OK |
| Driver-intent preserved | Owned + week-tilted axes excluded from the profile; offsets strictly sub-threshold (cplh/splh <5%, ppa <3%) so no axis becomes a `determineLever` candidate. OK |
| Means preserved | Offsets zero-sum across a period's slots; weekly rotation a pure permutation → per-(week,period) mean and week aggregate unchanged. OK |
| Dispersion fixed | lunch sd 0.24 / dinner 0.27 / late_night 0.13; modal share <0.50 every daypart (was ~0.86/0.86/1.0). OK |
| Regressions | 211-test seeder-dependent batch green; no goldens moved; the 4+2 other failures verified byte-identical at base `874bcb69` (pre-existing). OK |

## SB — PR #891 (8 files)
| Check | Result |
|---|---|
| Algorithm | Mirrors the validated `_JimFaithfulSelector`: joint CPLH∧SPLH∧PPA ≥ kept-median selection; stable compound sort (cplh desc, recordKey asc); robust P25/P75 band; **median** target (Decision 3); dispersion floor → `building_flat`; min-evidence → `building_early`/`building_few_strong`; no cross-daypart poisoning; dead `qualifyingDayparts` removed; NaN/Inf gating. OK |
| Verdict emission | Per-period `verdict`/`verdictReason` + `operationVerdict` populated (S0 fields); additive `selectedCoverSum`. OK |
| target_cycle_service | Carries verdict/reason into `TargetCycleDaypart`; `coverCount`=real `selectedCoverSum` (mislabel fixed); whole-day pool from **teachable periods only** with no-teachable→Gap-42 fallback; projector carries verdict cycle→profile; `_recommendationAnalytics` single verdict source. OK (matches locked decisions) |
| `sqlite_database_seed.dart` touch (beyond literal scope) | **Justified necessary consumer adaptation**: honest grading returns `building_*` (zeroed band) for the pre-SA degenerate demo data, which would break demo bootstrap. SB extends the *existing* insufficient fallback to also cover the honest `building_*` case (falls back to the same deterministic demo band constants) and carries the verdict through. Minimal, well-commented, NOT a demo-data-shape change (SA owns shape). Becomes inert once SA's realistic data lands → SD must confirm periods are `teachable` end-to-end. ACCEPT + flag for post-merge re-verify. |
| Tests | `recommended_benchmark_selection_service_test.dart` rewritten (25 + new determinism/self-defeat/independence/flat/running-hot focused tests); `target_cycle_service_test.dart` + per-location test updated with old→new justification (un-pinning the OLD masking of degenerate data); not weakened. Pre-existing failures baseline-snapshotted at clean base. OK |

### OPERATOR DECISION REQUIRED — running-hot semantic (logic-deciding)
The spec I wrote is internally contradictory: the selection gate requires
PPA ≥ kept-median (all-three-strong), so the all-three-strong cohort can
**never** have PPA below median → the Decision-5 PPA-below-median signal is
mathematically unreachable on that set. SB resolved it faithfully: the
**teachable band** stays on the all-three-strong set; the **running-hot
health check** (two-signal: PPA >10% below daypart median AND labor-% >10%
above) is evaluated on the **throughput-strong** cohort (CPLH ∧ SPLH ≥
kept-median, NOT PPA-bounded). This is exactly Jim's "your best shifts ran
hot: high covers, weaker spend and labor" (deep-dive Ch.09 / Decision 5).
It is a sound single interpretation, documented in code + the PR — but it is
a semantic choice the operator should explicitly bless because it deviates
from the literal Decision-5 wording (which was unsatisfiable as written).

## Gate
Both logic/seeder-touching → merge requires explicit operator approval.
SB additionally requires explicit blessing of the running-hot resolution.
Audits clean; integration green.
