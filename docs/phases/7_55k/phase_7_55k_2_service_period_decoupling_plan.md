# Phase 7.55k.2 — Service-Period Decoupling Plan

Updated: 2026-04-12
Owner: Codex planning / Claude implementation
Status: Implemented

## What This Slice Delivers

A concrete decoupling plan that inventories the current identity and
definition seams, proposes minimum neutral model shapes, and documents
the read-service boundary before Phase 10.5.

This is a planning doc. No runtime code changes.

For the broader timing authority around business date, week start,
target-cycle rollover, service-period boundaries, and shift close
semantics, see:

- `docs/contracts/phase_7_55_time_boundary_contract.md`

## 1. Current Identity Seams

### Models that already carry persisted `businessDate`

| Model | Identity fields | Notes |
|-------|----------------|-------|
| `ShiftRecord` | `restaurantId + weekId + dayLabel + daypart + businessDate` | `businessDate` nullable for backward compat with pre-7.55f rows. Persisted in SQLite `shift_records.business_date`. |
| `OpenShiftSnapshot` | `restaurantId + weekId + dayLabel + daypart + businessDate` | `businessDate` required (non-null). Persisted in SQLite `open_shift_snapshots.business_date`. |
| `ReservationBookSnapshot` | `restaurantId + businessDate + daypart` | Already the closest to the target identity. No `weekId` or `dayLabel` — keyed directly on business date + daypart. |

### Models that lack `businessDate`

| Model | Identity fields | Gap |
|-------|----------------|-----|
| `HistoryPatternRecord` | `weekId + dayLabel + daypart` | No `businessDate`. No `restaurantId`. Lightweight signal derived from closed shifts. |
| `WeekRecord` | `restaurantId + weekId` | Week-level aggregate. No daypart. No `businessDate` span. |
| `WeekData` | `weekId` | In-memory WTD aggregate. No daypart. No business-date range. |

### Models with `businessDate` but label-based selection identity

| Model | Identity fields | Gap |
|-------|----------------|-----|
| `BaselineCandidateShift` | `recordKey = '${weekId}\|${dayLabel}\|${daypart}'` + nullable `businessDate` | In-memory view model, not a persisted storage model. Carries `businessDate` copied from `ShiftRecord`, but the durable selection identity (`recordKey`) is still label-based. Selection persistence and draft comparison key on that string. |

### Label-based joins still in use

| Location | Join key | What it does |
|----------|----------|-------------|
| `BaselineManagerService.getCandidateShiftsForDateRange` | `'${weekId}\|${dayLabel}\|${daypart}'` | Builds the selection record key from the shift's label-based identity. Selection persistence and draft comparison key on this string. |
| `BaselineManagerService._sortCandidates` | hardcoded `daypartOrder` map | Sorts candidates by daypart then CPLH. Daypart order is `lunch: 0, dinner: 1, late_night: 2`. |
| `HistoryPatternBuilder.fromClosedShifts` | `weekId + dayLabel + daypart` | Extracts pattern records from closed shifts. The source `ShiftRecord` has `businessDate` but the output `HistoryPatternRecord` drops it. |
| `CurrentWeekState.shiftRecordFromSnapshot` | copies `weekId + dayLabel + daypart` | Converts `OpenShiftSnapshot` into a `ShiftRecord`-compatible shape. Does not set `businessDate` on the output. |
| Variance `_FullWeekSection._buildGroups` | `WeekDayOrder.dayLabels` + `WeekDayOrder.daypartsFor(day)` | Groups Full Week shifts by day label, orders dayparts within each day by the fixture-era `daypartsFor` list. |
| `ScheduleForecastNotifier._resolveDaypartWeights` | `WeekDayOrder.daypartsFor(day)` (fallback) | Falls back to fixture-era daypart IDs when data-driven distribution weights are unavailable. |
| `BaselineData.daypartRanges` | `WeekDayOrder.daypartsFor(day)` | Builds per-daypart statistical ranges from the fixture-era daypart list. |
| `sqlite_database.dart` raw import audit | `'${weekId}_${dayLabel}_${daypart}'` | Used as `source_entity_id` in `raw_import_records` for the import audit trail. Not related to benchmark selection summary persistence (which is cycle-scoped via `target_cycle_id`). |

### Summary

Three persisted models already carry `businessDate`: `ShiftRecord`,
`OpenShiftSnapshot`, and `ReservationBookSnapshot`. Three derived/aggregate
models lack it entirely: `HistoryPatternRecord`, `WeekRecord`, `WeekData`.
`BaselineCandidateShift` carries `businessDate` but still uses a
label-based `recordKey` for selection identity.

The remaining gaps:

- `HistoryPatternRecord` is the primary model gap — it drops
  `businessDate` entirely.
- `BaselineCandidateShift.recordKey` is label-based despite having
  `businessDate` available on the model.
- `CurrentWeekState.shiftRecordFromSnapshot` does not propagate
  `businessDate` from snapshot to output.
- Multiple sort/group helpers key on `weekId|dayLabel|daypart` instead
  of `restaurantId|businessDate|daypart`.

## 2. Hardcoded Service-Period Definition Seams

### `WeekDayOrder.daypartsFor(...)` — The Central Fixture

Location: `lib/data/legacy_fixture_data.dart:1507–1523`

```text
Mon–Thu: ['lunch', 'dinner']
Fri:     ['lunch', 'dinner', 'late_night']
Sat:     ['dinner', 'late_night']
Sun:     ['dinner']
```

This is the single most impactful hardcoded seam. It defines which
dayparts exist on which days and is consumed by:

- Variance `_FullWeekSection._buildGroups` (groups and orders daypart
  rows)
- Schedule `_resolveDaypartWeights` (fallback daypart IDs)
- `BaselineData.daypartRanges` (per-daypart statistical ranges)

There is no `morning` support. Adding `morning` to any day would require
changing this function and all downstream consumers.

### Daypart Label Helpers (duplicated 6 times)

The same `lunch → 'Lunch'` / `dinner → 'Dinner'` / `late_night →
'Late Night'` switch is duplicated across:

| # | Location | File |
|---|----------|------|
| 1 | `ShiftRecord.daypartLabel` | `lib/models/shift_record.dart:227` |
| 2 | `HistoryPatternRecord.daypartLabel` | `lib/models/history_pattern_record.dart:21` |
| 3 | `BaselineCandidateShift.daypartLabel` | `lib/models/baseline_candidate_shift.dart:43` |
| 4 | `ShiftDashboardReadModel._daypartLabel` | `lib/models/shift_dashboard_read_model.dart:298` |
| 5 | `_daypartLabel()` | `lib/screens/schedule_builder.dart:261` |
| 6 | `BaselineData.daypartLabel` | `lib/data/legacy_fixture_data.dart:1295` |

All have a `default` fallback that returns the raw ID, so unknown
dayparts degrade gracefully but are not explicitly supported.

### Daypart Short-Label Helper

| Location | File |
|----------|------|
| `_DaypartChips._abbr()` | `lib/screens/variance_report.dart:752` |

Maps `lunch → 'L'`, `dinner → 'D'`, `late_night → 'LN'`. Default
returns first letter uppercase — `morning` would get `'M'`, which is
ambiguous with day label `'Mon'` in Variance context.

### Daypart Order Maps (duplicated 3 times)

| # | Location | File |
|---|----------|------|
| 1 | `_knownDaypartOrder` | `lib/screens/schedule_builder.dart:272` |
| 2 | `daypartOrder` in `_sortCandidates` | `lib/data/baseline_manager_service.dart:108` |
| 3 | `daypartOrder` in test mirror | `test/baseline_manager_service_test.dart:39` |

All encode `lunch: 0, dinner: 1, late_night: 2`. Unknown dayparts sort
last. `morning` would need index `-1` or `0` to sort before lunch.

### Daypart Cover Weight Fallback

Location: `lib/screens/schedule_builder.dart:255–259`

```text
lunch: 0.45, dinner: 0.40, late_night: 0.15
```

Used when data-driven distribution weights are unavailable. `morning`
would fall back to weight `1.0` — functional but not operationally
tuned.

### Fixture and Replay Assumptions

| Location | What it hardcodes |
|----------|------------------|
| `MockIntegrationReplaySeed.weekSlots` | 14 slots per week: Mon–Thu lunch+dinner, Fri lunch+dinner+late_night, Sat dinner+late_night, Sun dinner. No morning. |
| `MockIntegrationReplaySeed._daypartRatios` | Per-day daypart cover split ratios. No morning. |
| `MockIntegrationReplaySeed._daypartPPAOffset` | PPA offsets by daypart. No morning. |
| `fixture_seed_data.dart` shift slots | Hardcoded shifts and pattern records following the same lunch/dinner/late_night worldview. |

### Where `morning` would fail today

1. `WeekDayOrder.daypartsFor(...)` — does not return `morning` for any
   day
2. `_DaypartChips._abbr()` — `morning` → `'M'`, ambiguous with Mon
3. All 3 daypart order maps — `morning` would sort last (index 99)
4. `MockIntegrationReplaySeed.weekSlots` — no morning slots generated
5. All fixture `_daypartRatios` — no morning ratios

The label helpers degrade gracefully (return raw ID), but operational
tuning (weights, ratios, ordering) would be wrong for `morning`.

## 3. Proposed Minimum Model Shapes

### `ServicePeriodKey`

Neutral identity for any daypart-scoped fact.

```dart
class ServicePeriodKey {
  final String restaurantId;
  final String businessDate;   // ISO 8601 date, e.g. '2026-03-27'
  final String servicePeriodId; // e.g. 'lunch', 'dinner', 'morning'
}
```

Usage:
- closed shift facts
- open shift snapshots
- reservation snapshots
- read-model joins
- history pattern records (replacing `weekId|dayLabel|daypart`)
- benchmark selection keys (replacing `weekId|dayLabel|daypart`)

`weekId` and `dayLabel` remain useful grouping fields. They are not
removed — they just stop being the durable identity for daypart facts.

### `ServicePeriodDefinition`

One entry per configured service period for a restaurant.

```dart
class ServicePeriodDefinition {
  final String id;             // stable key: 'morning', 'lunch', etc.
  final String label;          // 'Morning', 'Lunch', 'Dinner', 'Late Night'
  final String shortLabel;     // 'AM', 'L', 'D', 'LN'
  final int sortOrder;         // 0 = morning, 1 = lunch, 2 = dinner, 3 = late_night
  final String? localStartRule; // e.g. '06:00' — nullable until Phase 10.5
  final String? localEndRule;   // e.g. '11:00' — nullable until Phase 10.5
  final bool rollsOverMidnight; // true for late_night
  final List<int>? applicableWeekdays; // null = all days, [5, 6] = Fri+Sat only
}
```

This shape replaces:
- all 6 duplicated label helpers
- the short-label helper in Variance
- all 3 duplicated daypart order maps
- `WeekDayOrder.daypartsFor(...)` per-day availability
- the `_daypartCoverWeight` fallback (via a separate default weight or
  data-driven weights)

`localStartRule` and `localEndRule` are nullable now — they become
meaningful when Phase 10.5 introduces live timestamp bucketing for the
Shift screen. Until then, service period definitions primarily serve
ordering, labeling, and per-day availability.

### Design constraints

- These shapes are app-owned, not vendor-owned.
- Persistence should be restaurant-scoped in SQLite.
- The default set should match current fixture behavior:
  `morning` (disabled by default), `lunch`, `dinner`, `late_night`.
- Adapters do not own service-period definitions. If a vendor exposes a
  native service-period field, the app maps it to its own definition.
- No configurable service-period settings UI in this phase. A settings
  surface is a later product decision.

## 4. Read-Service Boundary Before Phase 10.5

### Services that should exist before 10.5

| Service | Purpose | Owned by |
|---------|---------|----------|
| `ServicePeriodDefinitionResolver` | Resolves the active set of `ServicePeriodDefinition`s for a restaurant. Replaces all hardcoded label/order/availability helpers. | `7.55k.3` or `7.55k.4` |
| `DaypartPatternSummaryBuilder` | Builds aggregate `DaypartPatternSummary` records from closed `ShiftRecord`s identified by `ServicePeriodKey`. The summary groups by recurring service-period bucket, not by single business date. Replaces `HistoryPatternBuilder` with richer model. | `7.55k.3` |
| `VarianceWeekProjectionReadService` | Builds the Full Week Projection read model with explicit per-row scope labels (closed / open / projected). Replaces mixed widget-helper logic in `_FullWeekSection`. | `7.55k.4` |
| `LearnCoachingReadService` | Builds the Learn coaching read model from `DaypartPatternSummary` + `LearnBenchmarkContext`. Replaces direct frequency analysis in widgets. | `7.55k.6` |

### Principle

No widget should own:
- source-truth decisions (closed vs open vs projected)
- service-period bucketing rules (which timestamps map to which period)
- daypart ordering or label resolution (hardcoded switch statements)
- evidence-gating decisions (minimum sample size, early-signal labels)

Widgets render read models. Read services build them.

### What stays reserved for Phase 10.5

| Service | Purpose | Why 10.5 |
|---------|---------|----------|
| `ShiftServicePeriodReadService` | Tracks the current live service period, switches context as dayparts open/close. | Requires live timestamp bucketing and real-time POS/labor feed. |
| Live time-into-service display | Shows elapsed time within the current service period. | Requires knowing which period is active. |
| Shift primary-driver teaching (per-daypart) | Teaches the lever that matters for the current open service period. | Requires daypart-live truth, not whole-day aggregates. |

`7.55k` may improve closed-history daypart coaching, but it must not
change the Shift dashboard from whole-day to current-service-period
behavior.

## 5. Phase Ownership

| Phase | What it delivered or owns |
|-------|-------------------------|
| `7.55f` | Delivered persisted `businessDate` on closed `ShiftRecord`. V12 migration backfills existing rows. |
| `7.55i` | Established app-owned service-period guidance (not vendor-native dayparts) and timestamp bucketing direction. Retired after `7.55i.3a`. |
| `7.55k.1` | Delivered the daypart scope audit: classified every surface, identified 7 overstatement gaps, created the handoff map. |
| `7.55k.2` | Defines the neutral identity (`ServicePeriodKey`) + definition (`ServicePeriodDefinition`) + read-service boundary plan. (This doc.) |
| `7.55k.3` | Builds `DaypartPatternSummary` model and builder. May introduce `ServicePeriodDefinitionResolver` if needed before `7.55k.4`. |
| `7.55k.4` | Tightens Variance Full Week projection semantics: explicit row-scope labels, per-row status badges, reconciliation. |
| `7.55k.5` | Upgrades History benchmark dayparts from frequency labels to evidence-backed summaries. |
| `7.55k.6` | Upgrades Learn Repeatable Wins with operational proof. |
| `7.55k.7` | Adds interim visibility rules: sample-size gating, early-signal labels, honest empty states. |
| `7.55k.8` | Feeds new endpoint requirements back into `7.55j`. |
| `7.55l` | Delivered `TargetCycle` + `WeeklyPlanSnapshot` runtime architecture. Foundation for locked comparison truth. |
| `7.55m` | Delivered runtime-truth stabilization: date authority, replay contract, Shift time truthfulness, driver parity, OPZ truth, surface cleanup. |
| `10.5` | Owns live daypart-aware Shift, live time-into-service, `ShiftServicePeriodReadService`, and daypart-live driver teaching. |

## 6. Handoff Map

### `7.55k.3` — Daypart Pattern Summary Model (next)

Build the richer `DaypartPatternSummary` from closed `ShiftRecord`s.

`DaypartPatternSummary` is an aggregate summary grouped by recurring
service-period bucket (e.g., "Saturday Dinner"), not a per-date fact.
Source facts feeding the summary are keyed by `ServicePeriodKey`
(`restaurantId + businessDate + servicePeriodId`). The summary itself
aggregates across those facts — its identity is the recurring bucket,
not a single business date.

What to consume from this plan:
- source facts use `ServicePeriodKey`-shaped identity; the summary
  aggregates over those facts and carries exemplar/source references
  back to them
- carry closed shift count, benchmark count, leak count, average
  metrics, and exemplar shift ids
- the builder should accept `ServicePeriodDefinition`s for ordering and
  label resolution instead of hardcoding switch statements
- minimum sample threshold should be a parameter, not hardcoded

What to leave alone:
- do not introduce the full `ServicePeriodDefinitionResolver` yet if a
  simpler static set suffices for `7.55k.3`
- do not change Variance or Learn screens yet

### `7.55k.4` — Variance Full Week Projection Semantics

What to consume from this plan:
- use `ServicePeriodDefinition` for daypart ordering and labels
  (replacing `WeekDayOrder.daypartsFor` in the Full Week section)
- add explicit per-row scope labels (closed / open / projected)
- consider a `VarianceWeekProjectionReadService` to own the mixed-scope
  read model
- fix `CurrentWeekState.shiftRecordFromSnapshot` to propagate
  `businessDate`

### `7.55k.5` — History Benchmark Dayparts Upgrade

What to consume from this plan:
- replace `HistoryPatternRecord` with `DaypartPatternSummary` as the
  evidence source
- show sample count + at least one metric proof alongside daypart labels

### `7.55k.6` — Learn Repeatable Wins Upgrade

What to consume from this plan:
- replace frequency-based wins with `DaypartPatternSummary`-backed
  evidence
- use `ServicePeriodDefinition` for label resolution in coaching copy

### `7.55k.7` — Interim Visibility Rules

Dependencies from this plan:
- requires `DaypartPatternSummary` with sample counts (from `7.55k.3`)
- requires `ServicePeriodDefinition` for label resolution

### `7.55k.8` — Integration Implications

Dependencies from this plan:
- the `ServicePeriodKey` shape defines what endpoint responses must carry
  for app-owned daypart classification to work
- timestamped source facts are the requirement, not vendor-native
  dayparts

### Phase 10.5 boundary

Phase 10.5 explicitly owns:
- `ShiftServicePeriodReadService`
- live daypart-aware Shift screen
- real time-into-service display
- `localStartRule` / `localEndRule` on `ServicePeriodDefinition` becoming
  meaningful for live bucketing
- Shift primary-driver teaching per daypart

`7.55k` must not change the Shift dashboard from whole-day to
current-service-period behavior.

## Files

- `docs/phases/7_55k/phase_7_55k_2_service_period_decoupling_plan.md` (this doc)

## Cross-References

- `docs/phases/7_55k/phase_7_55k_1_daypart_scope_audit.md` — surface classification
  and overstatement gaps
- `docs/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md` — parent
  plan
- `docs/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md` —
  app-owned service-period guidance
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md` — locked
  comparison truth rules
