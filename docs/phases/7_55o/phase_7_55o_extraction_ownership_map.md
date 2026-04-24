# Phase 7.55o - Extraction Ownership Map

Updated: 2026-04-24
Status: Active `7.55o` execution guide
Owner: `7.55o` extraction lane

## Why This Exists

The repo already has architecture contracts for truth ownership.

What `7.55o` still needs is a practical extraction map that says:

- what stays in each screen shell
- what is safe to move out
- what should not move yet because another phase owns the behavior

This keeps extraction from accidentally turning into behavior work.

## Ownership Map

### `lib/screens/variance_report.dart`

Shell should keep:

- top-level `VarianceReport` route/screen
- `DefaultTabController`
- shared header / tab dispatch

Safe to move out:

- This Week tab widgets
- History tab widgets
- Learn tab widgets
- duplicated comparison-table primitives that should become shared widgets

Must not change here:

- `VarianceWeekProjectionReadService` semantics
- row-state meaning (`closed`, `open`, `projected`)
- WTD / History / Learn logic ownership

### `lib/screens/schedule_builder.dart`

Shell should keep:

- top-level plan screen composition
- header / scroll structure

Safe to move out:

- `ScheduleForecastNotifier`
- schedule day/daypart view-model classes
- chart / summary / section widgets

Must not change here:

- locked current-week plan authority
- schedule resolver formulas
- service-period fallback behavior except where separately owned by `7.55r`

### `lib/screens/settings_screen.dart`

Shell should keep:

- route/screen scaffold
- top-level manager-facing composition

Safe to move out:

- status section
- mock replay section
- data-management section
- wage-mix section
- timing-authority display section
- audit-panel section wrapper

Must not change here:

- data-management actions
- wage-authority behavior
- timing authority meaning
- audit-panel behavior

### `lib/screens/baseline_manager_screen.dart`

Shell should keep:

- route/screen scaffold
- top-level draft state ownership

Safe to move out:

- calendar grid widgets
- per-day detail widgets
- candidate tile widgets
- footer/action widgets
- preview presentation widgets
- helper/date formatting utilities

Must not change here:

- selection semantics
- target-cycle write path
- candidate-truth behavior
- preview formulas

### `lib/screens/shift_dashboard.dart`

Shell should keep:

- route/screen scaffold
- top-level live-surface composition

Safe to move out:

- output cards
- input cards
- labor section widgets
- empty-state widgets

Must not change here:

- whole-day Shift behavior
- freshness behavior
- target alignment behavior

### `lib/screens/week_detail_screen.dart`

Shell should keep:

- route/screen scaffold
- top-level historical layout

Safe to move out:

- comparison-table primitives
- grouped band widgets
- historical summary sections

Must not change here:

- preserved-history truth
- weighted blended-wage behavior
- frozen dollar-impact semantics

### `lib/infrastructure/persistence/sqlite/sqlite_database.dart`

Shell/file should keep until explicitly split:

- migration ordering
- seeding ordering
- replay reset entrypoints

Safe to move out later:

- grouped migration helpers
- grouped seeding helpers
- bootstrap helper clusters

Must not change here:

- schema behavior
- migration order
- seed output meaning

### `lib/data/legacy_fixture_data.dart`

Not a primary extraction target right now.

Reason:

- still carries compatibility/bridge metadata
- still intersects with other bounded cleanup lanes

Only peel from this file when the ownership of the extracted concept is already
settled.

## Cross-Phase Boundaries

Keep these out of ordinary `7.55o` extraction slices:

- service-period runtime cleanup -> `7.55r`
- audit-panel provenance/drift follow-through -> `7.55r`
- editable timing writes -> `10a`
- live Shift daypart/time-into-service behavior -> `10.5`
- broad bridge-retirement work -> separate scoped follow-up

## One-Sentence Rule

```text
`7.55o` moves screen structure and shared presentation ownership into cleaner
files, while leaving source-truth behavior on the same services, models, and
contracts that already own it today.
```
