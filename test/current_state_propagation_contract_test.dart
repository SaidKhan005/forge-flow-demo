// Phase 7.55n.11 — Current-state propagation contract tests.
//
// Validates the explicit propagation contract:
// A. Runtime-write and import-completion are distinct named entrypoints
// B. Both entrypoints converge on the same downstream refresh path
// C. The contract is honest — no actual connector implementation is implied
// D. The bus API shape supports both producer paths explicitly

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

  // ── A: API shape — both entrypoints exist and are callable ───────────

  group('A — API shape', () {
    test('notifyRuntimeWriteCompleted is a callable method', () {
      // Validates that the method exists and is invocable. The listener
      // verifies it actually fires the ChangeNotifier.
      final calls = <String>[];
      void listener() => calls.add('write');
      bus.addListener(listener);
      bus.notifyRuntimeWriteCompleted();
      expect(calls, ['write']);
      bus.removeListener(listener);
    });

    test('notifyImportCompletionPersisted is a callable method', () {
      final calls = <String>[];
      void listener() => calls.add('import');
      bus.addListener(listener);
      bus.notifyImportCompletionPersisted();
      expect(calls, ['import']);
      bus.removeListener(listener);
    });

    test('both entrypoints exist on the same bus instance', () {
      // Both methods should be accessible on the singleton —
      // there is one bus, not separate channels.
      expect(
        bus,
        isA<AppRuntimeInvalidationBus>()
            .having(
              (b) => b.notifyRuntimeWriteCompleted,
              'notifyRuntimeWriteCompleted',
              isNotNull,
            )
            .having(
              (b) => b.notifyImportCompletionPersisted,
              'notifyImportCompletionPersisted',
              isNotNull,
            ),
      );
    });
  });

  // ── B: Convergence — both paths reach the same coordinator ──────────

  group('B — convergence through coordinator', () {
    late _TrackingWeekDataNotifier weekData;
    late _TrackingShiftDashboardNotifier dashboard;
    late AppRefreshCoordinator coordinator;
    late void Function() busListener;

    setUp(() async {
      final scope = _TrackingRestaurantScopeNotifier();
      final target = _TrackingActiveTargetNotifier();
      weekData = _TrackingWeekDataNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      dashboard = _TrackingShiftDashboardNotifier();
      final demand = _TrackingDemandNotifier();
      final weights = _TrackingScheduleWeightsNotifier();

      coordinator = AppRefreshCoordinator(
        restaurantScope: scope,
        activeTarget: target,
        weekData: weekData,
        shiftDashboard: dashboard,
        demandForecast: demand,
        scheduleWeights: weights,
      );
      // Consume cold-start skip so both entrypoints go through.
      coordinator.refreshCurrentStateSurfaces();

      weekData.calls.clear();
      dashboard.calls.clear();

      busListener = () => coordinator.refreshCurrentStateSurfaces();
      bus.addListener(busListener);
    });

    tearDown(() {
      bus.removeListener(busListener);
    });

    test('runtime-write refreshes week and shift through coordinator', () {
      bus.notifyRuntimeWriteCompleted();
      expect(weekData.calls, ['refresh']);
      expect(dashboard.calls, ['refresh']);
    });

    test('import-completion refreshes week and shift through coordinator', () {
      bus.notifyImportCompletionPersisted();
      expect(weekData.calls, ['refresh']);
      expect(dashboard.calls, ['refresh']);
    });

    test('sequential write then import both refresh independently', () {
      bus.notifyRuntimeWriteCompleted();
      expect(weekData.calls, ['refresh']);

      bus.notifyImportCompletionPersisted();
      expect(weekData.calls, ['refresh', 'refresh'],
          reason: 'each producer fires independently');
    });

    test('interleaved entrypoints produce correct cumulative refreshes', () {
      bus.notifyRuntimeWriteCompleted();
      bus.notifyImportCompletionPersisted();
      bus.notifyRuntimeWriteCompleted();

      expect(weekData.calls, ['refresh', 'refresh', 'refresh']);
      expect(dashboard.calls, ['refresh', 'refresh', 'refresh']);
    });
  });

  // ── C: Honesty — no connector implementation implied ────────────────

  group('C — honesty', () {
    test('bus is a plain ChangeNotifier, not a transport layer', () {
      // The bus does not carry vendor payloads, connection state,
      // or transport-level semantics. It is a pure invalidation signal.
      expect(bus, isA<ChangeNotifier>());
      expect(bus, isNot(isA<Stream<dynamic>>()));
    });

    test('import-completion entrypoint does not require adapter arguments', () {
      // notifyImportCompletionPersisted() takes no parameters.
      // A future connector calls it after it has already persisted
      // data to the canonical store. The bus does not know or care
      // what was imported.
      final calls = <String>[];
      void listener() => calls.add('fired');
      bus.addListener(listener);
      bus.notifyImportCompletionPersisted(); // no arguments
      expect(calls, ['fired']);
      bus.removeListener(listener);
    });
  });
}
