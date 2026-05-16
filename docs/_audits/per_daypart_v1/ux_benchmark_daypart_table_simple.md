# Benchmark UX — simple non-scrolling daypart table with better spacing (Lens Audit)

Branch: `claude/ux-benchmark-daypart-table-simple` · Base: `master` (`88ac0f0f`)
Authority: this UX prompt → `CLAUDE.md` UX Writing Standard + Metric Honesty
Doctrine + Design Rule 1/2 → `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`.

## Operator finding (binding, 2026-05-16)

Live walkthrough on the Benchmark screen. Two complaints about
`DaypartTable` (`lib/widgets/daypart_table.dart`):

- **A — Kill the scrollable table.** The prior cleanup
  (`ux_benchmark_cleanup.md`) introduced `_minTableWidth = 720` with a
  `SingleChildScrollView(scrollDirection: Axis.horizontal, …)` fallback,
  so on a phone the per-daypart table became a horizontally-scrolling
  table. The operator wants **one simple table that just fits**, no
  horizontal scroll, with **better spacing**.
- **B — "whole-day est." annotation.** Out of scope here (a separate core
  worker wires real per-daypart targets). This task **must not** remove,
  weaken, or re-label the honest Gap 42 `_poolFallbackTag` marker — only
  layout/spacing is mine.

## Scope

`lib/widgets/daypart_table.dart` only — pure layout/spacing. No change to
data, target/fallback logic, or `_poolFallbackTag` semantics. Sibling
workers own `shift_dashboard.dart`, `baseline_tracker.dart`,
`forge_flow_app.dart` — untouched. Test file updated to encode the new
no-scroll contract (the old test asserted the now-rejected scroll
behavior).

## Files changed

- `lib/widgets/daypart_table.dart`
  - **Removed** the `_minTableWidth = 720` constant and the
    `SingleChildScrollView(scrollDirection: Axis.horizontal, child:
    SizedBox(width: 720, …))` fallback entirely. `build()` now returns one
    static table for every width (`daypart_table.dart:112-225`). No
    horizontal scroll anywhere.
  - Responsive spacing from the `LayoutBuilder`: `hPad` 12→24, `vPad`
    16→20 (more vertical breathing room than the old fixed `v14`), and an
    inter-column `gap` of `(w/45).clamp(10,26)` — airy on wide layouts,
    tight-but-readable toward the 360px floor (`daypart_table.dart:131-145`).
  - `_TableRow` now takes `hPad/vPad/gap` and renders each cell via
    `_cell(i)` (`daypart_table.dart:243-330`):
    - Label column (data rows): plain wrapping `Text` + the subordinate
      `whole-day est.` marker `Column`, full size, never shrunk
      (`daypart_table.dart:296-318`).
    - OPZ-range column (last, incl. its `OPZ RANGE` header): wraps to two
      lines at full size (`maxLines: 2, softWrap: true`) so the widest
      token never forces the other columns tiny
      (`daypart_table.dart:320-329`). String unchanged ("floor – ceiling").
    - Every other cell (DAYPART header + numeric values + their headers):
      `FittedBox(fit: BoxFit.scaleDown)` single-line — at the 360px floor a
      value shrinks a hair instead of clipping/ellipsizing, and stays full,
      uniform size at any comfortable width (`daypart_table.dart:331-345`).
    - Label/OPZ columns get `flex: 5`, the four single-token numeric
      columns `flex: 4` (`daypart_table.dart:268-272`).
  - Reader/Design-Rule logic byte-unchanged: `_hasData`, `_isPoolFallback`,
    `_labelFor`, `_targetCellsFor`, `_opzRange`, `_poolFallbackTag`,
    `_missing` (`daypart_table.dart:43-113`).
- `test/daypart_table_slice_2_test.dart` — the old
  `'narrow phone width (360) scrolls instead of overflowing'` test encoded
  the now-rejected scroll contract; rewritten to assert **no horizontal
  `SingleChildScrollView`**, no overflow, and every column's data on-screen
  (not offstage) at 1080 and 360; the empty+fallback 360 test strengthened
  to also assert no horizontal scroll and that the `whole-day est.` marker
  still renders at 360 (honest semantics preserved).

## Pattern B — 14-lens self-audit

| # | Lens | Worker self-audit (file:line) | Independent audit |
|---|------|-------------------------------|-------------------|
| 1 | Product & user journey | Operator now sees one simple, comfortably-spaced table that fits the phone — no horizontal scroll (scroll branch deleted, `daypart_table.dart:112-225`). Card grammar (gradient/hairline-rule/3px-radius/mono header) unchanged (`daypart_table.dart:115-128`). | [orchestrator] |
| 2 | Information architecture & navigation | Same six columns, same order, same `Whole Day` rollup at the bottom (`daypart_table.dart:159-219`). No nav change. | [orchestrator] |
| 3 | Data model, migration, RLS | None. No schema/SQL/migration. | [orchestrator] |
| 4 | Repository & service layer | None. Reader accessors (`_targetCellsFor`/`_opzRange`/`_labelFor`/`_isPoolFallback`/`_hasData`) byte-unchanged (`daypart_table.dart:43-113`). | [orchestrator] |
| 5 | Proxy/route/gateway | N/A — pure UI widget. | [orchestrator] |
| 6 | Auth/roles/permissions/scope | N/A. | [orchestrator] |
| 7 | Lifecycle & destructive actions | None. Sibling-owned files (`shift_dashboard.dart`, `baseline_tracker.dart`, `forge_flow_app.dart`, seed/Settings) deliberately untouched. | [orchestrator] |
| 8 | Background workers/deploy/startup/health | N/A. | [orchestrator] |
| 9 | UI state, UX, accessibility | Honest states preserved: empty period → `—` not `0` (`daypart_table.dart:82-93`), no profile → `—` (`daypart_table.dart:90-93,205-216`); Gap 42 `whole-day est.` marker logic untouched and proven to still render at 360 (`daypart_table.dart:50,157` + test). No `RenderFlex overflowed`, no clipped/ellipsized data at 1080 or 360 — numeric atoms `scaleDown`, OPZ wraps, label wraps (`daypart_table.dart:296-345`); tests assert `takeException() isNull` + no horizontal scroll. | [orchestrator] |
| 10 | Performance & data loading | One `LayoutBuilder`; no extra I/O/rebuilds. `FittedBox`/wrapping are O(cells); table is 1 header + N period rows + 1 rollup. | [orchestrator] |
| 11 | Mobile/web/admin/API parity | Benchmark mobile surface only. Per-period read-back + OPZ-combined-string + whole-day rollup contracts unchanged — proven green by `daypart_table_slice_2_test.dart` (13/13) + `target_consistency_opz_test.dart` (23/23). | [orchestrator] |
| 12 | Tests, builds, evidence | `dart analyze` clean (0 issues) on both touched files. Full local runs disclosed below. CI dark. | [orchestrator] |
| 13 | Observability/audit/supportability | No logging surface; layout deterministic. Rationale documented in the `build()` LayoutBuilder docstring and `_cell` comments (`daypart_table.dart:131-145,296-345`). | [orchestrator] |
| 14 | Docs/tracker/prompt hygiene | Trackers/ledgers/memory NOT touched (worker contract). This audit doc added; `daypart_table.dart` docstrings refreshed; stale `_minTableWidth` docstring removed. | [orchestrator] |

## Concurrency compliance

Stayed strictly in `lib/widgets/daypart_table.dart` + its test file. Did
not touch `lib/screens/shift_dashboard.dart`,
`lib/screens/baseline_tracker.dart`, `lib/forge_flow_app.dart`, demo seed
files, or Settings files.

## Local verification (CI dark)

- `flutter pub get` — `Got dependencies!`.
- `dart analyze lib/widgets/daypart_table.dart test/daypart_table_slice_2_test.dart` — **No issues found!**
- `flutter test test/daypart_table_slice_2_test.dart test/target_consistency_opz_test.dart` — **+36 All tests passed!** (`daypart_table_slice_2_test.dart` 13/13 incl. the rewritten/strengthened 1080+360 no-scroll tests; `target_consistency_opz_test.dart` 23/23, unchanged contract regression-clean).
