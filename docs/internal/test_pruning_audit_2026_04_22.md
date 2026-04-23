# Test Pruning Audit - 2026-04-22

## Goal

Reduce local test runtime and flake risk without losing behavior coverage.

## Applied in this pass

Completed first-wave pruning in:

- `test/variance_visual_widget_test.dart`
- `test/settings_screen_widget_test.dart`
- `test/learn_layer_widget_test.dart`
- `test/variance_history_widget_test.dart`

Pattern used:

- keep one smoke per screen surface
- keep behavior, persistence, and contract-heavy tests
- gate redundant label/copy-only groups out of the fast local path

This audit favors:

- keeping pure unit and contract tests
- keeping one end-to-end smoke per major screen flow
- deleting or collapsing label-only widget assertions
- moving copy-specific assertions out of the hot path unless they protect a real product contract

## Method

This audit is based on:

- file size and test density across `test/`
- manual inspection of the largest widget files
- inspection of repeated `find.text(...)`, `findsNothing`, scroll helper, and DB setup patterns
- targeted repair work already completed in the variance/settings/schedule suites

I intentionally did **not** continue full-file timing passes after they proved too expensive for local iteration.

## Highest-priority prune targets

### 1. `test/variance_visual_widget_test.dart`

Why it is expensive:

- 927 lines
- 40 widget tests
- many repeated sliver/scroll assertions
- many tests mount the full `VarianceReport` just to prove labels exist

What to prune first:

- Collapse screen chrome tests at lines 59-82 into **one** smoke test that proves the screen mounts and tabs render.
- Collapse section-label tests at lines 90-117 into **one** test that checks the three section headers together.
- Delete most metric-label-only tests at lines 145-197. They prove labels like `Covers`, `PPA`, `CPLH`, `SPLH`, `FOH Hours`, `BOH Hours`, etc. but do not prove behavior.
- Collapse the Dollar Impact framing group at lines 522-566 into a single smoke, because row gating and sign rules already have dedicated coverage in `test/dollar_impact_card_widget_test.dart`.

What to keep:

- the projection-wire tests at lines 643-943
- one focused Full Week expansion smoke at lines 571-620
- the History tab range contract at lines 203-215

Recommended end state:

- reduce from ~40 widget tests to ~10-14

### 2. `test/settings_screen_widget_test.dart`

Why it is expensive:

- 689 lines
- repeated DB reseeding and `runAsync` usage
- custom async pump loops at lines 709-747
- many tests assert copy rather than durable behavior

What to prune first:

- Collapse the status-label matrix at lines 26-101 into **one** parameterized helper or one smoke that checks the section renders and one status state.
- Collapse section-label and timing-label presence checks at lines 108-170 into **one** smoke. The current test asserts `TIMING AUTHORITY`, timezone, and several labels individually.
- Remove copy-only assertions such as the Clear All description at lines 89-101 from the fast suite. Keep that in a slower acceptance bucket if needed.
- Collapse admin-reset copy checks at lines 638-701 into one interaction test. The dialog-open test already proves the important behavior.

What to keep:

- the Data Alignment Audit behavior test at lines 230-270
- one read-only wage-mix panel smoke at lines 280-340
- the real wage-mix persistence tests at lines 350-514 and later save-path tests
- one admin reset interaction test at lines 665-701

Recommended end state:

- split into:
  - `settings_screen_smoke_test.dart`
  - `settings_wage_mix_integration_test.dart`
  - optional slower acceptance tests for copy

### 3. `test/target_consistency_opz_test.dart`

Why it is expensive:

- 692 lines
- mixes pure math/unit coverage with large UI copy snapshots
- heavy `BaselineTracker` label assertions duplicate lower-level OPZ/range tests

What to prune first:

- The giant BaselineTracker copy audit at lines 205-267 should be reduced to a small smoke. It currently asserts many labels and many absences at once.
- The profile/fallback widget tests at lines 357-413 should be collapsed to one "profile wins" test and one "fallback is safe" smoke.
- The recommendation-signal badge tests at lines 430-584 should be simplified. Keep one test per state machine output, but do not assert all surrounding explanatory copy in each case.

What to keep:

- pure OPZ math/unit tests at lines 39-146
- range graph model tests
- shared blended-wage seam tests at lines 604-752

Recommended end state:

- keep the file, but move most widget copy checks into one small `baseline_tracker_smoke_test.dart`

### 4. `test/baseline_manager_screen_test.dart`

Why it is expensive:

- 1092 lines
- many tests mount the full screen for labels, calendar headers, and polish details
- multiple sections test adjacent pieces of the same flow separately

What to prune first:

- Collapse the required-label audit at lines 201-229 into one smoke.
- Collapse day-detail label checks at lines 286-325. One test can prove the detail view renders and lever text is humanized.
- Collapse calendar rendering/navigation tests at lines 639-760. There are multiple tests proving the same screen modes and date-cell presence.
- Remove style-shape assertions like "CLEAR ALL is a bordered button" at lines 1010-1024 from the fast suite.

What to keep:

- Cancel/Done persistence behavior
- once-per-cycle denial SnackBar flow at lines 1216-1245
- one DST-safe calendar correctness test
- one selection-through-calendar integration test

Recommended end state:

- split behavior tests from presentation tests
- keep one full navigation smoke, not many micro-steps

### 5. `test/variance_history_widget_test.dart`

Why it is expensive:

- 884 lines
- mixes:
  - pure `WeekRecord` unit tests
  - `WeekHistoryTile` label tests
  - `WeekDetailScreen` grouped-table rendering
  - `DollarImpactCard` behavior already covered elsewhere

What to prune first:

- Collapse grouped table structure tests at lines 244-289 into one smoke.
- Collapse the per-lever widget rendering loop at lines 443-460. One or two representative lever tests are enough because `LeverCardWidget` already has its own loop at lines 231-242.
- Move Dollar Impact widget behavior out of this file. The frozen-at-close group at lines 901-948 overlaps with `test/dollar_impact_card_widget_test.dart` and should only keep history-specific wiring assertions.
- Remove copy-negative assertions like `Target prorated` absent at lines 492-513 from the fast suite unless that phrase has repeatedly regressed.

What to keep:

- `WeekRecord` provenance and annualized unit tests
- preserved-plan-hours behavior
- one `WeekDetailScreen` smoke that proves section wiring
- one legacy/frozen wiring test for Dollar Impact

Recommended end state:

- split into:
  - `week_record_contract_test.dart`
  - `week_detail_screen_smoke_test.dart`
  - `week_history_tile_test.dart`

### 6. `test/learn_layer_widget_test.dart`

Why it is expensive:

- large number of "label is present" tests after opening the Learn tab
- multiple groups repeat the same assertions (`WIN REPEATS`, `WHAT HELD`, `WHAT TO PROTECT`, etc.)

What to prune first:

- Collapse section-label presence tests at lines 74-145 into one smoke.
- Collapse recurring-leak teaching-label checks at lines 171-186 into one smoke.
- De-duplicate Repeatable Wins assertions across lines 191-220 and 236-275.
- Keep unit policy tests at lines 322-339, but remove duplicate widget-level label checks around them.

What to keep:

- one Learn-tab smoke
- one evidence-row rendering test
- one coaching-scope honesty test
- visibility-policy unit tests

Recommended end state:

- reduce repeated open-tab + label-presence tests aggressively

### 7. `test/shift_visual_widget_test.dart`

Why it is expensive:

- many tests mount the full Shift screen just to prove labels exist
- several tests duplicate the same `pump` sequence

What to prune first:

- Collapse core section checks at lines 132-207 into one smoke.
- Collapse OPZ card presence checks at lines 212-246 into one smoke.
- Collapse metric card existence checks at lines 251-312. Keep the 2dp CPLH formatting test, drop the rest.

What to keep:

- persisted restaurant scope behavior
- live clock seam
- read-model `LABOR %` authority tests
- reservation signal tests at lines 432-450

Recommended end state:

- keep the behavior-specific tests, drop most pure label-presence checks

## Low-risk keepers

These look worth keeping mostly as-is because they are pure logic, data, or contract heavy:

- `test/dollar_impact_card_widget_test.dart`
- `test/target_cycle_service_test.dart`
- `test/baseline_range_logic_test.dart`
- `test/schedule_plan_resolver_test.dart`
- `test/persistence_scope_alignment_test.dart`
- `test/wage_standard_context_service_test.dart`
- `test/weekly_plan_snapshot_service_test.dart`
- `test/business_date_foundation_test.dart`

## Cross-cutting refactor recommendations

### Replace label matrices with one smoke per surface

A large share of the suite currently says:

- mount screen
- pump a few frames
- assert one label

That pattern should become:

- mount screen once
- assert the surface is in the expected state
- assert a small set of anchor labels together

### Prefer unit tests for text mapping and formatting

When the behavior is really "enum/source type maps to display string", prefer pure Dart tests over screen tests.

Examples:

- `WeekRecord.provenanceLabel`
- OPZ/range status labels
- sign/formatting helpers

### Move copy-only assertions out of pre-commit coverage

Tests that exist only to prove wording such as:

- old label removed
- new phrase present
- explanatory paragraph text changed

should not block normal iteration unless the wording is itself a product contract.

### Introduce shared screen-smoke helpers

Several files rebuild the same expensive widget tree repeatedly. A shared helper per screen would allow:

- one mount per group
- fewer duplicated `pump()` calls
- fewer flaky scroll helpers

## Suggested pruning order

1. `test/variance_visual_widget_test.dart`
2. `test/settings_screen_widget_test.dart`
3. `test/learn_layer_widget_test.dart`
4. `test/variance_history_widget_test.dart`
5. `test/target_consistency_opz_test.dart`
6. `test/baseline_manager_screen_test.dart`
7. `test/shift_visual_widget_test.dart`

## Practical target

For local development:

- pre-commit should run `dart analyze` plus changed-file tests and a small smoke set

For CI:

- run the broader focused suite

For slower acceptance coverage:

- keep copy-heavy widget acceptance tests in a separate job or bucket
