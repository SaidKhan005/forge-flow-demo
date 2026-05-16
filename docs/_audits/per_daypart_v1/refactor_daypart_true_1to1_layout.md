# Audit — Shift daypart view: TRUE 1:1 layout with Whole Day (shared section widgets, bespoke card retired)

Branch: `claude/refactor-daypart-1to1-layout` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line).

## Operator instruction (binding, repeated, final)

The daypart view's widget layout must be the SAME GRAMMAR as Whole Day —
not a lookalike, the **same widgets**. The prior implementation
re-implemented the three sections inside a bespoke bordered
`_DaypartScaffoldCard` with its own header/tile widgets and a different
layout engine, so it could never match. This refactor unifies the two
lenses onto one shared widget set fed by a data-source-agnostic adapter.

## Architecture

`_ShiftSectionViewData` (`lib/screens/shift_dashboard.dart:715-880`) is a
value type both lenses project into:

- `…fromWholeDay(ShiftDashboardReadModel)` (`:749-790`) — every field
  the whole-day card always drew is non-null, so the shared widgets
  reproduce the pre-refactor whole-day render exactly.
- `…fromPeriod(ServicePeriodAccumulator, DaypartTargetContext)`
  (`:792-879`) — honest nulls everywhere a number is not derivable;
  Gap-42 fallback honored (a null `DaypartTargetContext` field flows
  straight through to a hidden sub-line / no band).

The three shared sections (`_OutputsSection` `:882`, `_InputsSection`
`:958`, `_FohProductivitySection` `:1064`) plus `_LaborCard`/
`_LaborVarianceSection` (`:1715`/`:1740`) and `_CompactHoursColumn`
(`:1828`) consume `_ShiftSectionViewData` only. `_sectionGroups`
(`:189-228`) emits the three pinned `StickySectionDelegate` groups;
`_wholeDaySlivers` (`:230`) and `_servicePeriodSlivers` (`:247`) call it
with the only differences being the header labels and the projected
data. The period identity + tri-state status + driver chip render in the
compact `_DaypartPeriodHeader` (`:1312`) ABOVE the sections — not a card
wrapping them.

## What changed

| File | Change |
|---|---|
| `lib/screens/shift_dashboard.dart` | Added `_ShiftSectionViewData` (+`_LaborVarianceData`/`_HoursColumnData`/`_OpzBandData`) `:625-880`. Generalized `_OutputsSection`/`_InputsSection` to consume it; added shared `_FohProductivitySection` `:1064-1117`. Generalized `_LaborCard`/`_LaborVarianceSection` `:1715-1826` + `_CompactHoursColumn` `:1828-1923` to honest-nullable. Added `_sectionGroups` `:189-228`; `_wholeDaySlivers` `:230-245` + `_servicePeriodSlivers` `:247-309` rebuilt; added compact `_DaypartPeriodHeader` `:1312-1461`. Retired `_DaypartScaffoldSection`, `_DaypartScaffoldCard`, `_DaypartSectionHeader`, `_dpFmt`, `_DaypartOutputsSection`, `_DaypartLaborCard`, `_DaypartInputsSection`, `_DaypartFohProductivitySection`, `_DaypartTargetedCell`, `_MetricCell` (no dead code; net −246 lines). `_DaypartStatusLine`/`_DaypartDriverChip`/`_restaurantLocalNow`/`_TimeIntoServiceHeader` kept. |
| `test/widget/shift_dashboard_daypart_true_1to1_layout_test.dart` | NEW — 5 tests: shared-widget finder parity (tall viewport), per-period LABOR Theoretical+pill parity, closed→"Period closed"+honest "—", 1080px no-overflow, 360px functional + pre-existing-overflow-only guard. |
| `test/widget/shift_dashboard_daypart_parity_test.dart` | 4 cases rewritten to the new 1:1 structure (bespoke "Target X" sub-lines retired → shared `ZoneStatusCard` band parity); header doc updated; relaxed a `12.50` finder (CPLH appears in pill AND ZoneStatusCard). |
| `test/widget/shift_dashboard_daypart_closed_state_test.dart` | Bespoke "Target 13.00/$540/$41.50" assertions → shared `ZoneStatusCard` band assertion. |
| `test/widget/shift_dashboard_daypart_test.dart` | `SERVICE PERIOD` single-header + `Target —` assertions → new section-grammar assertions. |
| `test/shift_dashboard_daypart_toggle_widget_test.dart` | `SERVICE PERIOD` assertions → `OUTPUTS`/`INPUTS` grammar (3 cases). |
| `test/widget/shift_dashboard_ticker_test.dart` | `_DaypartScaffoldSection`→`_DaypartPeriodHeader` rename; `SERVICE PERIOD` proxy → `OUTPUTS`. |

`lib/state/shift_service_period_notifier.dart` deliberately **untouched**
— the period→view-data projection lives in the screen adapter (prompt:
"keep minimal"); the notifier already exposes `buckets` +
`daypartTargetFor` + `definitions`.

## Pattern B — 14-lens self-audit

| # | Lens | Verdict | Evidence |
|---|---|---|---|
| 1 | Slice intent met (true 1:1, same widgets) | PASS | Daypart `_servicePeriodSlivers` `:247-309` calls the SAME `_sectionGroups` `:189` whole-day does (`_wholeDaySlivers:230`), emitting the SAME `_OutputsSection`/`_InputsSection`/`_FohProductivitySection`. New test "SAME shared section widgets … finder parity" green (MetricPill/SalesForecastCard/ZoneStatusCard counts equal across lenses). |
| 2 | (b) Daypart uses same section/header widgets | PASS | Daypart headers `StickySectionDelegate('OUTPUTS'/'INPUTS'/'FOH PRODUCTIVITY')` via `_sectionGroups` `:194-225`; identical widget tree, only labels + projected data differ. Bespoke `_DaypartSectionHeader`/`_DaypartScaffoldCard` deleted (grep: zero refs outside the file). |
| 3 | (a) Whole-day byte-untouched (Promise 3 / Layer 9) | PASS | `…fromWholeDay` `:749-790` passes all non-null fields; generalized `_LaborVarianceSection` `:1740-1826` collapses to the exact prior sequence (value→`SizedBox(3)`→Theoretical→`SizedBox(8)`→pill) when non-null; `_CompactHoursColumn` `:1828` renders `Target N hrs`+pill when `needed!=null`; `_FohProductivitySection` `:1064` = `Padding(h16)`+`ZoneStatusCard` when band present. Whole-day test set (`shift_dashboard_daypart_test.dart` "whole-day view is unchanged", `…ticker_test.dart`, `…chip_foh_ux_test.dart`, `…notifier_test`) all green; 1080px no-overflow green; standalone probe confirmed whole-day 360px overflow fingerprint unchanged. |
| 4 | (c) Preserved: closed/active/future + missing-tz copy | PASS | `_DaypartStatusLine` kept verbatim (`:1463-1521`), driven by `resolveServicePeriodPhase` in `_DaypartPeriodHeader` `:1442-1450`; missing-tz banner `:1378-1399`; "Selected service period is unavailable." `:1402-1405`. Tests: closed_state "past/closed…Period closed", "genuinely future…Opens at", daypart_test "missing timezone banner" green. |
| 5 | (c) Preserved: honest empty states (no phantom 0) | PASS | Per-period `…fromPeriod` `:liveOr` `:823-826` → `MetricProvenance.unavailable` when no labor/covers → shared `MetricPill` unavailable branch renders `—` + the SAME "Connect a … vendor" copy whole-day uses (`metric_pill.dart:279-307`; tooltips in `_OutputsSection`/`_InputsSection`). LABOR null actual→`—`, null theoretical→no sub-line, null variance→no pill (`_LaborVarianceSection:1745-1826`). Tests assert no `0.0%`/`$0.00`/`Target $0.00`. |
| 6 | (c) Preserved: LABOR Theoretical % + ±pts pill (#789) | PASS | Flows through shared `_LaborCard`/`_LaborVarianceSection`; `…fromPeriod` threads `tc.theoreticalLaborPct` `:809` + computed `variancePts` `:810-812`. New test "per-period LABOR Theoretical sub-line + ±pts delta pill" asserts `4.3%` / `Theoretical 30.0%` / `−25.7 pts`; parity test's whole-day-LABOR-unchanged case green. |
| 7 | (c) Preserved: chip border-only + FOH matrix labels | PASS | `_ShiftPeriodSelector`/`_PeriodPill`/`OpzMatrixGrid` not in the diff (`git diff --stat`); `shift_dashboard_chip_foh_ux_test.dart` green unchanged. |
| 8 | (c) Preserved: Gap-42 fallback (empty rows → no locked target) | PASS | `…fromPeriod` reads `DaypartTargetContext` nullable fields directly (`:803-851`); `tc.hasOpzBand` false → `opz=null` → `_FohProductivitySection` honest no-zone line `:1067-1090`. Parity test "null/empty honest state" + daypart_test "no locked productivity zone" green. |
| 9 | Authority order | PASS | Prompt > CLAUDE.md (Promise 3/Layer 9, Metric Honesty, UX). The retired bespoke "Target X" rate sub-lines were a daypart-only addition Whole Day never had; removing them is REQUIRED by the binding 1:1 instruction (the locked rate targets still drive the shared OPZ band + Sales forecast — `…fromPeriod:817-851`). Tracker/contract docs not edited. |
| 10 | Scope discipline | PASS | Only `shift_dashboard.dart` + 5 test files touched (`git diff --stat`); notifier untouched (projection kept in screen, prompt "keep minimal"). Demo-seed / Settings files not touched (disjoint, per concurrency note). |
| 11 | Null-safety / analyze | PASS | `dart analyze lib/screens/shift_dashboard.dart lib/state/shift_service_period_notifier.dart` + all 5 touched/new test files → **No issues found!** `_ShiftSectionViewData` made private to avoid `library_private_types_in_public_api`. |
| 12 | Tests prove the seam | PASS | 55/55 across the 9 named/adjacent files (`…daypart_parity`, `…daypart_closed_state`, `…daypart_test`, `…daypart_true_1to1_layout`, `…daypart_toggle`, `…notifier_test`, `…chip_foh_ux`, `…ticker_test`, `…notifier_cold_boot`). New file adds explicit cross-lens widget-finder parity. |
| 13 | No dead code | PASS | All 10 retired widgets/helpers deleted, replaced with a single explanatory comment block `:1502-1516`; grep confirms no remaining references anywhere in `lib`/`test`. |
| 14 | Contract STOP | PASS | branch → implement → self-audit → commit + push → PR → STOP. No merge, no tracker edits, no `--no-verify`. Hooks installed (step 0). |

## Local verification (CI dark)

- `flutter pub get` — Got dependencies.
- `dart analyze lib/screens/shift_dashboard.dart lib/state/shift_service_period_notifier.dart` + 5 touched/new test files — **No issues found!**
- `flutter test` (9 files): `shift_dashboard_daypart_parity_test.dart`, `shift_dashboard_daypart_closed_state_test.dart`, `shift_dashboard_daypart_test.dart`, `shift_dashboard_daypart_true_1to1_layout_test.dart`, `shift_dashboard_daypart_toggle_widget_test.dart`, `shift_dashboard_notifier_test.dart`, `shift_dashboard_chip_foh_ux_test.dart`, `shift_dashboard_ticker_test.dart`, `shift_dashboard_notifier_cold_boot_test.dart` — **+55 All tests passed!**

## Residual / follow-up (operator decision)

**Pre-existing 360px cosmetic overflow — out of this slice's scope.** At
360px the SHARED whole-day widgets `_LaborVarianceSection` (±pts pill
Row), `MetricPill` (value Row), and `DataSourceHealthPill` overflow by
~8.3 / 17 / 2.0 px. **Verified pre-existing**: a standalone probe of the
master whole-day lens (no period selected) at 360px throws the identical
three overflows. Promise 3 / Layer 9 freezes the whole-day shared-widget
output, so this slice neither introduces nor is permitted to "fix" that
narrow-width overflow (a fix would mutate frozen whole-day rendering).
The daypart lens inherits exactly the same behavior (true 1:1). The
1080px operator-console width is clean for both lenses (tested). The
360px shared-widget overflow is flagged here as a separate, pre-existing
follow-up for operator routing — not a daypart regression.
