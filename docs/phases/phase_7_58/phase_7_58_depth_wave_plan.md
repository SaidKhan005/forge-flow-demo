# Phase 7.58 — Depth Wave Plan

Status: Wave CLOSED 2026-05-05 on master @ `699a45f`. All 5 slices ACCEPT (`7.58.UX.6`, `7.58.UX.8`, `7.58.cross-axis.0`, `10.5.6`, `7.58.UX.7+9`). The bounded `7.58.UX.6` follow-up (legacy widget-test assertion alignment in `variance_history_widget_test.dart`) closed via `3154679` / PR #144; `flutter test test/variance_history_widget_test.dart` → 70/70 PASS. Audit verdict: `docs/_execution/2026-05-05_depth_wave_audit.md`.
Owner: Phase 7.58 advisor depth lane (operator-facing teaching surfaces).

Authority (read in this order):

1. `docs/contracts/phase_7_58_primary_driver_contract.md` — Single Source of Truth + Presentation Split + Depth Surfaces (this addendum) bind every depth-wave slice.
2. `docs/Knowledge_graph_docs/Bold By Design.md` (chapters 2 / 5 / 8 / 9 / 10 / 11 / 12) — three-lever framework, OPZ floor + ceiling, productivity curve.
3. `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` (chapters 6 / 7 / 8 / 9) — CPLH × SPLH 2x2 matrix, theoretical labor as math floor, 60-day discipline.
4. `docs/_execution/2026-05-05_outcome_engineering_depth_audit.md` — origin audit; named the 7 gaps this wave closes (minus EWF, deferred to Phase 12).
5. `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt + walkthrough rules.

## Posture

**Core app logic is preserved.** This wave does NOT change:

- `LaborModel.determineLever` signature or thresholds
- `LaborModel.attributeDollarImpactByAxis` (engine math from `7.58.1`)
- `LaborModel.theoreticalLaborPct` (math floor formula)
- `ShiftFactBuilder` / `PostgresShiftRecordWriter` / `VarianceDriverPatternReadService`
- Persistence schema (no migrations)
- Sync seam, RLS, Concern A TPV preservation

This wave ONLY tightens what existing surfaces show by making knowledge-graph depth structural inside existing components. The lever catalog (16 single-axis cards) stays the source of truth; a sibling cross-axis pair catalog parallels it. Each tab keeps its existing job; no chrome is added or removed.

## Goal

Surface six pieces of Bold by Design + Jim Taylor depth that already live in narrative copy or persisted-but-not-rendered fields. Operators read `actual − theoretical` as one number today; after this wave they read it with its math-floor context, OPZ position, cross-axis pair pattern, and pattern coverage denominator visible inside the existing chrome they already navigate.

## Out of Scope (binding)

- **Employee Workload Factor (EWF) modeling** (Bold by Design ch. 8 + 13) — defers to Phase 12. Needs vendor ticket-time + remake-rate data the V1 spine doesn't carry. Documented in the origin audit; not addressed here.
- New tabs, new sections, new tiles, new cards. Each tab keeps the chrome it has.
- Migrations. Every signal reads from already-persisted columns or already-computed fields.
- Engine math changes. Sub-slices consume existing `LaborModel` functions.

## Sub-slice family

Five slices total. Wave A runs 4 file-disjoint worktrees in parallel. Wave B runs 1 sequential slice after Wave A lands (consumes the cross-axis backend from `.cross-axis.0`).

| Slice | Wave | Type | Owns | Effort |
|---|---|---|---|---|
| `7.58.UX.6` | A | renderer | DOLLAR IMPACT footer relabels to `Best Possible / Actual / Closable Gap`; theoretical labor pct named as the math floor it always was. | ~80 LOC |
| `7.58.UX.8` | A | renderer | OPZ-aware adornment on dollar-attribution rows (`+$32 cplh : team was stretched` when actual CPLH crossed the ceiling). | ~150 LOC |
| `7.58.cross-axis.0` | A | engine + catalog | New `lib/data/cross_axis_pair_catalog.dart` with 4 entries (CPLH × SPLH cells). Extends `HistoryTeachingAnalyzer.summarize` to detect recurring pair patterns; new `crossAxisPairs: List<CrossAxisPairRecord>` field on `HistoryTeachingSummary`. | ~600 LOC |
| `10.5.6` | A | renderer | New `_OpzMatrixGrid` widget (3×3, CPLH × SPLH) inside the existing OPZ tile on Shift Dashboard whole-day; cross-axis sub-label resolver swaps single-axis copy when the two axes disagree. | ~250 LOC |
| `7.58.UX.7+9` | B | renderer | Owns `variance_learn_tab.dart` end-to-end this wave. Adds the coverage denominator caption to the leak-snapshot card AND swaps the carousel data source to the cross-axis pair catalog when `.cross-axis.0`'s analyzer surfaces a recurring pair pattern. Shipped as one slice because both touch the same file region. | ~300 LOC |

Total: ~1380 LOC + 5 walkthroughs across 5 slices.

## File-ownership disjointness (Wave A)

| Lane | Files NEW | Files MODIFY |
|---|---|---|
| `7.58.UX.6` | `test/widgets/dollar_impact_card_depth_test.dart`, `docs/_walkthroughs/7.58.UX.6.md` | `lib/widgets/dollar_impact_card.dart` (footer region only) |
| `7.58.UX.8` | `docs/_walkthroughs/7.58.UX.8.md`; widget tests extend existing `test/widgets/lever_card_test.dart` | `lib/widgets/lever_card.dart` (`_DollarAttributionSection` row renderer only) |
| `7.58.cross-axis.0` | `lib/data/cross_axis_pair_catalog.dart`, `lib/models/cross_axis_pair_record.dart`, `test/services/history_cross_axis_pattern_test.dart` | `lib/services/history_teaching_analyzer.dart` (return shape only, additive field) |
| `10.5.6` | `lib/widgets/opz_matrix_grid.dart`, `test/widgets/opz_matrix_grid_test.dart`, `docs/_walkthroughs/10.5.6.md` | `lib/screens/shift_dashboard.dart` (OPZ tile region + sub-label resolver), `lib/models/shift_dashboard_read_model.dart` (`_computeOpzSubLabel` extended for cross-axis case; SPLH state input added) |

Wave A is fully file-disjoint. No serialization rule needed.

Wave B (`7.58.UX.7+9`) owns `variance_learn_tab.dart` after Wave A lands. It consumes the `crossAxisPairs` field from `.cross-axis.0` and the `coverageCount` field already on `LearnTeachingSummary` (shipped by `7.58.3`).

## Frontend exposure (per HP #10)

Operator-facing surfaces touched by this wave:

- `lib/widgets/dollar_impact_card.dart` — `7.58.UX.6` relabel.
- `lib/widgets/lever_card.dart` `_DollarAttributionSection` — `7.58.UX.8` row adornment.
- `lib/screens/shift_dashboard.dart` OPZ tile region — `10.5.6` 3×3 matrix grid + cross-axis sub-label swap.
- `lib/screens/variance/variance_learn_tab.dart` `_LeakSnapshotCard` + carousel resolver — `7.58.UX.7+9` coverage caption + cross-axis swap-in.

Demo-mode walkthroughs at the click-path bar (`docs/_walkthroughs/7.58.UX.5.md` style):

- `7.58.UX.6.md` — DOLLAR IMPACT footer reads `Best Possible: 24.2% · Actual: 31.4% · Closable Gap: +7.2 pts`.
- `7.58.UX.8.md` — `+$32 cplh : team was stretched` row appears when actual CPLH crossed `opzCeilingCPLH` on the demo seed shift.
- `10.5.6.md` — Shift Dashboard whole-day OPZ tile shows the 3×3 matrix with active cell highlighted; cross-axis sub-label reads "Forecast was low. Team executed. Fix the forecast, not the floor." in the demo CPLH-below + SPLH-above scenario.
- `7.58.UX.7.md` (paired walkthrough with `.9`) — Learn snapshot reads `COVERS CAME IN LIGHT · Repeated 6 of last 12 Tue Lunches`; carousel swap demonstrates `FORECAST WAS LOW. TEAM EXECUTED.` headline when the cross-axis analyzer surfaces a recurring pair.

## Hard gates

1. **No core-logic edits.** Every slice that modifies `lib/services/labor_model.dart`, `lib/domain/services/shift_fact_builder.dart`, `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart`, or any persistence module is REJECT. The wave is renderer-side + analyzer-additive only.
2. **No new chrome at the tab level.** A slice that adds a new card / tile / section / tab is FOLLOW-UP NEEDED. Depth surfaces inside existing components.
3. **No copy duplicated across tabs.** OPZ status lives on Shift Dashboard. Coverage denominator lives on Learn. Best Possible / Actual / Gap lives on DOLLAR IMPACT card. Cross-axis pair diagnosis lives in two places (Shift Dashboard sub-label for live; Learn carousel for recurring) and only those two — never on Variance > History or anywhere else.
4. **No em dashes in operator-facing copy** anywhere this wave introduces. Use periods, colons, or middots.
5. **Walkthrough at click-path bar** (per `CODEX_PROMPT_GENERATION_STANDARD.md` "Walkthrough Specificity"). Vague walkthroughs return FOLLOW-UP NEEDED.
6. **Honest fallback** when inputs are insufficient. The matrix grid renders 9 dim cells when SPLH is null (BOH not punched in). Coverage caption omits when `coverageCount == 0`. OPZ adornment only renders when `actualCPLH > opzCeilingCPLH` AND that axis appears in the dollar attribution.

## Dependencies

- `7.58.UX.7+9` depends on `.cross-axis.0` ACCEPT (engine + catalog must exist before the carousel swap can read from it). All other slices are independent.

## Acceptance verdicts

Same shape as `phase_7_58_primary_driver_contract.md`:

- **ACCEPT** — sub-slice satisfies its hard gates, no core-logic edits, walkthrough at the bar.
- **FOLLOW-UP NEEDED** — bounded miss (e.g., walkthrough vague; one widget test missing).
- **REJECT** — engine math touched, new chrome added, copy duplicated across tabs, or em dash leaked into operator-facing string literal.

## Cross-references

- `docs/contracts/phase_7_58_primary_driver_contract.md` "Depth Surfaces" section (this wave's binding addendum).
- `docs/_execution/2026-05-05_outcome_engineering_depth_audit.md` — origin audit + the 7 named gaps.
- `docs/_execution/2026-05-05_8_slice_audit_against_bold_by_design.md` — prior 8-slice audit verdict (all ACCEPT).
- `docs/Knowledge_graph_docs/Bold By Design.md` — chapter authorities cited per slice.
- `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` — CPLH × SPLH 2x2 source.
