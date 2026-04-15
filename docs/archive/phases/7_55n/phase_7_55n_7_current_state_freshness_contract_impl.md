# Phase 7.55n.7 - Current-State Freshness Contract Implementation

Updated: 2026-04-13
Owner: Claude implementation
Status: Landed

## Goal

Land the shared freshness foundation for current-state surfaces so the app
has one honest, reusable freshness model before adding Shift pull-to-refresh,
updated-age UI, resume refresh, and boundary auto-refresh in later slices.

## Scope

- In: shared freshness model, evaluation service, Shift notifier plumbing,
  age formatting helper
- Out: pull-to-refresh UI (7.55n.8), app lifecycle hooks (7.55n.9),
  boundary auto-refresh (7.55n.10), vendor polling/websockets/timers

## What This Establishes

1. One shared per-surface freshness model (`CurrentStateFreshness` +
   `FreshnessState` enum) with four contract states: live, updated,
   stale, refreshing.

2. One pure evaluation service (`CurrentStateFreshnessService`) with
   injectable `now` and configurable threshold windows. No DB access,
   no singleton, no state. Deterministic and testable.

3. Shift freshness truth on `ShiftDashboardNotifier` via the
   `freshness` getter, evaluated from the latest persisted
   `OpenShiftSnapshot.updatedAt` timestamp.

4. Reusable age formatting (`Fmt.timeAgo(Duration)`) so later UI slices
   can render "Updated just now" / "Updated 3 min ago" without inventing
   widget-local formatting.

5. App-level `AppDataStatus` remains separate and unchanged. Both coexist
   on the notifier: `status` is app-level readiness (24h threshold),
   `freshness` is per-surface data age (5min/2hr thresholds).

## Freshness Thresholds

| State | Shift window | Meaning |
|---|---|---|
| `live` | < 5 min | Data fresh enough to present as current truth |
| `updated` | 5 min - 2 hr | Usable but not live; UI should show age |
| `stale` | > 2 hr | Not current; must not masquerade as live |
| `refreshing` | in-flight | Preserves prior timestamp during revalidation |

Defined as static constants on `CurrentStateFreshnessService`. Future
surfaces (Variance) can call `evaluate()` with wider windows.

## Touched Seams

| File | What changed |
|---|---|
| `lib/models/current_state_freshness.dart` | New. `FreshnessState` enum + `CurrentStateFreshness` value model |
| `lib/services/current_state_freshness_service.dart` | New. Pure evaluation with injectable now/thresholds |
| `lib/data/shift_dashboard_notifier.dart` | Exposes `CurrentStateFreshness? freshness` from `OpenShiftSnapshot.updatedAt` |
| `lib/utils/formatters.dart` | Added `Fmt.timeAgo(Duration)` for age label formatting |
| `test/current_state_freshness_test.dart` | New. Threshold, formatter, refreshing, custom-threshold, model tests |
| `test/shift_dashboard_notifier_test.dart` | Added freshness exposure tests |

## Design Decisions

| Decision | Rationale |
|---|---|
| Freshness nullable on notifier | Null = no current-state data. Avoids inventing a state for "no data." |
| Pure service, not singleton | No DB access, no state. Testable with zero mocking. |
| `age` as getter, not stored | Derived from `evaluatedAt - updatedAt`. Keeps model honest. |
| No `ageLabel` on model | Display formatting belongs to `Fmt.timeAgo()`, not the data model. |
| WeekData freshness deferred | No honest timestamp source exists. `maxClosedDate` is business-date identity, not data freshness. |
| `AppDataStatus` untouched | App-level readiness (24h) is separate from per-surface freshness (5min/2hr). |
| UTC for `now` | Persisted timestamps are UTC (7.55n.6). Notifier uses `DateTime.now().toUtc()`. |

## Remaining Gaps

- Pull-to-refresh UI on Shift (7.55n.8)
- `Updated x min ago` / `Live` labeling on Shift screen (7.55n.8)
- App resume / foreground refresh (7.55n.9)
- Automatic boundary invalidation (7.55n.10)
- WeekData / Variance freshness plumbing: deferred because no honest
  timestamp source exists today. When Variance needs freshness display,
  it can derive from the Shift surface's freshness state (both are
  refreshed by the same `refreshCurrentStateSurfaces()` call via
  `AppRefreshCoordinator`).
- Vendor live-data capability audit (7.55n.12)
