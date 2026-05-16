# Benchmark UX cleanup — daypart table spacing + Operating strip header/alignment (Lens Audit)

Branch: `claude/ux-benchmark-cleanup` · Base: `master` (`10cf59ca`)
Authority: this UX prompt → `CLAUDE.md` UX Writing Standard + Metric Honesty →
`docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`.

## Scope

Layout / wording only. No data or read-logic changes.

- **Finding C — Daypart Breakdown table cramped + overflow risk.** The
  `DAYPART BREAKDOWN` table crowded its six columns and could wrap/clip at
  narrow widths.
- **Finding D — strip below the table had no section header and read worse
  than the table above it.** The `_OperatingStrip` ("Operating Wage Mix" +
  "Theoretical Labor %: The Floor") rendered headerless with ragged
  `spaceBetween` rows.

## Files changed

- `lib/widgets/daypart_table.dart` — column breathing room (per-cell
  `SizedBox(width: 14)` gaps + label flex 5 / numeric flex 4 + row padding
  `h18 v14`) (`daypart_table.dart:165-200`); a `_minTableWidth = 720`
  guarantee — at the demo device width (1080) and wider the columns spread to
  fill, below it the table scrolls horizontally inside its card instead of
  ever throwing `RenderFlex overflowed` or clipping text
  (`daypart_table.dart:83-159`). No reader/Design-Rule logic touched
  (`_targetCellsFor`, `_opzRange`, `_labelFor` byte-unchanged
  `daypart_table.dart:45-81`).
- `lib/screens/baseline_tracker.dart` — new pinned `OPERATING INPUTS`
  section header in the exact `StickySectionDelegate` grammar as
  `DAYPART BREAKDOWN` (`baseline_tracker.dart:139-146`); `_OperatingStrip`
  rebuilt as a sibling card matching the DaypartTable decoration (gradient
  surface, hairline rule border, 3px radius) with an `IntrinsicHeight` two-half
  split (`baseline_tracker.dart:586-625`); `_StripHalf` rebuilt as an aligned
  label/value grid mirroring `_TableRow` (mono7 sub-header, hairline rule
  dividers, value right-aligned at a consistent flex column)
  (`baseline_tracker.dart:628-700`); no-profile fallback restyled to match
  (`baseline_tracker.dart:525-538`). Wage/% values, formatting and the
  `ActiveTargetProfile` reads are byte-unchanged
  (`baseline_tracker.dart:541-584`).
- Tests: 2 new overflow tests (1080 + 360, assert `tester.takeException()`
  isNull) in `test/daypart_table_slice_2_test.dart`; `OPERATING INPUTS`
  header assertion added to `test/target_consistency_opz_test.dart`.

## Pattern B — 14-lens self-audit

| # | Lens | Worker self-audit (file:line) | Independent audit |
|---|------|-------------------------------|-------------------|
| 1 | Product & user journey | Operator sees a table that breathes and a strip that reads as a deliberate sibling under its own header (`baseline_tracker.dart:139-146`, `586-625`). No data meaning changed. | [orchestrator] |
| 2 | Information architecture & navigation | `OPERATING INPUTS` header uses the same sticky-pin grammar as `DAYPART BREAKDOWN` (`baseline_tracker.dart:142-145`); slot order unchanged. | [orchestrator] |
| 3 | Data model, migration, RLS | None. No schema/SQL/migration. | [orchestrator] |
| 4 | Repository & service layer | None. `_OperatingStrip` still reads `ActiveTargetProfileNotifier?.profile` + same bridge fallbacks (`baseline_tracker.dart:521-584`); `DaypartTable` reader accessors byte-unchanged (`daypart_table.dart:45-81`). | [orchestrator] |
| 5 | Proxy/route/gateway | N/A — pure UI. | [orchestrator] |
| 6 | Auth/roles/permissions/scope | N/A. | [orchestrator] |
| 7 | Lifecycle & destructive actions | None. Parallel-worker files (`sqlite_database_seed.dart`, `shift_dashboard.dart`, `shift_service_period_notifier.dart`, Settings, `demo_team_fixtures.dart`) deliberately untouched. | [orchestrator] |
| 8 | Background workers/deploy/startup/health | N/A. | [orchestrator] |
| 9 | UI state, UX, accessibility | No phantom zeros / sentinels — honest `—` / fallback paths preserved (`daypart_table.dart:57-81,138-152`); plain-English header `OPERATING INPUTS`, no em dash (colon retained in "Theoretical Labor %: The Floor", `baseline_tracker.dart:618`). No `RenderFlex overflowed` and no clipped text at 1080 or 360 (horizontal-scroll fallback `daypart_table.dart:148-157`; tests assert `takeException() isNull`). | [orchestrator] |
| 10 | Performance & data loading | `LayoutBuilder` + `IntrinsicHeight` only; no extra I/O or rebuilds; both halves are 1 header + 3 rows so IntrinsicHeight is O(1). | [orchestrator] |
| 11 | Mobile/web/admin/API parity | Benchmark mobile surface only. Whole-day rollup + per-period read contract unchanged — proven green by `target_consistency_opz_test.dart` (23/23) + `daypart_table_slice_2_test.dart` (7/7). | [orchestrator] |
| 12 | Tests, builds, evidence | `dart analyze` clean (0 issues) on all 4 touched files. `daypart_table_slice_2_test.dart` 7/7 (incl. 2 new overflow tests), `target_consistency_opz_test.dart` 23/23, `baseline_override_propagation_test.dart` 5/5. CI dark — commands disclosed in PR. | [orchestrator] |
| 13 | Observability/audit/supportability | No logging surface; layout is deterministic. Docstrings document the `_minTableWidth` rationale (`daypart_table.dart:83-88`) and the strip's sibling-grammar intent (`baseline_tracker.dart:628-634`). | [orchestrator] |
| 14 | Docs/tracker/prompt hygiene | Trackers/ledgers/memory NOT touched (worker contract). Docstrings refreshed; this audit doc added. | [orchestrator] |

## Concurrency compliance

Stayed strictly in `lib/widgets/daypart_table.dart`, `lib/screens/baseline_tracker.dart`,
and the two test files. Did not touch any parallel-worker-owned file
(`sqlite_database_seed.dart` / `sqlite_database.dart` / `demo_team_fixtures.dart`,
`shift_dashboard.dart` / `shift_service_period_notifier.dart`, Settings files).

## Local verification (CI dark)

- `flutter pub get` — ok.
- `dart analyze lib/widgets/daypart_table.dart lib/screens/baseline_tracker.dart test/daypart_table_slice_2_test.dart test/target_consistency_opz_test.dart` — **No issues found!**
- `flutter test test/daypart_table_slice_2_test.dart` — **+7 All tests passed.**
- `flutter test test/target_consistency_opz_test.dart` — **+23 All tests passed.**
- `flutter test test/baseline_override_propagation_test.dart` — **+5 All tests passed.**
