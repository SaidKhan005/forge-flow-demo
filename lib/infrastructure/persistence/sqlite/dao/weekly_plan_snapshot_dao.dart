import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/demand_forecast_context.dart';
import '../../../../domain/models/weekly_plan_snapshot.dart';

class WeeklyPlanSnapshotDao {
  final Database _db;
  const WeeklyPlanSnapshotDao(this._db);

  /// Returns the snapshot in force for [businessDate], or null.
  ///
  /// Finds the snapshot where weekStartDate <= businessDate <= weekEndDate.
  Future<WeeklyPlanSnapshot?> getSnapshotForBusinessDate(
    String restaurantId,
    String businessDate,
  ) async {
    final rows = await _db.query(
      'weekly_plan_snapshots',
      where:
          'restaurant_id = ? AND week_start_date <= ? AND week_end_date >= ?',
      whereArgs: [restaurantId, businessDate, businessDate],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Returns the snapshot matching [weekKey], or null.
  Future<WeeklyPlanSnapshot?> getSnapshotForWeekKey(
    String restaurantId,
    String weekKey,
  ) async {
    final rows = await _db.query(
      'weekly_plan_snapshots',
      where: 'restaurant_id = ? AND week_key = ?',
      whereArgs: [restaurantId, weekKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Inserts or replaces a snapshot.
  Future<void> upsertSnapshot(WeeklyPlanSnapshot snapshot) async {
    final map = snapshot.toMap();
    final dayRows = map.remove('day_rows') as List<dynamic>;
    final forecastContext = map.remove('forecast_context');
    map['day_rows_json'] = jsonEncode(dayRows);
    map['forecast_context_json'] = forecastContext == null
        ? null
        : jsonEncode(forecastContext);
    // Theme H#6 — `metadata` is a Map<String, Object?> on the snapshot
    // model. SQLite can't store maps directly, so encode it as JSON for
    // the cell value the same way day_rows / forecast_context are.
    if (map.containsKey('metadata')) {
      final rawMetadata = map['metadata'];
      map['metadata'] = rawMetadata == null ? null : jsonEncode(rawMetadata);
    }
    // SQLite stores booleans as 0 / 1; the model uses bool. Coerce so the
    // INTEGER column accepts the value cleanly.
    if (map.containsKey('is_active')) {
      final raw = map['is_active'];
      if (raw is bool) {
        map['is_active'] = raw ? 1 : 0;
      }
    }
    await _db.insert(
      'weekly_plan_snapshots',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> attachForecastContext({
    required String restaurantId,
    required DemandForecastContext context,
    String? forecastContextId,
    String? weekStartDate,
    String? weekEndDate,
  }) async {
    final values = <String, Object?>{
      if (forecastContextId != null) 'forecast_context_id': forecastContextId,
      'forecast_context_json': jsonEncode(context.toMap()),
    };

    var updated = 0;
    if (forecastContextId != null) {
      updated = await _db.update(
        'weekly_plan_snapshots',
        values,
        where: 'restaurant_id = ? AND forecast_context_id = ?',
        whereArgs: [restaurantId, forecastContextId],
      );
    }
    if (updated == 0 && weekStartDate != null && weekEndDate != null) {
      updated = await _db.update(
        'weekly_plan_snapshots',
        values,
        where:
            'restaurant_id = ? AND week_start_date = ? AND week_end_date = ?',
        whereArgs: [restaurantId, weekStartDate, weekEndDate],
      );
    }
    final anchorBusinessDate = context.anchorBusinessDate;
    if (updated == 0 && anchorBusinessDate != null) {
      updated = await _db.update(
        'weekly_plan_snapshots',
        values,
        where:
            'restaurant_id = ? AND week_start_date <= ? AND week_end_date >= ?',
        whereArgs: [restaurantId, anchorBusinessDate, anchorBusinessDate],
      );
    }
    return updated;
  }

  Future<DemandForecastContext?> getForecastContextForBusinessDate(
    String restaurantId,
    String businessDate,
  ) async {
    final rows = await _db.query(
      'weekly_plan_snapshots',
      columns: const <String>['forecast_context_json'],
      where:
          'restaurant_id = ? AND week_start_date <= ? AND week_end_date >= ? '
          'AND forecast_context_json IS NOT NULL',
      whereArgs: [restaurantId, businessDate, businessDate],
      orderBy: 'locked_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _contextFromJson(rows.first['forecast_context_json']);
  }

  Future<DemandForecastContext?> getForecastContextForWeekKey(
    String restaurantId,
    String weekKey,
  ) async {
    final rows = await _db.query(
      'weekly_plan_snapshots',
      columns: const <String>['forecast_context_json'],
      where:
          'restaurant_id = ? AND week_key = ? '
          'AND forecast_context_json IS NOT NULL',
      whereArgs: [restaurantId, weekKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _contextFromJson(rows.first['forecast_context_json']);
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    await _db.delete(
      'weekly_plan_snapshots',
      where: 'restaurant_id != ?',
      whereArgs: [keepRestaurantId],
    );
  }

  /// Converts a database row back to a [WeeklyPlanSnapshot].
  WeeklyPlanSnapshot _fromRow(Map<String, dynamic> row) {
    final map = Map<String, dynamic>.from(row);
    final dayRowsJson = map.remove('day_rows_json') as String;
    final forecastContextJson = map.remove('forecast_context_json') as String?;
    map['day_rows'] = jsonDecode(dayRowsJson) as List<dynamic>;
    if (forecastContextJson != null && forecastContextJson.trim().isNotEmpty) {
      map['forecast_context'] = jsonDecode(forecastContextJson);
    }
    // Theme H#6 — decode the metadata JSON cell back to a Map. The
    // snapshot model handles Map / null gracefully; we just need to
    // unwrap the on-disk JSON string here.
    final metadataRaw = map['metadata'];
    if (metadataRaw is String && metadataRaw.trim().isNotEmpty) {
      try {
        map['metadata'] = jsonDecode(metadataRaw);
      } catch (_) {
        map['metadata'] = null;
      }
    }
    return WeeklyPlanSnapshot.fromMap(map);
  }

  DemandForecastContext? _contextFromJson(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return DemandForecastContext.fromMap(decoded);
    }
    if (decoded is Map) {
      return DemandForecastContext.fromMap(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    return null;
  }
}
