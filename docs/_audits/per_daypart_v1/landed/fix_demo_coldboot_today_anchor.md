# Audit — Cold-boot demo seeds the current week to *today* (no more HISTORICAL ONLY)

Branch: `claude/fix-demo-coldboot-today-anchor` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line). Orchestrator column blank.

## Defect

Operator-reproduced on emulator-5554 (2026-05-16): a clean cold boot
shows Shift **"HISTORICAL ONLY — Week history exists but no
current-week open/projected state."** No exception — a silent
seed/clock-anchor mismatch. The cold-boot seed (`_onCreate`) anchored
every table to the fixed `MockIntegrationReplaySeed.defaultBusinessDate`
(2026-03-27 / 2026-W13), while the Shift dashboard evaluates
current-week open/projected state against the real wall clock
(`lib/state/shift_dashboard_notifier.dart:82,126` — `DateTime.now()
.toUtc()`). The seeded "current week" never contained "now", so cold
boot always degraded to HISTORICAL ONLY.

## Fix (surgical — seed the current week relative to today)

Anchor the **cold-boot DB seed only** to today's UTC ISO date, via the
existing `MockIntegrationReplaySeed.generateForDate(today)`, mirroring
the date threading already proven in
`reseedMockReplayForBusinessDate`. Pure date-source change: the
generator, seeder internals, the 12-historical-week count, and all
honest-empty/Design-Rule-2 behavior are untouched. `defaultBusinessDate`
and the static `MockIntegrationReplaySeed.output` are unchanged (still
2026-03-27) for unit tests / back-compat.

| File | Change |
|---|---|
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart:6-9` | `+ import 'package:meta/meta.dart';` (for `@visibleForTesting`). |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart:192-216` | `@visibleForTesting static String? debugColdBootTodayOverride;` + `_coldBootAnchorIsoDate()` — yyyy-MM-dd from `DateTime.now().toUtc()` (same UTC basis as `shift_dashboard_notifier.dart:82,126`); override seam is null in production. |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart:218-271` | `_onCreate` now computes `coldBootBusinessDate` once, builds `replay = MockIntegrationReplaySeed.generateForDate(coldBootBusinessDate)`, and threads that date into `_seedDemoActiveTargetProfile`, the `mock_replay_state` insert, `_backfillLockedTargets`, and `_seedWeeklyPlanSnapshotFromReplay` (the three sites previously hardcoded to `defaultBusinessDate`, plus the `output`→`generateForDate` swap feeding `_seedDemoDataFromReplay`/`_seedOpenShiftSnapshotsFromReplay`). Call list, ordering, and the FU-mobile-cold-boot comment block are otherwise unchanged. |
| `test/sqlite_database_cold_boot_today_anchor_test.dart` (new) | Cold-boot with injected today (2026-09-04) → asserts `mock_replay_state` = injected today, a current-week open shift exists, exactly 12 historical week_records == the today-anchored oracle weeks (not 2026-W13); + back-compat test asserting `defaultBusinessDate`/`output` still 2026-03-27. |

## Pattern B — 14-lens self-audit

| # | Lens | Worker verdict | Evidence | Orchestrator |
|---|---|---|---|---|
| 1 | Slice intent met | PASS | Cold-boot seed anchored to today; seeded current week now contains "now" → no HISTORICAL ONLY. New test proves seeded weeks == today-anchored oracle, not 2026-W13 (`sqlite_database_cold_boot_today_anchor_test.dart:64-115`). | |
| 2 | Authority order | PASS | Prompt > CLAUDE.md HP #2 / Metric Honesty / Time Guardrails. UTC ISO basis matches `shift_dashboard_notifier.dart:82,126` (`sqlite_database.dart:210-215`). | |
| 3 | HP #2 — writer-side switch only | PASS | Change is entirely in the SEED writer (`_onCreate`). No reader branches on `kDemoMode`; no `demo_*` table; readers consume the same tables either way. Doc comment at `sqlite_database.dart:192-203` records this. | |
| 4 | Promise 2 (closed truth not rewritten) | PASS | Only the cold-boot *initial* seed date moves; 12 historical weeks are still generated coherently relative to the anchor by the unchanged generator (`mock_integration_replay_seed.dart:380-413`). No later cycle/weekly-plan rewrite added. | |
| 5 | Metric Honesty / Design Rule 2 | PASS | No honest-empty/degrade logic touched. The fix makes the *correct* current-week state exist on cold boot; it does not fabricate state — `generateForDate` produces the same coherent shape for any date. | |
| 6 | Scope discipline | PASS | `git diff --stat`: 1 file changed (`sqlite_database.dart`, +55/-7) + 1 new test. No edit to `sqlite_database_seed.dart`, `mock_integration_replay_seed.dart`, `baseline_manager_service.dart`, or any Settings/screen file. **No `sqlite_database_seed.dart` signature touch — nothing for the orchestrator to reconcile with W6 on that axis.** | |
| 7 | W6 boundary respected | PASS | Did NOT touch the reseed PK-collision idempotency, Riverside/multi-location envelope, cold-boot `wage_role_rows`/reservations/notifications seeder bodies. Cold-boot call list is byte-unchanged except the date source. | |
| 8 | No app-logic regression | PASS | Pure date-source change; `generateForDate`/seeders unchanged. `reseedDemo()`/`reseedMockReplayForBusinessDate` still use `defaultBusinessDate` (`sqlite_database.dart:459-461`) — default-path tests unaffected. | |
| 9 | Back-compat | PASS | `defaultBusinessDate` const and static `output` unchanged; back-compat test green (`sqlite_database_cold_boot_today_anchor_test.dart:119-128`). 17 existing demo-seed/cold-boot tests (default path) green. | |
| 10 | Test seam legitimacy | PASS | `debugColdBootTodayOverride` is `@visibleForTesting`, null in production, writer-side (analogous to `_overrideDbPath`/`useDatabasePath`) — NOT a `kDemoMode` reader fork (`sqlite_database.dart:205-216`). | |
| 11 | Tests prove the seam | PASS | New test cold-boots a fresh DB with injected today, asserts anchor moved + 12 hist weeks + open shift exists; back-compat asserted. `flutter test` 9/9 (new + cold-boot + slice3) then 17/17 (per-location/per-period/slice-E) — all green. | |
| 12 | Null-safety / analyze | PASS | `dart analyze lib/.../sqlite_database.dart test/...today_anchor_test.dart` → **No issues found!** Override is `String?`, guarded. | |
| 13 | House rules | PASS | No `db/migrations/*` change → drift scanner / cutoff lint N/A. Canonical hooks installed (step 0). No tracker edits. | |
| 14 | Contract STOP | PASS | branch → implement → self-audit → commit + push → PR → STOP. No merge, no `--no-verify`. | |

## Local verification (CI dark — real results)

- `pwsh scripts/install_git_hooks.ps1` → hooks enabled (pre-commit, pre-push).
- `flutter pub get` — OK.
- `dart analyze lib/infrastructure/persistence/sqlite/sqlite_database.dart test/sqlite_database_cold_boot_today_anchor_test.dart` — **No issues found!**
- `flutter test sqlite_database_cold_boot_today_anchor_test.dart shift_dashboard_notifier_cold_boot_test.dart per_daypart_v1_slice3_demo_seed_snapshot_test.dart` — **+9 All tests passed!**
- `flutter test per_daypart_v1_demo_seed_per_location_data_test.dart per_daypart_v1_demo_seed_per_period_cycle_test.dart dev/demo_slice_e_pt2_mobile_seed_hook_test.dart` — **+17 All tests passed!**
- No pre-existing failures encountered in the run scope (KNOWN_FAILING_TESTS snapshot: none triggered here).

## Concurrency note for the orchestrator

Seed-touching. Merge this **before** W6
(`claude/demo-seed-multilocation-operational-envelope`) and reconcile W6
on top. **No `sqlite_database_seed.dart` signature change was needed** —
the diff is confined to `_onCreate` orchestration + a test seam in
`sqlite_database.dart`, so the W6 reconciliation surface is limited to
the `_onCreate` body (W6 owns the per-table seeder bodies it calls;
this slice only changes which date `_onCreate` passes them).

## Residual / follow-ups

None. Pure cold-boot date-anchor; default/reseed paths and back-compat
unchanged.
