# Phase 7.58 depth wave — landing audit

Date: 2026-05-05
Owner: Phase 7.58 advisor depth lane closeout
Authority:

- `docs/contracts/phase_7_58_primary_driver_contract.md` "Depth Surfaces" section
- `docs/phases/phase_7_58/phase_7_58_depth_wave_plan.md`
- `docs/Knowledge_graph_docs/Bold By Design.md` (chapters 2 / 8 / 9 / 10) and `jim_taylor_labor_model_deep_dive.md` (ch. 7 / 8)

## Verdict

**5 ACCEPT (wave closed).** Master is `699a45f`. Initial audit (master `8cb58fa`) returned 4 ACCEPT + 1 FOLLOW-UP NEEDED on `7.58.UX.6`; the follow-up (`3154679`, PR #144) aligned the three legacy assertion blocks in `test/variance_history_widget_test.dart` and the suite is now 70/70 PASS.

| Slice | Verdict | Note |
|---|---|---|
| `7.58.UX.6` (DOLLAR IMPACT relabel) | **ACCEPT** (post follow-up `3154679`) | Triplet renders against demo seed week; legacy widget-test assertions aligned to new footer. |
| `7.58.UX.8` (OPZ-aware row adornment) | **ACCEPT** | |
| `7.58.cross-axis.0` (engine + 4-cell catalog) | **ACCEPT** | |
| `10.5.6` (OPZ matrix grid + cross-axis sub-label) | **ACCEPT** | |
| `7.58.UX.7+9` (Learn coverage + carousel swap) | **ACCEPT** | |

Architectural compliance audit clean across all 5 slices: zero em dashes in operator-facing string literals; zero `vendorProvidedForecast` references; `LaborModel.determineLever` / `theoreticalLaborPct` / `attributeDollarImpactByAxis` / `ShiftFactBuilder.fromClosedShiftInput` signatures unchanged; file-ownership boundaries respected.

## Per-slice audit

### `7.58.UX.6` — DOLLAR IMPACT relabel (`f53a425`) + follow-up (`3154679`) — ACCEPT

**Implementation.** Renderer-only change to `lib/widgets/dollar_impact_card.dart`. Footer renders `Best Possible: X% · Actual: Y% · Closable Gap: ±Z pts` whenever `theoreticalLaborPct` is non-null. Falls back to the existing `footerText` when null. Slice-owned test `test/widgets/dollar_impact_card_depth_test.dart` PASSES (6/6) including a sum-invariant test pinning `Closable Gap = Actual − Best Possible`.

**The follow-up (closed `3154679`, PR #144).** The original audit flagged three pre-existing assertion blocks in `test/variance_history_widget_test.dart` that asserted pre-relabel close-stamp / "$3M annual sales" boilerplate against `WeekRecord` fixtures carrying `theoreticalLaborPct: 20.48`. The follow-up commit updated all three blocks to expect the new triplet footer. `flutter test test/variance_history_widget_test.dart` → **70/70 PASS** (was 68/70 pre-follow-up). Slice-owned `dollar_impact_card_depth_test.dart` regression remains green; analyzer clean.

**Verdict: ACCEPT.**

### `7.58.UX.8` — OPZ-aware row adornment (`a15676e`) — ACCEPT

**Implementation.** `LeverCardWidget` gains four optional `double?` params (`actualCPLH`, `opzCeilingCPLH`, `actualSPLH`, `opzCeilingSPLH`). When a `cplh_*` or `splh_*` row is present in the dollar attribution AND its actual exceeds the OPZ ceiling, the row label appends ` : team was stretched`. `variance_this_week_tab.dart` and `week_detail_screen.dart` wire the params from `WeekData` and `WeekRecord` respectively. Honest fallback when params are null (legacy widget tests stay green).

**Tests.** `test/widgets/lever_card_test.dart` extended with branch coverage for both adornment-on and adornment-off paths. Em-dash grep on `lib/widgets/lever_card.dart` PASSES.

**Bold by Design alignment.** Honors ch. 10 ("when productivity is too high"): `+$32 cplh : team was stretched` makes the workload cost of the favorable-looking dollar visible inline.

**Verdict: ACCEPT.**

### `7.58.cross-axis.0` — engine + 4-cell catalog (`e2ad5a9`) — ACCEPT

**Implementation.** New `lib/data/cross_axis_pair_catalog.dart` with exactly the 4 locked entries the contract names (`cplhBelowSplhAbove`, `cplhOnSplhBelow`, `cplhAboveSplhBelow`, `bothBelow`) plus `CrossAxisPairs.all`. New `lib/models/cross_axis_pair_record.dart` carries `pairId`, `count`, `topDayparts`. `HistoryTeachingAnalyzer.summarize` extended with a (week, daypart) bucket detector that classifies into a pair cell only when both axes fired; counts + ranks per-cell pairs and returns them as `crossAxisPairs` ordered by count descending. `LearnTeachingSummary` threads the new field.

**Tests.** `test/services/history_cross_axis_pattern_test.dart` PASSES across single-axis-only fixtures (empty result), CPLH-below + SPLH-above pair counting, tie-break determinism, and em-dash grep on the catalog file.

**Boundary.** Single-axis path (`mostCommonLeakId` etc.) is byte-identical pre/post — the cross-axis layer is purely additive. `LaborModel.determineLever` is not consulted by the new detector; the detector reads `HistoryPatternRecord.leverId` which already came from `determineLever`.

**Verdict: ACCEPT.**

### `10.5.6` — OPZ matrix grid + cross-axis sub-label (`0811255`) — ACCEPT

**Implementation.** New `lib/widgets/opz_matrix_grid.dart` 3×3 grid (CPLH rows: above-ceiling / in-OPZ / below-floor; SPLH columns: low / on / high). Active cell highlighted; nine dim cells when SPLH input is null. `ShiftDashboardReadModel.buildWholeDay` extended with `splhState` classifier (±5% tolerance) and a cross-axis-aware `_computeOpzSubLabel` that swaps to the joint Jim Taylor diagnosis when CPLH and SPLH disagree. `ZoneStatusCard` renders the matrix and the sub-label inside the same Container — preserves the single-tile constraint.

**Tests.** `test/widgets/opz_matrix_grid_test.dart` PASSES. `test/shift_dashboard_notifier_test.dart` PASSES (regression). `test/shift_fact_builder_test.dart` PASSES (regression — engine math untouched).

**Sub-label content.** Four cross-axis cells use the contract-locked phrasing:
- CPLH below + SPLH above: `Below OPZ floor. Team executed. Volume problem, not staffing. Fix the forecast.`
- CPLH above + SPLH below: `Above OPZ ceiling AND kitchen slowed. Pull ticket times before adding hours.`
- CPLH on + SPLH below: `In OPZ. PPA dropped. Watch upselling.`
- CPLH on + SPLH above: `In OPZ. Kitchen running strong. Document this shift.`

Single-axis fallbacks unchanged. Em-dash grep PASSES on operator-facing literals.

**Verdict: ACCEPT.**

### `7.58.UX.7+9` — Learn coverage + carousel swap (`8ff955c`) — ACCEPT

**Implementation.** `_LeakSnapshotCard` appends `Repeated <count> of last <coverageCount> <pluralized daypart>` (joined by middot) when `coverageCount > 0`; honest fallback when 0. The Recurring Leak carousel data resolver swaps from `LeverCards` to `CrossAxisPairs` when `crossAxisPairs.first.count >= 3 AND > primaryLeakCount`. Same 4-card walk in both branches.

**Tests.** `test/screens/variance/variance_learn_tab_depth_test.dart` PASSES across single-axis branch, cross-axis branch, 4-card-structure invariant, swap-predicate gating, and em-dash hygiene grep.

**Bonus.** Slice scrubbed two pre-existing operator-facing U+2014 placeholders to honor the depth wave's em-dash ban — em-dash grep on `variance_learn_tab.dart` PASSES on operator-facing literals.

**Verdict: ACCEPT.**

## Test runs

```
flutter test test/widgets/dollar_impact_card_depth_test.dart \
             test/widgets/lever_card_test.dart \
             test/widgets/opz_matrix_grid_test.dart \
             test/services/history_cross_axis_pattern_test.dart \
             test/screens/variance/variance_learn_tab_depth_test.dart
  -> 69 / 69 PASS

flutter test test/variance_visual_widget_test.dart                        -> 21 / 21 PASS
flutter test test/variance_learn_history_coverage_test.dart                -> regression PASS
flutter test test/variance_learn_history_parity_test.dart                  -> regression PASS
flutter test test/lever_logic_test.dart                                    -> regression PASS
flutter test test/labor_model_dollar_attribution_test.dart                 -> 28 / 28 PASS
flutter test test/fixture_lever_roundtrip_test.dart                        -> regression PASS
flutter test test/shift_fact_builder_test.dart                             -> regression PASS
flutter test test/shift_dashboard_notifier_test.dart                       -> regression PASS

flutter test test/variance_history_widget_test.dart                        -> 70 / 70 PASS
                                                                              (post follow-up `3154679`,
                                                                              PR #144 — three legacy
                                                                              footer assertion blocks
                                                                              aligned to new triplet)
```

Total (post follow-up): 69/69 new depth-wave tests PASS; full regression including `variance_history_widget_test.dart` 70/70 PASS. Wave closed 2026-05-05 on master @ `699a45f`.

## Architectural compliance audit

| Rule | Verdict | Evidence |
|---|---|---|
| Core app logic preserved | ✅ | `LaborModel.determineLever`, `theoreticalLaborPct`, `attributeDollarImpactByAxis`, `ShiftFactBuilder.fromClosedShiftInput` all signature-stable. |
| Concern A (TPV immutability) | ✅ | Untouched by every depth-wave commit. |
| Layer 6 (forecast is F&F-computed) | ✅ | Zero `vendorProvidedForecast` references anywhere under `lib/`. |
| Persistence schema unchanged | ✅ | Zero migrations in the wave. |
| No new chrome at the tab level | ✅ | Every change lives inside an existing component (DOLLAR IMPACT footer, lever card row, OPZ tile, Learn snapshot, Learn carousel resolver). The matrix grid is a NEW widget BUT lives inside the existing OPZ tile per the contract addendum's tab-ownership rule. |
| No copy duplicated across tabs | ✅ | OPZ matrix on Shift Dashboard only; coverage caption on Learn only; Best Possible on DOLLAR IMPACT only; row adornment on lever card only. History tab unchanged. |
| Em dash ban on operator-facing literals | ✅ | Grep across every modified + new file file-private to operator-facing strings: zero hits. (Comments and dartdoc retain em dashes — those are not operator-facing per the contract scope.) |
| Walkthrough at click-path bar | ✅ | All 5 walkthroughs landed: 7.58.UX.6 / 7.58.UX.7 / 7.58.UX.8 / 7.58.UX.9 / 10.5.6. |

## Honest summary

The Phase 7.58 depth wave landed cleanly. Bold by Design + Jim Taylor depth now surfaces structurally inside the existing chrome operators already navigate: the math floor lives on the DOLLAR IMPACT card; the OPZ matrix lives on the Shift Dashboard; the OPZ-aware row lives on the lever card; the cross-axis pair pattern lives in the Learn carousel; the coverage denominator lives on the Learn snapshot. Tab ownership is preserved (no concept duplicated); core app logic is untouched (engine math, persistence, sync, Concern A, Layer 6 all stable). The single bounded follow-up (legacy widget-test assertions in `variance_history_widget_test.dart`) closed via `3154679` / PR #144; suite is 70/70 PASS.

**Phase 7.58 closes as advisor-depth-complete on master @ `699a45f`.**
