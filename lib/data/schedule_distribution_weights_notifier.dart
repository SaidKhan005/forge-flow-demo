// Phase 7.55e.4 — Runtime loader for ScheduleDistributionWeights.
//
// Loads closed ShiftRecords from the most recent 8 weekIds (temporary
// pre-7.55f approximation of a 60-day window) and builds distribution
// weights via DistributionWeightBuilder.
//
// Pure ChangeNotifier — no UI, no SQLite import. Repositories are injected
// so tests can use fakes without SQLite.

import 'package:flutter/foundation.dart';
import '../domain/models/schedule_distribution_weights.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../domain/repositories/week_record_repository.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/services/distribution_weight_builder.dart';

class ScheduleDistributionWeightsNotifier extends ChangeNotifier {
  final RestaurantScopeRepository _scopeRepo;
  final WeekRecordRepository _weekRepo;
  final ShiftRecordRepository _shiftRepo;

  ScheduleDistributionWeights? _weights;
  bool _isLoading = false;
  bool _hasLoaded = false;

  /// Current distribution weights. Null before first load or when unavailable.
  ScheduleDistributionWeights? get weights => _weights;

  /// Whether an async load is in progress.
  bool get isLoading => _isLoading;

  /// Whether at least one load attempt has completed (success or failure).
  bool get hasLoaded => _hasLoaded;

  ScheduleDistributionWeightsNotifier({
    required RestaurantScopeRepository scopeRepo,
    required WeekRecordRepository weekRepo,
    required ShiftRecordRepository shiftRepo,
  })  : _scopeRepo = scopeRepo,
        _weekRepo = weekRepo,
        _shiftRepo = shiftRepo;

  /// Loads closed shifts from the most recent 8 weekIds and builds
  /// distribution weights.
  ///
  /// Safe to call from widget lifecycle — never throws into the widget tree.
  /// On failure, sets weights to null (Schedule falls back to defaults).
  ///
  /// Uses weekId-based history as a temporary 60-day approximation.
  /// Phase 7.55f will replace this with true business_date range querying.
  Future<void> load() async {
    _isLoading = true;
    // Do not notify yet — let the load complete before triggering rebuilds.

    try {
      final restaurantId = await _scopeRepo.getActiveRestaurantId();
      final weekHistory = await _weekRepo.getWeekHistory(restaurantId);

      if (weekHistory.isEmpty) {
        _weights = null;
        _isLoading = false;
        _hasLoaded = true;
        notifyListeners();
        return;
      }

      // Take the most recent 8 weekIds as a temporary pre-7.55f
      // 60-day approximation. weekHistory is ordered most-recent-first.
      final recentWeekIds = weekHistory
          .take(8)
          .map((w) => w.weekId)
          .toList();

      final closedShifts = await _shiftRepo.getClosedShiftsForWeeks(
        restaurantId,
        recentWeekIds,
      );

      _weights = DistributionWeightBuilder.fromClosedShifts(closedShifts);
    } catch (_) {
      // Swallow errors — Schedule will fall back to default weights.
      _weights = null;
    }

    _isLoading = false;
    _hasLoaded = true;
    notifyListeners();
  }
}
