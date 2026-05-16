# Audit — Shift UX: active chip border-only + FOH matrix label fix

Branch: `claude/ux-shift-chip-foh` · Base: `master` · Scope: layout/label only.

## Operator findings addressed

- **A — Kill "ACTIVE NOW" text.** The active service-period chip no longer
  renders the literal `ACTIVE NOW` text. The current real-time period is
  signalled by an orange (`AppColors.sunset`) border at width `2.0`; all
  other chips keep the subtle border. Selected-state styling is unchanged
  (`AppColors.sunset` fill, `sunsetDark` border). Screen-reader parity
  preserved via `Semantics(value: 'active now')`.
- **B — FOH matrix labels truncated.** The CPLH×SPLH row labels
  (`CPLH OVER/OPZ/UNDER`) and column headers (`SPLH LOW/ON/HIGH`) no
  longer hard-clip. The label gutter widened to a named `_labelGutter`
  (76px, sized for the longest label at `mono10`); `TextOverflow.ellipsis`
  replaced with `softWrap: true, maxLines: 2` so labels render in full on
  one line at phone width and gracefully wrap (never ellipsize) on
  ultra-narrow viewports. The header spacer matches the gutter so columns
  stay aligned.

## Files changed

| File | Change |
|---|---|
| `lib/screens/shift_dashboard.dart:920-967` | `_PeriodPill`: border-only active affordance; removed `ACTIVE NOW` `Text`/`Column`; added active `Key` + `Semantics.value`. |
| `lib/widgets/opz_matrix_grid.dart:58-83,97-149` | `_labelGutter` const; row/col labels full + soft-wrap, no ellipsis. |
| `test/widget/shift_dashboard_chip_foh_ux_test.dart` | New: asserts orange border + no "ACTIVE NOW" text; full labels + no overflow at 1080/360/300px. |
| `test/shift_dashboard_daypart_toggle_widget_test.dart` | Swapped 9 `find.text('ACTIVE NOW')` → `find.byKey(Key('shift_period_pill_active'))`. |
| `test/widget/shift_dashboard_daypart_test.dart` | Same swap (1 site). |

## Pattern B — 14-lens self-audit (worker)

| # | Lens | Verdict | Evidence |
|---|---|---|---|
| 1 | Scope adherence | PASS | Touched only `shift_dashboard.dart` + the shared FOH matrix widget `opz_matrix_grid.dart` (the CPLH×SPLH matrix lives here, rendered by `ZoneStatusCard` for both whole-day `shift_dashboard.dart:213` and daypart `:1710`) + tests. `shift_service_period_notifier.dart` untouched (read-only path sufficed). No seed/Settings files touched. |
| 2 | Operator intent A | PASS | `shift_dashboard.dart:954-964` `ACTIVE NOW` block deleted; `:923-931` border = `sunset` when `activeNow && !selected`, width `2.0`; selected branch unchanged. |
| 3 | Operator intent B | PASS | `opz_matrix_grid.dart:103-119` (header) + `:130-141` (row label): full string, `softWrap`/`maxLines:2`, no `ellipsis`; gutter `_labelGutter=76` `:61-64`. |
| 4 | No metric/read-logic change | PASS | Diff is pure layout/label + a11y; `_cplhBandFor`/`_splhBandFor`, read models, notifiers untouched. |
| 5 | Design Rule 2 / phantom zeros | PASS | No numeric rendering touched; closed-state/honest-dash paths unchanged (closed-state + parity tests green). |
| 6 | Promise 3 / Layer 9 (whole-day untouched) | PASS | `_PeriodPill` + `OpzMatrixGrid` shared; change is symmetric layout-only — whole-day parity test `whole-day half is byte-untouched` green. |
| 7 | LABOR Theoretical/delta parity preserved | PASS | `shift_dashboard_daypart_parity_test.dart` LABOR Theoretical + delta-pill cases green (58/58). |
| 8 | No RenderFlex overflow | PASS | New test asserts `tester.takeException() == null` at 1080 / 360 / 300px. |
| 9 | Accessibility | PASS | `Semantics(button, selected, value: activeNow ? 'active now' : null, label)` `shift_dashboard.dart:933-938` keeps active state for screen readers after text removal. |
| 10 | Test coverage | PASS | New dedicated test (border color+width, no text, full labels, no overflow ×3 widths); existing toggle/daypart tests migrated to stable key. |
| 11 | `dart analyze` | PASS | `No issues found!` on all touched lib + test files. |
| 12 | Regression suite | PASS | 58/58 across new + `opz_matrix_grid` + toggle + daypart + parity + closed-state. |
| 13 | UX Writing Standard | PASS | No new operator copy; deliberate full labels (no jargon, no clipped abbreviations). |
| 14 | Demo-mode HP #2 | PASS | No `kDemoMode` branch, no `demo_*` table, no reader fork; pure UI. |

## Local verification (CI dark)

- `flutter pub get` — Got dependencies.
- `dart analyze lib/screens/shift_dashboard.dart lib/widgets/opz_matrix_grid.dart test/widget/shift_dashboard_chip_foh_ux_test.dart test/shift_dashboard_daypart_toggle_widget_test.dart test/widget/shift_dashboard_daypart_test.dart` — **No issues found!**
- `flutter test` (new + `opz_matrix_grid_test` + `shift_dashboard_daypart_toggle_widget_test` + `shift_dashboard_daypart_test` + `shift_dashboard_daypart_parity_test` + `shift_dashboard_daypart_closed_state_test`) — **All 58 tests passed.**

## Verdict

Self-audit clean. Layout/label + a11y only; closed-state, honest-dash,
LABOR parity, and whole-day semantics preserved. Ready for orchestrator
independent audit.
