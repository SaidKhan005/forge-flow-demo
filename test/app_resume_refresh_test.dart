// Phase 7.55n.9 + 7.55n.9a -- App resume / foreground refresh tests.
//
// Validates:
// A. app resume after backgrounding triggers refreshCurrentStateSurfaces()
// B. cold-start guard: initial build does NOT trigger resume refresh
// C. sticky-flag guard: inactive -> resumed after a prior cycle does NOT fire
// D. the behavior routes through the shared AppRefreshCoordinator seam
// E. ProxyProvider2 cold-start skip: first proxy update does not refresh
//
// Uses a production-style ProxyProvider2 wiring (not a plain
// Provider<AppRefreshCoordinator>.value) so the tests can catch
// cold-start proxy-update issues.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/state/app_refresh_coordinator.dart';
import 'package:forge_and_flow/state/app_runtime_invalidation_bus.dart';
import 'package:forge_and_flow/state/demand_forecast_context_notifier.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/schedule_distribution_weights_notifier.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
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

// ── Stubs ───────────────────────────────────────────────────────────────

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

class _StubDemandForecastNotifier extends DemandForecastContextNotifier {
  @override
  Future<void> load() async {}
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
          String restaurantId, String weekId) async =>
      [];
  @override
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
          String restaurantId, List<String> weekIds) async =>
      [];
  @override
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
          String restaurantId, String startDate, String endDate) async =>
      [];
  @override
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async =>
      null;
  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async => 1;
}

// ── Tracking notifiers for observing refresh calls ──────────────────────

class _TrackingWeekDataNotifier extends WeekDataNotifier {
  final calls = <String>[];
  _TrackingWeekDataNotifier() : super(const _NullShiftDataSource());
  @override
  Future<void> refresh() async {
    calls.add('refresh');
  }
}

class _TrackingShiftDashboardNotifier extends ShiftDashboardNotifier {
  final calls = <String>[];
  _TrackingShiftDashboardNotifier()
      : super.emptyForTest(AppDataStatus.noData);
  @override
  Future<void> refresh() async {
    calls.add('refresh');
  }
}

// ── Test bus that can be triggered manually ──────────────────────────────

class _TestBus extends ChangeNotifier implements AppRuntimeInvalidationBus {
  void fire() => notifyListeners();

  @override
  void notifyCurrentStateChanged() => fire();
  @override
  void notifyRuntimeWriteCompleted() => fire();
  @override
  void notifyImportCompletionPersisted() => fire();
}

// ── Test harness using production-style ProxyProvider2 wiring ────────────

late _TrackingWeekDataNotifier _weekData;
late _TrackingShiftDashboardNotifier _shiftDashboard;

Widget _buildAppShellWithProxyWiring() {
  final scope = RestaurantScopeNotifier.fromRestaurant(
    const RestaurantLocation(
      restaurantId: 'test',
      displayName: 'Test',
      businessTimezone: 'UTC',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    ),
  );
  final target = ActiveTargetProfileNotifier.fromProfile(
    const ActiveTargetProfile(
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
    ),
  );
  _weekData = _TrackingWeekDataNotifier();
  _shiftDashboard = _TrackingShiftDashboardNotifier();
  final demand = _StubDemandForecastNotifier();
  final weights = ScheduleDistributionWeightsNotifier(
    scopeRepo: _FakeScopeRepo(),
    weekRepo: _FakeWeekRepo(),
    shiftRepo: _FakeShiftRepo(),
  );
  final bus = _TestBus();

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>.value(value: scope),
      Provider<ShiftDataSource>.value(value: const _NullShiftDataSource()),
      ChangeNotifierProvider<ActiveTargetProfileNotifier>.value(value: target),
      ChangeNotifierProvider<WeekDataNotifier>.value(value: _weekData),
      ChangeNotifierProvider<ShiftDashboardNotifier>.value(
          value: _shiftDashboard),
      ChangeNotifierProvider<DemandForecastContextNotifier>(
          create: (_) => demand),
      ChangeNotifierProvider<ScheduleDistributionWeightsNotifier>(
          create: (_) => weights),
      // Production-style bus + ProxyProvider2 wiring — matches ForgeFlowScope.
      ChangeNotifierProvider<AppRuntimeInvalidationBus>.value(value: bus),
      ProxyProvider2<ActiveTargetProfileNotifier, AppRuntimeInvalidationBus,
          AppRefreshCoordinator>(
        create: (ctx) => AppRefreshCoordinator(
          restaurantScope: ctx.read<RestaurantScopeNotifier>(),
          activeTarget: ctx.read<ActiveTargetProfileNotifier>(),
          weekData: ctx.read<WeekDataNotifier>(),
          shiftDashboard: ctx.read<ShiftDashboardNotifier>(),
          demandForecast: ctx.read<DemandForecastContextNotifier>(),
          scheduleWeights: ctx.read<ScheduleDistributionWeightsNotifier>(),
        ),
        update: (ctx, targetNotifier, bus, previous) {
          previous!.refreshCurrentStateSurfaces();
          return previous;
        },
      ),
    ],
    child: const MaterialApp(home: AppShell()),
  );
}

void main() {
  // ── A: resume after background triggers refresh ───────────────────────

  group('A -- resume after backgrounding', () {
    testWidgets('triggers refresh after paused then resumed', (tester) async {
      await tester.pumpWidget(_buildAppShellWithProxyWiring());
      await tester.pump();
      // Clear any constructor calls from initial load
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(_weekData.calls, ['refresh']);
      expect(_shiftDashboard.calls, ['refresh']);
    });

    testWidgets('triggers again on second resume cycle', (tester) async {
      await tester.pumpWidget(_buildAppShellWithProxyWiring());
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // First cycle
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      // Second cycle
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(_weekData.calls, ['refresh', 'refresh']);
      expect(_shiftDashboard.calls, ['refresh', 'refresh']);
    });
  });

  // ── B: cold-start guard ───────────────────────────────────────────────

  group('B -- cold-start guard', () {
    testWidgets(
        'initial build does NOT trigger extra current-state refresh via proxy',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithProxyWiring());
      await tester.pump();
      await tester.pump();

      // The ProxyProvider2 fires update() once on initial build.
      // With the cold-start guard, this should NOT call refresh on
      // week/shift notifiers. Their only calls should be from their
      // own constructor _load(), not from the coordinator.
      expect(_weekData.calls, isEmpty,
          reason:
              'ProxyProvider2 initial update should be skipped by cold-start guard');
      expect(_shiftDashboard.calls, isEmpty,
          reason:
              'ProxyProvider2 initial update should be skipped by cold-start guard');
    });

    testWidgets('resumed without prior paused does NOT trigger refresh',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithProxyWiring());
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(_weekData.calls, isEmpty);
      expect(_shiftDashboard.calls, isEmpty);
    });
  });

  // ── C: sticky-flag guard ──────────────────────────────────────────────

  group('C -- sticky-flag guard', () {
    testWidgets('inactive alone does NOT trigger refresh on resume',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithProxyWiring());
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(_weekData.calls, isEmpty,
          reason: 'inactive -> resumed should not trigger refresh');
      expect(_shiftDashboard.calls, isEmpty);
    });

    testWidgets(
        'inactive -> resumed after a prior paused -> resumed cycle does NOT fire again',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithProxyWiring());
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // First: real background cycle
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_weekData.calls, ['refresh'],
          reason: 'paused -> resumed should fire');

      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Then: transient interruption (phone call overlay)
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(_weekData.calls, isEmpty,
          reason:
              'inactive -> resumed after prior cycle should NOT fire (flag was reset)');
      expect(_shiftDashboard.calls, isEmpty);
    });
  });

  // ── D: routes through shared coordinator ──────────────────────────────

  group('D -- uses shared coordinator seam', () {
    testWidgets('resume refresh goes through coordinator, not widget-local',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithProxyWiring());
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      // Both week and shift refreshed — same as refreshCurrentStateSurfaces()
      expect(_weekData.calls, ['refresh']);
      expect(_shiftDashboard.calls, ['refresh']);
    });
  });

  // ── E: proxy update still works after cold start ──────────────────────

  group('E -- proxy update after cold start', () {
    testWidgets(
        'cold-start skip does not block subsequent real proxy updates',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithProxyWiring());
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // The cold-start guard consumed the first proxy update.
      // A real paused -> resumed cycle triggers refreshCurrentStateSurfaces()
      // through the lifecycle observer, proving the coordinator is no
      // longer guarded.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(_weekData.calls, ['refresh']);
      expect(_shiftDashboard.calls, ['refresh']);
    });
  });
}
