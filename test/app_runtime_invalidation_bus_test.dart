// Phase 7.55p.4b + 7.55n.11 — AppRuntimeInvalidationBus tests.
//
// Validates:
// A. Runtime-write entrypoint fires listeners
// B. Import-completion entrypoint fires listeners
// C. Both entrypoints reach current-state surfaces through coordinator
// D. Neither entrypoint touches non-current-state notifiers
// E. No background/polling/timer behavior
// F. Backward-compatible notifyCurrentStateChanged still works

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/state/app_refresh_coordinator.dart';
import 'package:forge_and_flow/state/app_runtime_invalidation_bus.dart';
import 'package:forge_and_flow/state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/state/demand_forecast_context_notifier.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/schedule_distribution_weights_notifier.dart';
import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:forge_and_flow/state/week_data_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/models/app_data_status.dart';

// ─── Tracking fakes ─────────────────────────────────────────────────────────
// Same pattern as coordinator tests: override refresh/load to track calls.

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
  final bus = AppRuntimeInvalidationBus.instance;

  // ── A: Runtime-write entrypoint ──────────────────────────────────────

  group('A — runtime-write entrypoint', () {
    test('notifyRuntimeWriteCompleted fires listeners', () {
      final calls = <String>[];
      void listener() => calls.add('fired');
      bus.addListener(listener);
      bus.notifyRuntimeWriteCompleted();
      expect(calls, ['fired']);
      bus.removeListener(listener);
    });

    test('removed listeners are not called', () {
      final calls = <String>[];
      void listener() => calls.add('fired');
      bus.addListener(listener);
      bus.removeListener(listener);
      bus.notifyRuntimeWriteCompleted();
      expect(calls, isEmpty);
    });

    test('multiple listeners all fire', () {
      final calls = <String>[];
      void listenerA() => calls.add('a');
      void listenerB() => calls.add('b');
      bus.addListener(listenerA);
      bus.addListener(listenerB);
      bus.notifyRuntimeWriteCompleted();
      expect(calls, ['a', 'b']);
      bus.removeListener(listenerA);
      bus.removeListener(listenerB);
    });
  });

  // ── B: Import-completion entrypoint ──────────────────────────────────

  group('B — import-completion entrypoint', () {
    test('notifyImportCompletionPersisted fires listeners', () {
      final calls = <String>[];
      void listener() => calls.add('fired');
      bus.addListener(listener);
      bus.notifyImportCompletionPersisted();
      expect(calls, ['fired']);
      bus.removeListener(listener);
    });

    test('removed listeners are not called via import-completion path', () {
      final calls = <String>[];
      void listener() => calls.add('fired');
      bus.addListener(listener);
      bus.removeListener(listener);
      bus.notifyImportCompletionPersisted();
      expect(calls, isEmpty);
    });
  });

  // ── C: Both entrypoints → coordinator → current-state surfaces ──────
  // Simulates the ProxyProvider2 wiring in ForgeFlowScope: when the bus
  // fires, the coordinator's refreshCurrentStateSurfaces() is called.

  group('C — both entrypoints through coordinator', () {
    late _TrackingWeekDataNotifier weekData;
    late _TrackingShiftDashboardNotifier dashboard;
    late _TrackingRestaurantScopeNotifier scope;
    late _TrackingActiveTargetNotifier target;
    late _TrackingDemandNotifier demand;
    late _TrackingScheduleWeightsNotifier weights;
    late AppRefreshCoordinator coordinator;
    late void Function() busListener;

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
      // Clear any tracking from cold-start consumption.
      weekData.calls.clear();
      dashboard.calls.clear();

      // Simulate ProxyProvider2 wiring: bus fires → refreshCurrentStateSurfaces
      busListener = () => coordinator.refreshCurrentStateSurfaces();
      bus.addListener(busListener);
    });

    tearDown(() {
      bus.removeListener(busListener);
      scope.dispose();
      target.dispose();
      weekData.dispose();
      dashboard.dispose();
      demand.dispose();
      weights.dispose();
    });

    test('runtime-write signal refreshes WeekDataNotifier', () {
      bus.notifyRuntimeWriteCompleted();
      expect(weekData.calls, ['refresh']);
    });

    test('runtime-write signal refreshes ShiftDashboardNotifier', () {
      bus.notifyRuntimeWriteCompleted();
      expect(dashboard.calls, ['refresh']);
    });

    test('import-completion signal refreshes WeekDataNotifier', () {
      bus.notifyImportCompletionPersisted();
      expect(weekData.calls, ['refresh']);
    });

    test('import-completion signal refreshes ShiftDashboardNotifier', () {
      bus.notifyImportCompletionPersisted();
      expect(dashboard.calls, ['refresh']);
    });

    test('both entrypoints produce identical downstream behavior', () {
      bus.notifyRuntimeWriteCompleted();
      final afterWrite = List<String>.from(weekData.calls);
      weekData.calls.clear();

      bus.notifyImportCompletionPersisted();
      final afterImport = List<String>.from(weekData.calls);

      expect(afterWrite, ['refresh']);
      expect(afterImport, ['refresh']);
      expect(afterWrite, afterImport,
          reason:
              'both entrypoints should produce identical refresh behavior');
    });
  });

  // ── D: Neither entrypoint touches non-current-state notifiers ────────

  group('D — scope isolation', () {
    late _TrackingWeekDataNotifier weekData;
    late _TrackingShiftDashboardNotifier dashboard;
    late _TrackingRestaurantScopeNotifier scope;
    late _TrackingActiveTargetNotifier target;
    late _TrackingDemandNotifier demand;
    late _TrackingScheduleWeightsNotifier weights;
    late void Function() busListener;

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

      final coordinator = AppRefreshCoordinator(
        restaurantScope: scope,
        activeTarget: target,
        weekData: weekData,
        shiftDashboard: dashboard,
        demandForecast: demand,
        scheduleWeights: weights,
      );
      // Consume cold-start skip (7.55n.9a) so subsequent calls go through.
      coordinator.refreshCurrentStateSurfaces();
      scope.calls.clear();
      target.calls.clear();
      weekData.calls.clear();
      dashboard.calls.clear();
      demand.calls.clear();
      weights.calls.clear();

      busListener = () => coordinator.refreshCurrentStateSurfaces();
      bus.addListener(busListener);
    });

    tearDown(() {
      bus.removeListener(busListener);
      scope.dispose();
      target.dispose();
      weekData.dispose();
      dashboard.dispose();
      demand.dispose();
      weights.dispose();
    });

    test('runtime-write does not touch RestaurantScopeNotifier', () {
      bus.notifyRuntimeWriteCompleted();
      expect(scope.calls, isEmpty);
    });

    test('runtime-write does not touch ActiveTargetProfileNotifier', () {
      bus.notifyRuntimeWriteCompleted();
      expect(target.calls, isEmpty);
    });

    test('runtime-write does not load DemandForecastContextNotifier', () {
      bus.notifyRuntimeWriteCompleted();
      expect(demand.calls, isEmpty);
    });

    test('runtime-write does not load ScheduleDistributionWeightsNotifier',
        () {
      bus.notifyRuntimeWriteCompleted();
      expect(weights.calls, isEmpty);
    });

    test('import-completion does not touch RestaurantScopeNotifier', () {
      bus.notifyImportCompletionPersisted();
      expect(scope.calls, isEmpty);
    });

    test('import-completion does not touch ActiveTargetProfileNotifier', () {
      bus.notifyImportCompletionPersisted();
      expect(target.calls, isEmpty);
    });
  });

  // ── E: Scope honesty ─────────────────────────────────────────────────

  group('E — scope honesty', () {
    test('bus is a ChangeNotifier (explicit signal, not a timer/poller)', () {
      expect(bus, isA<ChangeNotifier>());
    });

    test('bus does not auto-fire on construction', () {
      final calls = <String>[];
      void listener() => calls.add('fired');
      bus.addListener(listener);
      // No entrypoint called
      expect(calls, isEmpty);
      bus.removeListener(listener);
    });
  });

  // ── F: Backward compatibility ────────────────────────────────────────

  group('F — backward compatibility', () {
    test('notifyCurrentStateChanged still fires listeners', () {
      final calls = <String>[];
      void listener() => calls.add('fired');
      bus.addListener(listener);
      bus.notifyCurrentStateChanged();
      expect(calls, ['fired']);
      bus.removeListener(listener);
    });
  });
}
