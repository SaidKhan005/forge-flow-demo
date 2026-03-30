import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite_mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/shift_record.dart';
import '../models/week_record.dart';
import 'demo_data.dart';

class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    String dbPath;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      dbPath = p.join(Directory.current.path, 'forge_flow_v2.db');
    } else {
      final dir = await sqflite_mobile.getDatabasesPath();
      dbPath = p.join(dir, 'forge_flow_v2.db');
    }

    return openDatabase(
      dbPath,
      version: 6,
      onCreate: _onCreate,
      onUpgrade: (db, oldV, newV) async {
        await db.execute('DROP TABLE IF EXISTS shift_records');
        await db.execute('DROP TABLE IF EXISTS week_records');
        await db.execute('DROP TABLE IF EXISTS baseline_selected_records');
        await _onCreate(db, newV);
      },
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE shift_records (
        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
        week_id               TEXT NOT NULL,
        day_label             TEXT NOT NULL,
        daypart               TEXT NOT NULL,
        status                TEXT NOT NULL DEFAULT 'closed',
        covers                INTEGER NOT NULL,
        forecast_covers       INTEGER NOT NULL,
        ppa                   REAL NOT NULL,
        cplh                  REAL NOT NULL,
        splh                  REAL NOT NULL,
        blended_wage          REAL NOT NULL,
        foh_hours             INTEGER NOT NULL,
        boh_hours             INTEGER NOT NULL,
        foh_labor_pct         REAL NOT NULL,
        boh_labor_pct         REAL NOT NULL,
        total_labor_pct       REAL NOT NULL,
        theoretical_labor_pct REAL NOT NULL DEFAULT 20.6,
        variance_pts          REAL NOT NULL,
        primary_lever         TEXT NOT NULL,
        scheduled_foh_hours   INTEGER,
        scheduled_boh_hours   INTEGER,
        foh_labor_dollar      REAL,
        boh_labor_dollar      REAL,
        source_system         TEXT,
        source_shift_id       TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE week_records (
        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
        week_id               TEXT NOT NULL UNIQUE,
        week_label            TEXT NOT NULL,
        total_covers          INTEGER NOT NULL,
        forecast_covers       INTEGER NOT NULL,
        total_foh_hours       INTEGER NOT NULL,
        total_boh_hours       INTEGER NOT NULL,
        avg_ppa               REAL NOT NULL,
        avg_cplh              REAL NOT NULL,
        theoretical_labor_pct REAL NOT NULL,
        actual_labor_pct      REAL NOT NULL,
        dollar_gap            REAL NOT NULL,
        primary_lever_id      TEXT NOT NULL,
        shifts_completed      INTEGER NOT NULL DEFAULT 14,
        blended_foh_wage      REAL NOT NULL DEFAULT 16.50,
        blended_boh_wage      REAL NOT NULL DEFAULT 21.35
      )
    ''');

    await db.execute('''
      CREATE TABLE baseline_selected_records (
        record_key TEXT PRIMARY KEY NOT NULL
      )
    ''');

    final batch = db.batch();
    for (final s in DemoData.currentWeekShifts) {
      batch.insert('shift_records', s.toMap()..remove('id'));
    }
    for (final s in DemoData.historicalClosedShifts) {
      batch.insert('shift_records', s.toMap()..remove('id'));
    }
    for (final w in DemoData.weekHistory) {
      batch.insert('week_records', w.toMap()..remove('id'));
    }
    await batch.commit(noResult: true);
  }

  // ── Baseline selected record keys ─────────────────────────────────────────

  Future<Set<String>> getBaselineSelectedRecordKeys() async {
    final db = await database;
    final rows = await db.query('baseline_selected_records');
    return rows.map((r) => r['record_key'] as String).toSet();
  }

  Future<void> replaceBaselineSelectedRecordKeys(Set<String> keys) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('baseline_selected_records');
      for (final key in keys) {
        await txn.insert('baseline_selected_records', {'record_key': key});
      }
    });
  }

  // ── Shift records ─────────────────────────────────────────────────────────

  Future<List<ShiftRecord>> getShiftsForWeek(String weekId) async {
    final db = await database;
    final rows = await db.query(
      'shift_records',
      where: 'week_id = ?',
      whereArgs: [weekId],
    );
    return rows.map(ShiftRecord.fromMap).toList();
  }

  Future<int> insertShift(ShiftRecord record) async {
    final db = await database;
    return db.insert('shift_records', record.toMap()..remove('id'));
  }

  /// Atomically replaces any existing row for the same week/day/daypart slot,
  /// then inserts the new record. Safe to use for both projected → closed
  /// replacement and re-closing an already-closed slot.
  Future<int> replaceShiftForSlot(ShiftRecord record) async {
    final db = await database;
    return db.transaction<int>((txn) async {
      await txn.delete(
        'shift_records',
        where: 'week_id = ? AND day_label = ? AND daypart = ?',
        whereArgs: [record.weekId, record.dayLabel, record.daypart],
      );
      return txn.insert('shift_records', record.toMap()..remove('id'));
    });
  }

  // ── Week records ──────────────────────────────────────────────────────────

  Future<List<WeekRecord>> getWeekHistory() async {
    final db = await database;
    final rows = await db.query('week_records', orderBy: 'week_id DESC');
    return rows.map(WeekRecord.fromMap).toList();
  }

  Future<int> upsertWeekRecord(WeekRecord record) async {
    final db = await database;
    return db.insert(
      'week_records',
      record.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> reseedDemo() async {
    final db = await database;
    await db.delete('shift_records');
    await db.delete('week_records');
    await db.delete('baseline_selected_records');
    final batch = db.batch();
    for (final s in DemoData.currentWeekShifts) {
      batch.insert('shift_records', s.toMap()..remove('id'));
    }
    for (final s in DemoData.historicalClosedShifts) {
      batch.insert('shift_records', s.toMap()..remove('id'));
    }
    for (final w in DemoData.weekHistory) {
      batch.insert('week_records', w.toMap()..remove('id'));
    }
    await batch.commit(noResult: true);
  }

  // ── Historical closed shifts query ────────────────────────────────────────

  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
      List<String> weekIds) async {
    if (weekIds.isEmpty) return [];
    final db = await database;
    final placeholders = weekIds.map((_) => '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT * FROM shift_records '
      "WHERE status = 'closed' "
      'AND week_id IN ($placeholders) '
      'ORDER BY week_id DESC',
      weekIds,
    );
    return rows.map(ShiftRecord.fromMap).toList();
  }
}
