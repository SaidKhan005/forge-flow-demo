// DatabaseHelper — thin compatibility wrapper.
//
// Schema creation, migration, and demo seeding are now owned by SqliteDatabase.
// Operational queries are now owned by DAOs and repository implementations.
// This class delegates all work to those layers while preserving the
// DatabaseHelper.instance singleton that existing code references.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'repositories/sqlite_baseline_selection_repository.dart';
import 'repositories/sqlite_shift_record_repository.dart';
import 'repositories/sqlite_week_record_repository.dart';
import 'sqlite_database.dart';
import '../../../models/shift_record.dart';
import '../../../models/week_record.dart';

class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  Future<Database> get database => SqliteDatabase.instance.database;

  static const _restaurantId = DemoScope.restaurantId;

  // ── Baseline selected record keys ─────────────────────────────────────────

  Future<Set<String>> getBaselineSelectedRecordKeys() =>
      SqliteBaselineSelectionRepository.instance
          .getSelectedRecordKeys(_restaurantId);

  Future<void> replaceBaselineSelectedRecordKeys(Set<String> keys) =>
      SqliteBaselineSelectionRepository.instance
          .replaceSelectedRecordKeys(_restaurantId, keys);

  // ── Shift records ─────────────────────────────────────────────────────────

  Future<List<ShiftRecord>> getShiftsForWeek(String weekId) =>
      SqliteShiftRecordRepository.instance
          .getShiftsForWeek(_restaurantId, weekId);

  Future<int> replaceShiftForSlot(ShiftRecord record) =>
      SqliteShiftRecordRepository.instance.replaceShiftForSlot(record);

  // ── Week records ──────────────────────────────────────────────────────────

  Future<List<WeekRecord>> getWeekHistory() =>
      SqliteWeekRecordRepository.instance.getWeekHistory(_restaurantId);

  Future<int> upsertWeekRecord(WeekRecord record) =>
      SqliteWeekRecordRepository.instance.upsertWeekRecord(record);

  // ── Historical closed shifts query ────────────────────────────────────────

  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
          List<String> weekIds) =>
      SqliteShiftRecordRepository.instance
          .getClosedShiftsForWeeks(_restaurantId, weekIds);

  // ── Reseed ────────────────────────────────────────────────────────────────

  Future<void> reseedDemo() => SqliteDatabase.instance.reseedDemo();
}
