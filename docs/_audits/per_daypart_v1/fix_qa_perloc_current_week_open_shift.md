# Audit — Per-location current-week open/projected shift for all 4 demo locations (no more HISTORICAL ONLY off Downtown)

Branch: `claude/fix-qa-perloc-current-week-open-shift` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line). Orchestrator column blank.

## Defect (operator-reproduced, binding)

After the sibling scope-wiring fix, switching to a non-Downtown
location and refreshing showed **HISTORICAL ONLY / empty Shift**. Root
cause confirmed by code trace: `ShiftDashboardNotifier._load()`
(`lib/state/shift_dashboard_notifier.dart:104-105`) resolves the live
business date via `SqliteOpenShiftSnapshotRepository.getCurrentBusinessDate`
→ `OpenShiftSnapshotDao.getCurrentBusinessDate`
(`lib/infrastructure/persistence/sqlite/dao/open_shift_snapshot_dao.dart:29-39`),
which queries `WHERE restaurant_id = ? AND status = 'open' LIMIT 1`.
The W6 per-location operational envelope
(`_seedHistoricalOpenShiftSnapshotsFromReplay`) emitted the
non-Downtown scenario open daypart as **`projected`, not `open`** ("one
global open row stays Downtown's" — W6 design). So a correctly-scoped
read of `demo_restaurant_north_loop` / `_riverside` / `_harbour`
returned `null` → `businessDate == null` →
`shift_dashboard_notifier.dart:174-178` sets `loadedReadModel = null` →
the dashboard renders the empty "No open or projected shift is
available." state (`lib/screens/shift_dashboard.dart:127-129`).

Pre-change assertion (disclosed per CI-dark): on master,
`SELECT … FROM open_shift_snapshots WHERE status='open'` returned
exactly **1** row (always Downtown), and
`getCurrentBusinessDate('demo_restaurant_north_loop')` returned `null`.
Verified by the pre-existing pinned test
`per_daypart_v1_demo_seed_multilocation_operational_envelope_test.dart`
which asserted `expect(open.length, 1)` + `open.first['restaurant_id']
== downtown` (now updated in lockstep — see below).

## Fix (seed-only — every location gets its own live current-week shift)

Extracted Downtown's current-week open/projected/closed snapshot
construction (the body of `_seedOpenShiftSnapshotsFromReplay`) into a
shared, location-parameterized builder
`_buildCurrentWeekOpenShiftSnapshots({restaurantId, currentWeekShifts,
scenario, now})`. Downtown's seeder is now a thin wrapper over it
(byte-identical output). The per-location envelope
(`_seedHistoricalOpenShiftSnapshotsFromReplay`) calls the **same**
builder for each non-Downtown location, passing that location's
already-scaled current-week shifts
(`_envelopeShiftsForLocation` → `_scaleShiftForLocation` +
`_demoLocationProfiles`). Because the in-progress open covers/CPLH/SPLH
are recomputed from the passed-in *scaled* covers/hours, every
location's live shift carries its **own** per-location figures (not a
Downtown clone, not a phantom), while the row SHAPE is exactly
Downtown's. Honest-degrade preserved: a (day, daypart) the scenario
does not serve has no shift in the input list → no fabricated row.

| File | Change |
|---|---|
| `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:139-300` | New `_buildCurrentWeekOpenShiftSnapshots(...)` pure builder (Downtown's exact projected/open(~63%)/current-day-closed logic, parameterized by `restaurantId`/`currentWeekShifts`/`scenario`/`now`). `_seedOpenShiftSnapshotsFromReplay` reduced to a thin Downtown wrapper that batch-inserts the builder output (`ConflictAlgorithm.replace`). Downtown output byte-identical. |
| `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:2313-2412` | `_seedHistoricalOpenShiftSnapshotsFromReplay`: doc updated; the non-Downtown current-week loop (was: `projected`/`closed` only, never `open`) replaced by a call to the shared `_buildCurrentWeekOpenShiftSnapshots` with the location's scaled `currentShifts` + `nowIsoUtc()`. `isDowntown` guard unchanged (Downtown's current week still owned solely by `_seedOpenShiftSnapshotsFromReplay`); historical-closed loop unchanged. |
| `test/per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart` (new) | Cold-boot (fixed today `2026-09-04` AND real current UTC date) + reseed/advance. Asserts every one of the 4 `DemoScope` locations has exactly one today-week `status='open'` row + ≥1 today-week `projected` row, `getCurrentBusinessDate(rid)` resolves the live date (the exact dashboard read path), per-location-distinct figures (North Loop covers ≠ Downtown), zero orphans (all scopes ⊆ demo ids; every open cell has a backing `shift_records` row), and idempotency (reseed → counts stable, exactly 4 open rows total, no PK collision). |
| `test/per_daypart_v1_demo_seed_multilocation_operational_envelope_test.dart` | Lockstep: pinned single-global-open invariant flipped to the per-location invariant (one `status='open'` per `restaurant_id`, 4 total; North Loop open covers ≠ Downtown). Determinism-fingerprint comment updated (in-force-week exclusion now covers all 4 locations' current-week rows; still scoped by shared `scenario.currentWeekId`). |
| `test/mock_replay_scenario_test.dart` | Lockstep: 4 scenario-coherence tests (default/Sat/W14 reseed, regenerate-on-advance) that incidentally relied on global open-count==1 now scope the day/daypart/week assertion to Downtown and separately assert one open row per location. |
| `test/mock_integration_replay_seed_test.dart` | Lockstep: "open Friday dinner snapshot derives from mock replay" scopes the byte-for-byte derivation assertion to Downtown; adds the per-location set assertion. |
| `test/runtime_fixture_retirement_test.dart` | Lockstep: "open Friday dinner snapshot retains openShiftSourceShiftId" asserts every per-location row (scenario-derived `source_shift_id` is location-independent) instead of a single global row. |

No `db/migrations/*` changes. No `sqlite_database.dart` change (the
existing `_seedOpenShiftSnapshotsFromReplay` / `_seedOperationalEnvelopeFromReplay`
call sites are byte-unchanged; the per-location open seed threads
through the existing W6 envelope seam). No state/notifier/screen/
scope-repo file touched (sibling `claude/fix-qa-location-scope-not-propagated`
owns those).

## Pattern B — 14-lens self-audit

| # | Lens | Worker verdict | Evidence | Orchestrator |
|---|---|---|---|---|
| 1 | Slice intent met | PASS | Every demo location now has its own today-anchored `status='open'` + `projected` rows; `getCurrentBusinessDate` resolves per location → no HISTORICAL ONLY on scope switch. Proven `perloc_current_week_open_shift_test.dart` (fixed + real-date cold boot, all 4 locations). | |
| 2 | Authority order | PASS | Prompt > CLAUDE.md HP #2/#4 / Metric Honesty / Design Rule 2. W8 today-anchor (`_coldBootAnchorIsoDate`), W6 envelope, W9 post-open structure, Slice C scaling all preserved (only the non-Downtown current-week branch changed). | |
| 3 | HP #2 — writer-side switch only | PASS | Change entirely in SEED writers (`_buildCurrentWeekOpenShiftSnapshots`, `_seedHistoricalOpenShiftSnapshotsFromReplay`). No reader branches on `kDemoMode`; no `demo_*` table; same `open_shift_snapshots` table, same DAO/repo/notifier read path. | |
| 4 | HP #4 — per-(operator,location) scoping | PASS | Every emitted row's `restaurant_id` = the location's own id; builder takes `restaurantId` explicitly; new test asserts `allScopes == demoIds` (zero cross-scope/orphan rows). | |
| 5 | Metric Honesty / Design Rule 2 | PASS | Open covers/CPLH/SPLH recomputed from each location's *scaled* covers/hours (per-location-distinct, asserted North Loop ≠ Downtown). No fabricated phantom — `firstWhere` only resolves the scenario-designated open slot; a day/daypart with no shift in the input list yields no row. New test asserts every open cell has a backing `shift_records` row. | |
| 6 | Promise 2 (closed truth not rewritten) | PASS | Historical-closed loop (`snapFor`, deterministic `'${bd}T23:59…'`) unchanged. Downtown's current week still owned solely by `_seedOpenShiftSnapshotsFromReplay` (the `isDowntown` guard short-circuits before the new per-location call). | |
| 7 | Idempotent across cold boot + reseed/advance | PASS | `ConflictAlgorithm.replace` on the `(restaurant_id, week_id, day_label, daypart)` UNIQUE; `reseedMockReplayForBusinessDate` clears `open_shift_snapshots` then rebuilds. New test reseeds same today → counts stable (1 open/location, 4 total, no dup, no PK collision). W6 determinism test still byte-identical. | |
| 8 | Scope discipline | PASS | `git status`: only `sqlite_database_seed.dart` + 4 test files modified + 1 new test. No state/notifier/screen/scope-repo file (sibling's domain); no `sqlite_database.dart`; no migration. | |
| 9 | Mirrors Downtown exactly | PASS | Single shared `_buildCurrentWeekOpenShiftSnapshots`; Downtown wrapper output byte-identical (verified: W8/W6/per_daypart/mock_replay Downtown-scoped assertions green). Non-Downtown differs only by the scaled input shifts. | |
| 10 | No app-logic / contract change | PASS | Pure seed change. No formula/integration/proxy/auth. DAO/repo/notifier untouched. `_seedOpenShiftSnapshotsFromReplay`/`_seedOperationalEnvelopeFromReplay` call sites in `sqlite_database.dart` byte-unchanged. | |
| 11 | Lockstep test updates legitimate | PASS | The old "exactly one global open row (Downtown)" invariant *is* the defect (prompt-binding). Updated in lockstep across 4 test files to the per-location invariant; scenario-coherence intent preserved by scoping to Downtown. No test weakened (added per-location set assertions). | |
| 12 | Baseline / no new regressions | PASS | Baselined on a fresh `origin/master` worktree. The 3 remaining batch failures — `mock_replay_scenario_test.dart:485` (`benchmark_selection_summaries`), `shift_dashboard_empty_state_widget_test.dart` (no-data finder), `shift_dashboard_notifier_test.dart` (`inTheBooksCovers` 72 vs 144) — reproduce **identically on origin/master**. Pre-existing, NOT introduced here. | |
| 13 | analyze / house rules | PASS | `dart analyze` on all 6 touched files → **No issues found!**. No `db/migrations/*` → drift scanner / cutoff lint N/A. Canonical hooks installed (step 0). No tracker edits. | |
| 14 | Contract STOP | PASS | branch → implement → self-audit → commit + push → PR → STOP. No merge, no `--no-verify`. Seed-touching / high blast radius → flagged for orchestrator review. | |

## Local verification (CI dark — real results)

- `powershell … scripts/install_git_hooks.ps1` → hooks enabled (pre-commit, pre-push).
- `flutter pub get` — OK.
- `dart analyze lib/.../sqlite_database_seed.dart` + 5 test files — **No issues found!**
- `flutter test per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart per_daypart_v1_demo_seed_multilocation_operational_envelope_test.dart mock_integration_replay_seed_test.dart runtime_fixture_retirement_test.dart` — **+37 All tests passed!**
- `flutter test` per_daypart demo-seed suites (cold_boot_wage, per_location_data, per_period_cycle, slice_a_hierarchy, slice_f_hp11, slice3_demo_seed_snapshot, slice_3_plan_persistence) — **+33 All tests passed!**
- W8/W9 cold-boot suites (`sqlite_database_cold_boot_today_anchor_test.dart`, `sqlite_database_cold_boot_partial_seed_regression_test.dart`) — green.
- `mock_replay_scenario_test.dart` — only `:485 benchmark_selection_summaries` fails; **confirmed pre-existing on origin/master** (baseline).
- Pre-change assertion confirmed: on origin/master the pinned envelope test asserted `open.length == 1` (Downtown only) — i.e. non-Downtown had no `status='open'` row → the empty-Shift defect.

## Pre-existing failures (baseline snapshot, origin/master `c3055425`)

Not introduced by this branch — reproduce identically on a clean
`origin/master` worktree:

1. `mock_replay_scenario_test.dart` — "E … benchmark_selection_summaries survive replay advance" — `Expected: non-empty / Actual: []`.
2. `shift_dashboard_empty_state_widget_test.dart` — "renders no-data state instead of spinner" — `Found 0 widgets with text "No shifts or history found…"`.
3. `shift_dashboard_notifier_test.dart` — "notifier read model includes inTheBooksCovers after reseed" — `Expected: <72> / Actual: <144>`.
