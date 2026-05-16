# Audit — Benchmark daypart breakdown: honest "—" for empty periods + mark Gap-42 pool fallback

Branch: `claude/fix-benchmark-phantom-zeros` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line).

## Diagnosis correction (recorded for the orchestrator)

The independent-audit gap #1 stated the read service "returns sentinel
zeros with no 'no data' signal". That is **partially inaccurate**:
`DaypartRange` already carries a `sampleSize` field
(`baseline_authority_service.dart:115`), and
`benchmark_tracker_read_service.dart:138-154` already emits
`sampleSize: 0` for the empty-range branch. The "no data" signal exists
on the type — it was simply **not consumed** by the table. The honest,
diff-tight fix is therefore to consume `sampleSize` in
`daypart_table.dart`, **not** to add a redundant `hasData` field to
`DaypartRange` (which lives in `baseline_authority_service.dart` —
out of the allowed file scope and reinforced by plan Gap 44: the
`BaselineData` bridge stays whole-day, do not extend it). The read
service is left byte-untouched. The pool rollup math / cover-weighted Σ
(Design Rule 4) is untouched.

## What changed

| File | Change |
|---|---|
| `lib/widgets/daypart_table.dart:43-77` | Added `_poolFallbackTag = 'whole-day est.'`, `_hasData(range)` (`range.sampleSize > 0`), `_isPoolFallback(range)` (profile present, row has data, no per-period child row). |
| `lib/widgets/daypart_table.dart:81-95` | `_targetCellsFor` short-circuits to `[—,—,—,—]` when `!_hasData(range)` — empty period dashes its targets instead of showing pool/sentinel numbers. |
| `lib/widgets/daypart_table.dart:128-145` | AVG COVERS cell renders `_missing` (`—`) when `!hasData`; per-period row passes `subLabel: 'whole-day est.'` only when `_isPoolFallback`. |
| `lib/widgets/daypart_table.dart:206-279` | `_TableRow` gained optional `subLabel`; when set, the label cell becomes a 2-child `Column` (label + muted `mono8`/`textMuted` tag). Style extracted to `_styleFor(i)`; existing column flex/padding/alignment untouched. |
| `test/daypart_table_slice_2_test.dart` | +`_emptyRange` builder, +`_dinnerOnlyProfile` fixture, +7 tests across 3 new groups (empty-period honesty, Gap-42 marker, no-overflow with empty+fallback). |

## Pattern B — 14-lens self-audit

| # | Lens | Verdict | Evidence |
|---|---|---|---|
| 1 | Slice intent met | PASS | (a) empty period → AVG COVERS + targets `—` (`daypart_table.dart:84-86,131`); (b) Gap-42 fallback row marked `whole-day est.` (`:88-95,145,247-265`); (c) pool/Design-Rule-4 math untouched; (d) `active_target_profile.dart` not modified (`git diff --stat`: only 2 files). |
| 2 | Authority order | PASS | Prompt > CLAUDE.md Metric Honesty Doctrine + Design Rules 1/2 honored; plan Gap 42 (honest fallback) + Gap 44 (BaselineData stays whole-day — not extended) respected. |
| 3 | No phantom zeros (Metric Honesty / Design Rule 2) | PASS | `!_hasData` → `_missing` for AVG COVERS and all 4 target cells (`:84-86,131`). Test `empty period → AVG COVERS + target cells render "—", never a 0` asserts `findsNothing` for `0`, `0.00`, `$0`, `$0.00`, `0.00 – 0.00`. |
| 4 | Gap-42 fallback visually marked (Design Rule 1) | PASS | `_isPoolFallback` true only for a data-bearing period with no child row → `subLabel` muted tag (`:88-95,145`). Tests prove marker count = pooled rows (2), true per-period row (dinner) unmarked, all-child-row profile → no marker. |
| 5 | Pool / Σ math untouched (Design Rule 4) | PASS | `benchmark_tracker_read_service.dart` byte-identical to base (`git diff` empty for that file); `_rangeFor` cover-weighted Σ (`:157-179`) unchanged; rollup row still sums `avgCovers` (`daypart_table.dart` rollup line unchanged). Test asserts rollup `300` (0+220+80) + pool CPLH `4.50` intact. |
| 6 | `active_target_profile.dart` not modified | PASS | `git diff --stat` shows only `lib/widgets/daypart_table.dart` + `test/daypart_table_slice_2_test.dart`. Scope-constraint #4 honored — no model field added; signal carried on the existing `DaypartRange.sampleSize`. |
| 7 | Scope discipline | PASS | Read service, `baseline_authority_service.dart`, and all concurrency-owned files (`sqlite_database_seed.dart`, `shift_dashboard.dart`, `shift_service_period_*`, demo auth fixture) untouched. |
| 8 | No app-logic / formula change | PASS | No new formula; only render-time predicates on a pre-existing `sampleSize` value. Whole-day rollup branch logic unchanged. |
| 9 | Null-safety / degrade paths | PASS | `subLabel` is `String?`; `_isPoolFallback` guards `profile == null` and `!_hasData` before `daypartFor`. `dart analyze` clean on touched files (pre-existing deprecation infos in untouched read-service test lines 88-98 only). |
| 10 | Tests prove the seam | PASS | `flutter test test/daypart_table_slice_2_test.dart` → **+13 All tests passed** (6 pre-existing + 7 new). Empty-period, marker-distinction, dashed-not-marked, and 1080/360 no-overflow all green. |
| 11 | Backward compat | PASS | `subLabel` optional → existing `_TableRow(...)` call sites (header, rollup, non-fallback rows) compile + render unchanged; the 6 original Slice-2 tests still pass (incl. Gap-42 fallback rows that now also carry the marker — assertions unaffected). |
| 12 | UX writing | PASS | Reuses existing `_missing` `—` grammar; new tag `whole-day est.` is plain, lower-case, muted (`mono8`/`textMuted`), matches the table's quiet typography — no heavy chrome, no engineering jargon. |
| 13 | House rules | PASS | No `db/migrations/*` change → scanners N/A. Hooks installed (step 0). No tracker edits. Diff tight (2 files). |
| 14 | Contract STOP | PASS | branch → implement → self-audit → commit + push → PR → STOP. No merge, no `--no-verify`, no tracker edits. |

## Local verification (CI dark)

- `flutter pub get` — OK (Got dependencies!).
- `dart analyze lib/widgets/daypart_table.dart lib/services/benchmark_tracker_read_service.dart test/daypart_table_slice_2_test.dart test/benchmark_tracker_read_service_test.dart` — **6 issues, all pre-existing `deprecated_member_use_from_same_package` infos in untouched `benchmark_tracker_read_service_test.dart:88-98`**; zero issues in `daypart_table.dart` / new test additions / read service.
- `flutter test test/daypart_table_slice_2_test.dart` — **+13 All tests passed!**
- `flutter test test/benchmark_tracker_read_service_test.dart` — **+15 -1**: one **pre-existing baseline failure** `reseeded demo cycle projects the current recommendation geometry` (`closeTo(4.7479)` vs actual `4.7463`, diff `0.0016`). **Not introduced by this diff** — proof: `git status --porcelain` shows only `daypart_table.dart` + its test changed; the read service and its test are byte-identical to the branch base, so a numeric drift in demo recommendation geometry cannot originate here. Out of scope (read-service / demo-seed owned; Design Rule 4 untouched).

## Residual / follow-ups

None blocking. The pre-existing `reseeded demo cycle projects the
current recommendation geometry` tolerance failure is a latent
demo-seed / read-service drift unrelated to this phantom-zero fix; flag
to the orchestrator for the read-service/demo-seed owner if not already
tracked.
