# Audit — Shift UX: whole-day primary-driver chip + daypart header de-dup

Branch: `claude/ux-shift-whole-day-driver-and-header-dedup` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line). Orchestrator independent-audit column intentionally left blank.

## Operator findings (live walkthrough 2026-05-16, binding) — 2 items, ONE file

- **Item 2** — Whole-day Shift was missing the primary-driver chip the daypart lens has.
- **Item 1** — The daypart header announced the selected period twice (selector pill + in-header shortLabel pill / duplicated full label).

## Symptom verification on fresh tree (pre-change)

Both symptoms confirmed real on the worktree's master-equivalent tree before any edit:

- Item 2: `_wholeDaySlivers` returned only `_sectionGroups(...)` — no driver chip — while the daypart path renders `_DaypartDriverChip(card: primaryLeverCard)` inside `_DaypartPeriodHeader` (`shift_dashboard.dart` pre-change `_wholeDaySlivers` body vs `_DaypartPeriodHeader:1463`). Symptom real.
- Item 1: `_DaypartPeriodHeader`'s `else` block rendered a `Container` shortLabel pill (`selectedDefinition.shortLabel`) + an `Expanded(Text(selectedDefinition.label))` + the time range, while `_ShiftPeriodSelector._PeriodPill` already renders `definition.label` for the selected pill (`shift_dashboard.dart:1235`). Period identity announced twice. Symptom real.

Key simplification found during verification: `ShiftDashboardReadModel` **already** exposes a fully resolved `primaryLeverCard` (`shift_dashboard_read_model.dart:58`, set in `buildWholeDay` via `LeverCards.lookup(leverId)!` at `shift_dashboard_read_model.dart:432,498`). Item 2 therefore needed **no read-model threading** — it is a pure display wiring of an already-computed value. Scope stayed `lib/screens/shift_dashboard.dart` only.

## What changed (one file)

| File | Change |
|---|---|
| `lib/screens/shift_dashboard.dart:226-258` | `_wholeDaySlivers` now prepends a `SliverToBoxAdapter` rendering `_DaypartDriverChip(card: rm.primaryLeverCard)` wrapped in `Padding(fromLTRB(16,4,16,8))` + `Align(centerLeft)`, then spreads the unchanged `_sectionGroups(...)`. Mirrors the daypart chip's structural position (directly above the section groups / SHIFT OUTPUTS). Doc comment updated to record the chip as additive chrome (Promise 3 / Layer 9). |
| `lib/screens/shift_dashboard.dart:1424-1466` | `_DaypartPeriodHeader` `else` block: removed the duplicate identity Row (shortLabel `Container` pill + `Expanded(Text(selectedDefinition.label))`) and the `SizedBox(height:6)`. Replaced with one `Row` = `Expanded(_DaypartStatusLine)` + fixed time-range `Text`. Status line, time range, and `_DaypartDriverChip(card: primaryLeverCard)` all preserved. |
| `test/widget/shift_dashboard_whole_day_driver_and_header_dedup_test.dart` (new, 5 tests) | Item 2: whole-day chip renders the read-model-resolved lever label; whole-day never shows the "NO PATTERN YET" phantom; chip sits above `SHIFT OUTPUTS`. Item 1: daypart header announces the period exactly once (full label `findsOneWidget`) with status line + time range + chip preserved; null-lever daypart path still shows the SAME `_DaypartDriverChip` "NO PATTERN YET" degrade with no phantom. |

No other files touched. Concurrency-owned `lib/screens/baseline_tracker.dart` not touched. Demo seeds, Settings, `shift_service_period_notifier.dart` not modified (read-only use only).

## Pattern B — 14-lens self-audit

| # | Lens | Worker verdict | Orchestrator verdict |
|---|---|---|---|
| 1 | Slice intent met | PASS — Item 2: whole-day renders `_DaypartDriverChip(card: rm.primaryLeverCard)` above sections (`shift_dashboard.dart:243-258`); Item 1: duplicate identity removed, period announced once (`:1424-1466`). Both new tests + 24 cross-file tests green. | |
| 2 | Authority order | PASS — Prompt > CLAUDE.md (UX Writing, Metric Honesty, Promise 3 / Layer 9). Operator UX direction binding and honored. No Tier-2 contract contradicted. | |
| 3 | Promise 3 / Layer 9 (whole-day metric byte-untouched) | PASS — `_sectionGroups(...)` call args unchanged; `_ShiftSectionViewData.fromWholeDay(rm)` unchanged; the chip is an additive leading `SliverToBoxAdapter`, no metric math added (`shift_dashboard.dart:243-257`). Existing whole-day regression tests (`daypart_test` "whole-day view is unchanged", `daypart_closed_state` "whole-day half is byte-untouched", `ticker_test`) green. | |
| 4 | Promise 2 (closed truth keeps stamp) | PASS — No stamp/target read path touched. Daypart `_DaypartStatusLine` (Period closed / Active now / Opens at …) preserved verbatim (`:1444-1457`); `daypart_closed_state_test` green. | |
| 5 | Metric Honesty / Design Rule 2 (no phantom) | PASS — Chip reuses the existing `_DaypartDriverChip` null → "PRIMARY DRIVER · NO PATTERN YET" degrade (`:1546-1583`); whole-day's `primaryLeverCard` is non-nullable by `ShiftDashboardReadModel` contract so it shows a real resolved driver, never a phantom. New tests assert no `NO PATTERN YET` on whole-day and the SAME degrade with no `PRIMARY DRIVER · $` phantom on the null daypart path. | |
| 6 | No new chip / exact visual reuse | PASS — Whole-day chip is the literal `_DaypartDriverChip` widget (`:248`), same class the daypart header uses (`:1463` pre-change `:1463`→ now `:1465`). No new widget, no new style constants. | |
| 7 | True 1:1 structural position | PASS — Daypart chip is the last element of `_DaypartPeriodHeader`, a `SliverToBoxAdapter` placed immediately before `_sectionGroups(...)` (`_servicePeriodSlivers:280-301`). Whole-day chip is a `SliverToBoxAdapter` immediately before `_sectionGroups(...)` (`:244-257`). Test "chip sits ABOVE SHIFT OUTPUTS" asserts `getTopLeft(chip).dy < getTopLeft(outputs).dy`. | |
| 8 | Item 1 de-dup correctness | PASS — selector pill remains canonical switcher (`_ShiftPeriodSelector:1235`, untouched); in-header shortLabel pill + duplicated full label removed; status line + time range + driver chip kept (`:1424-1466`). Test asserts full label `findsOneWidget` while `Active now` + `11:00 – 15:00` + `PRIMARY DRIVER ·` all present. | |
| 9 | No RenderFlex overflow (1080 / 360) | PASS — New daypart Row has exactly one flexible child (`Expanded(_DaypartStatusLine)`) absorbing slack + a fixed-size time-range `Text`; cannot overflow. Whole-day chip uses `Align(centerLeft)` (natural size, no Row). `true_1to1_layout` 1080px test green; its 360px test's pre-existing shared-widget cosmetic overflow (documented in that test's own name) is unrelated to the touched header Row / chip. | |
| 10 | Scope discipline | PASS — `git diff --stat`: 1 file (`lib/screens/shift_dashboard.dart`, +58/−49) + 1 new test. No read-model threading needed (value pre-exposed). Concurrency file `baseline_tracker.dart` untouched; demo seeds / Settings / notifier untouched. | |
| 11 | No app-logic / read-logic change | PASS — `rm.primaryLeverCard` consumed read-only; `LaborModel.determineLever` / `LeverCards.lookup` not called from the screen; no computation added. Daypart still uses `periodNotifier.primaryLeverCardFor` unchanged (`:1369`). | |
| 12 | UX writing standard | PASS — No new copy strings introduced; chip/status copy is the existing verbatim wording. De-dup removes redundancy (training-clear, one period announcement). | |
| 13 | House rules | PASS — No `db/migrations/*` change → drift scanner N/A. Git hooks installed at step 0 (pre-commit/pre-push). No tracker/ledger edits. `dart analyze` clean on every touched file. | |
| 14 | Contract STOP | PASS — branch → implement → self-audit → commit + push → open PR → STOP. No merge, no tracker advance, no `--no-verify`. | |

## Local verification (CI dark — honest results)

- `flutter pub get` — **Got dependencies!** (53 transitive packages have newer incompatible versions; pre-existing, unrelated).
- `dart analyze lib/screens/shift_dashboard.dart` — **No issues found!**
- `dart analyze test/widget/shift_dashboard_whole_day_driver_and_header_dedup_test.dart` — **No issues found!**
- `flutter test` new test + `shift_dashboard_daypart_parity_test.dart` + `shift_dashboard_daypart_closed_state_test.dart` + `shift_dashboard_daypart_test.dart` — **+24 All tests passed!**
- `flutter test shift_dashboard_daypart_true_1to1_layout_test.dart shift_dashboard_daypart_opz_no_actuals_test.dart shift_dashboard_chip_foh_ux_test.dart shift_dashboard_ticker_test.dart` — **+18 All tests passed!** (RenderFlex stripes observed are the pre-existing 360px shared-widget cosmetic overflow the `true_1to1_layout` 360px test explicitly tolerates by name; unrelated to the touched header Row / additive chip.)

## Residual / follow-ups

None blocking. Whole-day's `primaryLeverCard` is non-nullable by the `ShiftDashboardReadModel` contract (`LeverCards.lookup(leverId)!`), so the authoritative whole-day lens always shows a real resolved driver; the "NO PATTERN YET" degraded state is the SAME shared `_DaypartDriverChip` behaviour, exercised on the per-period lens where in-period evidence can legitimately be absent (test pin #3). This is the honest 1:1 — not a gap.
