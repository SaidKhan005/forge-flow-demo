# Phase 7.55o - Deep Extraction Follow-Up

Assessed: 2026-04-24  
Status: active `7.55o` planning follow-up  
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
| `lib/screens/variance_report.dart` | 2991 | 39 | still the largest mixed-concern screen |
| `lib/data/legacy_fixture_data.dart` | 1346 | n/a | huge bridge/config file, but not a simple extraction target |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | 2104 | 2 | monolithic bootstrap/migration/seeding hub |
| `lib/screens/settings_screen.dart` | 2147 | 25 | status, mock replay, data management, wage editor, timing display, audit panel in one surface |
| `lib/screens/baseline_manager_screen.dart` | 1235 | 13 | calendar UI, preview logic, candidate selection, bottom-bar flow all mixed |
| `lib/screens/schedule_builder.dart` | 1163 | 12 | screen + notifier + view models + fallback daypart allocation in one file |
| `lib/screens/shift_dashboard.dart` | 750 | 14 | screen shell plus many local sections/helpers |
| `lib/screens/baseline_tracker.dart` | 634 | 5 | benchmark UI still carries local presentation structure |
| `lib/screens/week_detail_screen.dart` | 453 | 4 | duplicated comparison-table primitives still present |

### Structural import pressure

| File / seam | Current signal |
|---|---|
| `sqlite_database.dart` | imported by 42 files across `lib/` and `test/` |
| `legacy_fixture_data.dart` | imported by 28 files in `lib/` |
| duplicated section/table primitives | repeated across Variance, Week Detail, Benchmark |

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

That means the remaining `7.55o` work is less about inventing a shell system
and more about:

- shrinking the still-monolithic screens
- moving local widgets / helpers / view models to better file boundaries
- preserving the already-landed source-truth seams while doing so

---

## What The Original 7.55o Analysis Got Right

### 1. `variance_report.dart` should still be the first extraction target

That file is still the clearest "developer velocity tax" in the repo:

- 3 tabs
- async loading in multiple local states
- dense UI sections
- duplicated primitives
- mixed surface math/presentation concerns

The core recommendation still holds:

- keep `variance_report.dart` as a shell
- move tab-specific widgets out
- move shared primitives out

### 2. `sqlite_database.dart` is still lower priority than Variance

Even at 1446 lines, it is comparatively coherent:

- schema
- migration routing
- seeding
- mock replay reset helpers

It is big, but it is not as mixed and fast-changing as the Variance screen.

So the priority call remains correct:

- **split Variance first**
- **split SQLite later only if churn continues**

---

## What The Original 7.55o Analysis Under-Scoped

## 1. `baseline_manager_screen.dart` is a real hotspot, not a side note

At 1069 lines, this file is no longer just "large but fine."

It currently mixes:

- draft selection state
- async loading of candidates
- calendar grouping/layout
- plan impact preview model
- per-day detail rendering
- selection affordances
- footer action bars

This is not just widget volume. It is multiple responsibilities in one file.

Recommended shape later:

- `baseline_manager/manager_screen_shell.dart`
- `baseline_manager/calendar_grid.dart`
- `baseline_manager/day_detail.dart`
- `baseline_manager/candidate_tile.dart`
- `baseline_manager/plan_preview_widgets.dart`
- keep preview model logic out of the screen file

Assessment:

- this is a **real** `7.55o` target
- do not leave it out of the lane

## 2. `schedule_builder.dart` is carrying too much non-screen logic

This file is only 775 lines, but it has an important structural smell:

- `ScheduleForecastNotifier` lives inside the screen file
- schedule day/daypart view models live inside the screen file
- fallback daypart allocation helpers live inside the screen file
- widget tree and planning logic are bundled together

That means this is not just visual bloat. It is a separation-of-concerns seam.

Important specific concern:

- the screen file still owns fixture-era fallback daypart allocation via
  `WeekDayOrder.daypartsFor(...)`

That part will be affected by `7.55n`, which is exactly why this should not be
split before timing/service-period work lands.

Recommended later shape:

- move `ScheduleForecastNotifier` out of the screen file
- move schedule day/daypart view models out of the screen file
- keep the screen focused on composition/rendering

Assessment:

- this should be a formal `7.55o` target
- but **after** `7.55n`, not before it

## 3. `settings_screen.dart` is now a multi-tool admin surface

This file is not just "a little long."

It currently mixes:

- data status
- mock replay controls
- destructive data management
- wage fallback editing
- audit panel surface

This creates two problems:

1. engineering friction when touching any one of those concerns
2. product clutter, because a manager-facing surface and a debug/admin surface
   are still sharing one flat page

Recommended later shape:

- `settings/status_section.dart`
- `settings/mock_replay_section.dart`
- `settings/data_management_section.dart`
- `settings/wage_authority_section.dart`
- `settings/audit_section.dart`

Assessment:

- definitely in scope for `7.55o`
- especially because the user has already called out settings organization

## 4. Shared primitives are still incomplete, even though some landed

The first note correctly called out shared-surface duplication. Since then,
some of that work has landed:

- `SectionLabel` is now shared through `sticky_section_delegate.dart`
- `DollarImpactCard` is now shared through `widgets/dollar_impact_card.dart`
- app-shell header primitives are shared through `app_screen_header.dart`

What is still duplicated:

- `_GroupBand`
  - `variance_report.dart`
  - `week_detail_screen.dart`
- `_TableRow`
  - `variance_report.dart`
  - `week_detail_screen.dart`

This means `7.55o.1` should no longer be framed as "extract the first shared
widgets." It should be framed as "finish the comparison-surface kit and stop
leaving the remaining duplicated table/group primitives inside the two
screens."

Recommended primitive set:

- `comparison_column_header.dart`
- `comparison_group_band.dart`
- `comparison_metric_row.dart`

That will remove duplication from:

- Variance
- Week Detail
- Benchmark (partial)

## 5. `shift_dashboard.dart` is not first-tier, but it is not tiny anymore

At 658 lines, this file is still workable, but it already has:

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

This file is 1346 lines and imported in 28 runtime files, but it is not just
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
- the remaining `7.55o` work should therefore stay focused on file/layer
  extraction and ownership cleanup, not on reopening the already-landed shell
  redesign

### `7.55o.1` — Shared surface primitives extraction

Do first.

Targets:

- extract duplicated section/table primitives shared by Variance and Week Detail
- extract shared dollar-impact card
- optionally extract shared small chips/badges if the API can stay clean

Why first:

- low risk
- high reuse
- makes every later split easier

### `7.55o.2` — Variance shell split

Do second.

Targets:

- keep `variance_report.dart` as shell + tab dispatch
- move This Week, History, and Learn tab sections to their own files
- keep existing read services; do not re-internalize truth logic

### `7.55o.3` — Schedule planning surface separation

Do third, after `7.55n`.

Targets:

- move `ScheduleForecastNotifier` out of `schedule_builder.dart`
- move day/daypart view models out of the screen file
- leave service-period fallback rewiring for the already-owned `7.55n` work

### `7.55o.4` — Settings surface split

Do fourth.

Targets:

- split by responsibility
- keep one screen shell
- reduce the current "flat admin wall" feel

### `7.55o.5` — Baseline Manager decomposition

Do fifth.

Targets:

- shell vs calendar vs detail vs preview
- reduce merge conflicts on one of the most stateful screens

### `7.55o.6` — SQLite bootstrap breakup (only if still justified)

Do last, and only if needed.

Targets:

- migrations directory
- seeders directory
- grouped schema files

Reason for deferring:

- stable but large
- lower day-to-day friction than the screen files

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

The deeper practical scope is:

1. shared surface primitives
2. Variance shell split
3. Schedule screen separation
4. Settings split
5. Baseline Manager split
6. SQLite breakup only if still worth it

That sequence better matches the current repo friction and the user's recent
surface concerns about settings, clarity, and maintainability.
