# Audit — Demo data Slice C: per-location closed history + cycles (distinct, deterministic)

**Branch:** `claude/demo-slice-c-per-location-data` · **Base:** `master` @ `c8e4278f`
**Date:** 2026-05-15 · **Pattern:** B (worker self-audit + independent re-read, file:line)
**Authority:** this prompt → `docs/_audits/per_daypart_v1/full_demo_data_spec.md` (Slice C / §2c) → `CLAUDE.md` HP #2 / HP #4 / HP #11.

## Scope delivered

Downtown (`DemoScope.restaurantId`) keeps Slice B's cohort byte-for-byte. North Loop /
Riverside / Harbour now get the SAME shape — ≥60d closed `shift_records`, `week_records`,
an active `target_cycles` + `target_cycle_dayparts`, `active_target_profiles`,
`target_profile_versions`, `import_runs`/`raw_import_records` — scoped by each location's
`restaurant_id`. Each location is deterministically distinct (volume/CPLH/SPLH/PPA) so
the scope drawer is a real switcher.

Files: `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` (+443, one new
contiguous region + one call at the tail of `_seedDemoDataFromReplay`);
`test/per_daypart_v1_demo_seed_per_location_data_test.dart` (new, 6 tests);
`test/persistence_scope_alignment_test.dart` (2 outdated single-location assertions
updated to the multi-location reality). `mock_integration_replay_seed.dart` and
`_seedWeeklyPlanSnapshotFromReplay` untouched.

## Pattern B — 14-lens

| # | Lens | Worker self-audit (file:line) | Independent re-read verdict |
|---|---|---|---|
| 1 | Slice intent — all 4 locations demo-complete | New loop seeds shifts/weeks/cycle/profile/imports for `i=1..3` of `DemoScope.locations` (`sqlite_database_seed.dart:1342-1474`); called from both seed paths via tail of `_seedDemoDataFromReplay` (`:1550-1557`). Test asserts ≥60 distinct closed dates + active cycle + 3 dayparts per location (`per_daypart_v1_demo_seed_per_location_data_test.dart:38-69`). | PASS — `_seedDemoDataFromReplay` is invoked by `_onCreate` (`sqlite_database.dart:207`) and `reseedMockReplayForBusinessDate` (`:533`), so the loop runs on cold-boot, reseed, and advance. |
| 2 | Materially distinct, not clones | `_demoLocationProfiles` constant factors per index (`:1224-1229`); recommendation consumes each location's scaled cohort → per-period targets differ true-to-logic; test asserts pairwise ≥1% per-period CPLH + non-equal SPLH/PPA + ≥5% cover-volume across all 6 pairs × 3 periods (`...per_location_data_test.dart:96-140`). | PASS — distinctness flows through `_seedRecommendationCandidates` → `RecommendedBenchmarkSelectionService` (`:1267-1271`), a monotone scaling of every closed-shift rate, so the ratio between locations == the factor ratio deterministically. |
| 3 | Design Rule 4 (pool == cover-weighted Σ) | `_buildLocationSeedCycle` uses the canonical `TargetCycleDaypartPool.fromDayparts` and stamps the parent scalars from the pool (`:1300-1318`), identical to `_buildDemoSeedCycle`. Test asserts `cycle.target* closeTo pool.* 1e-9` per location (`...per_location_data_test.dart:72-86`). | PASS — no deprecated pooled/union accessor; mirrors merged Slice 1 path. |
| 4 | HP #4 per-(operator,location) isolation | Every insert keys `restaurant_id = locations[i].restaurantId`; never writes Downtown's id; cycle id `demo_cycle_<rid>_<date>` (`:1313`). Test asserts `shift_records`/`week_records` distinct restaurant_id set == the 4 demo ids exactly and each cycle.restaurantId matches (`...per_location_data_test.dart:142-160`). | PASS — no cross-write; Downtown rows untouched (the leading scoped delete in `_seedDemoDataFromReplay:1488-1492` is Downtown-only; table-wide reseed deletes precede the function). |
| 5 | Determinism / NO RNG | All variation from constant `_demoLocationProfiles` + deterministic base replay; `_round2` fixed; no `Random`. Test reseeds twice and asserts byte-identical shift/cycle fingerprint for all 4 locations (`...per_location_data_test.dart:185-216`). | PASS — `mock_integration_replay_seed.dart` unmodified (its no-RNG invariant preserved); import_run timestamp columns are the only non-deterministic field and match Downtown's existing accepted pattern (not part of demo-fidelity fingerprint). |
| 6 | Slice B driver-mix preserved per location | Every rate tilt < its `determineLever` threshold (cplh/splh ±5% → ≤4.5%; ppa ±3% → ≤2.2%; `:1224-1229`), volume applied to actual AND forecast covers; `primaryLever` carried verbatim (`:1280` doc + `:1320`). Test asserts each new location's closed `primary_lever` multiset == Downtown's and Downtown spans ≥6 ids (`...per_location_data_test.dart:162-183`). | PASS — by construction a sub-threshold tilt cannot move a non-owned axis past threshold; empirically proven identical. |
| 7 | HP #2 — production tables, no `demo_*`, no reader branch | Writes only `shift_records`/`week_records`/`target_cycles`/`target_cycle_dayparts`/`active_target_profiles`/`target_profile_versions`/`import_runs`/`raw_import_records` (`:1342-1474`). No new table, no `kDemoMode` branch. `demo_mode_writer_side_test.dart` (HP #2 guard) green (14/14). | PASS. |
| 8 | Reuse Slice B helpers read-only | `mock_integration_replay_seed.dart` not in diff; reused `MockReplayOutput` shape, `demoServicePeriodIds`, `demoDaypartTargetBand`, `_seedRecommendationCandidates`, `_addIsoDays`, `_deterministicHash`, `_businessDateFromWeekDay` read-only. | PASS — `git diff --stat` shows only seed + 2 test files. |
| 9 | Concurrency — other workers' functions untouched | `_seedWeeklyPlanSnapshotFromReplay` not modified; new code is one contiguous region before `_seedDemoDataFromReplay` + a single call line at its tail. | PASS — localized hunk; orchestrator rebases at merge. |
| 10 | Idempotency / advance path | Per-location cycle reuses an existing active cycle else builds (`:1376-1384`), mirroring `_ensureDemoSeedCycle`; table-wide reseed deletes clear all locations first; `ConflictAlgorithm.replace`/`ignore` on profile/version/imports. | PASS — reseed rebuilds deterministically; advance preserves locked cycles (parity with Downtown). |
| 11 | History truth readable (locked targets) | `_backfillLockedTargets` is Downtown-scoped, so per-location rows are stamped here via `withLockedTargetDefaults` from the projected profile (`:1410-1426`), preserving null daypart stamps (Design Rule 2). | PASS — `lockedTargetCPLH` getters won't throw for new locations. |
| 12 | dart analyze | `dart analyze` clean on both touched files + new test. | PASS — "No issues found!". |
| 13 | Regression baseline | `persistence_scope_alignment_test.dart`: master baseline = 8 distinct failures (K×5 / L×3, pre-existing partial-schema `no such table: target_cycle_dayparts`, Slice-1-era, unrelated). Mine = same 8 after updating 2 by-design-outdated single-location G assertions. Net new failures: 0. | PASS — baseline snapshot run on `c8e4278f` confirmed identical K/L set. |
| 14 | Tests green (prompt list) | `per_daypart_v1_demo_seed_per_period_cycle_test` (3) + `target_cycle_daypart_pool_test` (4) + new per-location (6) + nearest demo-seed `demo_mode_writer_side`/`demo_mode_state` (14) all green. | PASS. |

## Local commands (CI dark — disclosed)

- `powershell scripts/install_git_hooks.ps1` → hooks enabled.
- `flutter pub get` → Got dependencies.
- `dart analyze lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart test/per_daypart_v1_demo_seed_per_location_data_test.dart test/persistence_scope_alignment_test.dart` → **No issues found!**
- `flutter test test/per_daypart_v1_demo_seed_per_location_data_test.dart` → **+6 All tests passed**
- `flutter test test/per_daypart_v1_demo_seed_per_period_cycle_test.dart test/target_cycle_daypart_pool_test.dart` → **+7 All tests passed**
- `flutter test test/integration/demo_mode_writer_side_test.dart test/integration/demo_mode_state_test.dart` → **+14 All tests passed**
- `flutter test test/persistence_scope_alignment_test.dart` → **+33 -8** (8 = pre-existing K/L partial-schema failures, identical on master `c8e4278f` baseline; 0 net new).

## Residual / notes for orchestrator

- 8 pre-existing `persistence_scope_alignment_test.dart` K/L failures are latent on master (`target_cycle_dayparts` missing in those tests' deliberately partial schema — a Slice 1 era concern), out of Slice C scope.
- Week-record per-location values are deterministic proportional scalings of the base aggregates (extensive ∝ volume, intensive ∝ rate tilt) — a localized demo-fidelity simplification; Design Rule 4 applies to the cycle (verified exactly), not week aggregates.
- Per-location wage authority / `wage_role_rows` is Slice F scope, intentionally not seeded here (cycles use `MeridianConfig` defaults like Downtown's empty-rows fallback).
