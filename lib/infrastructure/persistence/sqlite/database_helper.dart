// DatabaseHelper — thin compatibility wrapper.
//
// Schema creation, migration, and demo seeding are now owned by SqliteDatabase.
// Operational queries are now owned by DAOs and repository implementations.
// This class delegates all work to those layers while preserving the
// DatabaseHelper.instance singleton that existing code references.
//
// Per-operator isolation (CODE_HEALTH Launch Blocker #1, 2026-05-07):
// historically `_restaurantId` was hardcoded to `DemoScope.restaurantId` so
// non-demo callers silently hit the demo scope. The hardcoding is removed:
// each method resolves the active scope via
// `SqliteRestaurantScopeRepository.instance.getActiveRestaurantId()` so the
// helper reflects the active operator/location at call time. CLAUDE.md:
// "Per-operator isolation is non-negotiable."

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'repositories/sqlite_baseline_selection_repository.dart';
import 'repositories/sqlite_restaurant_scope_repository.dart';
import 'repositories/sqlite_shift_record_repository.dart';
import 'repositories/sqlite_week_record_repository.dart';
import 'sqlite_database.dart';
import '../../../models/shift_record.dart';
import '../../../models/week_record.dart';

/// Resolves the active restaurant id for `DatabaseHelper` calls; injected
/// so tests can pin the scope without going through the global singleton.
typedef DatabaseHelperScopeReader = Future<String> Function();

class DatabaseHelper {
  DatabaseHelper._({DatabaseHelperScopeReader? scopeReader})
      : _scopeReader = scopeReader ??
            SqliteRestaurantScopeRepository.instance.getActiveRestaurantId,
        _label = 'instance';

  DatabaseHelper._forScope(String scopeId)
      : _scopeReader = (() async => scopeId),
        _label = 'forScope($scopeId)';

  final DatabaseHelperScopeReader _scopeReader;
  final String _label;

  /// Compatibility singleton. Resolves the active scope on every call;
  /// no longer pinned to `DemoScope.restaurantId`. Prefer
  /// [DatabaseHelper.forCurrentScope] in new code so the resolution seam
  /// is explicit at the call site.
  static final DatabaseHelper instance = DatabaseHelper._();

  /// Returns a `DatabaseHelper` pinned to a specific restaurant scope.
  /// Cached per-scope so repeated calls return the same instance.
  factory DatabaseHelper.forScope(String scopeId) {
    return _scoped.putIfAbsent(scopeId, () => DatabaseHelper._forScope(scopeId));
  }

  /// Returns a `DatabaseHelper` that resolves the active scope on every
  /// call (same behavior as [instance]). Prefer this over [instance] so
  /// the per-operator isolation seam is explicit at the call site.
  factory DatabaseHelper.forCurrentScope() => instance;

  static final Map<String, DatabaseHelper> _scoped = <String, DatabaseHelper>{};

  Future<Database> get database => SqliteDatabase.instance.database;

  Future<String> _resolveRestaurantId() async {
    final id = await _scopeReader();
    if (kDebugMode && _label == 'instance' && id != DemoScope.restaurantId) {
      debugPrint(
        'DatabaseHelper.instance: resolved non-demo scope "$id". '
        'Migrate this call site to DatabaseHelper.forCurrentScope() or '
        'pass the scope explicitly to the underlying repository.',
      );
    }
    return id;
  }

  // ── Baseline selected record keys ─────────────────────────────────────────

  Future<Set<String>> getBaselineSelectedRecordKeys() async {
    final restaurantId = await _resolveRestaurantId();
    return SqliteBaselineSelectionRepository.instance
        .getSelectedRecordKeys(restaurantId);
  }

  Future<void> replaceBaselineSelectedRecordKeys(Set<String> keys) async {
    final restaurantId = await _resolveRestaurantId();
    return SqliteBaselineSelectionRepository.instance
        .replaceSelectedRecordKeys(restaurantId, keys);
  }

  // ── Shift records ─────────────────────────────────────────────────────────

  Future<List<ShiftRecord>> getShiftsForWeek(String weekId) async {
    final restaurantId = await _resolveRestaurantId();
    return SqliteShiftRecordRepository.instance
        .getShiftsForWeek(restaurantId, weekId);
  }

  Future<int> replaceShiftForSlot(ShiftRecord record) =>
      SqliteShiftRecordRepository.instance.replaceShiftForSlot(record);

  // ── Week records ──────────────────────────────────────────────────────────

  Future<List<WeekRecord>> getWeekHistory() async {
    final restaurantId = await _resolveRestaurantId();
    return SqliteWeekRecordRepository.instance.getWeekHistory(restaurantId);
  }

  Future<int> upsertWeekRecord(WeekRecord record) =>
      SqliteWeekRecordRepository.instance.upsertWeekRecord(record);

  // ── Historical closed shifts query ────────────────────────────────────────

  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
      List<String> weekIds) async {
    final restaurantId = await _resolveRestaurantId();
    return SqliteShiftRecordRepository.instance
        .getClosedShiftsForWeeks(restaurantId, weekIds);
  }

  // ── Reseed ────────────────────────────────────────────────────────────────

  Future<void> reseedDemo() => SqliteDatabase.instance.reseedDemo();
}
