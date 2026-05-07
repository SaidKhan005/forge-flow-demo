// Phase 8 gap-4 — App data status reads first_backfill_status.
//
// Validates that AppDataStatusService.evaluate() surfaces the
// first-connection backfill lifecycle from the same `import_runs`
// cache the sync runtime persists into via `_persistFirstBackfillStatus`.
//
// Cases covered:
//   * No connections (no first-backfill row, no data)        -> noData /
//     FirstBackfillStatus.notStarted
//   * One connection, backfill `inProgress`                  ->
//     backfillPending / FirstBackfillStatus.inProgress
//   * One connection, backfill `completed`, data present     -> current /
//     FirstBackfillStatus.completed (the "ready" state)
//   * One connection, backfill `failed`                      ->
//     backfillFailed / FirstBackfillStatus.failed (diagnostic preserved)
//   * One connection, backfill `dead_lettered`               ->
//     backfillFailed / FirstBackfillStatus.deadLettered (operator
//     contacts support / disconnect+reconnect)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/import_run.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_import_tracking_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/services/app_data_status_service.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  group('first_backfill_status surfacing', () {
    test(
      'no connections (no first_backfill row, no data) -> '
      'noData / FirstBackfillStatus.notStarted',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('shift_records');
        await db.delete('week_records');
        await db.delete('open_shift_snapshots');
        await db.delete('import_runs');

        final status = await AppDataStatusService.instance.evaluate();

        expect(status.type, AppDataStatusType.noData);
        expect(status.firstBackfillStatus, FirstBackfillStatus.notStarted);
      },
    );

    test(
      'one connection, backfill inProgress -> '
      'backfillPending / FirstBackfillStatus.inProgress',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('shift_records');
        await db.delete('week_records');
        await db.delete('open_shift_snapshots');
        await db.delete('import_runs');

        // Mirror what `_persistFirstBackfillStatus` writes when the
        // proxy returns a `running` first_backfill_status row.
        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          const ImportRun(
            importRunId: 'first_backfill:job-1',
            restaurantId: 'demo_restaurant_001',
            mode: 'first_backfill',
            startedAt: '2026-05-06T12:00:00.000Z',
            status: 'running',
          ),
        );

        final status = await AppDataStatusService.instance.evaluate();

        expect(status.type, AppDataStatusType.backfillPending);
        expect(status.firstBackfillStatus, FirstBackfillStatus.inProgress);
      },
    );

    test(
      'one connection, backfill completed AND data present -> '
      'current / FirstBackfillStatus.completed (ready)',
      () async {
        // reseedDemo() already lays down the demo open-shift snapshots
        // and week records. Simulate a freshly completed first backfill
        // by replacing the latest import_run with the proxy's terminal
        // success status.
        final db = await SqliteDatabase.instance.database;
        await db.delete('import_runs');
        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          const ImportRun(
            importRunId: 'first_backfill:job-2',
            restaurantId: 'demo_restaurant_001',
            mode: 'first_backfill',
            startedAt: '2026-05-06T12:00:00.000Z',
            completedAt: '2026-05-06T12:30:00.000Z',
            status: 'completed',
          ),
        );

        final status = await AppDataStatusService.instance.evaluate();

        // "ready" in operator-language. The existing CURRENT type is
        // the live/up-to-date label and the new field carries the
        // backfill provenance.
        expect(status.type, AppDataStatusType.current);
        expect(status.firstBackfillStatus, FirstBackfillStatus.completed);
      },
    );

    test(
      'one connection, backfill failed -> '
      'backfillFailed / FirstBackfillStatus.failed with diagnostic',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('import_runs');
        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          const ImportRun(
            importRunId: 'first_backfill:job-3',
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
        expect(status.firstBackfillStatus, FirstBackfillStatus.failed);
        expect(status.description, contains('Vendor rate limit'));
      },
    );

    test(
      'one connection, backfill dead_lettered -> '
      'backfillFailed / FirstBackfillStatus.deadLettered',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('import_runs');
        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          const ImportRun(
            importRunId: 'first_backfill:job-4',
            restaurantId: 'demo_restaurant_001',
            mode: 'first_backfill',
            startedAt: '2026-05-06T12:00:00.000Z',
            completedAt: '2026-05-06T12:10:00.000Z',
            status: 'dead_lettered',
            errorSummary: 'Retry budget exhausted',
          ),
        );

        final status = await AppDataStatusService.instance.evaluate();

        expect(status.type, AppDataStatusType.backfillFailed);
        expect(status.firstBackfillStatus, FirstBackfillStatus.deadLettered);
        // The dead-letter description steers the operator toward the
        // recovery action (contact support / disconnect+reconnect)
        // when the persisted error_summary is absent; when present,
        // the persisted summary wins.
        expect(status.description, contains('Retry budget exhausted'));
        expect(status.label, 'BACKFILL DEAD-LETTERED');
      },
    );

    test(
      'dead_lettered with no persisted error_summary surfaces the '
      'recovery hint instead of a generic "first backfill failed" line',
      () async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('import_runs');
        await SqliteImportTrackingRepository.instance.createOrReplaceImportRun(
          const ImportRun(
            importRunId: 'first_backfill:job-5',
            restaurantId: 'demo_restaurant_001',
            mode: 'first_backfill',
            startedAt: '2026-05-06T12:00:00.000Z',
            completedAt: '2026-05-06T12:10:00.000Z',
            status: 'dead_lettered',
          ),
        );

        final status = await AppDataStatusService.instance.evaluate();

        expect(status.firstBackfillStatus, FirstBackfillStatus.deadLettered);
        expect(status.description.toLowerCase(), contains('support'));
      },
    );
  });
}
