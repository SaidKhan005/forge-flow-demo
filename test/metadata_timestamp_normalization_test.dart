// Phase 7.55n.6 — Metadata timestamp normalization tests.
//
// Covers:
// A. Shared helper returns a UTC ISO timestamp
// B. Demo reseed writes UTC created_at / updated_at for restaurant/timing rows
// C. Demo reseed writes UTC updated_at for open-shift / reservation snapshots
// D. ShiftService.closeShift() writes UTC created_at for target_profile_versions
// E. WeeklyPlanSnapshot metadata remains UTC (generatedAt / lockedAt)
// F. Business-date behavior remains unchanged by this slice

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/domain/services/utc_metadata_timestamp.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/data/shift_service.dart';
import 'package:forge_and_flow/data/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';

/// Returns true if [ts] looks like a UTC ISO 8601 string.
///
/// Accepts both trailing 'Z' and '+00:00' offset forms.
bool _isUtcTimestamp(String ts) {
  return ts.endsWith('Z') ||
      ts.endsWith('+00:00') ||
      ts.contains('.') && ts.endsWith('Z');
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // ── A: Shared helper returns a UTC ISO timestamp ──────────────────────────

  group('A — nowIsoUtc returns UTC', () {
    test('returns ISO 8601 string ending with Z', () {
      final ts = nowIsoUtc();
      expect(_isUtcTimestamp(ts), isTrue,
          reason: 'Expected UTC marker, got: $ts');
    });

    test('parses back to a DateTime with isUtc == true', () {
      final ts = nowIsoUtc();
      final parsed = DateTime.parse(ts);
      expect(parsed.isUtc, isTrue);
    });

    test('two calls are monotonically non-decreasing', () {
      final a = nowIsoUtc();
      final b = nowIsoUtc();
      expect(b.compareTo(a), greaterThanOrEqualTo(0));
    });
  });

  // ── B: Demo reseed writes UTC for restaurant/timing rows ──────────────────

  group('B — restaurant and timing config seed metadata is UTC', () {
    test('restaurant_locations created_at is UTC', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_locations',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId]);
      expect(rows, isNotEmpty);
      final createdAt = rows.first['created_at'] as String;
      expect(_isUtcTimestamp(createdAt), isTrue,
          reason: 'Expected UTC created_at, got: $createdAt');
    });

    test('restaurant_locations updated_at is UTC', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_locations',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId]);
      expect(rows, isNotEmpty);
      final updatedAt = rows.first['updated_at'] as String;
      expect(_isUtcTimestamp(updatedAt), isTrue,
          reason: 'Expected UTC updated_at, got: $updatedAt');
    });

    test('restaurant_timing_configs created_at is UTC', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_timing_configs',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId]);
      expect(rows, isNotEmpty);
      final createdAt = rows.first['created_at'] as String;
      expect(_isUtcTimestamp(createdAt), isTrue,
          reason: 'Expected UTC created_at, got: $createdAt');
    });

    test('restaurant_timing_configs updated_at is UTC', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_timing_configs',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId]);
      expect(rows, isNotEmpty);
      final updatedAt = rows.first['updated_at'] as String;
      expect(_isUtcTimestamp(updatedAt), isTrue,
          reason: 'Expected UTC updated_at, got: $updatedAt');
    });
  });

  // ── C: Demo reseed writes UTC for open-shift / reservation snapshots ──────

  group('C — snapshot seed metadata is UTC', () {
    test('open_shift_snapshots updated_at is UTC', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('open_shift_snapshots',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId],
          limit: 5);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final updatedAt = row['updated_at'] as String;
        expect(_isUtcTimestamp(updatedAt), isTrue,
            reason: 'Expected UTC updated_at, got: $updatedAt');
      }
    });

    test('reservation_book_snapshots updated_at is UTC', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('reservation_book_snapshots',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId]);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final updatedAt = row['updated_at'] as String;
        expect(_isUtcTimestamp(updatedAt), isTrue,
            reason: 'Expected UTC updated_at, got: $updatedAt');
      }
    });
  });

  // ── D: closeShift writes UTC created_at for target_profile_versions ───────

  group('D — closeShift target_profile_version created_at is UTC', () {
    test('newly created version row has UTC created_at', () async {
      final db = await SqliteDatabase.instance.database;

      // Count existing version rows before closing a shift.
      final before = await db.query('target_profile_versions');
      final countBefore = before.length;

      // Close the Friday dinner shift.
      await ShiftService.instance.closeShift(ClosedShiftInput(
        businessDate: DateTime(2026, 3, 27),
        weekId: '2026-W13',
        dayLabel: 'Fri',
        daypart: 'dinner',
        covers: 304,
        forecastCovers: 310,
        actualSales: 12768.0,
        actualFohHours: 71,
        actualBohHours: 73,
        scheduledFohHours: 69,
        scheduledBohHours: 72,
        actualFohLaborDollars: 1246.25,
        actualBohLaborDollars: 1627.75,
        sourceSystem: 'demo_pos',
        sourceShiftId: 'w13-fri-dinner-close',
      ));

      // There should be at least one new version row.
      final after = await db.query('target_profile_versions',
          orderBy: 'created_at DESC');
      expect(after.length, greaterThan(countBefore));

      // The newest row should have a UTC created_at.
      final newest = after.first;
      final createdAt = newest['created_at'] as String;
      expect(_isUtcTimestamp(createdAt), isTrue,
          reason: 'Expected UTC created_at, got: $createdAt');
    });

    test('compat backfill version row has UTC created_at', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('target_profile_versions',
          where: 'target_profile_version_id LIKE ?',
          whereArgs: ['compat_%']);
      expect(rows, isNotEmpty);
      final createdAt = rows.first['created_at'] as String;
      expect(_isUtcTimestamp(createdAt), isTrue,
          reason: 'Expected UTC created_at, got: $createdAt');
    });
  });

  // ── E: WeeklyPlanSnapshot metadata remains UTC ────────────────────────────

  group('E — WeeklyPlanSnapshot generatedAt / lockedAt remain UTC', () {
    test('generated snapshot has UTC generatedAt', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      expect(_isUtcTimestamp(snapshot!.generatedAt), isTrue,
          reason: 'Expected UTC generatedAt, got: ${snapshot.generatedAt}');
    });

    test('generated snapshot has UTC lockedAt', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      expect(_isUtcTimestamp(snapshot!.lockedAt), isTrue,
          reason: 'Expected UTC lockedAt, got: ${snapshot.lockedAt}');
    });
  });

  // ── F: Business-date behavior remains unchanged ───────────────────────────

  group('F — business date is not affected by UTC normalization', () {
    test('shift_records business_date is plain date, not UTC timestamp',
        () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('shift_records',
          where: 'restaurant_id = ? AND business_date IS NOT NULL',
          whereArgs: [DemoScope.restaurantId],
          limit: 5);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final bd = row['business_date'] as String;
        // Business date should be YYYY-MM-DD, not a full ISO timestamp.
        expect(bd.length, 10,
            reason: 'business_date should be YYYY-MM-DD, got: $bd');
        expect(bd.contains('T'), isFalse,
            reason: 'business_date should not contain time component');
      }
    });

    test('open_shift_snapshots business_date is plain date', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('open_shift_snapshots',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId],
          limit: 5);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final bd = row['business_date'] as String;
        expect(bd.length, 10,
            reason: 'business_date should be YYYY-MM-DD, got: $bd');
        expect(bd.contains('T'), isFalse);
      }
    });

    test('mock_replay_state current_business_date is plain date', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('mock_replay_state',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId]);
      expect(rows, isNotEmpty);
      final bd = rows.first['current_business_date'] as String;
      expect(bd.length, 10,
          reason: 'current_business_date should be YYYY-MM-DD, got: $bd');
      expect(bd.contains('T'), isFalse);
    });
  });
}
