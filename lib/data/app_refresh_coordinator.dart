// ─── AppRefreshCoordinator — app-owned refresh / invalidation policy ────────
// Phase 7.55p.4a + 7.55p.4b1
//
// Central seam that owns the local-runtime refresh policy. Three entry points:
//
// 1. refreshAll()  — full manual refresh after Settings actions that do NOT
//    fire the runtime invalidation bus (e.g., wage changes). Refreshes
//    scope, target, demand, and weights directly. Current-state surfaces
//    (week, shift) are NOT refreshed here because the active-target
//    cascade handles them: target.refresh() notifies listeners →
//    ForgeFlowScope's ProxyProvider2 calls refreshCurrentStateSurfaces().
//
// 2. refreshAfterWrite() — called after Settings-triggered writes that
//    fire the AppRuntimeInvalidationBus (reseedDemo, clearAllData,
//    advanceMockReplayDay). Refreshes scope, demand, and weights.
//    Skips target to avoid cascading to current-state through
//    ProxyProvider2, because the bus already handled that refresh.
//
// 3. refreshCurrentStateSurfaces() — canonical shared rule for
//    current-state operational data refresh. This is the single
//    definition of what "current-state surfaces" means. Called by:
//    - ForgeFlowScope's ProxyProvider2 when active target changes
//      or the runtime invalidation bus fires
//
// Current runtime reality:
// - Freshness is reload-driven (user-initiated via Settings actions)
//   plus bus-driven (write completion via AppRuntimeInvalidationBus).
// - Active-target changes cascade to current-state surfaces through the
//   coordinator's ProxyProvider2 wiring in ForgeFlowScope.
// - No timers, no polling, no auto-refresh loops.
// - Notification scheduling is deferred to 7.55p.4d.

import 'active_target_profile_notifier.dart';
import 'demand_forecast_context_notifier.dart';
import 'restaurant_scope_notifier.dart';
import 'schedule_distribution_weights_notifier.dart';
import 'shift_dashboard_notifier.dart';
import 'week_data_notifier.dart';

class AppRefreshCoordinator {
  final RestaurantScopeNotifier _restaurantScope;
  final ActiveTargetProfileNotifier _activeTarget;
  final WeekDataNotifier _weekData;
  final ShiftDashboardNotifier _shiftDashboard;
  final DemandForecastContextNotifier _demandForecast;
  final ScheduleDistributionWeightsNotifier _scheduleWeights;

  /// Cold-start guard: the first `refreshCurrentStateSurfaces()` call is
  /// skipped. ProxyProvider2.update() fires once on initial build before
  /// any real dependency change, and the notifiers already load in their
  /// constructors. This prevents a duplicate refresh on cold start.
  bool _coldStartComplete = false;

  AppRefreshCoordinator({
    required RestaurantScopeNotifier restaurantScope,
    required ActiveTargetProfileNotifier activeTarget,
    required WeekDataNotifier weekData,
    required ShiftDashboardNotifier shiftDashboard,
    required DemandForecastContextNotifier demandForecast,
    required ScheduleDistributionWeightsNotifier scheduleWeights,
  })  : _restaurantScope = restaurantScope,
        _activeTarget = activeTarget,
        _weekData = weekData,
        _shiftDashboard = shiftDashboard,
        _demandForecast = demandForecast,
        _scheduleWeights = scheduleWeights;

  /// Full manual refresh of all app-state surfaces.
  ///
  /// Called after Settings actions that do NOT fire the runtime
  /// invalidation bus (e.g., wage changes). Refreshes scope, target,
  /// demand, and weights directly.
  ///
  /// Current-state surfaces (week, shift) are refreshed via the
  /// active-target cascade: [_activeTarget.refresh()] notifies
  /// ForgeFlowScope's ProxyProvider2, which calls
  /// [refreshCurrentStateSurfaces()]. This ensures week/shift refresh
  /// once per manual refresh, not twice.
  void refreshAll() {
    _restaurantScope.refresh();
    _activeTarget.refresh();
    _demandForecast.load();
    _scheduleWeights.load();
  }

  /// Refresh supporting surfaces after a write that fires the bus.
  ///
  /// Called after Settings-triggered writes (reseedDemo, clearAllData,
  /// advanceMockReplayDay) that already fired
  /// [AppRuntimeInvalidationBus.notifyCurrentStateChanged()].
  /// Refreshes scope, demand, and weights. Skips target to avoid
  /// cascading to current-state surfaces through ProxyProvider2 —
  /// the bus already handled that refresh.
  void refreshAfterWrite() {
    _restaurantScope.refresh();
    _demandForecast.load();
    _scheduleWeights.load();
  }

  /// Canonical rule: refresh surfaces that read current-state operational data.
  ///
  /// This is the single definition of what "current-state surfaces" means.
  /// Called by:
  /// - ForgeFlowScope's ProxyProvider2 when active target changes or the
  ///   runtime invalidation bus fires
  /// - AppShell lifecycle observer on app resume
  ///
  /// The first call is skipped (cold-start guard) because ProxyProvider2
  /// fires update() once on initial build before any real dependency
  /// change, and notifiers already load in their constructors.
  /// Screens and proxy providers do not maintain their own copy of this list.
  void refreshCurrentStateSurfaces() {
    if (!_coldStartComplete) {
      _coldStartComplete = true;
      return;
    }
    _weekData.refresh();
    _shiftDashboard.refresh();
  }
}
