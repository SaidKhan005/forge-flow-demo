# Phase 7.55o - Deep Extraction Follow-Up

Assessed: 2026-04-24  
Status: complete through `7.55o.6`  
Relationship: supersedes the earlier extraction analysis; archived copy retained for reference

## Why This Exists

The first `7.55o` analysis correctly identified the two biggest files:

- `lib/screens/variance_report.dart`
- `lib/infrastructure/persistence/sqlite/sqlite_database.dart`

After a deeper code pass, that is still directionally right, but it is now too
narrow for the amount of engineering friction in the repo.

If we only split `variance_report.dart` and maybe `sqlite_database.dart`, we
will still be left with several medium-large, mixed-concern screens that create
merge drag and make the next waves of work slower than they need to be.

This follow-up captures:

1. what the original analysis got right
2. what it under-scoped
3. what should actually be sequenced inside `7.55o`

---

## Current Hotspots (2026-04-24 refresh)

### Production files

| File | Lines | Classes | Read |
|---|---:|---:|---|
| `lib/screens/variance/variance_this_week_tab.dart` | 1733 | 17 | extracted This Week implementation from `7.55o.2`; still dense but now tab-local rather than route-shell mixed |
| `lib/data/legacy_fixture_data.dart` | 1784 | 20 | huge bridge/config file, but not a simple extraction target |
| `lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart` | 732 | 0 | extracted SQLite migration helpers from `7.55o.6` |
| `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` | 625 | 0 | extracted SQLite seeding / replay-reset helpers from `7.55o.6` |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | 409 | 2 | lifecycle / public API shell after `7.55o.6` |
| `lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart` | 378 | 0 | extracted SQLite schema helpers from `7.55o.6` |
| `lib/screens/settings/settings_wage_authority_section.dart` | 1042 | 15 | extracted wage authority/editor surface from `7.55o.4`; large but responsibility-local |
| `lib/screens/settings/settings_data_sections.dart` | 564 | 8 | extracted data status / mock replay / data management / audit wrapper from `7.55o.4` |
| `lib/screens/settings_screen.dart` | 226 | 2 | Settings route shell and section dispatch after `7.55o.4` |
| `lib/screens/baseline_manager_screen.dart` | 250 | 2 | Baseline Manager route/state/dispatch shell after `7.55o.5` |
| `lib/screens/schedule_builder.dart` | 609 | 9 | Plan screen composition/rendering shell after `7.55o.3` |
| `lib/screens/schedule/schedule_forecast_notifier.dart` | 530 | 1 | extracted locked-plan notifier and allocation helpers from `7.55o.3` |
| `lib/screens/shift_dashboard.dart` | 750 | 14 | screen shell plus many local sections/helpers |
| `lib/screens/baseline_tracker.dart` | 634 | 5 | benchmark UI still carries local presentation structure |
| `lib/screens/variance/variance_learn_tab.dart` | 599 | 11 | extracted Learn implementation from `7.55o.2` |
| `lib/screens/variance/variance_history_tab.dart` | 531 | 7 | extracted History implementation from `7.55o.2` |
| `lib/screens/week_detail_screen.dart` | 363 | 2 | shared comparison-table primitives extracted in `7.55o.1` |
| `lib/screens/variance_report.dart` | 59 | 1 | shell-only route / tab dispatch after `7.55o.2` |

### Structural import pressure

| File / seam | Current signal |
|---|---|
| `sqlite_database.dart` | imported by 42 files across `lib/` and `test/` |
| `legacy_fixture_data.dart` | imported by 28 files in `lib/` |
| comparison-surface primitives | `ComparisonGroupBand` and `ComparisonMetricRow` now shared across Variance and Week Detail; Benchmark reuse remains optional later |

## What Already Landed Since The First 7.55o Note

The refactor lane is not starting from zero anymore. These shared pieces are
already extracted and should be treated as landed infrastructure, not
re-opened work:

- `lib/widgets/app_screen_header.dart`
  - `AppScreenHeader`
  - `FadingHeaderShell`
- `lib/widgets/sticky_section_delegate.dart`
  - shared `SectionLabel`
  - shared sticky header delegate
- `lib/widgets/dollar_impact_card.dart`
  - shared Variance / Week Detail dollar-impact widget
- `lib/widgets/comparison_group_band.dart`
  - shared comparison group band for Variance / Week Detail
- `lib/widgets/comparison_metric_row.dart`
  - shared comparison metric row for Variance / Week Detail
- `lib/screens/variance/`
  - `ThisWeekTab`
  - `HistoryTab`
  - `LearnTab`
  - `VarianceChip`
  - `variance_report.dart` is now a shell-only route / tab dispatcher
- `lib/screens/schedule/`
  - `ScheduleForecastNotifier`
  - `ScheduleLockedPlanLoadState`
  - `ScheduleDayView`
  - `ScheduleDaySubrow`
  - `schedule_builder.dart` remains the Plan screen composition/rendering
    shell
- `lib/screens/settings/`
  - shared settings card/action primitives
  - data status / mock replay / data management / audit wrapper sections
  - read-only timing authority section
  - wage authority summary + whole-mix editor section
  - `settings_screen.dart` remains the Settings route shell and section
    dispatcher
- `lib/screens/baseline_manager/`
  - shared Baseline Manager date / lever helpers
  - preview model + preview panel
  - calendar grid
  - day detail + candidate tiles
  - clear-all and bottom action bars
  - `baseline_manager_screen.dart` remains the route, draft-state, and
    target-cycle write dispatcher
- `lib/infrastructure/persistence/sqlite/`
  - `sqlite_database.dart` is now the lifecycle / public-API shell
  - `sqlite_database_schema.dart` owns schema helper functions
  - `sqlite_database_seed.dart` owns seed / replay reset helper functions
  - `sqlite_database_migrations.dart` owns migration helper functions

That means the completed `7.55o` work became less about inventing a shell
system and more about:

- shrinking the still-monolithic screens
- moving local widgets / helpers / view models to better file boundaries
- preserving the already-landed source-truth seams while doing so

---

## What The Original 7.55o Analysis Got Right

### 1. `variance_report.dart` was the first extraction target

`7.55o.2` accepted this split. The route file is now a 59-line shell, and the
dense tab implementations live under `lib/screens/variance/`:

- This Week tab
- History tab
- Learn tab
- shared variance chip helper

The original recommendation has landed and should not be reopened as part of
later cleanup.

### 2. `sqlite_database.dart` was correctly deferred until after Variance

`7.55o.6` accepted the SQLite split after the higher-friction screen files
were already carved apart. The main file is now a 409-line lifecycle /
public-API shell, with schema, seed, and migration bodies moved to same-library
part files.

The original priority call remains correct in hindsight:

- **split Variance first**
- **split SQLite later**
- keep schema text, migration order, seed output, and reset entrypoints stable

---

## What The Original 7.55o Analysis Under-Scoped

## 1. `baseline_manager_screen.dart` decomposition has landed

`7.55o.5` closed the Baseline Manager screen split:

- `baseline_manager_screen.dart` is now the route, draft-state, and write
  dispatcher
- date / lever helpers live in
  `lib/screens/baseline_manager/baseline_manager_helpers.dart`
- `ManagerOverridePlanPreview` and preview widgets live in
  `baseline_manager_preview.dart`
- calendar grid, day detail / candidate tiles, and action bars live in their
  own responsibility files

The split preserved selection semantics, candidate truth, date-window logic,
preview formulas, labels, keys, empty states, and the target-cycle write path.

Assessment:

- accepted as `7.55o.5`
- the reported `baseline_override_propagation_test.dart` failure is tracked as
  pre-existing and not caused by the structural split

## 2. `schedule_builder.dart` non-screen logic has been split

`7.55o.3` closed the main separation-of-concerns seam:

- `ScheduleForecastNotifier` now lives in
  `lib/screens/schedule/schedule_forecast_notifier.dart`
- schedule day/daypart view models now live in
  `lib/screens/schedule/schedule_view_models.dart`
- `schedule_builder.dart` remains the Plan screen composition/rendering shell

The extracted notifier still owns locked-plan load state, service-period
fallback loading, and allocation helpers. Those behaviors remain unchanged and
should not be reopened inside post-`7.55o` cleanup work.

Assessment:

- accepted as `7.55o.3`
- no further schedule split was queued in the completed `7.55o` sequence

## 3. `settings_screen.dart` surface split has landed

`7.55o.4` closed the Settings screen split:

- `settings_screen.dart` is now the route shell and section dispatcher
- shared Settings card/action primitives live in
  `lib/screens/settings/settings_shared_widgets.dart`
- data status, mock replay, data management, and audit wrapper sections live in
  `lib/screens/settings/settings_data_sections.dart`
- read-only timing authority display lives in
  `lib/screens/settings/settings_timing_authority_section.dart`
- wage authority summary and whole-mix editor live in
  `lib/screens/settings/settings_wage_authority_section.dart`

The split preserved data actions, wage-authority writes, timing display,
audit-panel behavior, labels, section order, and refresh semantics.

Assessment:

- accepted as `7.55o.4`
- editable restaurant timing + service-period writes still belong to `10a`

## 4. Shared primitives are now past the first extraction pass

The first note correctly called out shared-surface duplication. Since then,
the core reusable pieces have landed:

- `SectionLabel` is now shared through `sticky_section_delegate.dart`
- `DollarImpactCard` is now shared through `widgets/dollar_impact_card.dart`
- app-shell header primitives are shared through `app_screen_header.dart`
- `ComparisonGroupBand` is now shared through `widgets/comparison_group_band.dart`
- `ComparisonMetricRow` is now shared through `widgets/comparison_metric_row.dart`

What `7.55o.1` closed:

- duplicated `_GroupBand` definitions in Variance and Week Detail
- duplicated `_TableRow` definitions in Variance and Week Detail
- the Variance / Week Detail row-padding difference via an explicit shared
  `verticalPadding` parameter

What can still be considered later:

- moving the sticky comparison column header into a dedicated file if it
  becomes useful during the Variance shell split
- reusing comparison primitives in Benchmark only if the API stays clean

## 5. `shift_dashboard.dart` is not first-tier, but it is not tiny anymore

At 750 lines, this file is still workable, but it already has:

- header
- live clock
- outputs
- inputs
- empty state
- labor card
- labor variance section
- shared section headers

It is not the first file I would split, but it will benefit from:

- shared section/header extraction
- moving some section widgets into `widgets/` or `screens/shift/`

Assessment:

- medium priority
- do this only after shared primitives and bigger mixed-concern files

## 6. `legacy_fixture_data.dart` is large, but should not be treated like a normal extraction job

This file is 1784 lines and imported in 28 runtime files, but it is not just
"one big screen."

It still holds:

- compatibility bridge data
- lever cards
- benchmark helper values
- fixture-era config defaults

If we attack it as a pure file-bloat problem, we risk reorganizing the wrong
thing before the remaining bridge/runtime decisions are done.

Better treatment:

- reduce runtime imports over time
- peel off clearly stable concepts (for example lever-card display metadata)
  only when their ownership is settled
- do not make `legacy_fixture_data.dart` a primary `7.55o` extraction target
  unless we are also doing bridge retirement work

## 7. Test bloat is real, but secondary

The largest tests are now substantial:

- `target_cycle_service_test.dart` — 898 lines
- `learn_benchmark_context_service_test.dart` — 817 lines
- `persistence_scope_alignment_test.dart` — 736 lines
- `variance_history_widget_test.dart` — 658 lines

That is worth noticing, but it should be secondary to production-file cleanup.

If addressed later, the goal should be:

- harness extraction
- shared fixture builders
- grouped scenario helpers

not arbitrary test splitting for its own sake.

---

## Recommended 7.55o Sequence (deeper version)

Note after the later UX shell pass:

- shared app-shell/header work is no longer hypothetical
- the sticky/fading header treatment, cross-tab shell cleanup, Learn reskin,
  Plan/Benchmark header-stat cleanup, and Settings visual rework are already
  landed
- the remaining work in the lane stayed focused on file/layer extraction and
  ownership cleanup, not on reopening the already-landed shell redesign

### `7.55o.1` — Shared surface primitives extraction

Accepted 2026-04-24.

Landed:

- extract duplicated section/table primitives shared by Variance and Week Detail
- preserve the existing Variance vs Week Detail row-padding difference
- leave `DollarImpactCard`, sticky headers, and projection/read-service
  behavior untouched

Why this mattered:

- low risk
- high reuse
- makes every later split easier

### `7.55o.2` — Variance shell split

Accepted 2026-04-24.

Landed:

- kept `variance_report.dart` as a 59-line shell + tab dispatcher
- moved This Week, History, and Learn tab implementations under
  `lib/screens/variance/`
- moved the cross-tab chip helper to `variance_shared_widgets.dart`
- kept existing read services and source-truth logic untouched

### `7.55o.3` — Schedule planning surface separation

Accepted 2026-04-24.

Landed:

- kept `schedule_builder.dart` as a 609-line Plan screen shell
- moved `ScheduleForecastNotifier` and locked-plan load state to
  `lib/screens/schedule/schedule_forecast_notifier.dart`
- moved `ScheduleDayView` and `ScheduleDaySubrow` to
  `lib/screens/schedule/schedule_view_models.dart`
- preserved the `schedule_builder.dart` public import surface via exports
- kept resolver formulas, allocation math, fallback behavior, labels, and
  provider wiring unchanged

### `7.55o.4` — Settings surface split

Accepted 2026-04-24.

Landed:

- kept `settings_screen.dart` as a 226-line Settings route shell
- moved shared Settings primitives to `settings_shared_widgets.dart`
- moved data status, mock replay, data management, audit wrapper, hero, and
  footer sections to `settings_data_sections.dart`
- moved read-only timing authority display to
  `settings_timing_authority_section.dart`
- moved wage authority summary, editor state, and wage-mix helper widgets to
  `settings_wage_authority_section.dart`
- kept data actions, dialog/snackbar copy, wage writes, timing display,
  audit behavior, section order, and refresh semantics unchanged

### `7.55o.5` — Baseline Manager decomposition

Accepted 2026-04-24.

Landed:

- kept `baseline_manager_screen.dart` as a 250-line route/state/dispatch
  shell
- moved date and lever helpers to `baseline_manager_helpers.dart`
- moved `ManagerOverridePlanPreview` and preview widgets to
  `baseline_manager_preview.dart`
- moved calendar grid and day-detail/candidate presentation to separate files
- moved clear-all and bottom action bars to `baseline_manager_actions.dart`
- preserved the `baseline_manager_screen.dart` public import surface for
  `ManagerOverridePlanPreview`
- kept selection semantics, candidate truth, date-window logic, preview
  formulas, labels, keys, empty states, and target-cycle write behavior
  unchanged
- one required test failure in `baseline_override_propagation_test.dart` was
  reported and verified by the implementer as pre-existing on `master`

### `7.55o.6` — SQLite bootstrap breakup

Accepted 2026-04-24.

Landed:

- kept `sqlite_database.dart` as a 409-line lifecycle / public-API shell
- moved schema helpers to `sqlite_database_schema.dart`
- moved seed / replay-reset helpers to `sqlite_database_seed.dart`
- moved migration helpers to `sqlite_database_migrations.dart`
- used same-library `part` files so private helper access stayed intact
- kept `schemaVersion`, SQL text, migration order, seed output, reset/reseed
  entrypoints, and public test wrappers unchanged

Verification note:

- the targeted test run reported 224 / 233 passing
- the 9 reported failures were verified by the implementer as pre-existing on
  `master` and unrelated to the structural split

### Optional later follow-up

- large test harness extraction if churn on those tests starts slowing delivery

## Companion Docs Required Before Code Movement

As of the 2026-04-24 audit, `7.55o` now has three companion docs that should
be treated as part of the active refactor lane:

- `phase_7_55o_refactor_non_behavior_change_contract.md`
- `phase_7_55o_verification_matrix.md`
- `phase_7_55o_extraction_ownership_map.md`

Why they are needed:

- the architecture contracts already tell us **what the system means**
- the `7.55o` phase doc already tells us **what files are too big**
- what was missing was the explicit refactor contract for:
  - what must not change
  - how we prove behavior stayed stable
  - which concerns may move vs must stay put

Those companion docs close that gap without introducing a new top-level
architecture lane.

---

## What 7.55o Should Explicitly Not Do

- do not sneak timing/service-period behavior changes into extraction work
- do not use `7.55o` to retire bridge-era truth by accident
- do not relabel product language broadly while extracting structure unless the
  slice explicitly owns copy cleanup
- do not reopen the already-landed shell/header redesign while doing
  engineering hygiene
- do not touch `legacy_fixture_data.dart` aggressively without a separate
  bridge-ownership decision

---

## Bottom Line

The original `7.55o` analysis was right about the direction:

- Variance first
- SQLite later

But the lane is bigger than that now.

The completed practical scope was:

1. shared surface primitives
2. Variance shell split
3. Schedule screen separation
4. Settings split
5. Baseline Manager split
6. SQLite breakup

That sequence now lands the intended extraction lane without changing the
source-truth contracts that were established before it.
