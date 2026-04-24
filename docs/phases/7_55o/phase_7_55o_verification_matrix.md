# Phase 7.55o - Verification Matrix

Updated: 2026-04-24
Status: Active `7.55o` execution guardrail
Owner: `7.55o` extraction lane

## Why This Exists

Refactor slices are only useful if we can prove they did not change runtime
behavior.

This matrix is the minimum verification bar for `7.55o` file extraction and
surface-splitting work.

## Always-Run Guardrails

Run these after any `7.55o` slice that touches runtime `lib/` code:

- `test/current_state_alignment_test.dart`
- `test/target_state_alignment_test.dart`

Add these when the touched slice reaches persistence or replay seams:

- `test/replay_integrity_audit_test.dart`
- `test/persistence_scope_alignment_test.dart`

## Slice Matrix

### `7.55o.1` - Shared surface primitives extraction

Minimum tests:

- `test/variance_history_widget_test.dart`
- `test/variance_visual_widget_test.dart`
- `test/dollar_impact_card_widget_test.dart`

Manual app checks:

- Variance WTD renders unchanged
- Week Detail renders unchanged
- shared section labels still pin / render correctly

### `7.55o.2` - Variance shell split

Minimum tests:

- `test/variance_visual_widget_test.dart`
- `test/variance_history_widget_test.dart`
- `test/wtd_variance_logic_test.dart`
- `test/learn_layer_widget_test.dart`

Manual app checks:

- This Week / History / Learn tabs all render
- Full Week expansion behavior is unchanged
- History tile navigation to Week Detail still works

### `7.55o.3` - Schedule planning surface separation

Minimum tests:

- `test/schedule_builder_widget_test.dart`
- `test/schedule_plan_read_service_test.dart`
- `test/schedule_plan_resolver_test.dart`
- `test/target_consistency_opz_test.dart`

Add when service-period helpers move:

- `test/service_period_definition_resolver_test.dart`

Manual app checks:

- Plan header stats still render
- day rows / chart / labor plan render unchanged
- locked-plan unavailable behavior still degrades honestly

### `7.55o.4` - Settings surface split

Minimum tests:

- `test/settings_screen_widget_test.dart`
- `test/app_data_status_test.dart`

Add when audit panel code moves:

- `test/data_alignment_audit_read_service_test.dart`

Manual app checks:

- Data Status / Mock Replay / Wage Mix / Timing Authority still appear
- audit panel still expands and loads
- action buttons still call the same flows

### `7.55o.5` - Baseline Manager decomposition

Minimum tests:

- `test/baseline_manager_screen_test.dart`
- `test/baseline_manager_service_test.dart`
- `test/baseline_override_propagation_test.dart`
- `test/target_cycle_service_test.dart`

Manual app checks:

- calendar grid still loads
- date drill-in still works
- draft selection / Done / Cancel behavior is unchanged
- plan preview still matches current formulas

### `7.55o.6` - SQLite bootstrap breakup

Minimum tests:

- `test/replay_integrity_audit_test.dart`
- `test/persistence_scope_alignment_test.dart`
- `test/target_cycle_service_test.dart`
- `test/current_state_alignment_test.dart`
- `test/target_state_alignment_test.dart`

Add when timing/bootstrap seams move:

- `test/business_date_authority_service_test.dart`
- `test/weekly_plan_snapshot_service_test.dart`

Manual app checks:

- app boots on the seeded demo DB
- reset/reseed still works
- current state / benchmark / history still load from the same seeded truth

## Test-Selection Rule

If a slice touches more than one hotspot, union the relevant rows above.

Do not use "it was only a file move" as a reason to skip the minimum matrix.

## Final Handoff Requirement

Every `7.55o` slice should report:

- which files moved
- which behavior-critical seams were intentionally left untouched
- which tests were run from this matrix
- whether any behavior bug was discovered and intentionally left out of the
  refactor scope
