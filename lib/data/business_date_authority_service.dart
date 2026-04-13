// Phase 7.55m.1 — Shared business-date authority service.
//
// Centralizes the planning-anchor date precedence that was previously
// duplicated across BaselineManagerService, DemandForecastContextService,
// SchedulePlanReadService, and WeeklyPlanSnapshotService.
//
// Planning-anchor precedence:
//   1. Mock replay current business date (when available)
//   2. Latest closed business date (fallback)
//
// This service is strictly for planning-oriented date resolution.
// Operational current-shift authority (open-shift snapshots, live
// business day) remains in ShiftService / OpenShiftSnapshotRepository
// and is intentionally separate.
//
// Phase 7.55m.1a: Day-ordering constants now delegate to the shared
// CanonicalDayOrder source in lib/domain/canonical_day_order.dart.

import '../domain/canonical_day_order.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';

class BusinessDateAuthorityService {
  BusinessDateAuthorityService._();
  static final BusinessDateAuthorityService instance =
      BusinessDateAuthorityService._();

  final ShiftRecordRepository _shiftRepo =
      SqliteShiftRecordRepository.instance;

  // ── Planning-anchor resolution ──────────────────────────────────────────

  /// Resolves the planning-anchor date for [restaurantId].
  ///
  /// Precedence:
  ///   1. Mock replay current business date (when available)
  ///   2. Latest closed business date (fallback)
  ///
  /// Returns null when neither source can provide a date (genuinely no
  /// operational history for this restaurant).
  ///
  /// Used by: BaselineManagerService, DemandForecastContextService,
  /// SchedulePlanReadService, WeeklyPlanSnapshotService.
  ///
  /// NOT used by: ShiftService operational reads (open shift, current
  /// business day). Those use OpenShiftSnapshotRepository directly.
  Future<String?> resolvePlanningAnchorDate(String restaurantId) async {
    final mockDate = await SqliteDatabase.instance
        .getMockReplayBusinessDate(restaurantId);
    if (mockDate != null) return mockDate;

    return _shiftRepo.getLatestClosedBusinessDate(restaurantId);
  }

  // ── Canonical day ordering ──────────────────────────────────────────────
  // All constants delegate to CanonicalDayOrder — the single shared source
  // in lib/domain/canonical_day_order.dart. Kept as pass-throughs so
  // existing callers do not need a simultaneous migration.

  /// Canonical Mon–Sun day ordering (0-based).
  ///
  /// Delegates to [CanonicalDayOrder.index].
  static const Map<String, int> canonicalDayOrder = CanonicalDayOrder.index;

  /// Canonical day-of-week labels in Mon–Sun order.
  ///
  /// Delegates to [CanonicalDayOrder.labels].
  static const List<String> canonicalDayLabels = CanonicalDayOrder.labels;

  /// Full day-of-week names indexed by 1-based day number.
  ///
  /// Delegates to [CanonicalDayOrder.fullNames].
  static const Map<int, String> fullDayNames = CanonicalDayOrder.fullNames;

  /// Returns the 1-based day number for [dayLabel], or null if unrecognized.
  ///
  /// Delegates to [CanonicalDayOrder.dayNumber].
  static int? dayNumber(String dayLabel) => CanonicalDayOrder.dayNumber(dayLabel);

  // ── Date arithmetic ─────────────────────────────────────────────────────

  /// Subtracts [days] from an ISO date string, returning an ISO date string.
  ///
  /// Shared across planning services to avoid duplicating date arithmetic.
  static String subtractDays(String isoDate, int days) {
    final parts = isoDate.split('-');
    final dt = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final result = dt.subtract(Duration(days: days));
    return '${result.year}-${result.month.toString().padLeft(2, '0')}'
        '-${result.day.toString().padLeft(2, '0')}';
  }
}
