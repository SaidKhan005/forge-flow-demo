# Phase 7.55p.4a — App Refresh / Invalidation Policy

Status: Landed

## Goal

Make runtime freshness explicit by introducing one app-owned refresh /
invalidation policy for the current local runtime. Manual refresh and
active-target-driven refresh share one canonical current-state rule
instead of maintaining overlapping lists. The current runtime remains
reload-driven; connector-fed live propagation is deferred to `7.55p.4b`.

## Scope

- In: one shared `AppRefreshCoordinator` that owns the refresh policy;
  `SettingsScreen` routes manual refresh through it; active-target
  dependent refresh cascades through the coordinator's ProxyProvider
  wiring; honest documentation that freshness is still reload-driven
- Out: connector/websocket/polling/auto-refresh loops (`7.55p.4b`);
  stale-threshold redesign; notification scheduling (`7.55p.4d`);
  Shift/Variance business logic changes

## Touched Seams

| File | What changed |
|---|---|
| `lib/data/app_refresh_coordinator.dart` | Central refresh policy: `refreshAll()` for manual actions (does not directly refresh week/shift — relies on cascade), `refreshCurrentStateSurfaces()` as canonical current-state rule |
| `lib/forge_flow_app.dart` | `ForgeFlowScope`: WeekData and ShiftDashboard changed from `ChangeNotifierProxyProvider` to `ChangeNotifierProvider`; coordinator changed from `Provider` to `ProxyProvider<ActiveTargetProfileNotifier>` that calls `refreshCurrentStateSurfaces()` on target changes |
| `lib/screens/settings_screen.dart` | `_refreshAppState()` routes through coordinator instead of manually poking notifiers |
| `test/app_refresh_coordinator_test.dart` | Verifies coordinator touches scope/target/demand/weights directly; verifies week/shift are NOT directly refreshed by `refreshAll()` (cascade-driven); verifies `refreshCurrentStateSurfaces()` is the canonical current-state rule; verifies no auto-refresh behavior |
| `test/settings_screen_widget_test.dart` | Existing tests still pass; no changes needed |

## How the Refresh Policy Works

### Manual refresh (`refreshAll`)

Called by Settings after mock reset, advance day, clear data, or wage
changes. Refreshes scope, target, demand, and weights directly. Does
NOT directly refresh week/shift — those refresh via the active-target
cascade (see below). This avoids double-refreshing week and shift.

### Active-target cascade

When `ActiveTargetProfileNotifier` notifies (from manual refresh or
from `BaselineManagerService.onActiveTargetChanged`), the coordinator's
`ProxyProvider` wiring in `ForgeFlowScope` calls
`refreshCurrentStateSurfaces()`. This is the single path for
active-target → current-state refresh.

### Current-state rule (`refreshCurrentStateSurfaces`)

Canonical definition of which surfaces depend on current-state
operational data: `WeekDataNotifier` and `ShiftDashboardNotifier`.
This method is the one place that defines "current-state surfaces."

## Remaining Gaps

- Current runtime freshness is reload-driven (user-initiated via
  Settings). No auto-refresh, no background polling, no live push.
- Connector-fed live propagation is deferred to `7.55p.4b`.
- Notification scheduling is deferred to `7.55p.4d`.
- `DemandForecastContextNotifier` and
  `ScheduleDistributionWeightsNotifier` are not wired to active-target
  changes. They reload on manual refresh only. Whether target changes
  should cascade into demand/weights refresh is a product decision for
  `7.55p.4b`.
