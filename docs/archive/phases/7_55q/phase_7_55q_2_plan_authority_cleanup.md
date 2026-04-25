# Phase 7.55q.2 - Plan Authority Cleanup (Drift 1)

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed (with `7.55q.2-review-fix` follow-up — see below)

## Goal

Remove the second competing current-week live plan authority from
the Schedule surface. Make the in-force current week read the locked
`WeeklyPlanSnapshot` projection — the singular plan-authority object
mandated by `7.55q.1` conformance Rule 1.

## 7.55q.2-review-fix — read-only locked path

The first pass routed `ScheduleForecastNotifier.loadLockedPlan`
through `SchedulePlanReadService.getCurrentLockedWeeklyPlan()`. That
helper still routes through
`WeeklyPlanSnapshotService.getCurrentWeekSnapshot()`, which
**auto-generates** a snapshot from the live plan
(`SchedulePlanReadService.getCurrentWeeklyPlan()`) when none is
persisted. The "locked" path therefore silently fell back to the live
path on cache miss — the second authority Rule 1 forbids was still
present, just hidden behind a label.

The review-fix splits read-only and generate-on-miss explicitly:

- **NEW** `WeeklyPlanSnapshotService.getExistingCurrentWeekSnapshot()`
  — read-only; never generates; returns null if no snapshot is
  persisted for the current week.
- **NEW** `SchedulePlanReadService.getExistingCurrentLockedWeeklyPlan()`
  — projection of the read-only snapshot; never triggers generation.
- `ScheduleForecastNotifier.loadLockedPlan` now calls the read-only
  sibling. Missing snapshot ⇒ `_plan = null` +
  `lockedPlanLoadState = unavailable`. No live fallback, no hidden
  snapshot creation.
- The original auto-generating
  `WeeklyPlanSnapshotService.getCurrentWeekSnapshot()` and
  `SchedulePlanReadService.getCurrentLockedWeeklyPlan()` are
  preserved for the legitimate generation paths (week-roll
  bootstrap, Audit/Shift initial generation, snapshot-service tests)
  with their docstrings now explicitly flagging the auto-generate
  behaviour.

A regression test in `test/schedule_plan_read_service_test.dart`
group `I` deletes only the snapshot row (leaving anchor + demand
intact) and asserts:
- `getExistingCurrentLockedWeeklyPlan()` returns null.
- The `weekly_plan_snapshots` table stays empty after the call (no
  side-effect generation).
- The live `getCurrentWeeklyPlan()` path WAS available — proving
  Schedule chose not to fall back to it.
- The auto-generating `getCurrentLockedWeeklyPlan()` path still
  produces a plan and recreates the snapshot, so the legitimate
  generation flow is preserved.

## Scope

- In: `ScheduleForecastNotifier` — add a `lockedAuthority` factory and
  a `loadLockedPlan()` async load that consumes
  `SchedulePlanReadService.getCurrentLockedWeeklyPlan()`; downgrade
  the existing explicit-input constructor to "test/preview" status;
  rewire the `ScheduleBuilder` proxy provider to the locked path;
  honest degradation when the snapshot is unavailable; focused tests;
  this phase doc
- Out: Variance / Benchmark / History changes (`7.55q.3` /
  `7.55q.4` / `7.55q.5` own those drifts)
- Out: Schedule surface redesign — column layout, planned-package
  wiring, daypart presentation all preserved as-is
- Out: Refresh / boundary / freshness-policy work — out of scope; the
  locked plan is intentionally not reactive to live demand changes
- Out: Manager Override preview path — `resolveFromInputs` remains
  valid for that flow

## Runtime seam

Before (drift):

```
ScheduleBuilder.build (ChangeNotifierProxyProvider3)
   │
   ├── create → ScheduleForecastNotifier.fromProfile(profile, ...)
   │              │
   │              v
   │           SchedulePlanReadService.resolveFromInputs(...)
   │           ↑ second competing live current-week plan authority
   │
   └── update → updateTargets / updateDemandCovers / updateDistributionWeights
                ↑ each path re-ran resolveFromInputs(...) on input change
```

After (`7.55q.2` + `7.55q.2-review-fix`):

```
ScheduleBuilder.build (ChangeNotifierProxyProvider3)
   │
   ├── create → ScheduleForecastNotifier.lockedAuthority(profile, weights)
   │              │
   │              v
   │           SchedulePlanReadService.getExistingCurrentLockedWeeklyPlan()
   │              │              ↑ READ-ONLY — never auto-generates
   │              v
   │           WeeklyPlanSnapshotService.getExistingCurrentWeekSnapshot()
   │              │              ↑ READ-ONLY — never auto-generates
   │              v
   │           projected via WeeklyPlanSnapshotSchedulePlanProjector
   │           ↑ singular in-force current-week plan authority
   │           ↑ missing snapshot ⇒ honest unavailable, NO live fallback
   │
   └── update → updateTargets / updateDistributionWeights / updateDemandCovers
                ↑ in locked mode:
                   - updateTargets only refreshes wages + PPA used by
                     planned-package math; plan stays locked
                   - updateDistributionWeights only affects daypart
                     subrow presentation; plan stays locked
                   - updateDemandCovers is a NO-OP — locked plan does
                     NOT recompute from demand changes
```

Auto-generating paths are still available via
`SchedulePlanReadService.getCurrentLockedWeeklyPlan()` /
`WeeklyPlanSnapshotService.getCurrentWeekSnapshot()` for callers that
explicitly need snapshot creation as a side effect (week-roll
bootstrap, Audit/Shift initial generation). The Schedule production
runtime is no longer one of those callers.

The Schedule UI (`_DerivedSummaryCards`, `_CoverBarChart`, `_DayTable`,
`_PlanSectionLabel`s, planned-package wiring) is unchanged. Only the
authority that supplies the underlying `SchedulePlan` changes.

## Authority modes

`ScheduleForecastNotifier` now carries an explicit authority mode:

| Mode | Constructor | Plan source | Production? |
|---|---|---|---|
| `live` | `ScheduleForecastNotifier(targetCPLH:..., ...)` | `SchedulePlanReadService.resolveFromInputs(...)` | **No** — test / preview only |
| `locked` | `ScheduleForecastNotifier.lockedAuthority(profile:..., ...)` | `SchedulePlanReadService.getExistingCurrentLockedWeeklyPlan()` (read-only, per `7.55q.2-review-fix`) | **Yes** — Schedule production runtime |

The mode is set at construction and is final. There is no mode
transition. In locked mode the notifier never calls
`resolveFromInputs(...)` — that is the structural enforcement of
conformance Rule 1.

The live mode is preserved because:

- many test files construct notifiers from explicit input values
  (`labor_model_boh_sales_test.dart`, `schedule_plan_resolver_test.dart`,
  `schedule_distribution_weights_notifier_test.dart`,
  `schedule_forecast_demand_resolver_test.dart`,
  `target_consistency_opz_test.dart`, this file's group A)
- the Manager Override preview-from-draft-targets flow legitimately
  needs to compute "what would the plan look like with these draft
  targets?" without touching the locked snapshot —
  `resolveFromInputs` is the right tool for that

## Honest degradation

When no current-week snapshot is persisted —
`getExistingCurrentLockedWeeklyPlan()` returns null — the notifier
exposes:

- `_plan == null`
- `lockedPlanLoadState == ScheduleLockedPlanLoadState.unavailable`

This covers two distinct cases honestly:
1. No anchor / no week key resolvable (e.g. fresh device, no mock
   replay state, no closed shift history yet). The read-only
   snapshot lookup never gets to the repo.
2. Anchor present, week key resolvable, but no snapshot persisted
   for that week. The repo lookup returns null. Critically, the
   read path does NOT auto-generate a fresh snapshot from the live
   plan in this case (the `7.55q.2-review-fix` change).

The Schedule UI falls back to its existing "No schedule plan
available" / "No forecast data available" messages. The notifier
MUST NOT fall back to live `resolveFromInputs` and MUST NOT route
through the auto-generating `getCurrentLockedWeeklyPlan()` — both
would silently re-introduce the second authority Rule 1 forbids.

`ScheduleLockedPlanLoadState` enumerates `idle` / `loading` /
`available` / `unavailable` so a future surface (e.g. a refresh
banner) can render distinct messaging without needing to inspect
private state.

## Bootstrap fallback

The proxy provider's `create` callback may run before
`ActiveTargetProfileNotifier` finishes loading. In that brief window
the wages / PPA used by planned-package math are not yet known. The
fallback profile (`_bootstrapFallbackProfile`) supplies config-default
wages (`MeridianConfig.fohWage` / `bohWage`) and config-default PPA
(`BaselineData.derivedTargetPPA`) so the planned-package math has
something honest to render.

The locked-plan load is unaffected by the bootstrap fallback — it
reads the snapshot directly from SQLite. When the real profile
arrives via the `update` callback, `updateTargets` replaces the
fallback wages / PPA without disturbing the locked plan.

## Files touched

| File | Change |
|---|---|
| `lib/screens/schedule_builder.dart` | Added `_ScheduleAuthorityMode` enum, public `ScheduleLockedPlanLoadState` enum, `lockedAuthority` factory, `loadLockedPlan()` method, `isLockedAuthority` / `lockedPlanLoadState` getters, `@visibleForTesting setLockedPlanForTest` injection seam; downgraded the existing constructor to test/preview status (live mode); `updateTargets` / `updateDemandCovers` / `updateDistributionWeights` / `_rebuildPlan` now branch on mode so locked-mode never recomputes the plan; removed the old `fromProfile` factory; `ScheduleBuilder.build` proxy provider now constructs `lockedAuthority` notifiers and calls `loadLockedPlan()`; bootstrap fallback uses `_bootstrapFallbackProfile()` (config-default wages + PPA). **review-fix:** `loadLockedPlan` now calls `getExistingCurrentLockedWeeklyPlan` (read-only) instead of `getCurrentLockedWeeklyPlan` (auto-generate). |
| `lib/data/schedule_plan_read_service.dart` | **review-fix:** added `getExistingCurrentLockedWeeklyPlan()` (read-only sibling of `getCurrentLockedWeeklyPlan`); updated the file-level header and the `getCurrentLockedWeeklyPlan` docstring to honestly flag its auto-generate behaviour. |
| `lib/data/weekly_plan_snapshot_service.dart` | **review-fix:** added `getExistingCurrentWeekSnapshot()` (read-only sibling of `getCurrentWeekSnapshot`); updated `getCurrentWeekSnapshot` docstring to honestly flag its auto-generate behaviour. |
| `test/schedule_builder_widget_test.dart` | Added group D — pure-Dart conformance proof using `setLockedPlanForTest`. D1: constructor sets locked mode + idle state + null plan (no eager `resolveFromInputs`). D2a: locked-mode `updateTargets` does NOT mutate the plan (wages/PPA refresh only). D2b: locked-mode `updateDemandCovers` is a no-op. D2c: locked-mode `updateDistributionWeights` leaves the plan unchanged. D3: honest degradation — null plan coexists with unavailable load state; surface getters degrade honestly. D4: real `ScheduleBuilder.testContent` renders the three section labels with a locked-authority notifier (surface is authority-agnostic). D5: `setLockedPlanForTest` throws on a live-mode notifier (seam is locked-mode only) |
| `test/schedule_plan_read_service_test.dart` | **review-fix:** added group `I` — read-only locked path. Deletes only the `weekly_plan_snapshots` row (anchor + demand intact) and asserts: `getExistingCurrentLockedWeeklyPlan` returns null, no snapshot is recreated as a side effect, the live `getCurrentWeeklyPlan` path WAS available (proving Schedule chose not to fall back), and the auto-generating `getCurrentLockedWeeklyPlan` path still works for legitimate generation callers. |
| `docs/archive/phases/7_55q/phase_7_55q_2_plan_authority_cleanup.md` | **New** — this doc; updated by the review-fix to honestly describe the read-only vs auto-generate split. |

## Files intentionally untouched

| File | Why |
|---|---|
| `lib/domain/models/weekly_plan_snapshot.dart` | No additive helper was needed for this slice |
| `lib/widgets/schedule_day_row.dart` | UI surface — `7.55p.5j` planned-package wiring preserved as-is |
| `lib/screens/baseline_tracker.dart` | Drift 2 — owned by `7.55q.3` |
| `lib/models/week_data.dart` | Drift 3 — owned by `7.55q.3` |
| `lib/data/shift_service.dart` | Drift 4 — owned by `7.55q.4` |
| `lib/screens/variance_report.dart` | Drift 5 — owned by `7.55q.4` |
| `lib/models/week_record.dart` | Drift 6 — owned by `7.55q.5` |
| `lib/screens/week_detail_screen.dart` | Drift 7 — owned by `7.55q.5` |
| Tracker markdown files | Per prompt, no tracker updates in this run |

## What this slice does NOT do

- **Does not delete the live `resolveFromInputs` path.** That path is
  still consumed by Manager Override preview
  (`SchedulePlanReadService.getPreviewPlanFromTargetValues`) and by
  many existing tests through `ScheduleForecastNotifier(...)`. The
  removal is structural — the production runtime no longer routes
  through it for the in-force current week.
- **Does not auto-reload the locked plan when demand changes.** The
  locked plan is locked. If a user / system event invalidates the
  current snapshot mid-week (rare), an external caller can invoke
  `notifier.loadLockedPlan()` to refresh. Auto-reload-on-invalidation
  is a separate concern (the `7.55n.10` boundary refresh / refresh
  coordinator lane already governs cross-week boundary reloads).
- **Does not change planned-package wiring.** `7.55p.5j` planned
  labor package math (week-scope `plannedLaborPackageForWeek`,
  day-scope packages on `ScheduleDayView`, daypart-scope packages on
  `ScheduleDaySubrow`, total row aggregate via `service.aggregate`)
  is preserved exactly. The `_DayTable` and `_DerivedSummaryCards`
  consume the same getters.
- **Does not change daypart subrow allocation.** The presentation
  splits daypart subrows from plan day rows using the same
  `_distributionWeights` / `_resolveDaypartWeights` logic as before.
  In locked mode that input is still routed in via
  `updateDistributionWeights`.
- **Does not touch closed-truth or per-shift locked snapshots.** The
  Rule 4 closed exception (per `7.55q.1`) stays untouched.

## Remaining gaps (handed off to later slices)

- **`7.55q.3`** — Benchmark blended-wage seam (Drift 2) and WTD
  blended-wage seam (Drift 3). Will land one shared cycle-locked
  blended-wage object so Benchmark / WTD / Variance read 1:1.
- **`7.55q.4`** — Variance WTD non-closed and Variance Full Week
  open / projected rows must read benchmark targets from the current
  `ActiveTargetProfile` (not the snapshot's older cycle for non-closed
  rows) and plan-side fields from the locked `WeeklyPlanSnapshot`.
  Closed-row Rule 4 exception stays in force.
- **`7.55q.5`** — History `WeekRecord` / `week_detail_screen`
  conformance: stop re-modeling target hours from actuals, stop the
  unweighted blended-wage average; preserve locked closed truth.
- **Auto-reload of locked plan on snapshot invalidation** — out of
  scope here. Handled by the existing refresh / invalidation lane
  if needed, by an explicit external `loadLockedPlan()` call.
- **Schedule surface decomposition** — `7.55o.3` owns the planning
  surface separation; this slice intentionally keeps Schedule's
  visual structure intact while changing the underlying authority.
