// Business Timing Live - OpenShiftSnapshotsRepository.
//
// Location-scoped Postgres persistence for the provisional live Shift read
// model. The table carries the profile id that opened the business day, while
// location timezone authority stays on `locations.timezone`.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class OpenShiftSnapshotsRepository extends OperatorScopedRepository {
  OpenShiftSnapshotsRepository(super.tenantWrapper);

  static const String _selectColumns =
      'snapshot_id::text as snapshot_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'business_timing_profile_id::text as business_timing_profile_id, '
      'business_date::text as business_date, '
      'week_start_date::text as week_start_date, '
      'week_id, '
      'day_label, '
      'snapshot_scope, '
      'service_period_key, '
      'service_period_label, '
      'status, '
      'forecast_covers, '
      'current_covers, '
      'scheduled_foh_hours, '
      'scheduled_boh_hours, '
      'current_ppa, '
      'current_cplh, '
      'current_splh, '
      'blended_wage, '
      'time_label, '
      'service_elapsed_label, '
      'source_system, '
      'source_shift_id, '
      'provenance, '
      'last_event_at, '
      'created_at, '
      'updated_at';

  /// Upserts one whole-day or service-period live snapshot. Conflict identity
  /// is `(operator_id, location_id, business_date, snapshot_scope,
  /// service_period_key)`, matching the server read model contract.
  Future<OpenShiftSnapshotPostgresRow> upsertSnapshot({
    required OpenShiftSnapshotPostgresWrite snapshot,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: snapshot.operatorId,
      locationId: snapshot.locationId,
      userId: userId,
    );
    return withTenant<OpenShiftSnapshotPostgresRow>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.open_shift_snapshots ('
        '  operator_id, location_id, business_timing_profile_id, '
        '  business_date, week_start_date, week_id, day_label, '
        '  snapshot_scope, service_period_key, service_period_label, '
        '  status, forecast_covers, current_covers, scheduled_foh_hours, '
        '  scheduled_boh_hours, current_ppa, current_cplh, current_splh, '
        '  blended_wage, time_label, service_elapsed_label, source_system, '
        '  source_shift_id, provenance, last_event_at'
        ') values ('
        '  @operator_id::uuid, @location_id::uuid, '
        '  @business_timing_profile_id::uuid, @business_date::date, '
        '  @week_start_date::date, @week_id, @day_label, @snapshot_scope, '
        '  @service_period_key, @service_period_label, @status, '
        '  @forecast_covers, @current_covers, @scheduled_foh_hours, '
        '  @scheduled_boh_hours, @current_ppa, @current_cplh, '
        '  @current_splh, @blended_wage, @time_label, '
        '  @service_elapsed_label, @source_system, @source_shift_id, '
        '  @provenance::jsonb, @last_event_at::timestamptz'
        ') '
        'on conflict on constraint '
        'open_shift_snapshots_location_business_day_scope_uq '
        'do update set '
        '  business_timing_profile_id = excluded.business_timing_profile_id, '
        '  week_start_date = excluded.week_start_date, '
        '  week_id = excluded.week_id, '
        '  day_label = excluded.day_label, '
        '  service_period_label = excluded.service_period_label, '
        '  status = excluded.status, '
        '  forecast_covers = excluded.forecast_covers, '
        '  current_covers = excluded.current_covers, '
        '  scheduled_foh_hours = excluded.scheduled_foh_hours, '
        '  scheduled_boh_hours = excluded.scheduled_boh_hours, '
        '  current_ppa = excluded.current_ppa, '
        '  current_cplh = excluded.current_cplh, '
        '  current_splh = excluded.current_splh, '
        '  blended_wage = excluded.blended_wage, '
        '  time_label = excluded.time_label, '
        '  service_elapsed_label = excluded.service_elapsed_label, '
        '  source_system = excluded.source_system, '
        '  source_shift_id = excluded.source_shift_id, '
        '  provenance = excluded.provenance, '
        '  last_event_at = excluded.last_event_at, '
        '  updated_at = now() '
        'returning $_selectColumns',
        parameters: snapshot.toSqlParameters(),
      );
      if (rows.isEmpty) {
        throw StateError('open_shift_snapshots upsert returned no rows');
      }
      return _snapshotRowFromMap(rows.single);
    });
  }

  Future<List<OpenShiftSnapshotPostgresRow>> listForBusinessDate({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<OpenShiftSnapshotPostgresRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_selectColumns '
        'from public.open_shift_snapshots '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and business_date = @business_date::date '
        'order by case when snapshot_scope = \'whole_day\' then 0 else 1 end, '
        '         service_period_key asc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'business_date': businessDate,
        },
      );
      return <OpenShiftSnapshotPostgresRow>[
        for (final row in rows) _snapshotRowFromMap(row),
      ];
    });
  }

  Future<List<OpenShiftSnapshotPostgresRow>> listUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    int limit = 250,
    String? userId,
  }) {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<OpenShiftSnapshotPostgresRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_selectColumns '
        'from public.open_shift_snapshots '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and updated_at > @updated_after::timestamptz '
        'order by updated_at asc, snapshot_id asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_after': updatedAfter.toUtc().toIso8601String(),
          'limit': limit,
        },
      );
      return <OpenShiftSnapshotPostgresRow>[
        for (final row in rows) _snapshotRowFromMap(row),
      ];
    });
  }
}

class OpenShiftSnapshotPostgresWrite {
  const OpenShiftSnapshotPostgresWrite({
    required this.operatorId,
    required this.locationId,
    required this.businessTimingProfileId,
    required this.businessDate,
    required this.weekStartDate,
    required this.weekId,
    required this.dayLabel,
    required this.snapshotScope,
    required this.servicePeriodKey,
    required this.servicePeriodLabel,
    required this.status,
    required this.forecastCovers,
    required this.currentCovers,
    required this.scheduledFohHours,
    required this.scheduledBohHours,
    required this.currentPpa,
    required this.currentCplh,
    required this.currentSplh,
    required this.blendedWage,
    this.timeLabel = '',
    this.serviceElapsedLabel = '',
    this.sourceSystem,
    this.sourceShiftId,
    this.provenance = const <String, Object?>{},
    this.lastEventAt,
  });

  final String operatorId;
  final String locationId;
  final String businessTimingProfileId;
  final String businessDate;
  final String weekStartDate;
  final String weekId;
  final String dayLabel;
  final String snapshotScope;
  final String servicePeriodKey;
  final String servicePeriodLabel;
  final String status;
  final int forecastCovers;
  final int currentCovers;
  final int scheduledFohHours;
  final int scheduledBohHours;
  final double currentPpa;
  final double currentCplh;
  final double currentSplh;
  final double blendedWage;
  final String timeLabel;
  final String serviceElapsedLabel;
  final String? sourceSystem;
  final String? sourceShiftId;
  final Map<String, Object?> provenance;
  final DateTime? lastEventAt;

  PostgresParameters toSqlParameters() => <String, Object?>{
    'operator_id': operatorId,
    'location_id': locationId,
    'business_timing_profile_id': businessTimingProfileId,
    'business_date': businessDate,
    'week_start_date': weekStartDate,
    'week_id': weekId,
    'day_label': dayLabel,
    'snapshot_scope': snapshotScope,
    'service_period_key': servicePeriodKey,
    'service_period_label': servicePeriodLabel,
    'status': status,
    'forecast_covers': forecastCovers,
    'current_covers': currentCovers,
    'scheduled_foh_hours': scheduledFohHours,
    'scheduled_boh_hours': scheduledBohHours,
    'current_ppa': currentPpa,
    'current_cplh': currentCplh,
    'current_splh': currentSplh,
    'blended_wage': blendedWage,
    'time_label': timeLabel,
    'service_elapsed_label': serviceElapsedLabel,
    'source_system': sourceSystem,
    'source_shift_id': sourceShiftId,
    'provenance': jsonEncode(provenance),
    'last_event_at': lastEventAt?.toUtc().toIso8601String(),
  };
}

class OpenShiftSnapshotPostgresRow {
  const OpenShiftSnapshotPostgresRow({
    required this.snapshotId,
    required this.operatorId,
    required this.locationId,
    required this.businessTimingProfileId,
    required this.businessDate,
    required this.weekStartDate,
    required this.weekId,
    required this.dayLabel,
    required this.snapshotScope,
    required this.servicePeriodKey,
    required this.servicePeriodLabel,
    required this.status,
    required this.forecastCovers,
    required this.currentCovers,
    required this.scheduledFohHours,
    required this.scheduledBohHours,
    required this.currentPpa,
    required this.currentCplh,
    required this.currentSplh,
    required this.blendedWage,
    required this.timeLabel,
    required this.serviceElapsedLabel,
    required this.sourceSystem,
    required this.sourceShiftId,
    required this.provenance,
    required this.lastEventAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String snapshotId;
  final String operatorId;
  final String locationId;
  final String businessTimingProfileId;
  final String businessDate;
  final String weekStartDate;
  final String weekId;
  final String dayLabel;
  final String snapshotScope;
  final String servicePeriodKey;
  final String servicePeriodLabel;
  final String status;
  final int forecastCovers;
  final int currentCovers;
  final int scheduledFohHours;
  final int scheduledBohHours;
  final double currentPpa;
  final double currentCplh;
  final double currentSplh;
  final double blendedWage;
  final String timeLabel;
  final String serviceElapsedLabel;
  final String? sourceSystem;
  final String? sourceShiftId;
  final Map<String, Object?> provenance;
  final DateTime? lastEventAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'snapshot_id': snapshotId,
    'operator_id': operatorId,
    'location_id': locationId,
    'business_timing_profile_id': businessTimingProfileId,
    'business_date': businessDate,
    'week_start_date': weekStartDate,
    'week_id': weekId,
    'day_label': dayLabel,
    'snapshot_scope': snapshotScope,
    'service_period_key': servicePeriodKey,
    'service_period_label': servicePeriodLabel,
    'status': status,
    'forecast_covers': forecastCovers,
    'current_covers': currentCovers,
    'scheduled_foh_hours': scheduledFohHours,
    'scheduled_boh_hours': scheduledBohHours,
    'current_ppa': currentPpa,
    'current_cplh': currentCplh,
    'current_splh': currentSplh,
    'blended_wage': blendedWage,
    'time_label': timeLabel,
    'service_elapsed_label': serviceElapsedLabel,
    'source_system': sourceSystem,
    'source_shift_id': sourceShiftId,
    'provenance': provenance,
    'last_event_at': lastEventAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

OpenShiftSnapshotPostgresRow _snapshotRowFromMap(PostgresRow row) {
  return OpenShiftSnapshotPostgresRow(
    snapshotId: row['snapshot_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    businessTimingProfileId: row['business_timing_profile_id']! as String,
    businessDate: _dateString(row['business_date'])!,
    weekStartDate: _dateString(row['week_start_date'])!,
    weekId: row['week_id']! as String,
    dayLabel: row['day_label']! as String,
    snapshotScope: row['snapshot_scope']! as String,
    servicePeriodKey: row['service_period_key']! as String,
    servicePeriodLabel: row['service_period_label']! as String,
    status: row['status']! as String,
    forecastCovers: row['forecast_covers']! as int,
    currentCovers: row['current_covers']! as int,
    scheduledFohHours: row['scheduled_foh_hours']! as int,
    scheduledBohHours: row['scheduled_boh_hours']! as int,
    currentPpa: _toDouble(row['current_ppa']),
    currentCplh: _toDouble(row['current_cplh']),
    currentSplh: _toDouble(row['current_splh']),
    blendedWage: _toDouble(row['blended_wage']),
    timeLabel: row['time_label'] as String? ?? '',
    serviceElapsedLabel: row['service_elapsed_label'] as String? ?? '',
    sourceSystem: row['source_system'] as String?,
    sourceShiftId: row['source_shift_id'] as String?,
    provenance: _jsonObjectFromValue(row['provenance']),
    lastEventAt: _toDateTime(row['last_event_at']),
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

Map<String, Object?> _jsonObjectFromValue(Object? value) {
  if (value == null) return const <String, Object?>{};
  final dynamic decoded = value is String ? jsonDecode(value) : value;
  if (decoded is! Map<dynamic, dynamic>) {
    throw StateError('provenance JSON was not an object');
  }
  return <String, Object?>{
    for (final entry in decoded.entries) entry.key.toString(): entry.value,
  };
}

String? _dateString(Object? value) {
  if (value == null) return null;
  if (value is DateTime) {
    return value.toUtc().toIso8601String().substring(0, 10);
  }
  if (value is String) {
    if (value.isEmpty) return null;
    return value.length >= 10 ? value.substring(0, 10) : value;
  }
  return null;
}

double _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.parse(value);
  throw StateError('numeric value was not parseable');
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
