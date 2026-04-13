/// Evaluates app data readiness from persisted state.
library;

import '../infrastructure/persistence/sqlite/repositories/sqlite_import_tracking_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../models/app_data_status.dart';
import 'shift_service.dart';

class AppDataStatusService {
  AppDataStatusService._();
  static final AppDataStatusService instance = AppDataStatusService._();

  /// Stale threshold: current-state data older than this is considered stale.
  static const staleThresholdHours = 24;

  /// Evaluates the current app data status for the active restaurant.
  /// [now] is injectable for deterministic testing.
  Future<AppDataStatus> evaluate({DateTime? now}) async {
    final restaurantId =
        await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
    final effectiveNow = now ?? DateTime.now();

    // 1. Check latest import run
    final latestImport = await SqliteImportTrackingRepository.instance
        .getLatestImportRun(restaurantId);

    // 2. Check for failed import
    if (latestImport != null && latestImport.status == 'failed') {
      return AppDataStatus.failedImport(
        errorSummary: latestImport.errorSummary,
        timestamp: latestImport.completedAt ?? latestImport.startedAt,
      );
    }

    // 3. Check for any data at all
    final weeks = await SqliteWeekRecordRepository.instance
        .getWeekHistory(restaurantId);
    final hasHistory = weeks.isNotEmpty;

    // 4. Determine current-week presence from open snapshots
    final openWeekId = await ShiftService.instance.getCurrentWeekId();
    final hasOpenState = openWeekId != null;

    // Also check for current-week closed shifts not yet in week_records
    final hasCurrentWeekShifts =
        await _hasCurrentWeekShifts(restaurantId, weeks, effectiveNow);

    if (!hasHistory && !hasOpenState && !hasCurrentWeekShifts) {
      return AppDataStatus.noData;
    }

    // 5. Historical-only: has history but no current-week state at all
    if (hasHistory && !hasOpenState && !hasCurrentWeekShifts) {
      return AppDataStatus.historicalOnly;
    }

    // 6. Check staleness from open-state timestamps
    if (hasOpenState) {
      final openSnapshots = await SqliteOpenShiftSnapshotRepository.instance
          .getOpenShiftsForWeek(restaurantId, openWeekId);
      if (openSnapshots.isNotEmpty) {
        final latestUpdated = openSnapshots
            .map((s) => DateTime.tryParse(s.updatedAt))
            .whereType<DateTime>()
            .fold<DateTime?>(
                null, (a, b) => a == null || b.isAfter(a) ? b : a);

        if (latestUpdated != null) {
          final age = effectiveNow.difference(latestUpdated);
          if (age.inHours >= staleThresholdHours) {
            return AppDataStatus.stale(
                timestamp: latestUpdated.toIso8601String());
          }
        }
      }
    }

    // 7. Current/live state
    return AppDataStatus.current(
      importStatus: latestImport?.status,
      timestamp: latestImport?.completedAt ?? latestImport?.startedAt,
    );
  }

  /// Checks whether closed shift_records exist for the actual current week
  /// (derived from [effectiveNow]) that are not yet in completed week_records.
  Future<bool> _hasCurrentWeekShifts(
      String restaurantId, List<dynamic> weekRecords, DateTime effectiveNow) async {
    final currentWeekId = _isoWeekId(effectiveNow);
    final completedWeekIds =
        weekRecords.map((w) => w.weekId as String).toSet();
    if (completedWeekIds.contains(currentWeekId)) return false;

    final db = await SqliteDatabase.instance.database;
    final rows = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM shift_records "
      "WHERE restaurant_id = ? AND week_id = ? AND status = 'closed'",
      [restaurantId, currentWeekId],
    );
    final count = (rows.first['cnt'] as int?) ?? 0;
    return count > 0;
  }

  /// Derives ISO week id (YYYY-Www) from a DateTime.
  static String _isoWeekId(DateTime date) {
    // ISO 8601: week 1 contains Jan 4. Monday is day 1.
    final jan4 = DateTime(date.year, 1, 4);
    final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    final daysSince = date.difference(week1Monday).inDays;
    if (daysSince < 0) {
      // Date is before week 1 of this year — belongs to previous year's last week
      return _isoWeekId(DateTime(date.year - 1, 12, 28));
    }
    final weekNum = (daysSince ~/ 7) + 1;
    return '${date.year}-W${weekNum.toString().padLeft(2, '0')}';
  }
}
