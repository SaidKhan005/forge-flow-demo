// Regression — switching the active location must re-scope the data
// surfaces (Shift / Variance / Plan / Benchmark), not just the header.
//
// Defect (operator-reproduced, two symptoms one root):
//   A. Swapping the active location only changed the header / location
//      name; the Shift / Variance / Plan / Benchmark data stayed
//      identical across locations.
//   B. After switching, pull-to-refresh made the data disappear
//      (the switched location had no current-week open shift — SEED
//      side, owned by a sibling worker, not this test).
//
// Root cause (WIRING half — this PR): selecting a location already
// propagates the new `restaurantId` into the scope
// `getActiveRestaurantId()` resolves, but NOTHING told the data
// notifiers to reload. They read scope once (constructor) and
// otherwise only reload on pull-to-refresh, so the header (which
// watches `RestaurantScopeNotifier` directly) updated while the data
// notifiers stayed pinned to the previously-resolved location.
//
// Fix: `_AppShellState` binds a listener to the provided
// `RestaurantScopeNotifier` (the same proven mechanism the demo-mode
// banner uses) and, on a real `activeScope` flip, schedules one
// post-frame `AppRefreshCoordinator.refreshAll()` (the same path
// Settings wage changes use). `refreshAll()` re-scopes scope + active
// target + demand + weights; the active-target -> ProxyProvider2
// cascade then re-scopes the current-state surfaces (week, shift,
// service-period).
//
// This test mounts the real `AppShell` with the production-style
// provider set (including the real ProxyProvider2 cascade body), lets
// the initial cold-start settle, then flips the active location via
// `RestaurantScopeNotifier` and pumps. Asserts: NO framework exception
// (#815 markNeedsBuild-during-build regression guard), every named
// data notifier reloaded WITHOUT a manual pull, a single flip triggers
// exactly one debounced reload, and a repeated same-scope notify is
// deduped while a genuine new location triggers another reload.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/state/app_refresh_coordinator.dart';
import 'package:forge_and_flow/state/app_runtime_invalidation_bus.dart';
import 'package:forge_and_flow/state/demand_forecast_context_notifier.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/schedule_distribution_weights_notifier.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/state/shift_service_period_notifier.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:forge_and_flow/state/week_data_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/repositories/restaurant_scope_repository.dart';
import 'package:forge_and_flow/domain/repositories/shift_record_repository.dart';
import 'package:forge_and_flow/domain/repositories/week_record_repository.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';

// ── Stubs (mirrors test/forge_flow_app_demo_mode_scope_defer_test.dart) ──

class _NullShiftDataSource implements ShiftDataSource {
  const _NullShiftDataSource();
  @override
  Future<WeekData?> getWeekToDate() async => null;
  @override
  Future<List<WeekRecord>> getWeekHistory() async => [];
  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async => [];
  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async => [];
  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async => [];
}

class _FakeScopeRepo implements RestaurantScopeRepository {
  @override
  Future<RestaurantLocation> getOrCreateActiveRestaurant() async =>
      const RestaurantLocation(
        restaurantId: 'test',
        displayName: 'Test',
        businessTimezone: 'UTC',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );
  @override
  Future<String> getActiveRestaurantId() async => 'test';
}

class _FakeWeekRepo implements WeekRecordRepository {
  @override
  Future<List<WeekRecord>> getWeekHistory(String restaurantId) async => [];
  @override
  Future<int> upsertWeekRecord(WeekRecord record) async => 1;
}

class _FakeShiftRepo implements ShiftRecordRepository {
  @override
  Future<List<ShiftRecord>> getShiftsForWeek(
    String restaurantId,
    String weekId,
  ) async => [];
  @override
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
    String restaurantId,
    List<String> weekIds,
  ) async => [];
  @override
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
    String restaurantId,
    String startDate,
    String endDate,
  ) async => [];
  @override
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async =>
      null;
  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async => 1;
}

// ── Tracking notifiers — count reload calls without touching SQLite ──

/// Scope notifier whose active (operator, location) can be flipped
/// synchronously WITHOUT touching SQLite, mirroring
/// `test/forge_flow_app_demo_mode_scope_defer_test.dart`'s
/// `_ScopeSwitchableNotifier`. `_AppShellState` listens to this
/// notifier and reads scope via `activeScope`; `switchScope` ->
/// `notifyListeners()` reproduces exactly what the production
/// `activateBusinessScope` path drives. Also tracks `refresh()` so the
/// `AppRefreshCoordinator.refreshAll()` fan-out can be asserted.
class _ScopeSwitchableTrackingNotifier extends RestaurantScopeNotifier {
  _ScopeSwitchableTrackingNotifier({BusinessScope? activeScope})
      : _scope = activeScope,
        super.fromRestaurant(const RestaurantLocation(
          restaurantId: 'test',
          displayName: 'Test',
          businessTimezone: 'UTC',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
        ));

  BusinessScope? _scope;
  int refreshCount = 0;

  @override
  BusinessScope? get activeScope => _scope;

  void switchScope(BusinessScope scope) {
    _scope = scope;
    notifyListeners();
  }

  @override
  Future<void> refresh() async => refreshCount++;
}

class _TrackingTargetNotifier extends ActiveTargetProfileNotifier {
  _TrackingTargetNotifier()
      : super.fromProfile(const ActiveTargetProfile(
          targetProfileId: 'p',
          restaurantId: 'test',
          sourceType: 'system_baseline',
          targetCPLH: 20,
          targetSPLH: 60,
          targetPPA: 30,
          fohWage: 15,
          bohWage: 18,
          opzFloorCPLH: 15,
          opzCeilingCPLH: 25,
          theoreticalFohLaborPct: 25,
          theoreticalBohLaborPct: 25,
          theoreticalLaborPct: 25,
          builtAt: '',
        ));
  int refreshCount = 0;
  // Mirrors the real ActiveTargetProfileNotifier.refresh(): it always
  // notifyListeners() so the ProxyProvider2 cascade fires. Without the
  // notify the current-state (week/shift) re-scope would not be proven.
  @override
  Future<void> refresh() async {
    refreshCount++;
    notifyListeners();
  }
}

class _TrackingWeekDataNotifier extends WeekDataNotifier {
  _TrackingWeekDataNotifier() : super(const _NullShiftDataSource());
  int refreshCount = 0;
  @override
  Future<void> refresh() async => refreshCount++;
}

class _TrackingShiftDashboardNotifier extends ShiftDashboardNotifier {
  _TrackingShiftDashboardNotifier() : super.emptyForTest(AppDataStatus.noData);
  int refreshCount = 0;
  @override
  Future<void> refresh() async => refreshCount++;
}

class _TrackingShiftServicePeriodNotifier extends ShiftServicePeriodNotifier {
  _TrackingShiftServicePeriodNotifier() : super.fromBuckets(buckets: const {});
  int refreshCount = 0;
  @override
  Future<void> refresh() async => refreshCount++;
}

class _TrackingDemandNotifier extends DemandForecastContextNotifier {
  int loadCount = 0;
  @override
  Future<void> load() async => loadCount++;
}

BusinessScope _locationScope(String operatorId, String locationId) =>
    BusinessScope(
      scopeId: locationId,
      scopeType: 'location',
      operatorId: operatorId,
      locationId: locationId,
      label: 'Loc $locationId',
    );

({
  Widget widget,
  _ScopeSwitchableTrackingNotifier scope,
  _TrackingTargetNotifier target,
  _TrackingWeekDataNotifier week,
  _TrackingShiftDashboardNotifier shift,
  _TrackingShiftServicePeriodNotifier period,
  _TrackingDemandNotifier demand,
  ScheduleDistributionWeightsNotifier weights,
}) _buildHarness() {
  final scope = _ScopeSwitchableTrackingNotifier(
    activeScope: _locationScope('op-1', 'loc-1'),
  );
  final target = _TrackingTargetNotifier();
  final week = _TrackingWeekDataNotifier();
  final shift = _TrackingShiftDashboardNotifier();
  final period = _TrackingShiftServicePeriodNotifier();
  final demand = _TrackingDemandNotifier();
  final weights = ScheduleDistributionWeightsNotifier(
    scopeRepo: _FakeScopeRepo(),
    weekRepo: _FakeWeekRepo(),
    shiftRepo: _FakeShiftRepo(),
  );
  final bus = AppRuntimeInvalidationBus.instance;

  final widget = MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>.value(value: scope),
      Provider<ShiftDataSource>.value(value: const _NullShiftDataSource()),
      ChangeNotifierProvider<ActiveTargetProfileNotifier>.value(value: target),
      ChangeNotifierProvider<WeekDataNotifier>.value(value: week),
      ChangeNotifierProvider<ShiftDashboardNotifier>.value(value: shift),
      ChangeNotifierProvider<ShiftServicePeriodNotifier>.value(value: period),
      ChangeNotifierProvider<DemandForecastContextNotifier>.value(
        value: demand,
      ),
      ChangeNotifierProvider<ScheduleDistributionWeightsNotifier>.value(
        value: weights,
      ),
      ChangeNotifierProvider<AppRuntimeInvalidationBus>.value(value: bus),
      // Production ProxyProvider2 wiring (verbatim from forge_flow_app.dart):
      // an active-target change cascades post-frame to the current-state
      // surfaces through the coordinator.
      ProxyProvider2<
        ActiveTargetProfileNotifier,
        AppRuntimeInvalidationBus,
        AppRefreshCoordinator
      >(
        create: (ctx) => AppRefreshCoordinator(
          restaurantScope: ctx.read<RestaurantScopeNotifier>(),
          activeTarget: ctx.read<ActiveTargetProfileNotifier>(),
          weekData: ctx.read<WeekDataNotifier>(),
          shiftDashboard: ctx.read<ShiftDashboardNotifier>(),
          shiftServicePeriod: ctx.read<ShiftServicePeriodNotifier>(),
          demandForecast: ctx.read<DemandForecastContextNotifier>(),
          scheduleWeights: ctx.read<ScheduleDistributionWeightsNotifier>(),
        ),
        update: (ctx, _, __, previous) {
          final coordinator = previous!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            coordinator.refreshCurrentStateSurfaces();
          });
          return coordinator;
        },
      ),
    ],
    child: const MaterialApp(
      home: AppShell(testDisableDefaultBoundaryEventOutbox: true),
    ),
  );

  return (
    widget: widget,
    scope: scope,
    target: target,
    week: week,
    shift: shift,
    period: period,
    demand: demand,
    weights: weights,
  );
}

void main() {
  testWidgets(
    'active-location switch re-scopes the data surfaces post-frame, '
    'deduped, with no markNeedsBuild-during-build',
    (tester) async {
      final h = _buildHarness();

      await tester.pumpWidget(h.widget);
      // Let the initial mount + the first (cold-start-skipped)
      // ProxyProvider2 cascade settle before the flip.
      await tester.pump();
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'initial mount must not throw',
      );

      // Baseline: no scope flip has happened yet, so the scope-driven
      // refresh path has not run.
      final scopeBefore = h.scope.refreshCount;
      final targetBefore = h.target.refreshCount;
      final weekBefore = h.week.refreshCount;
      final shiftBefore = h.shift.refreshCount;
      final periodBefore = h.period.refreshCount;
      final demandBefore = h.demand.loadCount;

      // Operator switches the active location. AppShell `context.watch`es
      // RestaurantScopeNotifier (business-scope drawer) and listens to
      // it, so `switchScope` -> `notifyListeners()` reproduces exactly
      // what the production `activateBusinessScope` path drives. The
      // re-scope refresh is deferred post-frame (#815-safe).
      h.scope.switchScope(_locationScope('op-2', 'loc-2'));
      await tester.pump(); // run the scheduled post-frame refreshAll()
      await tester.pump(); // run the cascaded post-frame current-state

      expect(
        tester.takeException(),
        isNull,
        reason: 'scope switch must not throw setState/markNeedsBuild '
            'called during build (#815 regression guard)',
      );

      // refreshAll() re-scoped scope + active target + demand + weights
      // WITHOUT a manual pull...
      expect(h.scope.refreshCount, scopeBefore + 1,
          reason: 'scope re-resolved on switch');
      expect(h.target.refreshCount, targetBefore + 1,
          reason: 'active target re-scoped on switch (Plan/Benchmark)');
      expect(h.demand.loadCount, demandBefore + 1,
          reason: 'demand forecast re-scoped on switch');
      // ...and the active-target cascade re-scoped the current-state
      // surfaces (Shift / Variance / service-period) — exactly once.
      expect(h.week.refreshCount, weekBefore + 1,
          reason: 'Variance/week reloaded on switch (no pull)');
      expect(h.shift.refreshCount, shiftBefore + 1,
          reason: 'Shift dashboard reloaded on switch (no pull)');
      expect(h.period.refreshCount, periodBefore + 1,
          reason: 'Shift service-period reloaded on switch (no pull)');

      // Dedupe: re-notifying with the SAME location triggers no
      // further reload (the notifier fires for load / seed / isLoading
      // toggles too, all on the same active scope).
      h.scope.switchScope(_locationScope('op-2', 'loc-2'));
      await tester.pump();
      await tester.pump();
      expect(h.scope.refreshCount, scopeBefore + 1,
          reason: 'same-scope re-notify is deduped (one reload per switch)');
      expect(h.shift.refreshCount, shiftBefore + 1);

      // A genuine new location triggers exactly one more reload.
      h.scope.switchScope(_locationScope('op-3', 'loc-3'));
      await tester.pump();
      await tester.pump();
      expect(h.scope.refreshCount, scopeBefore + 2,
          reason: 'a new location re-scopes again');
      expect(h.shift.refreshCount, shiftBefore + 2);
      expect(
        tester.takeException(),
        isNull,
        reason: 'second switch must not throw',
      );
    },
  );
}
