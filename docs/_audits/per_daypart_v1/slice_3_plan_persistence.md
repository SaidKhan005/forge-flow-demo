# Per-Daypart Targets V1 — Slice 3 audit: Plan tab persistence wiring

> Branch: `claude/per-daypart-slice-3-plan-persistence`
> Base: `master`

## Slice intent (from `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`, Slice 3 + Extended + Gap 41)

- `ScheduleForecastNotifier.adjustedDayViews` reads sub-row values from
  the persisted `weekly_plan_snapshot_day_dayparts` rows instead of
  calling `DaypartPlanAllocator` (plan Gap 6 / Gap 12).
- `DaypartPlanAllocator` retired (kept as a fallback for snapshots that
  pre-date the migration / Gap 42, and for non-locked-read consumers).
- No UI changes — sub-rows render the same columns from a different
  source.
- Clean up `schedule_builder.dart:107-113` sentinel-0 (Gap 41 / Design
  Rule 2).
- Locked operator decision: NO target columns on the Plan tab — Plan
  owns demand, Benchmark owns targets. (Honored: no CPLH/SPLH/PPA
  columns added; `ScheduleDaySubrow` shape unchanged.)

## Scope (files modified)

- `lib/services/schedule_plan_read_service.dart` — new read-only
  `getExistingCurrentLockedSnapshot()` returning the raw persisted
  `WeeklyPlanSnapshot` (the projector drops `dayDayparts`; the locked
  path needs the snapshot itself). Routes through the existing
  side-effect-free `getExistingCurrentWeekSnapshot()`.
- `lib/screens/schedule/schedule_forecast_notifier.dart` — holds the
  loaded `_lockedSnapshot`; `loadLockedPlan()` loads the snapshot and
  projects `_plan` from it (one source); `adjustedDayViews` reads
  persisted `dayDayparts` via the new `_persistedSubrowsForDay`, with
  `_allocatorSubrowsForDay` as the documented live/preview + empty-
  `dayDayparts` fallback; new `@visibleForTesting`
  `setLockedSnapshotForTest`.
- `lib/services/daypart_plan_allocator.dart` — `@Deprecated` on the
  class with replacement guidance pointing at
  `WeeklyPlanSnapshot.dayDayparts`; documents the remaining legitimate
  fallback / not-yet-swapped consumers.
- `lib/screens/schedule_builder.dart` — `_bootstrapFallbackProfile()`
  sentinel-0 cleanup (Gap 41 / Design Rule 2): `0 // unused on locked
  path` replaced with honest `MeridianConfig` config defaults;
  `@visibleForTesting scheduleBootstrapFallbackProfileForTest()`.
- `test/per_daypart_v1_slice_3_plan_persistence_test.dart` — NEW, 6
  tests.

## Pattern B audit table (worker self-audit + executor independent audit)

| # | Lens | Status | Evidence (file:line) |
|---|------|--------|----------------------|
| 1 | Scope match | PASS | `git diff --name-only origin/master...HEAD`: only the 4 lib files + 1 new test + this audit doc. No `target_cycle_service.dart`, no `weekly_plan_snapshot_service.dart` write path, no `data_alignment_audit_read_service.dart`, no `lib/screens/shifts/*`, no `benchmark*`, no variance card, no vendor sinks (all explicitly off-limits per the prompt's CONCURRENCY section). |
| 2 | Authority order | PASS | Prompt > `core_app_architecture.md` > plan doc Slice 3 > CLAUDE.md. Implementation matches the plan's Slice 3 + Extended (Gap 41) + Gaps 6/12 rows. No conflict with `core_app_architecture.md` (read-seam swap only; canonical write path untouched). |
| 3 | Hard Promises | PASS | HP #2 (demo persists): no `kDemoMode` branch added; locked snapshot read is identical demo/prod. HP #3 (no app-logic change before 7.58): this is a read-seam swap to already-persisted canonical data — no formula/decision change; the day-level math and the persisted per-period values are unchanged, only their *source* moves from render-time regeneration to the lock-time stamp. HP #11 untouched (Plan tab has no scope surface). |
| 4 | Service-layer split | PASS | Read service in `lib/services/`; notifier in `lib/screens/schedule/`; pure projector reused from `lib/domain/services/`. No `lib/data/` touched. No raw postgres imports. |
| 5 | Design Rule 1 (period-scoped naming) | PASS | Persisted sub-rows are read from `WeeklyPlanSnapshotDayDaypart` (`daypart`-named per-period type, `weekly_plan_snapshot.dart:62`) via `dayDayparts`; `_persistedSubrowsForDay` reads `r.forecastCovers/forecastSales/requiredFohHours/requiredBohHours` off the per-period row, never substituting a whole-day pool scalar (`schedule_forecast_notifier.dart` `_persistedSubrowsForDay`). Whole-day day row keeps its own names. |
| 6 | Design Rule 2 (missing = null, never 0) | PASS | (a) Empty `dayDayparts` → allocator fallback, NOT a fabricated zero row (`schedule_forecast_notifier.dart` `adjustedDayViews` `hasPersistedDayparts` guard). (b) Day with no business-date mapping → empty sub-row list, whole-day row still renders honestly (`_persistedSubrowsForDay` `businessDate == null` guard). (c) Sentinel cleanup: `_bootstrapFallbackProfile()` `0`-as-null sentinels replaced with real `MeridianConfig` defaults (`schedule_builder.dart` `_bootstrapFallbackProfile`). (d) A genuine zero-hour persisted period is RENDERED with an honest 0, not dropped as "missing" — proven by the "Design Rule 2" test. |
| 7 | Design Rule 4 (read through persisted canonical write path) | PASS | The locked path reads `WeeklyPlanSnapshot.dayDayparts` (the rows the canonical writer `WeeklyPlanSnapshotService` stamps at lock time) via the read-only `getExistingCurrentLockedSnapshot()` → `getExistingCurrentWeekSnapshot()`. The write path is NOT touched (off-limits and unnecessary). No bypass / no regeneration on the locked path. |
| 8 | Demo-mode contract | PASS | No `kDemoMode` branch added/removed. Reader reads whatever the active scope's tables hold; demo and prod identical. |
| 9 | RLS-ready schema | N/A | No schema change. Reads existing `weekly_plan_snapshot_day_dayparts` via the existing repository path. |
| 10 | Time guardrails | PASS | Day→businessDate mapping uses the snapshot's own `dayRows` (`dr.day` ↔ `dr.businessDate`) — restaurant-local business-date anchor preserved; no timestamp arithmetic introduced. |
| 11 | No UI change | PASS | `ScheduleDaySubrow` / `ScheduleDayView` shapes unchanged (`schedule_view_models.dart`). `_DayTable` / `schedule_day_row.dart` consume the same view model. NO target columns added to Plan (locked operator decision). Persisted `double` per-period hours rounded to the existing `int` sub-row contract at the read seam — rendered table identical. |
| 12 | Allocator retirement | PASS | `@Deprecated` on `DaypartPlanAllocator` (`daypart_plan_allocator.dart`) with replacement guidance → `WeeklyPlanSnapshot.dayDayparts`. NOT deleted because it has legitimate non-locked-read consumers (`shift_service.dart` Variance — plan Slice 5; `data_alignment_audit_read_service.dart` — plan Slice 6; `canonical_fact_to_closed_shift_input.dart`) + the live/preview + legacy/Gap-42 fallback. `dart analyze` confirms only `deprecated_member_use_from_same_package` **info** at call sites — no errors/warnings. |
| 13 | Test coverage | PASS | `test/per_daypart_v1_slice_3_plan_persistence_test.dart`, 6 tests: (1) reader-swap correctness — persisted rows are read (lopsided 10/140 split, ordered, labelled); (2) allocator-retirement — persisted read ≠ allocator largest-remainder regeneration; (3) Design Rule 2 — zero-hour persisted period rendered as honest 0; (4) empty-`dayDayparts` fallback — degrades to allocator; (5) live/preview fallback — `setLockedPlanForTest` (no snapshot) keeps allocator path (pre-Slice-3 back-compat); (6) sentinel removal — bootstrap profile carries `MeridianConfig` defaults, none 0. All 6 pass. Nearest existing suites green: `schedule_builder_widget_test.dart` (incl. F allocator-equality + D-series locked tests), `weekly_plan_snapshot_day_dayparts_test.dart`, `schedule_plan_read_service_test.dart` — 41 tests pass, 0 regressions. |
| 14 | No tracker edits / no merge / no `--no-verify` | PASS | `git status`: no `PROJECT_TRACKER.md`, no `NEXT_WAVE_PLAN.md`, no plan doc, no ledger edits — only the 4 lib + 1 test + this audit. Hooks installed via `scripts/install_git_hooks.ps1` (step 0). Push via `git push` (no `--no-verify`); PR via `gh pr create`; agent STOPS. No merge. |

## Verification (CI is dark — exact local commands + results)

- `pwsh scripts/install_git_hooks.ps1` (via `powershell -ExecutionPolicy
  Bypass -File`; `pwsh` not on PATH in this Windows env) →
  "Forge & Flow git hooks enabled. Active hooks: pre-commit, pre-push."
- `flutter pub get` (worktree had no `.dart_tool/package_config.json`;
  required so `package:` resolves worktree-local, eliminating the
  cross-path duplicate-type analyze artifact that affects single-file
  analyze of ANY file in a fresh worktree) → "Got dependencies!".
- `dart analyze lib/services/schedule_plan_read_service.dart
  lib/screens/schedule/schedule_forecast_notifier.dart
  lib/services/daypart_plan_allocator.dart` → **0 errors, 0 warnings**;
  4 `deprecated_member_use_from_same_package` **info** only (the
  intended `@Deprecated` consequence per the prompt's allocator-
  retirement instruction).
- `dart analyze test/per_daypart_v1_slice_3_plan_persistence_test.dart
  lib/screens/schedule_builder.dart` → **0 errors, 0 warnings**; 3
  `deprecated_member_use_from_same_package` info only.
- `flutter test test/per_daypart_v1_slice_3_plan_persistence_test.dart`
  → **+6 All tests passed!**
- `flutter test test/schedule_builder_widget_test.dart
  test/weekly_plan_snapshot_day_dayparts_test.dart
  test/schedule_plan_read_service_test.dart` → **+41 All tests
  passed!** (no regression).

### Note on the worktree single-file analyze artifact

Single-file `dart analyze` in a worktree that lacks
`.dart_tool/package_config.json` resolves `package:forge_and_flow/...`
to the PARENT repo `lib/` while relative imports resolve worktree-local,
producing spurious `argument_type_not_assignable` "Type defined in
…\.claude\worktrees\… vs …\forge_flow_demo\lib\…" errors in files this
slice does not touch (e.g. `loadDistributionWeights`,
`forge_flow_bootstrap.dart`, `sqlite_database_seed.dart`). Verified
pre-existing on `master` (clean tree, same artifact) and verified GONE
after `flutter pub get` makes `package:` resolution consistent. Not
introduced by this slice; not a real defect.

## Follow-ups (out of scope, not fixed here)

1. **Variance read-seam swap (plan Slice 5)** — `ShiftService.getFullWeekShifts`
   still calls the now-`@Deprecated` allocator. Owned by Slice 5.
2. **Audit scorer extension (plan Slice 6)** — `data_alignment_audit_read_service.dart`
   still calls the allocator. Owned by Slice 6.
3. `canonical_fact_to_closed_shift_input.dart` also consumes the
   allocator; not in any per-period slice's scope — left as a documented
   deprecated consumer.
