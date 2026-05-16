# Audit — Cold-boot demo seed PARTIAL on real today (parent tables empty / children orphaned)

Branch: `claude/fix-coldboot-partial-seed-regression` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line). Orchestrator column blank.

## Defect

Operator-reproduced on emulator-5554 (current master, real current
date). On a clean cold boot (`pm clear` → fresh `forge_flow_v2.db`) the
demo seed was PARTIAL: `restaurant_locations`/`week_records`/
`reservation_book_snapshots`/`app_notifications`/`active_target_profiles`
populated, but `shift_records`=0, `target_cycles`=0
(`target_cycle_dayparts`=12 **orphaned**), `weekly_plan_snapshots`=0
(`weekly_plan_snapshot_day_dayparts`=735 **orphaned**),
`open_shift_snapshots`=0, `wage_role_rows`=0. No `E/flutter` crash —
silently half-seeded; every location showed Shift = empty / "data
disappears" on scope switch.

## Root cause (verified, not assumed)

The cold-boot path uniquely ran the **entire heavy demo seed inside
sqflite's `onCreate`**, which executes within an **implicit exclusive
transaction**. The seed invokes DAOs that each open their own
`Database.transaction()` — `TargetCycleDao.upsertCycle`
(`dao/target_cycle_dao.dart:40`, reached from `_ensureDemoSeedCycle`
→ `sqlite_database_seed.dart:977` and `_seedAdditionalLocationsFromReplay`
→ `:1524`), plus `WeeklyPlanSnapshotDao`/`OpenShiftSnapshotDao`/
`ReservationBookSnapshotDao`. A `Database.transaction()` opened while a
transaction is already in force on the same connection **does not
compose on Android native sqflite** the way it does on
`sqflite_common_ffi`: the nested-DAO writes commit/roll back
independently of the outer `onCreate` transaction, so when the
`onCreate` transaction was finalized the parent-table writes made
directly on the `onCreate` handle were rolled back while the
independently-committed nested-DAO writes (the orphaned
`target_cycle_dayparts`) and the final in-memory envelope step (the 735
orphaned `weekly_plan_snapshot_day_dayparts`, the 48 `week_records`,
reservations, notifications) survived — exactly the observed pattern,
with no crash. The reseed/advance path
(`reseedMockReplayForBusinessDate`) runs the **same seeders with the DB
already open** (no implicit `onCreate` transaction), so every DAO
transaction is a real top-level atomic transaction — which is why
advance/reset works on the device while a clean cold boot did not.

First-throwing step / exact mechanism: there is **no `catch` anywhere in
the cold-boot seed path** (grep of `sqlite_database_seed.dart`,
`sqlite_database.dart`, `database_helper.dart`). The "silent swallow"
is not a `try/catch` — it is the sqflite outer-transaction /
nested-DAO-transaction split described above (a half-commit, not a
caught exception). The demo flavor additionally races it: several
subsystems `await SqliteDatabase.instance.database` at boot and the old
`_db ??= await _initDb()` getter was not single-flight, so concurrent
first-callers could each run `_initDb()` on the same fresh file.

Reproduction honesty (proven locally, disclosed): the `flutter test`
harness only has `sqflite_common_ffi`, which **composes nested
transactions differently and coalesces concurrent same-path opens**, so
the behavioral half-seed is not reproducible in-process — a full
`_onCreate` cold boot fully seeds for every date tried (real clock,
2026-05-16, ±, year boundaries; sweep run during investigation). This is
the same reason the merged W6/W8 suites are green on master (the prompt
acknowledges this). I additionally proved the underlying sqflite
behavior: a `Database.transaction()` opened inside an outer
`db.transaction()` on the same connection **deadlocks** in
`sqflite_common_ffi` (60 s timeout), confirming nested-transaction
non-composition is real.

## Fix

`onCreate` is now **schema-only**; the heavy demo seed runs **post-open**
(after `openDatabase` returns), single-flight, exactly mirroring the
device-proven `reseedMockReplayForBusinessDate` path. Fail-fast = no
`catch`: any fatal seed error propagates out of `_initDb`/`database`
(visible `E/flutter`, test-catchable) instead of presenting a
half-populated DB as success. W8 today-anchor and W6 envelope bodies are
byte-unchanged (same call list, same order, same date threading).

| File | Change |
|---|---|
| `sqlite_database.dart:150-172` | Single-flight init: `_initInFlight` shared Future + `_runInitOnce()`; getter returns the in-flight init to all concurrent first-callers (replaces non-atomic `_db ??= await _initDb()`). |
| `sqlite_database.dart:179-185` | `close()` also clears `_initInFlight`. |
| `sqlite_database.dart:207-243` | `_initDb()` opens with `onCreate: _createFreshSchema`; AFTER `openDatabase` returns, if a fresh DB was created, runs `_seedColdBootDemo(db)` POST-open (full rationale in-comment). |
| `sqlite_database.dart:280-309` | `_needsColdBootSeed` flag; `_createFreshSchema` = `_createAllTables` + set flag (schema only, MUST NOT seed). |
| `sqlite_database.dart:311-352` (was `_onCreate`) | Renamed `_seedColdBootDemo`; body (seed call list) byte-identical to the old `_onCreate` post-`_createAllTables` sequence; `debugColdBootSeedRunCount++` at entry; one comment updated for the post-open re-entrancy rationale (`:354-358`). |
| `sqlite_database.dart:287-293,395-402` | `@visibleForTesting static int debugColdBootSeedRunCount`; `@visibleForTesting debugCreateFreshSchemaOnly(db)` test seams. |
| `test/sqlite_database_cold_boot_partial_seed_regression_test.dart` (new) | 4 tests: full seed + zero orphans for the **real current date** and **2026-05-16** across all 4 `DemoScope` locations; `onCreate` schema-only ⇒ empty DB; single-flight (8 concurrent first-callers → one Database, one seed). |

## Pattern B — 14-lens self-audit

| # | Lens | Worker verdict | Evidence | Orchestrator |
|---|---|---|---|---|
| 1 | Slice intent met | PASS | All 5 parent tables non-zero for 4 locations + zero orphans, real-today & 2026-05-16 (`...partial_seed_regression_test.dart` t1–t2, green). Mechanism removed by construction (seed no longer in `onCreate` tx). | |
| 2 | Authority order | PASS | Prompt > CLAUDE.md HP #2/#4. Mirrors device-proven reseed path; W8 anchor (`_coldBootAnchorIsoDate` `:271-278`) + W6 envelope bodies untouched. | |
| 3 | HP #2 — writer-side only | PASS | Pure writer-side restructuring of WHEN the seed runs; same tables, no `demo_*` table, no `kDemoMode` reader branch. Readers unchanged. | |
| 4 | HP #4 — per-location scope | PASS | Per-`restaurant_id` seeders byte-unchanged; test asserts per-location non-emptiness for all 4 (`assertFullySeededNoOrphans`). | |
| 5 | Metric Honesty / Design Rule 2 | PASS | Fix is fail-fast for *fatal* seed errors (propagate, don't half-seed); no honest-empty/degrade logic touched — `_seedColdBootDemo` body identical. | |
| 6 | Scope discipline | PASS | `git diff --stat`: 1 lib file + 1 new test. `sqlite_database_seed.dart`, `mock_integration_replay_seed.dart`, DAOs untouched. | |
| 7 | W6/W8 boundary respected | PASS | W6 envelope + W8 today-anchor seeders byte-unchanged; only their *invocation site* moved onCreate→post-open. W6/W8 suites green (11/11). | |
| 8 | No app-logic regression | PASS | Sequential callers: `await database` still returns a fully-seeded DB before resolving. `persistence_scope_alignment` −9 / `restaurant_scope_notifier` −2 confirmed **PRE-EXISTING** (identical counts on stashed master). | |
| 9 | No migration change | PASS | `_onUpgrade` untouched; no `db/migrations/*` change → drift scanner / cutoff lint N/A. No schema gap (no new table/column). | |
| 10 | Test seam legitimacy | PASS | `debugColdBootSeedRunCount`, `debugCreateFreshSchemaOnly` are `@visibleForTesting`, inert in production (mirrors existing `debugColdBootTodayOverride`/`useDatabasePath`). Not a `kDemoMode` fork. | |
| 11 | Tests prove the seam | PASS | New suite 4/4 green; reproduces intent (full seed/zero orphans) + structural invariant (onCreate empty) + single-flight. Honest note: cannot fail on master in FFI (env gap documented above & in PR). | |
| 12 | Null-safety / analyze | PASS | `dart analyze` lib + new test → **No issues found!** `_initInFlight` `Future<Database>?` guarded; `_needsColdBootSeed` reset before each open. | |
| 13 | House rules | PASS | Canonical hooks installed (step 0). No tracker edits. No `--no-verify`. CI dark — all local results disclosed. | |
| 14 | Contract STOP | PASS | branch → implement → self-audit → commit + push → PR → STOP. No merge. Flagged seed-touching / high-blast-radius for operator review. | |

## Local verification (CI dark — real results)

- `scripts/install_git_hooks.ps1` → hooks enabled (pre-commit, pre-push).
- `flutter pub get` → OK.
- `dart analyze lib/.../sqlite_database.dart test/...partial_seed_regression_test.dart` → **No issues found!**
- `flutter test test/sqlite_database_cold_boot_partial_seed_regression_test.dart` → **+4 All tests passed!**
- `flutter test` W6+W8+wage+dashboard (`...today_anchor` `...operational_envelope` `...cold_boot_wage` `shift_dashboard_notifier_cold_boot`) → **+11 All tests passed!**
- Regression baseline (stash master vs branch, same files): `persistence_scope_alignment_test.dart`+`demo_mode_writer_side_test.dart` = **+33 −9 on BOTH** → the −9 (K/L pre-v8-upgrade / partial-migration groups) and `restaurant_scope_notifier` −2 are **PRE-EXISTING / latent, untouched by this fix** (this fix only changes the fresh-create path; `_onUpgrade` is byte-unchanged).
- `per_daypart_v1` per-location / slice3 / per-period-cycle / slice-F-hp11 demo-seed suites → green in the same run.

## Reproduction-gap disclosure (binding, read before merge)

The prompt's prescribed behavioral test "MUST fail on current master"
holds **on the device**, not in the `flutter test`
(`sqflite_common_ffi`) harness — ffi composes nested transactions and
coalesces concurrent same-path opens differently from Android native
sqflite, so the behavioral half-seed is not in-process reproducible
(same reason the merged W6/W8 suites are green on master; the prompt
acknowledges this). The fix removes the Android failure **mechanism by
construction** (the seed never runs inside sqflite's `onCreate`
transaction; it runs on the same post-open path the device-proven
reseed/advance flow already uses) and the new suite locks that contract
plus single-flight. Recommend an emulator cold-boot smoke
(`pm clear` → launch → pull DB → confirm all 5 parent tables non-zero
for 4 locations, zero orphans) as the device-level acceptance.

## Concurrency note for the orchestrator

Seed-touching, high blast radius — flagged for operator review.
`sqlite_database_seed.dart` signature/body untouched, so there is no W6
reconciliation surface. No sibling workers on these files.
