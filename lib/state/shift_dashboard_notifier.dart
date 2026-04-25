import 'package:flutter/foundation.dart';
import '../domain/models/active_target_profile.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_reservation_book_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../models/app_data_status.dart';
import '../models/current_state_freshness.dart';
import '../models/shift_dashboard_read_model.dart';
import '../services/current_state_freshness_service.dart';
import '../services/app_data_status_service.dart';
import '../services/schedule_plan_read_service.dart';
import '../services/wage_standard_context_service.dart';

class ShiftDashboardNotifier extends ChangeNotifier {
  ShiftDashboardReadModel? _readModel;
  AppDataStatus? _status;
  bool _isLoading = true;
  bool _lockedPlanUnavailable = false;

  /// Per-surface freshness truth for the Shift current-state surface.
  ///
  /// Null when no current-state data exists (no open snapshots).
  /// Evaluated from the latest `OpenShiftSnapshot.updatedAt` on each load.
  /// The [refreshing] state preserves the prior source timestamp during
  /// in-flight revalidation.
  CurrentStateFreshness? _freshness;

  ShiftDashboardReadModel? get readModel => _readModel;
  AppDataStatus? get status => _status;
  bool get isLoading => _isLoading;
  CurrentStateFreshness? get freshness => _freshness;
  bool get lockedPlanUnavailable => _lockedPlanUnavailable;

  ShiftDashboardNotifier() {
    _load();
  }

  /// Test-only constructor for synchronous setup.
  ShiftDashboardNotifier.fromReadModel(
    ShiftDashboardReadModel model, {
    CurrentStateFreshness? freshness,
  })  : _readModel = model,
        _status = null,
        _freshness = freshness,
        _isLoading = false;

  /// Test-only constructor for synchronous empty-state rendering.
  ShiftDashboardNotifier.emptyForTest(AppDataStatus status)
      : _readModel = null,
        _status = status,
        _freshness = null,
        _isLoading = false;

  Future<void> refresh() async {
    // Do NOT set _isLoading = true — during pull-to-refresh the
    // RefreshIndicator provides its own progress feedback and the
    // current data should stay visible. _isLoading is only for the
    // initial cold load in the constructor.
    _freshness = _freshness?.updatedAt != null
        ? CurrentStateFreshness.refreshing(
            priorUpdatedAt: _freshness!.updatedAt,
            evaluatedAt: DateTime.now().toUtc(),
          )
        : null;
    notifyListeners();
    await _load();
  }

  Future<void> _load() async {
    // Always evaluate data status
    _status = await AppDataStatusService.instance.evaluate();
    _lockedPlanUnavailable = false;

    final restaurantId =
        await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();

    // Load active target profile via wage-aware bootstrap
    final ActiveTargetProfile profile = await WageStandardContextService
        .instance
        .loadOrBootstrapProfile(restaurantId);

    // Find the business date with an open shift
    final businessDate = await SqliteOpenShiftSnapshotRepository.instance
        .getCurrentBusinessDate(restaurantId);

    if (businessDate != null) {
      // Load ALL daypart snapshots for this business day
      final snapshots = await SqliteOpenShiftSnapshotRepository.instance
          .getSnapshotsForDay(restaurantId, businessDate);

      // Evaluate per-surface freshness from the latest snapshot timestamp.
      // Same maxUpdatedAt pattern as AppDataStatusService.evaluate().
      final maxUpdatedAt = snapshots
          .map((s) => DateTime.tryParse(s.updatedAt))
          .whereType<DateTime>()
          .fold<DateTime?>(
              null, (a, b) => a == null || b.isAfter(a) ? b : a);

      if (snapshots.isNotEmpty) {
        _freshness = const CurrentStateFreshnessService().evaluate(
          updatedAt: maxUpdatedAt,
          now: DateTime.now().toUtc(),
        );

        // Read the persisted locked weekly plan only. If it is missing,
        // degrade honestly instead of silently falling back to the live plan.
        final plan = await SchedulePlanReadService.instance
            .getExistingCurrentLockedWeeklyPlan();

        // Find the open snapshot's day label to pick the right day row
        final openSnap = snapshots
            .where((s) => s.status == 'open')
            .firstOrNull ?? snapshots.first;
        final dayLabel = openSnap.dayLabel;

        // Pick the matching day row from SchedulePlan
        final dayPlan = plan?.dayPlans
            .where((d) => d.day == dayLabel)
            .firstOrNull;

        // Sum reservation book unseated covers across all dayparts for the day
        final resSnapshots = await SqliteReservationBookSnapshotRepository
            .instance
            .getForDay(restaurantId, businessDate);
        final totalUnseated = resSnapshots.fold<int>(
            0, (s, r) => s + r.unseatedCovers);

        if (dayPlan != null) {
          _readModel = ShiftDashboardReadModel.buildWholeDay(
            snapshots: snapshots,
            profile: profile,
            forecastCovers: dayPlan.forecastCovers,
            forecastSales: dayPlan.forecastSales,
            planFohHours: dayPlan.requiredFohHours,
            planBohHours: dayPlan.requiredBohHours,
            inTheBooksCovers: totalUnseated > 0 ? totalUnseated : null,
          );
        } else {
          // No persisted locked plan or no matching day row.
          // Do not fabricate plan values from a single daypart snapshot or
          // from the live plan path.
          _readModel = null;
          _lockedPlanUnavailable = true;
        }
      } else {
        _readModel = null;
        _freshness = null;
        _lockedPlanUnavailable = false;
      }
    } else {
      _readModel = null;
      _freshness = null;
      _lockedPlanUnavailable = false;
    }

    _isLoading = false;
    notifyListeners();
  }
}