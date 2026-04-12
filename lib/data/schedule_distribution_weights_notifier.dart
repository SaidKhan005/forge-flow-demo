// Phase 7.55e.4 + 7.55l.5d + 7.55l.5e — Runtime loader for
// ScheduleDistributionWeights.
//
// 7.55l.5d: Loads closed ShiftRecords from business-date-anchored windows
// (60-day baseline + 21-day recent) with day-of-week smoothing.
//
// 7.55l.5e: Anchor precedence now matches the rest of the planning stack:
//   1. Mock replay business date (when available)
//   2. Latest closed business date (fallback)
// Eliminates the anchor mismatch between demand context and day weights
// during replay/demo mode.
//
// Pure ChangeNotifier — no UI dependency. Repositories and the optional
// mock-replay-date provider are injected so tests can use fakes without
// SQLite.

import 'package:flutter/foundation.dart';
import '../domain/models/schedule_distribution_weights.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../domain/repositories/week_record_repository.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/services/distribution_weight_builder.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import 'demand_forecast_context_service.dart';

/// Signature for the mock-replay-date lookup injected into the notifier.
///
/// Returns the mock replay business date for [restaurantId], or null when
/// no replay state is active.
typedef MockReplayDateProvider = Future<String?> Function(
    String restaurantId);

class ScheduleDistributionWeightsNotifier extends ChangeNotifier {
  final RestaurantScopeRepository _scopeRepo;
  // Transitional: kept in constructor for backward compatibility with existing
  // callers. Will be removed when all weight-loading paths use date-anchored
  // windows and no caller passes weekRepo.
  // ignore: unused_field
  final WeekRecordRepository _weekRepo;
  final ShiftRecordRepository _shiftRepo;
  final MockReplayDateProvider _mockReplayDateProvider;

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
    MockReplayDateProvider? mockReplayDateProvider,
  })  : _scopeRepo = scopeRepo,
        _weekRepo = weekRepo,
        _shiftRepo = shiftRepo,
        _mockReplayDateProvider = mockReplayDateProvider ??
            _defaultMockReplayDateProvider;

  /// Default provider that reads the mock replay business date from SQLite.
  /// Production callers use this automatically; tests inject a fake.
  static Future<String?> _defaultMockReplayDateProvider(
      String restaurantId) {
    return SqliteDatabase.instance
        .getMockReplayBusinessDate(restaurantId);
  }

  /// Loads closed shifts from business-date-anchored windows and builds
  /// distribution weights with day-of-week smoothing.
  ///
  /// Anchor precedence (same as DemandForecastContextService):
  ///   1. Mock replay business date (when available)
  ///   2. Latest closed business date (fallback)
  ///
  /// Windows: 60-day baseline + 21-day recent trend.
  ///
  /// Safe to call from widget lifecycle — never throws into the widget tree.
  /// On failure, sets weights to null (Schedule falls back to defaults).
  Future<void> load() async {
    _isLoading = true;
    // Do not notify yet — let the load complete before triggering rebuilds.

    try {
      final restaurantId = await _scopeRepo.getActiveRestaurantId();

      // Anchor precedence: mock replay date → latest closed date.
      // Matches DemandForecastContextService and SchedulePlanReadService.
      final mockDate = await _mockReplayDateProvider(restaurantId);
      final anchorDate = mockDate ??
          await _shiftRepo.getLatestClosedBusinessDate(restaurantId);

      if (anchorDate == null) {
        _weights = null;
        _isLoading = false;
        _hasLoaded = true;
        notifyListeners();
        return;
      }

      // 60-day baseline window (inclusive).
      final baselineStart =
          DemandForecastContextService.subtractDays(anchorDate, 59);
      final baselineShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId,
        baselineStart,
        anchorDate,
      );

      // 21-day recent window (inclusive).
      final recentStart =
          DemandForecastContextService.subtractDays(anchorDate, 20);
      final recentShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId,
        recentStart,
        anchorDate,
      );

      _weights = DistributionWeightBuilder.fromDateWindowShifts(
        baselineShifts: baselineShifts,
        recentShifts: recentShifts,
      );
    } catch (_) {
      // Swallow errors — Schedule will fall back to default weights.
      _weights = null;
    }

    _isLoading = false;
    _hasLoaded = true;
    notifyListeners();
  }
}
