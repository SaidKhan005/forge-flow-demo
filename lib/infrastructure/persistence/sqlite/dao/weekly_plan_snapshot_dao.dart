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
    return _fromRowWithChildren(rows.first);
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
    return _fromRowWithChildren(rows.first);
  }

  Future<WeeklyPlanSnapshot> _fromRowWithChildren(
    Map<String, dynamic> row,
  ) async {
    final base = _fromRow(row);
    // Per-Daypart V1 (Slice 1) — attach the per-(day, period) sub-rows
    // persisted alongside the parent snapshot.
    final children = await getDayDaypartsForSnapshot(base.snapshotId);
    if (children.isEmpty && base.wageAtLockTime == null) return base;
    return WeeklyPlanSnapshot(
      snapshotId: base.snapshotId,
      restaurantId: base.restaurantId,
      weekStartDate: base.weekStartDate,
      weekEndDate: base.weekEndDate,
      targetCycleId: base.targetCycleId,
      forecastContextId: base.forecastContextId,
      forecastCovers: base.forecastCovers,
      forecastSales: base.forecastSales,
      requiredFohHours: base.requiredFohHours,
      requiredBohHours: base.requiredBohHours,
      theoreticalFohLaborDollars: base.theoreticalFohLaborDollars,
      theoreticalBohLaborDollars: base.theoreticalBohLaborDollars,
      coversSource: base.coversSource,
      salesSource: base.salesSource,
      generatedAt: base.generatedAt,
      lockedAt: base.lockedAt,
      forecastContext: base.forecastContext,
      dayRows: base.dayRows,
      dayDayparts: children,
      wageAtLockTime: base.wageAtLockTime,
      isActive: base.isActive,
      supersedesSnapshotId: base.supersedesSnapshotId,
      lockReason: base.lockReason,
      lockedByUserId: base.lockedByUserId,
      metadata: base.metadata,
    );
  }

  /// Inserts or replaces a snapshot.
  ///
  /// Per-Daypart V1 (Slice 1): the snapshot's `dayDayparts` list is
  /// persisted to the `weekly_plan_snapshot_day_dayparts` child table
  /// (replace-for-snapshot semantics — legacy rows for the same
  /// snapshot_id are deleted before the new ones land). The
  /// `wageAtLockTime` stamp is JSON-encoded into
  /// `weekly_plan_snapshots.wage_at_lock_time_json`.
  Future<void> upsertSnapshot(WeeklyPlanSnapshot snapshot) async {
    final map = snapshot.toMap();
    final dayRows = map.remove('day_rows') as List<dynamic>;
    final forecastContext = map.remove('forecast_context');
    final dayDayparts =
        (map.remove('day_dayparts') as List<dynamic>? ?? const []);
    final wageAtLockTimeJson = map.remove('wage_at_lock_time_json');
    map['day_rows_json'] = jsonEncode(dayRows);
    map['forecast_context_json'] = forecastContext == null
        ? null
        : jsonEncode(forecastContext);
    // Per-Daypart V1 (Slice 1) — JSON-encode the wage stamp for the
    // dedicated column.
    map['wage_at_lock_time_json'] =
        wageAtLockTimeJson == null ? null : jsonEncode(wageAtLockTimeJson);
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
    // Wrap parent write + child replace in a transaction so partial
    // writes never leave the snapshot with stale child rows that don't
    // match the new parent.
    await _db.transaction((txn) async {
      await txn.insert(
        'weekly_plan_snapshots',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'weekly_plan_snapshot_day_dayparts',
        where: 'snapshot_id = ?',
        whereArgs: [snapshot.snapshotId],
      );
      if (dayDayparts.isEmpty) return;
      final nowIso = DateTime.now().toUtc().toIso8601String();
      for (final raw in dayDayparts) {
        final dp = Map<String, dynamic>.from(raw as Map);
        dp['snapshot_id'] = snapshot.snapshotId;
        dp['created_at'] = nowIso;
        await txn.insert('weekly_plan_snapshot_day_dayparts', dp);
      }
    });
  }

  /// Per-Daypart V1 (Slice 1) — returns the per-(day, period) sub-rows
  /// persisted for [snapshotId], or an empty list when none exist
  /// (legacy snapshot path).
  Future<List<WeeklyPlanSnapshotDayDaypart>> getDayDaypartsForSnapshot(
    String snapshotId,
  ) async {
    final rows = await _db.query(
      'weekly_plan_snapshot_day_dayparts',
      where: 'snapshot_id = ?',
      whereArgs: [snapshotId],
      orderBy: 'business_date ASC, service_period_id ASC',
    );
    return rows.map((r) => WeeklyPlanSnapshotDayDaypart.fromMap(r)).toList();
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

  /// Deletes every `weekly_plan_snapshots` row whose `restaurant_id` is
  /// NOT in [keepRestaurantIds]. The set-preserving sibling of
  /// [wipeForOtherScopes]; the demo bootstrap source-swap
  /// (`demoScopePreservingCrossTenantWipe`) passes the demo operator's
  /// full `DemoScope.locations` set so a demo location switch keeps
  /// every demo location's locked plans while a genuinely-foreign
  /// tenant is still purged. Production keeps using the single-keep
  /// method byte-unchanged. No-ops on an empty keep set (NOT IN () is
  /// invalid SQL and would otherwise delete everything).
  Future<int> deleteForRestaurantsNotIn(Set<String> keepRestaurantIds) async {
    if (keepRestaurantIds.isEmpty) return 0;
    final keep = keepRestaurantIds.toList(growable: false);
    final placeholders = List.filled(keep.length, '?').join(', ');
    return _db.delete(
      'weekly_plan_snapshots',
      where: 'restaurant_id NOT IN ($placeholders)',
      whereArgs: keep,
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
    // Per-Daypart V1 (Slice 1) — decode the wage stamp from its JSON
    // column so the snapshot model's fromMap can rehydrate it. Null on
    // legacy rows written before Slice 1.
    final wageRaw = map['wage_at_lock_time_json'];
    if (wageRaw is String && wageRaw.trim().isNotEmpty) {
      try {
        map['wage_at_lock_time_json'] = jsonDecode(wageRaw);
      } catch (_) {
        map['wage_at_lock_time_json'] = null;
      }
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
