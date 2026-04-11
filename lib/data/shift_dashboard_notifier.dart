import 'package:flutter/foundation.dart';
import '../domain/models/active_target_profile.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_reservation_book_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../models/app_data_status.dart';
import '../models/shift_dashboard_read_model.dart';
import 'app_data_status_service.dart';
import 'schedule_plan_read_service.dart';
import 'wage_standard_context_service.dart';

class ShiftDashboardNotifier extends ChangeNotifier {
  ShiftDashboardReadModel? _readModel;
  AppDataStatus? _status;
  bool _isLoading = true;

  ShiftDashboardReadModel? get readModel => _readModel;
  AppDataStatus? get status => _status;
  bool get isLoading => _isLoading;

  ShiftDashboardNotifier() {
    _load();
  }

  /// Test-only constructor for synchronous setup.
  ShiftDashboardNotifier.fromReadModel(ShiftDashboardReadModel model)
      : _readModel = model,
        _status = null,
        _isLoading = false;

  /// Test-only constructor for synchronous empty-state rendering.
  ShiftDashboardNotifier.emptyForTest(AppDataStatus status)
      : _readModel = null,
        _status = status,
        _isLoading = false;

  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();
    await _load();
  }

  Future<void> _load() async {
    // Always evaluate data status
    _status = await AppDataStatusService.instance.evaluate();

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

      if (snapshots.isNotEmpty) {
        // Resolve plan from shared authority (includes distribution weights)
        final plan = await SchedulePlanReadService.instance
            .getCurrentWeeklyPlan();

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
          // No SchedulePlan or no matching day row — show unavailable state.
          // Do not fabricate plan values from a single daypart snapshot.
          _readModel = null;
        }
      } else {
        _readModel = null;
      }
    } else {
      _readModel = null;
    }

    _isLoading = false;
    notifyListeners();
  }
}
