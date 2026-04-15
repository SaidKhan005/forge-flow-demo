// Phase 7.55p.4a + 7.55p.4b1 — AppRefreshCoordinator tests.
//
// Validates:
// A. refreshAll touches scope/target/demand/weights (not week/shift)
// B. refreshCurrentStateSurfaces touches only week/shift
// C. No auto-refresh, timer, or polling behavior
// D. refreshAfterWrite touches scope/demand/weights (not target/week/shift)

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/app_refresh_coordinator.dart';
import 'package:forge_and_flow/data/active_target_profile_notifier.dart';
import 'package:forge_and_flow/data/demand_forecast_context_notifier.dart';
import 'package:forge_and_flow/data/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/data/schedule_distribution_weights_notifier.dart';
import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/data/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/data/week_data_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/models/app_data_status.dart';

// ─── Tracking fakes ─────────────────────────────────────────────────────────
// Override refresh/load to track calls without hitting SQLite.

class _TrackingRestaurantScopeNotifier extends RestaurantScopeNotifier {
  final calls = <String>[];
  _TrackingRestaurantScopeNotifier()
      : super.fromRestaurant(RestaurantLocation(
          restaurantId: 'test_001',
          displayName: 'Test Restaurant',
          businessTimezone: 'America/Chicago',
          createdAt: '2026-01-01',
          updatedAt: '2026-01-01',
        ));
  @override
  Future<void> refresh() async {
    calls.add('refresh');
  }
}

class _TrackingActiveTargetNotifier extends ActiveTargetProfileNotifier {
  final calls = <String>[];
  _TrackingActiveTargetNotifier()
      : super.fromProfile(const ActiveTargetProfile(
          targetProfileId: 'test',
          restaurantId: 'test_001',
          sourceType: 'system_baseline',
          targetCPLH: 30,
          targetSPLH: 70,
          targetPPA: 25,
          fohWage: 12,
          bohWage: 14,
          opzFloorCPLH: 25,
          opzCeilingCPLH: 35,
          theoreticalFohLaborPct: 12,
          theoreticalBohLaborPct: 10,
          theoreticalLaborPct: 22,
          builtAt: '2026-01-01',
        ));
  @override
  Future<void> refresh() async {
    calls.add('refresh');
  }
}

class _TrackingWeekDataNotifier extends WeekDataNotifier {
  final calls = <String>[];
  _TrackingWeekDataNotifier() : super(const StaticShiftDataSource());
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

class _TrackingDemandNotifier extends DemandForecastContextNotifier {
  final calls = <String>[];
  @override
  Future<void> load() async {
    calls.add('load');
  }
}

class _TrackingScheduleWeightsNotifier extends ChangeNotifier
    implements ScheduleDistributionWeightsNotifier {
  final calls = <String>[];

  @override
  Future<void> load() async {
    calls.add('load');
  }

  @override
  ScheduleDistributionWeights? get weights => null;
  @override
  bool get isLoading => false;
  @override
  bool get hasLoaded => false;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

void main() {
  // ── A: refreshAll touches all notifiers ──────────────────────────────────

  group('A — refreshAll', () {
    late _TrackingRestaurantScopeNotifier scope;
    late _TrackingActiveTargetNotifier target;
    late _TrackingWeekDataNotifier weekData;
    late _TrackingShiftDashboardNotifier dashboard;
    late _TrackingDemandNotifier demand;
    late _TrackingScheduleWeightsNotifier weights;
    late AppRefreshCoordinator coordinator;

    setUp(() async {
      scope = _TrackingRestaurantScopeNotifier();
      target = _TrackingActiveTargetNotifier();
      weekData = _TrackingWeekDataNotifier();
      // Wait for WeekDataNotifier constructor _load() to complete
      await Future<void>.delayed(const Duration(milliseconds: 100));
      dashboard = _TrackingShiftDashboardNotifier();
      demand = _TrackingDemandNotifier();
      weights = _TrackingScheduleWeightsNotifier();
      // Clear any constructor-triggered calls
      scope.calls.clear();
      target.calls.clear();
      weekData.calls.clear();
      dashboard.calls.clear();
      demand.calls.clear();
      weights.calls.clear();

      coordinator = AppRefreshCoordinator(
        restaurantScope: scope,
        activeTarget: target,
        weekData: weekData,
        shiftDashboard: dashboard,
        demandForecast: demand,
        scheduleWeights: weights,
      );
    });

    tearDown(() {
      scope.dispose();
      target.dispose();
      weekData.dispose();
      dashboard.dispose();
      demand.dispose();
      weights.dispose();
    });

    test('refreshAll calls refresh on RestaurantScopeNotifier', () {
      coordinator.refreshAll();
      expect(scope.calls, ['refresh']);
    });

    test('refreshAll calls refresh on ActiveTargetProfileNotifier', () {
      coordinator.refreshAll();
      expect(target.calls, ['refresh']);
    });

    test('refreshAll does not directly refresh WeekDataNotifier (cascade-driven)',
        () {
      coordinator.refreshAll();
      expect(weekData.calls, isEmpty);
    });

    test(
        'refreshAll does not directly refresh ShiftDashboardNotifier (cascade-driven)',
        () {
      coordinator.refreshAll();
      expect(dashboard.calls, isEmpty);
    });

    test('refreshAll calls load on DemandForecastContextNotifier', () {
      coordinator.refreshAll();
      expect(demand.calls, ['load']);
    });

    test('refreshAll calls load on ScheduleDistributionWeightsNotifier', () {
      coordinator.refreshAll();
      expect(weights.calls, ['load']);
    });
  });

  // ── B: refreshCurrentStateSurfaces ────────────────────────────────────

  group('B — refreshCurrentStateSurfaces', () {
    late _TrackingRestaurantScopeNotifier scope;
    late _TrackingActiveTargetNotifier target;
    late _TrackingWeekDataNotifier weekData;
    late _TrackingShiftDashboardNotifier dashboard;
    late _TrackingDemandNotifier demand;
    late _TrackingScheduleWeightsNotifier weights;
    late AppRefreshCoordinator coordinator;

    setUp(() async {
      scope = _TrackingRestaurantScopeNotifier();
      target = _TrackingActiveTargetNotifier();
      weekData = _TrackingWeekDataNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      dashboard = _TrackingShiftDashboardNotifier();
      demand = _TrackingDemandNotifier();
      weights = _TrackingScheduleWeightsNotifier();
      scope.calls.clear();
      target.calls.clear();
      weekData.calls.clear();
      dashboard.calls.clear();
      demand.calls.clear();
      weights.calls.clear();

      coordinator = AppRefreshCoordinator(
        restaurantScope: scope,
        activeTarget: target,
        weekData: weekData,
        shiftDashboard: dashboard,
        demandForecast: demand,
        scheduleWeights: weights,
      );
      // Consume cold-start skip (7.55n.9a) so subsequent calls go through.
      coordinator.refreshCurrentStateSurfaces();
      // Clear any tracking from warm-up.
      scope.calls.clear();
      target.calls.clear();
      weekData.calls.clear();
      dashboard.calls.clear();
      demand.calls.clear();
      weights.calls.clear();
    });

    tearDown(() {
      scope.dispose();
      target.dispose();
      weekData.dispose();
      dashboard.dispose();
      demand.dispose();
      weights.dispose();
    });

    test('refreshes WeekDataNotifier', () {
      coordinator.refreshCurrentStateSurfaces();
      expect(weekData.calls, ['refresh']);
    });

    test('refreshes ShiftDashboardNotifier', () {
      coordinator.refreshCurrentStateSurfaces();
      expect(dashboard.calls, ['refresh']);
    });

    test('does not refresh RestaurantScopeNotifier', () {
      coordinator.refreshCurrentStateSurfaces();
      expect(scope.calls, isEmpty);
    });

    test('does not refresh ActiveTargetProfileNotifier', () {
      coordinator.refreshCurrentStateSurfaces();
      expect(target.calls, isEmpty);
    });

    test('does not load DemandForecastContextNotifier', () {
      coordinator.refreshCurrentStateSurfaces();
      expect(demand.calls, isEmpty);
    });

    test('does not load ScheduleDistributionWeightsNotifier', () {
      coordinator.refreshCurrentStateSurfaces();
      expect(weights.calls, isEmpty);
    });

    test('first call is skipped by cold-start guard (7.55n.9a)', () {
      // Fresh coordinator — first call should be a no-op
      final fresh = AppRefreshCoordinator(
        restaurantScope: scope,
        activeTarget: target,
        weekData: weekData,
        shiftDashboard: dashboard,
        demandForecast: demand,
        scheduleWeights: weights,
      );
      weekData.calls.clear();
      dashboard.calls.clear();

      fresh.refreshCurrentStateSurfaces();
      expect(weekData.calls, isEmpty,
          reason: 'first call should be skipped (cold-start guard)');
      expect(dashboard.calls, isEmpty);

      // Second call should go through
      fresh.refreshCurrentStateSurfaces();
      expect(weekData.calls, ['refresh']);
      expect(dashboard.calls, ['refresh']);
    });
  });

  // ── C: scope honesty ─────────────────────────────────────────────────

  group('C — scope honesty', () {
    test('coordinator is not a ChangeNotifier (no auto-refresh subscriptions)',
        () {
      final coordinator = AppRefreshCoordinator(
        restaurantScope: _TrackingRestaurantScopeNotifier(),
        activeTarget: _TrackingActiveTargetNotifier(),
        weekData: _TrackingWeekDataNotifier(),
        shiftDashboard: _TrackingShiftDashboardNotifier(),
        demandForecast: _TrackingDemandNotifier(),
        scheduleWeights: _TrackingScheduleWeightsNotifier(),
      );
      expect(coordinator, isNot(isA<ChangeNotifier>()));
    });
  });

  // ── D: refreshAfterWrite — bus-driven write dedup ───────────────────

  group('D — refreshAfterWrite', () {
    late _TrackingRestaurantScopeNotifier scope;
    late _TrackingActiveTargetNotifier target;
    late _TrackingWeekDataNotifier weekData;
    late _TrackingShiftDashboardNotifier dashboard;
    late _TrackingDemandNotifier demand;
    late _TrackingScheduleWeightsNotifier weights;
    late AppRefreshCoordinator coordinator;

    setUp(() async {
      scope = _TrackingRestaurantScopeNotifier();
      target = _TrackingActiveTargetNotifier();
      weekData = _TrackingWeekDataNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      dashboard = _TrackingShiftDashboardNotifier();
      demand = _TrackingDemandNotifier();
      weights = _TrackingScheduleWeightsNotifier();
      scope.calls.clear();
      target.calls.clear();
      weekData.calls.clear();
      dashboard.calls.clear();
      demand.calls.clear();
      weights.calls.clear();

      coordinator = AppRefreshCoordinator(
        restaurantScope: scope,
        activeTarget: target,
        weekData: weekData,
        shiftDashboard: dashboard,
        demandForecast: demand,
        scheduleWeights: weights,
      );
    });

    tearDown(() {
      scope.dispose();
      target.dispose();
      weekData.dispose();
      dashboard.dispose();
      demand.dispose();
      weights.dispose();
    });

    test('refreshes RestaurantScopeNotifier', () {
      coordinator.refreshAfterWrite();
      expect(scope.calls, ['refresh']);
    });

    test('loads DemandForecastContextNotifier', () {
      coordinator.refreshAfterWrite();
      expect(demand.calls, ['load']);
    });

    test('loads ScheduleDistributionWeightsNotifier', () {
      coordinator.refreshAfterWrite();
      expect(weights.calls, ['load']);
    });

    test('does not refresh ActiveTargetProfileNotifier (avoids cascade)', () {
      coordinator.refreshAfterWrite();
      expect(target.calls, isEmpty);
    });

    test('does not refresh WeekDataNotifier (bus handles it)', () {
      coordinator.refreshAfterWrite();
      expect(weekData.calls, isEmpty);
    });

    test('does not refresh ShiftDashboardNotifier (bus handles it)', () {
      coordinator.refreshAfterWrite();
      expect(dashboard.calls, isEmpty);
    });
  });
}
