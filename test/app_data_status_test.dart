// Phase 7.51d â€” App data status tests.
//
// Validates:
// A. no_data when empty
// B. historical_only when history exists but no current-week open state
// C. failed_import when latest import run failed
// D. stale when current-state timestamps are old
// E. current after fresh reseed
// F. intraday open-snapshot replacement

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/app_data_status_service.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/domain/models/import_run.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_import_tracking_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/app_data_status.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  setUp(setUpSqliteDemo);

  // â”€â”€ A: no_data â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” no data', () {
    test('status resolves to noData when all tables are empty', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('shift_records');
      await db.delete('week_records');
      await db.delete('open_shift_snapshots');
      await db.delete('import_runs');

      final status = await AppDataStatusService.instance.evaluate();
      expect(status.type, AppDataStatusType.noData);
      expect(status.label, 'NO DATA');
      expect(status.description.toLowerCase(), isNot(contains('demo')));
    });
  });

  group('A2 - first sync and backfill pending', () {
    test(
      'status resolves to backfillPending while first backfill is running',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('shift_records');
        await db.delete('week_records');
        await db.delete('open_shift_snapshots');
        await db.delete('import_runs');

        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          ImportRun(
            importRunId: 'backfill_run_001',
            restaurantId: 'demo_restaurant_001',
            mode: 'first_backfill',
            startedAt: '2026-05-06T12:00:00.000Z',
            status: 'running',
          ),
        );

        final status = await AppDataStatusService.instance.evaluate();
        expect(status.type, AppDataStatusType.backfillPending);
        expect(status.label, 'BACKFILL PENDING');
      },
    );

    test(
      'status resolves to firstSyncPending for non-backfill sync startup',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('shift_records');
        await db.delete('week_records');
        await db.delete('open_shift_snapshots');
        await db.delete('import_runs');

        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          ImportRun(
            importRunId: 'sync_run_001',
            restaurantId: 'demo_restaurant_001',
            mode: 'proxy_sync',
            startedAt: '2026-05-06T12:00:00.000Z',
            status: 'pending',
          ),
        );

        final status = await AppDataStatusService.instance.evaluate();
        expect(status.type, AppDataStatusType.firstSyncPending);
        expect(status.label, 'FIRST SYNC PENDING');
      },
    );
  });

  // â”€â”€ B: historical_only â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” historical only', () {
    test(
      'status resolves to historicalOnly when only completed week history exists',
      () async {
        final db = await SqliteDatabase.instance.database;
        // Remove all current-week state: open snapshots AND current-week shifts
        await db.delete('open_shift_snapshots');
        await db.delete(
          'shift_records',
        ); // remove all shifts including current week
        // week_records still has completed historical weeks â†’ historicalOnly

        final status = await AppDataStatusService.instance.evaluate();
        expect(status.type, AppDataStatusType.historicalOnly);
        expect(status.label, 'HISTORICAL ONLY');
      },
    );

    test('partial current-week closed shifts are NOT historicalOnly', () async {
      final db = await SqliteDatabase.instance.database;
      // Remove open snapshots only â€” current-week closed shifts remain
      await db.delete('open_shift_snapshots');
      // shift_records still has 2026-W13 closed shifts not in week_records
      // Inject now=2026-03-27 (Friday of W13) so the status service resolves
      // the current week as 2026-W13
      final now = DateTime(2026, 3, 27);

      final status = await AppDataStatusService.instance.evaluate(now: now);
      expect(status.type, isNot(AppDataStatusType.historicalOnly));
    });

    test(
      'older stray unrolled week does NOT count as current-week state',
      () async {
        final db = await SqliteDatabase.instance.database;
        // Clear all current state
        await db.delete('open_shift_snapshots');
        await db.delete('shift_records');
        // week_records still has completed historical weeks
        // Insert one stray closed shift in an old week NOT in week_records
        await db.insert('shift_records', {
          'restaurant_id': 'demo_restaurant_001',
          'week_id': '2025-W50', // old week, not current
          'day_label': 'Mon',
          'daypart': 'lunch',
          'status': 'closed',
          'covers': 100,
          'forecast_covers': 120,
          'ppa': 42.0,
          'cplh': 4.5,
          'splh': 180.0,
          'blended_wage': 18.5,
          'foh_hours': 22,
          'boh_hours': 24,
          'foh_labor_pct': 9.0,
          'boh_labor_pct': 12.0,
          'total_labor_pct': 21.0,
          'theoretical_labor_pct': 20.5,
          'variance_pts': 0.5,
          'primary_lever': 'COVERS_DOWN',
        });

        // now = 2026-03-27 â€” current week is 2026-W13, not 2025-W50
        final status = await AppDataStatusService.instance.evaluate(
          now: DateTime(2026, 3, 27),
        );
        // The stray 2025-W50 shift should NOT make this "current"
        expect(status.type, AppDataStatusType.historicalOnly);
      },
    );
  });

  // â”€â”€ C: failed_import â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C â€” failed import', () {
    test('status resolves to failedImport when latest run failed', () async {
      // Clear existing runs and insert a failed one
      final db = await SqliteDatabase.instance.database;
      await db.delete('import_runs');

      final failedRun = ImportRun(
        importRunId: 'failed_run_001',
        restaurantId: 'demo_restaurant_001',
        mode: 'fixture_replay',
        startedAt: DateTime.now().toIso8601String(),
        completedAt: DateTime.now().toIso8601String(),
        status: 'failed',
        errorSummary: 'Connection timeout',
      );
      await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
        failedRun,
      );

      final status = await AppDataStatusService.instance.evaluate();
      expect(status.type, AppDataStatusType.failedImport);
      expect(status.label, 'IMPORT FAILED');
      expect(status.description, contains('Connection timeout'));
    });

    test(
      'status resolves to backfillFailed for failed first backfill',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('import_runs');

        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          const ImportRun(
            importRunId: 'first_backfill_failed_001',
            restaurantId: 'demo_restaurant_001',
            mode: 'first_backfill',
            startedAt: '2026-05-06T12:00:00.000Z',
            completedAt: '2026-05-06T12:05:00.000Z',
            status: 'failed',
            errorSummary: 'Vendor rate limit',
          ),
        );

        final status = await AppDataStatusService.instance.evaluate();
        expect(status.type, AppDataStatusType.backfillFailed);
        expect(status.label, 'BACKFILL FAILED');
        expect(status.description, contains('Vendor rate limit'));
      },
    );
  });

  // â”€â”€ D: stale â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D â€” stale data', () {
    test('status resolves to stale when open state is old', () async {
      // Replace open snapshots with old timestamps
      final db = await SqliteDatabase.instance.database;
      final oldTimestamp = DateTime.now()
          .subtract(const Duration(hours: 48))
          .toIso8601String();

      await db.execute(
        "UPDATE open_shift_snapshots SET updated_at = ? WHERE restaurant_id = ?",
        [oldTimestamp, 'demo_restaurant_001'],
      );

      final status = await AppDataStatusService.instance.evaluate(
        now: DateTime.now(),
      );
      expect(status.type, AppDataStatusType.stale);
      expect(status.label, 'STALE');
    });

    test('stale threshold is deterministic with injected now', () async {
      // Set timestamps to 23 hours ago â€” should be current
      final db = await SqliteDatabase.instance.database;
      final recentTimestamp = DateTime.now()
          .subtract(const Duration(hours: 23))
          .toIso8601String();

      await db.execute(
        "UPDATE open_shift_snapshots SET updated_at = ? WHERE restaurant_id = ?",
        [recentTimestamp, 'demo_restaurant_001'],
      );

      final status = await AppDataStatusService.instance.evaluate(
        now: DateTime.now(),
      );
      expect(status.type, AppDataStatusType.current);
    });
  });

  // â”€â”€ E: current â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E â€” current after reseed', () {
    test('status resolves to current after fresh reseed', () async {
      final status = await AppDataStatusService.instance.evaluate();
      expect(status.type, AppDataStatusType.current);
      expect(status.label, 'CURRENT');
    });

    test(
      'running sync does not hide an already-landed open snapshot',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('import_runs');
        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          const ImportRun(
            importRunId: 'sync_run_with_open_state',
            restaurantId: 'demo_restaurant_001',
            mode: 'proxy_sync',
            startedAt: '2026-05-06T12:00:00.000Z',
            status: 'running',
          ),
        );

        final status = await AppDataStatusService.instance.evaluate();
        expect(status.type, AppDataStatusType.current);
        expect(status.latestImportStatus, 'running');
      },
    );
  });

  // â”€â”€ F: intraday open-snapshot replacement â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('F â€” intraday open-snapshot replacement', () {
    test('replacing open snapshot updates persisted current state', () async {
      final repo = SqliteOpenShiftSnapshotRepository.instance;

      // Read original
      final original = await repo.getCurrentOpenShift('demo_restaurant_001');
      expect(original, isNotNull);
      final originalCovers = original!.currentCovers;

      // Replace with updated actuals
      final updated = OpenShiftSnapshot(
        restaurantId: original.restaurantId,
        weekId: original.weekId,
        dayLabel: original.dayLabel,
        daypart: original.daypart,
        status: 'open',
        businessDate: original.businessDate,
        forecastCovers: original.forecastCovers,
        currentCovers: originalCovers + 20,
        scheduledFohHours: original.scheduledFohHours,
        scheduledBohHours: original.scheduledBohHours,
        currentPPA: 41.50,
        currentCPLH: 4.2,
        currentSPLH: 176.0,
        blendedWage: 18.80,
        timeLabel: '8:15 PM',
        serviceElapsedLabel: '3h 47m into service',
        updatedAt: DateTime.now().toIso8601String(),
      );
      await repo.replaceOpenShiftSnapshot(updated);

      // Re-read through the service query path
      final reloaded = await repo.getCurrentOpenShift('demo_restaurant_001');
      expect(reloaded, isNotNull);
      expect(reloaded!.currentCovers, originalCovers + 20);
      expect(reloaded.currentPPA, 41.50);
      expect(reloaded.timeLabel, '8:15 PM');

      // Full week merge also reflects the update
      final fullWeek = await ShiftService.instance.getFullWeekShifts(
        '2026-W13',
      );
      final openRows = fullWeek.where((s) => s.isOpen).toList();
      expect(openRows, isNotEmpty);
      expect(openRows.first.covers, originalCovers + 20);
    });
  });
}
