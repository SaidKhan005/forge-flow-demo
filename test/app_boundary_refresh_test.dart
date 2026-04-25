// Phase 7.55n.10 — App boundary-refresh integration tests.
//
// Validates:
// A. Boundary change while foregrounded triggers coordinator refresh
// B. No boundary refresh fires on initial mount
// C. Monitor stops on paused, restarts on resumed
// D. Resume re-seeds monitor to avoid duplicate refresh
// E. Repeated checks within same boundary do not keep refreshing
//
// Uses a production-style ProxyProvider2 wiring (same as
// app_resume_refresh_test.dart) so the tests catch real coordinator
// interactions.

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

// ── Stubs (same as app_resume_refresh_test.dart) ───────────────────────

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

// ── Tracking notifiers ─────────────────────────────────────────────────

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

// ── Test bus ────────────────────────────────────────────────────────────

class _TestBus extends ChangeNotifier implements AppRuntimeInvalidationBus {
  void fire() => notifyListeners();
  @override
  void notifyCurrentStateChanged() => fire();
  @override
  void notifyRuntimeWriteCompleted() => fire();
  @override
  void notifyImportCompletionPersisted() => fire();
}

// ── Harness ────────────────────────────────────────────────────────────

late _TrackingWeekDataNotifier _weekData;
late _TrackingShiftDashboardNotifier _shiftDashboard;

/// Controllable business date for the boundary monitor.
String _testBusinessDate = '2026-04-13';

Widget _buildAppShellWithBoundaryMonitor() {
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
    child: MaterialApp(
      home: AppShell(
        testBusinessDateResolver: (_) async => _testBusinessDate,
      ),
    ),
  );
}

void main() {
  setUp(() {
    _testBusinessDate = '2026-04-13';
  });

  // ── A: boundary change triggers refresh ────────────────────────────

  group('A — boundary change while foregrounded', () {
    testWidgets('triggers coordinator refresh exactly once', (tester) async {
      await tester.pumpWidget(_buildAppShellWithBoundaryMonitor());
      await tester.pump(); // post-frame callback → monitor init + seed
      await tester.pump(); // flush async seed
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Simulate business-date rollover while foregrounded.
      _testBusinessDate = '2026-04-14';

      // Advance time to trigger periodic check (1-minute default).
      await tester.pump(const Duration(minutes: 1));
      await tester.pump(); // flush async check

      expect(_weekData.calls, ['refresh']);
      expect(_shiftDashboard.calls, ['refresh']);
    });

    testWidgets('repeated checks at same boundary do not repeat refresh',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithBoundaryMonitor());
      await tester.pump();
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Cross boundary.
      _testBusinessDate = '2026-04-14';
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(_weekData.calls, ['refresh']);

      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Next check — same date — no additional refresh.
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(_weekData.calls, isEmpty,
          reason: 'same boundary should not re-trigger refresh');
      expect(_shiftDashboard.calls, isEmpty);
    });
  });

  // ── B: no boundary refresh on initial mount ─────────────────────────

  group('B — initial mount', () {
    testWidgets('no boundary refresh on initial mount', (tester) async {
      await tester.pumpWidget(_buildAppShellWithBoundaryMonitor());
      await tester.pump(); // post-frame callback
      await tester.pump(); // flush async seed
      // ProxyProvider2 initial update is consumed by cold-start guard.
      // Monitor seed does NOT fire callback.
      expect(_weekData.calls, isEmpty);
      expect(_shiftDashboard.calls, isEmpty);
    });
  });

  // ── C: lifecycle integration ────────────────────────────────────────

  group('C — lifecycle integration', () {
    testWidgets('monitor stops on paused — no boundary check while backgrounded',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithBoundaryMonitor());
      await tester.pump();
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Background the app.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      // Change date while backgrounded.
      _testBusinessDate = '2026-04-14';

      // Advance time — timer should be stopped, so no check fires.
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      // No refresh from boundary monitor — it was stopped.
      expect(_weekData.calls, isEmpty,
          reason: 'monitor should be stopped while backgrounded');
      expect(_shiftDashboard.calls, isEmpty);
    });

    testWidgets('monitor restarts on resumed after paused', (tester) async {
      await tester.pumpWidget(_buildAppShellWithBoundaryMonitor());
      await tester.pump();
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Background → resume cycle.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(); // flush re-seed

      // Resume fires one refresh (7.55n.9).
      expect(_weekData.calls, ['refresh']);
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Business date changes while foregrounded again.
      _testBusinessDate = '2026-04-14';
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      // Monitor is running again — detects the change.
      expect(_weekData.calls, ['refresh']);
      expect(_shiftDashboard.calls, ['refresh']);
    });
  });

  // ── D: resume dedup ─────────────────────────────────────────────────

  group('D — resume dedup with boundary monitor', () {
    testWidgets(
        'resumed after paused re-seeds monitor, preventing duplicate refresh',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithBoundaryMonitor());
      await tester.pump();
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Background at date '2026-04-13'.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      // Date changes while backgrounded.
      _testBusinessDate = '2026-04-14';

      // Resume — 7.55n.9 fires one refresh, monitor re-seeds to new date.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(); // flush re-seed

      // Only ONE refresh (from resume), not two.
      expect(_weekData.calls, ['refresh']);
      expect(_shiftDashboard.calls, ['refresh']);

      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Next periodic check — date hasn't changed since re-seed.
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      expect(_weekData.calls, isEmpty,
          reason:
              'monitor re-seeded to new date — no boundary change detected');
      expect(_shiftDashboard.calls, isEmpty);
    });
  });

  // ── E: second boundary while foregrounded ───────────────────────────

  group('E — multiple boundary changes', () {
    testWidgets('second boundary change while foregrounded triggers refresh again',
        (tester) async {
      await tester.pumpWidget(_buildAppShellWithBoundaryMonitor());
      await tester.pump();
      await tester.pump();
      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // First boundary change.
      _testBusinessDate = '2026-04-14';
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(_weekData.calls, ['refresh']);

      _weekData.calls.clear();
      _shiftDashboard.calls.clear();

      // Second boundary change.
      _testBusinessDate = '2026-04-15';
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(_weekData.calls, ['refresh']);
      expect(_shiftDashboard.calls, ['refresh']);
    });
  });
}
