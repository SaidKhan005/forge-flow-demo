# Metric Card Honesty Contract

Updated: 2026-05-03
Owner: Phase 8 framework lane (lands in `8.0`)
Status: Active authority for every load-bearing metric card across operator dashboards
Companion: `docs/contracts/phase_7_58_primary_driver_contract.md` (lever-id honesty; this doc is its forward extension to metric cards)

## Why This Exists

Phase 7.58 established honesty doctrine for the **Primary Driver lever id**: when no real lever has been computed, the renderer shows `LeverCardNotYetAvailable` instead of falling through to `LeverCards.coversDown`. Lever ids never silently lie.

The same doctrine was never extended to the load-bearing **metric cards** — CPLH, SPLH, PPA, blended wage, covers, hours. Those metrics carry the operator-trust signal:

> Operator logs in and trusts CPLH, SPLH, PPA, and every other metric on screen instantly.

(See `memory/project_one_outcome_anchor.md`.)

Today, when covers data is missing, `lib/domain/services/shift_fact_builder.dart:36` silently renders `PPA = 0.0`. When actual FOH hours is zero, `lib/models/shift_dashboard_read_model.dart:191-192` silently renders `CPLH = 0.0`. The operator cannot tell a real `$0.00` from a broken-fallback `$0.00`. That kills the anchor.

This contract closes that asymmetry.

## Authority Position

- Below `docs/contracts/phase_7_55_architecture_contract.md` Layer 10 (Variance row-status honesty).
- Beside (not above or below) `docs/contracts/phase_7_58_primary_driver_contract.md` — that doc owns lever-id honesty; this doc owns metric-card honesty. They share the doctrine pattern but bind disjoint surfaces.
- Above any UI that renders a metric card, any read service that emits a metric value, and any vendor adapter that produces a fact feeding a metric.

When this doc and a slice doc conflict, this doc wins.

## Scope

The metrics in scope are the load-bearing operator-trust signals across Shift, Variance (This Week / Week Detail / History / Learn), Schedule, and Baseline Manager:

- `actualCPLH`, `targetCPLH`
- `actualSPLH`, `targetSPLH`
- `PPA` (per-person-average; sales / covers)
- `actualCovers`, `forecastCovers`
- `actualFohHours`, `actualBohHours`, `scheduledFohHours`, `scheduledBohHours`
- `avgFohBlendedWage`, `avgBohBlendedWage`, `targetFohWage`, `targetBohWage`
- `actualSales`, `actualLaborDollars`

The doctrine binds future metrics (e.g., labor-cost variance, scheduled-vs-actual delta, prep-time-to-first-cover) the same way: any new metric must declare its `state` + `provenance` and follow the renderer rules below.

Out of scope: lever ids (covered by 7.58). Forecast cards on Schedule (covered by `ForecastDemandSource`; this doc cross-references but does not override).

## State + Provenance

Every metric value carries two pieces of data alongside the number, populated in the read model:

### `state` (closed cardinality)

- `live` — vendor data flowing, all required inputs present, computation is the real number.
- `partial` — some inputs present, some missing or in-flight (e.g., 6 of 8 shifts pulled; webhook sync still running). Computation is the real number for the inputs we have.
- `fallback` — required inputs not exposed by the vendor; we substituted from app forecast or target snapshot. Computation is an estimate, not a real measurement.
- `unavailable` — no inputs present, computation is undefined. The renderer must NOT emit a number.

### `provenance` (open enum)

A free-form short string identifying the data source. Examples (renamed 2026-05-04 for code-level accuracy):

- `vendor_toast` — POS vendor exposed and supplied this metric directly.
- `vendor_lightspeed_lsk` — POS vendor exposed and supplied this metric directly.
- `vendor_square_covers_unavailable_app_forecast_substituted` — POS vendor (Square) does not expose covers; F&F substituted its own app-derived forecast covers. The forecast itself is F&F-computed (per `core_app_architecture.md` Layer 6), never vendor-supplied. This naming makes that explicit.
- `vendor_quickbooks_time_dollars_unavailable_target_wage_substituted` — labor vendor exposed hours but neither dollars nor pay rates; F&F substituted target wage × hours from the operator's locked TargetSnapshot.
- `vendor_quickbooks_time_per_employee_actual_dollars` — labor vendor exposed per-employee actual labor dollars per shift (7shifts, QBT, ADP, Push Operations source class); aggregator summed those directly.
- `vendor_humanity_per_position_actual_dollars` — labor vendor exposed per-position pay rates + observed schedule hours (Humanity, Agendrix source class); aggregator computed actual dollars via rate × hours per role. Per Jim Taylor's model the per-position shape is exactly what `wage_role_rows` consumes — closer to model truth than per-employee, which has to aggregate down to roles anyway.
- `operator_manual_entry_per_daypart` — operator entered the value via the Data Accuracy tab on the operator web console (per `data_accuracy_settings_contract.md`).
- `app_forecast_60_day_avg` — F&F-derived forecast covers from the 60-day historical weekly average.
- `target_snapshot` — value sourced from the locked TargetSnapshot (target wages, target CPLH, etc.).
- `none` — sentinel; required when state == unavailable.

Used by Codex review, debugging tools, and the future advisor (Phase 11b) — not rendered on the operator dashboard except inside the dashboard pill detail sheet.

**Naming rule:** when a metric's value comes from a fallback substitution (vendor doesn't expose the field), the provenance string MUST name the vendor + the unavailable field + the substitution source explicitly. The pattern is: `vendor_<id>_<field>_unavailable_<substitution_source>_substituted`. This prevents future engineers from misreading the string (e.g., `vendor_square_with_forecast_covers` was misread as "Square pushed a forecast" before the rename).

### Required pairing

`state = unavailable` ⟹ `provenance = none`.
`state = live` ⟹ `provenance` names a vendor.
`state = partial` ⟹ `provenance` names the vendor + a partial qualifier.
`state = fallback` ⟹ `provenance` names the substitution source.

## Renderer Rules (operator-facing chrome)

The operator-facing chrome budget for metric honesty is **exactly one element**: the dashboard health pill, top-left, only when any source is non-live.

### Per-metric card

| State | Rendering |
|---|---|
| `live` | The number, clean, brand color, normal weight. Same as today. **No badge, no label, no chrome.** |
| `partial` | The number, clean. Same as `live`. **No card-level chrome.** Degradation is summarized at the dashboard pill, not on the card. |
| `fallback` | The number, clean. Same as `live`. **No card-level chrome.** Degradation is summarized at the dashboard pill, not on the card. |
| `unavailable` | `MetricCardNotYetAvailable` widget (new in `8.0`, mirrors `LeverCardNotYetAvailable` from 7.58). Renders a dash or "Not yet available" in the same card slot. **Never a phantom zero.** |

### Dashboard health pill

One pill, top-left of the dashboard (Shift, Variance, Schedule, Baseline Manager — wherever metric cards render).

- **All sources live across the visible metrics on this dashboard** → no pill rendered. The dashboard reads as it does today.
- **Any source non-live** → pill renders with one short plain-English line summarizing the most-impactful degradation (e.g., `"Square: covers via forecast"`, `"Labor sync 6 of 8 shifts"`, `"Toast: not yet connected"`). Tap the pill → small detail sheet listing each source + state in plain English.

### What is explicitly forbidden as operator chrome

- Inline labels next to numbers (e.g., `"PPA $42.50 · live · Toast"`).
- Per-card dots, icons, or warning glyphs.
- Color-shifted or muted-weight numbers based on state.
- Italics or font-style changes based on state.
- Tooltips that fire on hover/tap of a metric card itself.
- "All live" reassurance pill when fully healthy.

The operator scanning a healthy dashboard sees clean numbers, exactly as today. The pill is the single window into degradation.

### Long-press / detail sheet (optional, opt-in)

A long-press or tap-and-hold on a metric card MAY open a small detail sheet with full provenance for that metric. This is opt-in — never in the operator's default flow. Defer until operator demand justifies the engineering work; do not ship at V1 unless trivially additive.

## Producer Contract (read model)

Every read model that emits a metric value must populate state + provenance:

```dart
// Pseudocode of the producer shape
class MetricValue {
  final double? value;  // null when state == unavailable
  final MetricState state;
  final String provenance;
  // ...
}
```

Concrete file changes (lands in `8.0`):

- `lib/domain/models/metric_provenance.dart` NEW — `MetricState` enum + `MetricProvenance` helper.
- `lib/domain/services/shift_fact_builder.dart` — populate state + provenance on every metric the builder emits. Rules (provenance strings updated 2026-05-04 per the naming rule above):
  - Covers null OR covers == 0 with no vendor coverage → state = `unavailable` for PPA; provenance = `none`.
  - Covers from forecast fallback (vendor doesn't expose) → state = `fallback`; provenance = `vendor_<id>_covers_unavailable_app_forecast_substituted`. The forecast is F&F-computed (per `core_app_architecture.md` Layer 6), never vendor-supplied.
  - Covers from operator manual entry (Data Accuracy tab override per `data_accuracy_settings_contract.md`) → state = `fallback`; provenance = `operator_manual_entry_per_daypart`.
  - Actual labor dollars null → labor-derived metrics (CPLH, blended wage) state = `unavailable`; provenance = `none`.
  - Actual labor dollars present but partial sync → state = `partial`; provenance = `vendor_<id>_partial_sync`.
  - Labor dollars from labor vendor that exposes per-employee actuals (7shifts, QBT, ADP, Push Operations) → state = `live`; provenance = `vendor_<id>_per_employee_actual_dollars`.
  - Labor dollars from labor vendor that exposes per-position rates (Humanity, Agendrix) → aggregator computes actual dollars = rate × scheduled hours per role → state = `live`; provenance = `vendor_<id>_per_position_actual_dollars`. Per-position is closer to the Jim Taylor model truth than per-employee — `wage_role_rows` is per-role-weighted-up, so per-position vendor data populates `wage_role_rows` directly. The wage editor (`settings_wage_authority_section.dart` on mobile + the wage source card on the operator web Data Accuracy tab) surfaces vendor-populated rows for review/override; the post-spine-bridge follow-up `8.wage-editor-seed` ships the review/override UX.
  - Labor dollars derived from target wage × hours fallback (vendor exposes neither dollars nor rates) → state = `fallback`; provenance = `vendor_<id>_dollars_unavailable_target_wage_substituted`.
  - All inputs present → state = `live`; provenance = `vendor_<id>`.
- `lib/models/shift_dashboard_read_model.dart` — same population rules at the dashboard read level.
- `lib/widgets/metric_card_not_yet_available.dart` NEW — empty-state widget. Mirrors `LeverCardNotYetAvailable`.
- `lib/widgets/data_source_health_pill.dart` NEW — top-left pill widget + detail sheet.

## Consumer Contract (renderers)

Every renderer of a metric card switches on state, but the only branch that has visible chrome is `unavailable`:

```dart
// Pseudocode of the renderer shape
Widget render(MetricValue m) {
  if (m.state == MetricState.unavailable) {
    return MetricCardNotYetAvailable(label: m.label);
  }
  return MetricCardWidget(value: m.value);  // Same widget for live/partial/fallback
}
```

The dashboard root widget assembles the health pill from the union of states across the visible metrics. If any metric on the dashboard is non-live, the pill renders. Otherwise, no pill.

## Forbidden Patterns

- A metric card rendering a numeric value when state is `unavailable`. Always `MetricCardNotYetAvailable`.
- A renderer reading a value without consulting state. Always check state first.
- A producer emitting a metric without populating state + provenance. Both fields are required at the read-model boundary.
- A dashboard rendering metric cards without the health pill assembled. The pill (or its absence) is part of the dashboard's contract with the operator.

## Acceptance Criteria for Slices Touching Metrics

A slice touching any metric in scope (or introducing a new one) ships only when:

- [ ] Every metric in scope carries `state` + `provenance` in the read model output.
- [ ] Every renderer that shows the metric switches to `MetricCardNotYetAvailable` when state = `unavailable`.
- [ ] The dashboard root assembles the health pill correctly: absent when all-live, present with one-line summary otherwise.
- [ ] No card-level chrome (dots, icons, labels, muted weights, italics, tooltips) regardless of state.
- [ ] Demo-mode walkthrough exercises at least one `unavailable` and one `fallback` case, with named widgets and named values, per the click-path standard in `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Cross-references

- `docs/contracts/phase_7_58_primary_driver_contract.md` — lever-id honesty (sibling doctrine).
- `docs/contracts/phase_7_55_architecture_contract.md` Layer 10 — Variance row-status honesty (parent constraint).
- `memory/project_metric_honesty_doctrine.md` — durable record of why this doc exists.
- `memory/project_one_outcome_anchor.md` — the operator-trust outcome this contract serves.
- `memory/project_v1_lean_cut_2_2026_05_03.md` — the trim that birthed this doctrine.
- `lib/domain/models/schedule_forecast_demand.dart` — `ForecastDemandSource` enum (cross-references; planning-time provenance, distinct from closed-shift state).
- Phase 8 framework slice `8.0` — the slice that lands the contract's code surface.
