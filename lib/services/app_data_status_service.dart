/// Evaluates app data readiness from persisted state.
library;

import '../domain/models/import_run.dart';
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
  static const bool _demoMode = bool.fromEnvironment('kDemoMode');

  /// Stale threshold: current-state data older than this is considered stale.
  static const staleThresholdHours = 24;

  /// Evaluates the current app data status for the active restaurant.
  /// [now] is injectable for deterministic testing.
  Future<AppDataStatus> evaluate({DateTime? now}) async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();
    final effectiveNow = now ?? DateTime.now();

    // 1. Check latest import run
    final latestImport = await SqliteImportTrackingRepository.instance
        .getLatestImportRun(restaurantId);

    // First-backfill state derives from the same `import_runs` cache the
    // sync runtime persists into via `_persistFirstBackfillStatus`. The
    // proxy returns `first_backfill_status` per connection; the HTTP
    // sync client parses it and the runtime mirrors it as an
    // `ImportRun(mode: 'first_backfill')` row keyed on the job id. We
    // read whatever the latest persisted row is, mapping the proxy
    // status lexicon onto [FirstBackfillStatus].
    final firstBackfill = _firstBackfillStatusFrom(latestImport);

    // 2. Check for failed import
    if (latestImport != null && latestImport.status == 'failed') {
      final timestamp = latestImport.completedAt ?? latestImport.startedAt;
      return _isBackfillMode(latestImport.mode)
          ? AppDataStatus.backfillFailed(
              errorSummary: latestImport.errorSummary,
              timestamp: timestamp,
              firstBackfillStatus: firstBackfill,
            )
          : AppDataStatus.failedImport(
              errorSummary: latestImport.errorSummary,
              timestamp: timestamp,
              firstBackfillStatus: firstBackfill,
            );
    }

    // 2a. Defensive dead-letter handling. The current sync worker does
    // not emit `dead_lettered` yet, but the proxy contract reserves the
    // value (see `prompt.md` and the wider Phase 8 / 9 dead-letter
    // surface). When it lands, we surface it as a backfill-failed state
    // with a distinct [FirstBackfillStatus.deadLettered] field so the
    // UI can route the operator to support / disconnect+reconnect
    // without conflating with retryable failures.
    if (latestImport != null &&
        _isBackfillMode(latestImport.mode) &&
        firstBackfill == FirstBackfillStatus.deadLettered) {
      final timestamp = latestImport.completedAt ?? latestImport.startedAt;
      return AppDataStatus.backfillFailed(
        errorSummary: latestImport.errorSummary,
        timestamp: timestamp,
        firstBackfillStatus: FirstBackfillStatus.deadLettered,
      );
    }

    // 3. Check for any data at all
    final weeks = await SqliteWeekRecordRepository.instance.getWeekHistory(
      restaurantId,
    );
    final hasHistory = weeks.isNotEmpty;

    // 4. Determine current-week presence from open snapshots
    final openWeekId = await ShiftService.instance.getCurrentWeekId();
    final hasOpenState = openWeekId != null;

    // Also check for current-week closed shifts not yet in week_records
    final hasCurrentWeekShifts = await _hasCurrentWeekShifts(
      restaurantId,
      weeks,
      effectiveNow,
    );

    if (_isPendingImport(latestImport?.status) && !hasOpenState) {
      final timestamp = latestImport!.completedAt ?? latestImport.startedAt;
      return _isBackfillMode(latestImport.mode)
          ? AppDataStatus.backfillPending(
              timestamp: timestamp,
              firstBackfillStatus: firstBackfill,
            )
          : AppDataStatus.firstSyncPending(
              timestamp: timestamp,
              firstBackfillStatus: firstBackfill,
            );
    }

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
            .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

        if (latestUpdated != null) {
          final age = effectiveNow.difference(latestUpdated);
          if (age.inHours >= staleThresholdHours) {
            return AppDataStatus.stale(
              timestamp: latestUpdated.toUtc().toIso8601String(),
              firstBackfillStatus: firstBackfill,
            );
          }
        }
      }
    }

    if (_demoMode && hasOpenState) {
      return AppDataStatus.demo(
        timestamp: latestImport?.completedAt ?? latestImport?.startedAt,
        firstBackfillStatus: firstBackfill,
      );
    }

    // 7. Current/live state
    return AppDataStatus.current(
      importStatus: latestImport?.status,
      timestamp: latestImport?.completedAt ?? latestImport?.startedAt,
      firstBackfillStatus: firstBackfill,
    );
  }

  /// Checks whether closed shift_records exist for the actual current week
  /// (derived from [effectiveNow]) that are not yet in completed week_records.
  Future<bool> _hasCurrentWeekShifts(
    String restaurantId,
    List<dynamic> weekRecords,
    DateTime effectiveNow,
  ) async {
    final currentWeekId = _isoWeekId(effectiveNow);
    final completedWeekIds = weekRecords.map((w) => w.weekId as String).toSet();
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

  static bool _isPendingImport(String? status) {
    switch (status) {
      case 'queued':
      case 'pending':
      case 'started':
      case 'running':
      case 'in_progress':
        return true;
      default:
        return false;
    }
  }

  static bool _isBackfillMode(String mode) {
    final normalized = mode.toLowerCase();
    return normalized.contains('backfill') || normalized.contains('first_sync');
  }

  /// Maps the persisted import_run row (mode='first_backfill', mirrored
  /// from the proxy's `first_backfill_status`) onto a
  /// [FirstBackfillStatus] value the mobile UI can render.
  ///
  /// When the latest run is NOT a first_backfill row (or no row exists
  /// at all) we report [FirstBackfillStatus.notStarted] — the operator
  /// has not yet completed (or kicked off) a first-connection backfill
  /// for this restaurant.
  ///
  /// Lexicon mirrors `_persistFirstBackfillStatus` on the sync side
  /// (see `lib/services/sync/postgres_shift_record_to_mobile_sync.dart`)
  /// plus the proxy's wider job-status enum (`pending|queued|started|
  /// running|in_progress|succeeded|completed|failed|dead_lettered`):
  ///   * any "active" status (`pending|queued|started|running|
  ///     in_progress`)                   → [FirstBackfillStatus.inProgress].
  ///     The operator's connection exists and the backfill is moving;
  ///     UI must say "we're working on it", not "no data".
  ///   * `completed` / `succeeded`       → [FirstBackfillStatus.completed]
  ///   * `failed`                        → [FirstBackfillStatus.failed]
  ///   * `dead_lettered`                 → [FirstBackfillStatus.deadLettered]
  ///   * unknown statuses                → [FirstBackfillStatus.notStarted]
  ///                                       (defensive)
  ///
  /// Returns [FirstBackfillStatus.notStarted] when the latest import
  /// run is NOT a first_backfill row (or no row exists). That's the
  /// "no connections" path — the operator has not yet kicked off a
  /// first-connection backfill for this restaurant.
  static FirstBackfillStatus _firstBackfillStatusFrom(ImportRun? run) {
    if (run == null) return FirstBackfillStatus.notStarted;
    if (!_isBackfillMode(run.mode)) return FirstBackfillStatus.notStarted;
    switch (run.status) {
      case 'pending':
      case 'queued':
      case 'started':
      case 'running':
      case 'in_progress':
        return FirstBackfillStatus.inProgress;
      case 'completed':
      case 'succeeded':
        return FirstBackfillStatus.completed;
      case 'failed':
        return FirstBackfillStatus.failed;
      case 'dead_lettered':
        return FirstBackfillStatus.deadLettered;
      default:
        return FirstBackfillStatus.notStarted;
    }
  }
}
