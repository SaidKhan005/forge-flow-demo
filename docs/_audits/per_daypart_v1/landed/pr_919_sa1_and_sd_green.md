# Audit — PR #919 (SA.1 seeder recalibration) + SD #907 now GREEN

Verdict: **APPROVE both, pending operator merge sign-off. Merge order:
SA.1 (#919) → then SD (#907).** SA.1 closes the SD §5.7 finding.

## SA.1 — PR #919 (3 files, +398/-23)
`lib/dev/mock_integration_replay_seed.dart` + new `test/demo_slice_sa1_seeder_recalibration_test.dart` + 1 golden delta in `test/demo_slice_b_driver_variance_test.dart`.

| Check | Result |
|---|---|
| Scope | Seeder + 1 new test + 1 justified golden delta only. No model/migration/widget/service/`target_cycle_service`/copy. OK |
| SB floor unchanged | `minKeptStdevCPLH`/`minBenchmark` NOT touched (operator decision honoured — fix is in the data, not the floor). OK |
| Determinism | Pure function of week/day/period indices; per-week continuous scalar × zero-sum vector stays zero-sum per (week,period); two `generateForDate` calls byte-identical. OK |
| Driver-lever intact | All scaled offsets < 0.05 lever threshold; 16×12 lever-safety sweep 0 violations; `replay_week_driver_rotation_test` + `demo_slice_b_driver_variance_test` green. OK |
| Golden delta | `demo_slice_b`: lunch↔dinner `targetPPA` `>=0.50`→`>=0.30`. Pre-SA.1 lunch was `building_flat`→fallback PPA 40.5 (artificial 2.5 gap); now teachable→real median PPA 43.22→0.48 gap (still distinct = test intent). Justified, not a regression. OK |
| Pre-existing failures | `target_consistency_opz`/`perloc_current_week_open_shift`/`target_state_alignment` clusters verified identical on clean `origin/master`. Not regressions. OK |

## Authoritative integration: SD acceptance gate now passes 7/7
Scratch = `origin/master` + SA.1 + SD: **no conflicts**.
`flutter test per_daypart_v1_benchmark_acceptance_test.dart + replay_week_driver_rotation_test + demo_slice_b_driver_variance_test` → **27/27 PASS**.

`§5.2/§5.7 end-to-end demo proof — every demo period teachable`:
- operationVerdict = `teachable`
- lunch teachable band 4.48–4.53 w=0.05 target 4.52 headroom 0.01 (13 selected, keptStdev 0.147)
- dinner teachable band 4.89–4.93 w=0.04 target 4.90 headroom 0.03 (13 selected, keptStdev 0.203)
- late_night teachable band 4.005–4.065 w=0.06 target 4.035 headroom 0.03 (6 selected ≥ minBenchmark 5, keptStdev 0.148)

The previously-failing SD §5.7 is now green; all other SD criteria
(determinism, 600-fuzz 0 self-defeat, cruel-data, independence,
two-signal running-hot, verdict→copy verbatim/no-em-dash) remain green.

## Net
S0+SA+SB+SC merged; SA.1 #919 + SD #907 close the loop. After SA.1
merges, SD #907's §5.7 is green on master and SD merges as the durable
acceptance gate. Feature complete end-to-end.

(Hook note: SA.1 committed via canonical cheap `.githooks`, no `--no-verify`.
SD #907 was orchestrator-landed past the documented stale heavy whole-repo
analyze artifact — pre-existing master breakage, `demo_mode_banner.dart`
absent on master — with binding CI-dark verification disclosed.)
