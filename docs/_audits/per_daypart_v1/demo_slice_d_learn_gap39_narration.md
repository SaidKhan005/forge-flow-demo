# Audit — Demo Slice D (Gap 39): per-daypart targeting narration on Learn

**Slice:** Demo-data Slice D — Learn Gap-39 narration sharpening
**Branch:** `claude/demo-slice-d-learn-gap39`
**Authority:** Slice prompt → `docs/_audits/per_daypart_v1/full_demo_data_spec.md` §2e / §1.2 / Gap G5 / Slice D → `per_daypart_targets_v1_plan.md` Decision 13 → CLAUDE.md UX Writing Standard + Metric Honesty.
**Verdict:** approve-for-merge (orchestrator confirms).

## What changed (file:line)

| File | Change |
|---|---|
| `lib/services/history_teaching_analyzer.dart:34-56` | New `HistoryTeachingSummary` fields: `topLeakDaypartLabel`, `topLeakDaypartCount`, `contrastBenchmarkDaypartLabel` (defaulted, backward-compatible). |
| `lib/services/history_teaching_analyzer.dart:67-71` | Constructor wires the three new fields with safe defaults. |
| `lib/services/history_teaching_analyzer.dart:236-263` | Derives the dominant leak's service period + real repeat count from the existing `leakDpFreq`/`topLeakDayparts` path, and a same-day, different-period benchmark contrast restricted to the already-computed `benchmarkDayparts`. |
| `lib/services/history_teaching_analyzer.dart:271-273` | Returns the three new fields. |
| `lib/services/learn_teaching_analyzer.dart:9` | Imports `app_defaults` for `LeverCards.lookup` (shortLabel). |
| `lib/services/learn_teaching_analyzer.dart:18-58` | `_perPeriodDerivationLine` const + `_leakDirectionPhrase` + `_recurrencePhrase` helpers. |
| `lib/services/learn_teaching_analyzer.dart:128-150` | `primaryFixLine` is period-resolved (period + direction + real recurrence + same-day contrast) when resolvable; existing general copy retained as fallback. |
| `lib/services/learn_teaching_analyzer.dart:158-166` | `coachToLine` keeps the existing whole-day numbers slot and appends the one derivation training line (rides the existing copy slot). |
| `test/learn_teaching_analyzer_gap39_test.dart` | New: 7 tests — period resolution, derived-not-constant, honest fallback, derivation line + UX-Standard jargon ban. |

## Pattern B — 14-lens self-audit

| # | Lens | Finding | Evidence |
|---|---|---|---|
| 1 | Slice intent met | Learn narration resolves to the period the pattern lives in + one derivation training line | `learn_teaching_analyzer.dart:139-149`, `:163-166`; tests `+0..+6` pass |
| 2 | Authority order | Decision 13 honored: copy + analyzer data layer only; no widget/section/screen added | Only `*_teaching_analyzer.dart` + new test changed; `git diff --stat` = 2 lib files |
| 3 | (a) Period-resolved from real seeded recurrence | `topLeakDaypartLabel`/`Count` derived from existing `leakDpFreq`; `primaryFixLine` interpolates them; differs per dataset | `history_teaching_analyzer.dart:245-249`; test "is derived from the data, not a hardcoded constant" |
| 4 | (b) Derivation training line present + UX-Standard | Plain English, no jargon; `jargon` ban test asserts absence of pooled/cover-weighted/scalar/denominator/RLS/kDemoMode | `learn_teaching_analyzer.dart:25-31`; test "plain English, no engineering jargon" |
| 5 | (c) Honest fallback, no fabrication | Empty patterns → unchanged general copy; no same-day benchmark → contrast clause omitted; recurrence never over-claimed | `learn_teaching_analyzer.dart:147-149`; tests "empty patterns keep the existing general fix copy", "no recurring leak names no period", "contrast omitted not invented" |
| 6 | (d) No UX overhaul | No `variance_learn_tab.dart` change; all learn widget/parity/coverage/depth tests green; structural finders unchanged | `learn_layer_widget_test.dart` + 3 others "All tests passed!" |
| 7 | (e) HP #2 / production untouched | No seed files, no `kDemoMode` branch, no `demo_*` table; analyzer is reader-side copy only, runs identically in demo/prod | No edits outside `lib/services/*_teaching_analyzer.dart` |
| 8 | Determinism | Narration derived from frequency maps + tie-break order already in the analyzer; no RNG, no clock | `history_teaching_analyzer.dart:245-263` |
| 9 | Backward compatibility | New `HistoryTeachingSummary` fields defaulted; no caller signature change; existing exact-string tests (A: `primaryFixLine`, `studyLine`) untouched and pass | `history_teaching_analyzer.dart:67-71`; `learn_teaching_analyzer_test.dart` 31 tests pass |
| 10 | Concurrency boundary | No touch to `sqlite_database_seed.dart`, `mock_integration_replay_seed.dart`, `shift_dashboard.dart` | `git status` |
| 11 | Test coverage | New file proves period/direction/recurrence/contrast/fallback/derivation; nearest existing suites re-run green | see commands below |
| 12 | Metric Honesty | No magnitude is asserted (analyzer has no per-shift deviation); only engine-classified direction + counted recurrence + prominent benchmark contrast | `learn_teaching_analyzer.dart:34-58` comments |
| 13 | Lint/analyze | `dart analyze` clean on both touched lib files | command output below |
| 14 | Scope discipline | 2 lib files + 1 test; no tracker edits, no doc moves besides this audit | `git diff --stat` |

## Verify — local commands (CI dark; disclosed)

- `flutter pub get` → `Got dependencies!`
- `dart analyze lib/services/learn_teaching_analyzer.dart lib/services/history_teaching_analyzer.dart` → **No issues found!**
- `flutter test test/learn_teaching_analyzer_gap39_test.dart` → **+7 All tests passed!**
- `flutter test test/learn_teaching_analyzer_test.dart test/history_teaching_analyzer_test.dart` → **All tests passed!** (31 + 8; pre-existing exact-string assertions unaffected)
- `flutter test test/learn_layer_widget_test.dart test/screens/variance/variance_learn_tab_depth_test.dart test/variance_learn_history_parity_test.dart test/variance_learn_history_coverage_test.dart` → **+25 All tests passed!** (no finder/UX regression — Decision 13)

## Residual notes

- "12 points over target" style magnitude from the Decision 13 example is intentionally NOT produced: `HistoryPatternRecord` carries no per-shift deviation, so asserting a magnitude would violate Metric Honesty. Narration states direction + counted recurrence + period contrast, all backed by the data path.
- Contrast clause is conservatively gated to the top-2 same-day benchmark periods, so it never claims a sibling period "holds on plan" without a real benchmark pattern.
