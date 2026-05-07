import 'dart:convert';

import '../../domain/models/demand_forecast_context.dart';
import '../../domain/models/schedule_forecast_demand.dart';
import '../../domain/models/weekly_plan_snapshot.dart';

abstract class WeeklyPlanSyncProxyClient {
  Future<WeeklyPlanSnapshotSyncPage> fetchWeeklyPlanSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  });

  Future<ForecastContextSyncPage> fetchForecastContexts({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  });
}

enum WeeklyPlanResourceSyncState { synced, unavailable, skipped }

class WeeklyPlanMirrorSyncResult {
  const WeeklyPlanMirrorSyncResult({
    required this.weeklyPlanSnapshots,
    required this.forecastContexts,
  });

  final WeeklyPlanResourceSyncStatus weeklyPlanSnapshots;
  final WeeklyPlanResourceSyncStatus forecastContexts;

  bool get allAvailable =>
      weeklyPlanSnapshots.state == WeeklyPlanResourceSyncState.synced &&
      forecastContexts.state == WeeklyPlanResourceSyncState.synced;

  static WeeklyPlanMirrorSyncResult skipped() => WeeklyPlanMirrorSyncResult(
    weeklyPlanSnapshots: WeeklyPlanResourceSyncStatus.skipped(
      'weekly_plan_snapshots',
    ),
    forecastContexts: WeeklyPlanResourceSyncStatus.skipped('forecast_contexts'),
  );

  static WeeklyPlanMirrorSyncResult unavailable(String reason) =>
      WeeklyPlanMirrorSyncResult(
        weeklyPlanSnapshots: WeeklyPlanResourceSyncStatus.unavailable(
          'weekly_plan_snapshots',
          reason,
        ),
        forecastContexts: WeeklyPlanResourceSyncStatus.unavailable(
          'forecast_contexts',
          reason,
        ),
      );
}

class WeeklyPlanResourceSyncStatus {
  const WeeklyPlanResourceSyncStatus({
    required this.resource,
    required this.state,
    required this.rowsWritten,
    required this.pagesPulled,
    required this.finalCursor,
    this.unavailableReason,
    this.durableCacheAvailable = true,
  });

  final String resource;
  final WeeklyPlanResourceSyncState state;
  final int rowsWritten;
  final int pagesPulled;
  final String? finalCursor;
  final String? unavailableReason;
  final bool durableCacheAvailable;

  bool get isAvailable => state == WeeklyPlanResourceSyncState.synced;

  static WeeklyPlanResourceSyncStatus synced({
    required String resource,
    required int rowsWritten,
    required int pagesPulled,
    required String? finalCursor,
    bool durableCacheAvailable = true,
  }) => WeeklyPlanResourceSyncStatus(
    resource: resource,
    state: WeeklyPlanResourceSyncState.synced,
    rowsWritten: rowsWritten,
    pagesPulled: pagesPulled,
    finalCursor: finalCursor,
    durableCacheAvailable: durableCacheAvailable,
  );

  static WeeklyPlanResourceSyncStatus unavailable(
    String resource,
    String reason, {
    String? finalCursor,
    int pagesPulled = 0,
    bool durableCacheAvailable = true,
  }) => WeeklyPlanResourceSyncStatus(
    resource: resource,
    state: WeeklyPlanResourceSyncState.unavailable,
    rowsWritten: 0,
    pagesPulled: pagesPulled,
    finalCursor: finalCursor,
    unavailableReason: reason,
    durableCacheAvailable: durableCacheAvailable,
  );

  static WeeklyPlanResourceSyncStatus skipped(String resource) =>
      WeeklyPlanResourceSyncStatus(
        resource: resource,
        state: WeeklyPlanResourceSyncState.skipped,
        rowsWritten: 0,
        pagesPulled: 0,
        finalCursor: null,
      );
}

class WeeklyPlanSnapshotSyncPage {
  const WeeklyPlanSnapshotSyncPage({
    required this.snapshots,
    required this.nextCursor,
    this.unavailableReason,
  });

  final List<WeeklyPlanSnapshotSyncRow> snapshots;
  final String? nextCursor;
  final String? unavailableReason;

  bool get isUnavailable => unavailableReason != null;

  static WeeklyPlanSnapshotSyncPage unavailable(String reason) =>
      WeeklyPlanSnapshotSyncPage(
        snapshots: const <WeeklyPlanSnapshotSyncRow>[],
        nextCursor: null,
        unavailableReason: reason,
      );
}

class ForecastContextSyncPage {
  const ForecastContextSyncPage({
    required this.contexts,
    required this.nextCursor,
    this.unavailableReason,
  });

  final List<ForecastContextSyncRow> contexts;
  final String? nextCursor;
  final String? unavailableReason;

  bool get isUnavailable => unavailableReason != null;

  static ForecastContextSyncPage unavailable(String reason) =>
      ForecastContextSyncPage(
        contexts: const <ForecastContextSyncRow>[],
        nextCursor: null,
        unavailableReason: reason,
      );
}

class WeeklyPlanSnapshotSyncRow {
  const WeeklyPlanSnapshotSyncRow({
    required this.snapshot,
    this.operatorId,
    this.locationId,
    this.updatedAt,
  });

  final WeeklyPlanSnapshot snapshot;
  final String? operatorId;
  final String? locationId;
  final DateTime? updatedAt;

  factory WeeklyPlanSnapshotSyncRow.fromJson(Map<String, dynamic> json) {
    final snapshotJson = _snapshotPayload(json);
    return WeeklyPlanSnapshotSyncRow(
      operatorId: _readString(json['operator_id']),
      locationId: _readString(json['location_id']),
      updatedAt: _readDateTime(json['updated_at']),
      snapshot: WeeklyPlanSnapshot.fromMap(snapshotJson),
    );
  }
}

class ForecastContextSyncRow {
  const ForecastContextSyncRow({
    required this.context,
    this.forecastContextId,
    this.operatorId,
    this.locationId,
    this.businessDate,
    this.weekStartDate,
    this.weekEndDate,
    this.updatedAt,
  });

  final DemandForecastContext context;
  final String? forecastContextId;
  final String? operatorId;
  final String? locationId;
  final String? businessDate;
  final String? weekStartDate;
  final String? weekEndDate;
  final DateTime? updatedAt;

  factory ForecastContextSyncRow.fromJson(Map<String, dynamic> json) {
    final contextJson = _contextPayload(json);
    final anchorBusinessDate = _readDateString(
      contextJson['anchor_business_date'] ??
          contextJson['business_date'] ??
          contextJson['week_start_date'],
    );
    return ForecastContextSyncRow(
      forecastContextId:
          _readString(json['forecast_context_id']) ??
          _readString(contextJson['forecast_context_id']),
      operatorId: _readString(json['operator_id']),
      locationId: _readString(json['location_id']),
      businessDate:
          _readDateString(json['business_date']) ?? anchorBusinessDate,
      weekStartDate:
          _readDateString(json['week_start_date']) ??
          _readDateString(contextJson['week_start_date']),
      weekEndDate:
          _readDateString(json['week_end_date']) ??
          _readDateString(contextJson['week_end_date']),
      updatedAt: _readDateTime(json['updated_at']),
      context: DemandForecastContext.fromMap(contextJson),
    );
  }
}

String? weeklyPlanUnavailableReason(Map<String, Object?> body) {
  final available = _readBool(body['available']);
  final status = _readString(body['status'])?.toLowerCase();
  if (available == false ||
      status == 'unavailable' ||
      status == 'setup_required' ||
      status == 'not_configured' ||
      status == 'missing_upstream') {
    return _readString(body['unavailable_reason']) ??
        _readString(body['setup_reason']) ??
        _readString(body['reason']) ??
        status ??
        'weekly_plan_truth_unavailable';
  }
  return null;
}

Map<String, dynamic> _snapshotPayload(Map<String, dynamic> json) {
  final rawSnapshot =
      json['snapshot'] ?? json['weekly_plan_snapshot'] ?? json['snapshot_json'];
  final base = rawSnapshot == null
      ? Map<String, dynamic>.from(json)
      : _stringKeyMap(_decodeIfJson(rawSnapshot));

  final weekStart =
      _readDateString(base['week_start_date'] ?? base['week_start']) ??
      _requiredDateString(base, const <String>['business_week_start']);
  final weekEnd =
      _readDateString(base['week_end_date'] ?? base['week_end']) ??
      _deriveWeekEnd(weekStart);
  final forecastCovers = _requiredInt(base, const <String>[
    'forecast_covers',
    'weekly_forecast_covers',
    'total_forecast_covers',
  ]);
  final forecastSales = _requiredDouble(base, const <String>[
    'forecast_sales',
    'weekly_forecast_sales',
    'total_forecast_sales',
  ]);
  final requiredFohHours = _requiredInt(base, const <String>[
    'required_foh_hours',
    'foh_hours',
    'weekly_required_foh_hours',
  ]);
  final requiredBohHours = _requiredInt(base, const <String>[
    'required_boh_hours',
    'boh_hours',
    'weekly_required_boh_hours',
  ]);
  final dayRows = _readDayRows(
    base['day_rows'] ??
        base['daily_rows'] ??
        base['days'] ??
        base['day_rows_json'],
  );

  return <String, dynamic>{
    'snapshot_id': _requiredString(base, const <String>['snapshot_id', 'id']),
    'restaurant_id': _requiredString(base, const <String>[
      'restaurant_id',
      'location_id',
    ]),
    'week_key': _readString(base['week_key']) ?? '${weekStart}_$weekEnd',
    'week_start_date': weekStart,
    'week_end_date': weekEnd,
    'target_cycle_id': _requiredString(base, const <String>[
      'target_cycle_id',
      'cycle_id',
    ]),
    'forecast_context_id': _readString(base['forecast_context_id']),
    'forecast_covers': forecastCovers,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_foh_labor_dollars':
        _readDouble(base['theoretical_foh_labor_dollars']) ??
        _readDouble(base['foh_labor_dollars']) ??
        0,
    'theoretical_boh_labor_dollars':
        _readDouble(base['theoretical_boh_labor_dollars']) ??
        _readDouble(base['boh_labor_dollars']) ??
        0,
    'covers_source': _readForecastDemandSource(
      base['covers_source'],
      fallback: ForecastDemandSource.appDerivedFromHistoricalAverage,
    ).name,
    'sales_source': _readForecastDemandSource(
      base['sales_source'],
      fallback: ForecastDemandSource.appDerivedFromCoversAndPpa,
    ).name,
    'generated_at':
        _readIsoString(base['generated_at']) ??
        _readIsoString(base['created_at']) ??
        _readIsoString(base['updated_at']) ??
        DateTime.now().toUtc().toIso8601String(),
    'locked_at':
        _readIsoString(base['locked_at']) ??
        _readIsoString(base['active_at']) ??
        _readIsoString(base['created_at']) ??
        DateTime.now().toUtc().toIso8601String(),
    'forecast_context': _optionalContextPayload(base),
    'day_rows': dayRows,
    // Theme H#6: server-emitted lifecycle fields the mobile snapshot
    // model preserves so closed-truth semantics (which row is in force,
    // which one it superseded, who locked it, why) survive the sync.
    'is_active': _readBool(base['is_active']),
    'supersedes_snapshot_id': _readString(base['supersedes_snapshot_id']),
    'lock_reason': _readString(base['lock_reason']),
    'locked_by_user_id': _readString(base['locked_by_user_id']),
    'metadata': _readMapValue(base['metadata']),
  };
}

Map<String, Object?>? _readMapValue(Object? value) {
  if (value == null) return null;
  if (value is Map<String, Object?>) return value.isEmpty ? null : value;
  if (value is Map) {
    if (value.isEmpty) return null;
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): entry.value,
    };
  }
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return <String, Object?>{
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value,
        };
      }
    } catch (_) {
      return null;
    }
  }
  return null;
}

Map<String, dynamic> _contextPayload(Map<String, dynamic> json) {
  final raw =
      json['forecast_context'] ??
      json['context'] ??
      json['forecast_context_json'];
  return raw == null ? json : _stringKeyMap(_decodeIfJson(raw));
}

Map<String, dynamic>? _optionalContextPayload(Map<String, dynamic> json) {
  final raw =
      json['forecast_context'] ??
      json['context'] ??
      json['forecast_context_json'];
  if (raw == null) return null;
  return DemandForecastContext.fromMap(
    _stringKeyMap(_decodeIfJson(raw)),
  ).toMap();
}

List<Map<String, dynamic>> _readDayRows(Object? raw) {
  final decoded = _decodeIfJson(raw);
  if (decoded == null) return const <Map<String, dynamic>>[];
  if (decoded is! List) {
    throw const FormatException('Weekly-plan day_rows was not a list.');
  }
  return decoded
      .map((row) {
        final json = _stringKeyMap(row);
        final forecastCovers = _requiredInt(json, const <String>[
          'forecast_covers',
          'covers',
        ]);
        final forecastSales = _requiredDouble(json, const <String>[
          'forecast_sales',
          'sales',
        ]);
        return <String, dynamic>{
          'day': _requiredString(json, const <String>['day', 'day_label']),
          'business_date': _requiredDateString(json, const <String>[
            'business_date',
            'date',
          ]),
          'forecast_covers': forecastCovers,
          'forecast_sales': forecastSales,
          'required_foh_hours': _requiredInt(json, const <String>[
            'required_foh_hours',
            'foh_hours',
          ]),
          'required_boh_hours': _requiredInt(json, const <String>[
            'required_boh_hours',
            'boh_hours',
          ]),
        };
      })
      .toList(growable: false);
}

Object? _decodeIfJson(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return jsonDecode(trimmed);
    }
  }
  return value;
}

String _requiredString(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = _readString(json[key]);
    if (value != null) return value;
  }
  throw FormatException('Weekly-plan sync row was missing "${keys.first}".');
}

String _requiredDateString(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = _readDateString(json[key]);
    if (value != null) return value;
  }
  throw FormatException('Weekly-plan sync row was missing "${keys.first}".');
}

int _requiredInt(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = _readInt(json[key]);
    if (value != null) return value;
  }
  throw FormatException('Weekly-plan sync row was missing "${keys.first}".');
}

double _requiredDouble(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = _readDouble(json[key]);
    if (value != null) return value;
  }
  throw FormatException('Weekly-plan sync row was missing "${keys.first}".');
}

ForecastDemandSource _readForecastDemandSource(
  Object? value, {
  required ForecastDemandSource fallback,
}) {
  final raw = _readString(value);
  if (raw == null) return fallback;
  for (final source in ForecastDemandSource.values) {
    if (source.name == raw) return source;
  }
  final normalized = raw.toLowerCase();
  return switch (normalized) {
    'historical_average' ||
    'app_derived_from_historical_average' ||
    'sixty_day_average' => ForecastDemandSource.appDerivedFromHistoricalAverage,
    'covers_and_ppa' || 'app_derived_from_covers_and_ppa' =>
      ForecastDemandSource.appDerivedFromCoversAndPpa,
    'reservation_walk_in' || 'reservation_and_walk_in' =>
      ForecastDemandSource.appDerivedFromReservationAndWalkInModel,
    'demo' || 'demo_fallback' => ForecastDemandSource.demoFallback,
    'unavailable' => ForecastDemandSource.unavailable,
    _ => fallback,
  };
}

Map<String, dynamic> _stringKeyMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map<String, Object?>) return Map<String, dynamic>.from(value);
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  throw const FormatException('Weekly-plan sync row was not a JSON object.');
}

String? _readString(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return value.toString();
}

String? _readDateString(Object? value) {
  if (value == null) return null;
  if (value is DateTime) {
    return value.toUtc().toIso8601String().substring(0, 10);
  }
  final raw = _readString(value);
  if (raw == null) return null;
  return raw.length >= 10 ? raw.substring(0, 10) : raw;
}

String? _readIsoString(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc().toIso8601String();
  return _readString(value);
}

DateTime? _readDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  final raw = _readString(value);
  return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

bool? _readBool(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return null;
}

String _deriveWeekEnd(String weekStart) {
  final parsed = DateTime.tryParse(weekStart);
  if (parsed == null) return weekStart;
  return parsed.add(const Duration(days: 6)).toIso8601String().substring(0, 10);
}
