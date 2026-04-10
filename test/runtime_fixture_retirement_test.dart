// Phase 7.55e.6 — Runtime Fixture Retirement Tests
//
// Proves that the production app runtime path uses repository-backed
// SQLite/mock replay state, not hardcoded DemoData or WeekToDate constants.
//
// A. ForgeFlowScope provides LiveShiftDataSource
// B. SQLite seed provenance uses mock replay
// C. StaticShiftDataSource uses MockIntegrationReplaySeed (not DemoData)
// D. No DemoData operational lists in sqlite_database.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  // ── A. ForgeFlowScope provides LiveShiftDataSource ──────────────────────

  group('A — ForgeFlowScope runtime source', () {
    testWidgets('ForgeFlowScope provides LiveShiftDataSource', (tester) async {
      late ShiftDataSource captured;

      await tester.pumpWidget(
        ForgeFlowScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                captured = context.read<ShiftDataSource>();
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(captured, isA<LiveShiftDataSource>());
      expect(captured, isNot(isA<StaticShiftDataSource>()));
    });
  });

  // ── B. SQLite seed provenance uses mock replay ──────────────────────────

  group('B — SQLite seed provenance', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('shift_records carry mock_pos_labor_replay source', () async {
      final db = await SqliteDatabase.instance.database;
      final shifts = await db.query('shift_records',
          where: 'source_system = ?',
          whereArgs: [MockIntegrationReplaySeed.sourceSystem]);
      expect(shifts, isNotEmpty,
          reason: 'shift_records should carry mock_pos_labor_replay source');
    });

    test('import_runs use mock_pos_labor_replay mode', () async {
      final db = await SqliteDatabase.instance.database;
      final runs = await db.query('import_runs',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(runs, isNotEmpty);
      expect(runs.first['mode'], 'mock_pos_labor_replay');
    });

    test('raw_import_records use mock_pos_labor_replay source_type', () async {
      final db = await SqliteDatabase.instance.database;
      final raws = await db.query('raw_import_records',
          where: 'source_type = ?',
          whereArgs: ['mock_pos_labor_replay']);
      expect(raws, isNotEmpty,
          reason:
              'raw_import_records should carry mock_pos_labor_replay source_type');
    });

    test('open_shift_snapshots carry mock replay source_system', () async {
      final db = await SqliteDatabase.instance.database;
      final snapshots = await db.query('open_shift_snapshots',
          where: 'source_system = ?',
          whereArgs: [MockIntegrationReplaySeed.sourceSystem]);
      expect(snapshots, isNotEmpty,
          reason:
              'open_shift_snapshots should carry mock_pos_labor_replay source');
    });

    test('all seeded open_shift_snapshots have mock replay source_system', () async {
      final db = await SqliteDatabase.instance.database;
      final all = await db.query('open_shift_snapshots');
      expect(all, isNotEmpty);

      for (final row in all) {
        expect(row['source_system'], MockIntegrationReplaySeed.sourceSystem,
            reason:
                '${row['day_label']}/${row['daypart']}/${row['status']} should have mock replay source_system');
      }
    });

    test('no seeded open_shift_snapshots have null or empty source_shift_id', () async {
      final db = await SqliteDatabase.instance.database;
      final all = await db.query('open_shift_snapshots');
      expect(all, isNotEmpty);

      for (final row in all) {
        final sourceShiftId = row['source_shift_id'] as String?;
        expect(sourceShiftId, isNotNull,
            reason:
                '${row['day_label']}/${row['daypart']}/${row['status']} should have non-null source_shift_id');
        expect(sourceShiftId, isNotEmpty,
            reason:
                '${row['day_label']}/${row['daypart']}/${row['status']} should have non-empty source_shift_id');
      }
    });

    test('open Friday dinner snapshot retains openShiftSourceShiftId', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('open_shift_snapshots',
          where: "day_label = 'Fri' AND daypart = 'dinner' AND status = 'open'");
      expect(rows.length, 1);
      expect(rows.first['source_shift_id'],
          MockIntegrationReplaySeed.openShiftSourceShiftId);
    });
  });

  // ── C. StaticShiftDataSource uses mock replay ───────────────────────────

  group('C — StaticShiftDataSource backed by MockIntegrationReplaySeed', () {
    test('getWeekHistory returns mock replay week records', () async {
      final history = await const StaticShiftDataSource().getWeekHistory();

      expect(history.length, MockIntegrationReplaySeed.output.weekRecords.length);

      // Same weekIds in same order
      final replayIds =
          MockIntegrationReplaySeed.output.weekRecords.map((w) => w.weekId).toList();
      final historyIds = history.map((w) => w.weekId).toList();
      expect(historyIds, replayIds);
    });

    test('getFullWeekShifts returns mock replay current-week shifts', () async {
      final shifts =
          await const StaticShiftDataSource().getFullWeekShifts('2026-W13');

      expect(shifts.length,
          MockIntegrationReplaySeed.output.currentWeekShifts.length);
      expect(shifts.where((s) => s.isClosed).length, 9);
      expect(shifts.where((s) => s.isProjected).length, 5);
    });

    test('getWeekToDate derives from mock replay closed shifts', () async {
      final wtd = await const StaticShiftDataSource().getWeekToDate();

      expect(wtd, isNotNull);
      expect(wtd!.weekId, MockIntegrationReplaySeed.currentWeekId);
      expect(wtd.shiftsCompleted, 9);
      expect(wtd.shiftsTotal, 14);

      // Covers should match mock replay closed sum
      final replayClosed = MockIntegrationReplaySeed.output.currentWeekShifts
          .where((s) => s.isClosed);
      final expectedCovers =
          replayClosed.fold<int>(0, (s, r) => s + r.covers);
      expect(wtd.totalCovers, expectedCovers);
    });

    test('getHistoryPatternRecords derives from mock replay history', () async {
      final patterns =
          await const StaticShiftDataSource().getHistoryPatternRecords();

      expect(patterns, isNotEmpty);
      // Pattern records are built from 8 historical weeks
      final replayWeekIds =
          MockIntegrationReplaySeed.historicalWeekIds.toSet();
      for (final p in patterns) {
        expect(replayWeekIds.contains(p.weekId), isTrue,
            reason: '${p.weekId} should come from mock replay history');
      }
    });
  });

  // ── D. sqlite_database.dart has no DemoData operational reads ───────────

  group('D — no DemoData operational lists in SQLite bootstrap', () {
    test('sqlite_database.dart does not reference DemoData', () {
      // Source-level guardrail: grep the implementation file for DemoData.
      // If someone re-introduces DemoData, this test catches it.
      final file =
          File('lib/infrastructure/persistence/sqlite/sqlite_database.dart');
      expect(file.existsSync(), isTrue);

      final source = file.readAsStringSync();
      expect(source.contains('DemoData.'), isFalse,
          reason: 'sqlite_database.dart must not reference DemoData');
      expect(source.contains('fixture_seed_data.dart'), isFalse,
          reason: 'sqlite_database.dart must not import fixture_seed_data');
    });

    test('shift_data_source.dart does not import fixture_seed_data', () {
      final file = File('lib/data/shift_data_source.dart');
      expect(file.existsSync(), isTrue);

      final source = file.readAsStringSync();
      expect(source.contains('fixture_seed_data.dart'), isFalse,
          reason: 'shift_data_source.dart must not import fixture_seed_data');
      expect(source.contains('DemoData.'), isFalse,
          reason: 'shift_data_source.dart must not reference DemoData');
    });
  });
}
