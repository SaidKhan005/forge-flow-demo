// Phase 8 weekly plan server truth - forecast context repository.
//
// Forecast contexts are explainable server-owned inputs to weekly plan
// snapshots. Open contexts may be refreshed before lock; closed contexts are
// protected by the migration trigger and by this repository's closed-row guard.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class ForecastContextRepository extends OperatorScopedRepository {
  ForecastContextRepository(super.tenantWrapper);

  static const String _columns =
      'forecast_context_id::text as forecast_context_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'restaurant_id, '
      'anchor_business_date::text as anchor_business_date, '
      'baseline_total_covers, '
      'baseline_weekly_avg_covers, '
      'baseline_weeks_represented, '
      'recent_three_week_total_covers, '
      'recent_three_week_weekly_avg_covers, '
      'recent_trend_delta_covers, '
      'resolved_weekly_forecast_covers, '
      'target_ppa, '
      'forecast_sales, '
      'required_foh_hours, '
      'required_boh_hours, '
      'theoretical_labor_dollars, '
      'covers_source, '
      'sales_source, '
      'target_cycle_id::text as target_cycle_id, '
      'target_profile_id::text as target_profile_id, '
      'context_status, '
      'built_at, '
      'closed_at, '
      'idempotency_key, '
      'request_hash, '
      'metadata, '
      'created_by::text as created_by, '
      'created_at, '
      'updated_at';

  static const String _columnsWithAlias =
      'f.forecast_context_id::text as forecast_context_id, '
      'f.operator_id::text as operator_id, '
      'f.location_id::text as location_id, '
      'f.restaurant_id, '
      'f.anchor_business_date::text as anchor_business_date, '
      'f.baseline_total_covers, '
      'f.baseline_weekly_avg_covers, '
      'f.baseline_weeks_represented, '
      'f.recent_three_week_total_covers, '
      'f.recent_three_week_weekly_avg_covers, '
      'f.recent_trend_delta_covers, '
      'f.resolved_weekly_forecast_covers, '
      'f.target_ppa, '
      'f.forecast_sales, '
      'f.required_foh_hours, '
      'f.required_boh_hours, '
      'f.theoretical_labor_dollars, '
      'f.covers_source, '
      'f.sales_source, '
      'f.target_cycle_id::text as target_cycle_id, '
      'f.target_profile_id::text as target_profile_id, '
      'f.context_status, '
      'f.built_at, '
      'f.closed_at, '
      'f.idempotency_key, '
      'f.request_hash, '
      'f.metadata, '
      'f.created_by::text as created_by, '
      'f.created_at, '
      'f.updated_at';

  Future<ForecastContextPostgresRow> upsertContext({
    required ForecastContextPostgresWrite context,
    String actorKind = 'system',
    required String reason,
  }) {
    context.validate();
    _validateNonBlank(reason, 'reason');
    final ctx = TenantContext(
      operatorId: context.operatorId,
      locationId: context.locationId,
      userId: context.createdBy,
    );
    return withTenant<ForecastContextPostgresRow>(ctx, (exec) async {
      final replay = await _fetchByIdempotency(
        exec,
        operatorId: context.operatorId,
        locationId: context.locationId,
        idempotencyKey: context.idempotencyKey,
      );
      if (replay != null) return replay;

      final before = await _fetchForAnchor(
        exec,
        operatorId: context.operatorId,
        locationId: context.locationId,
        restaurantId: context.restaurantId,
        anchorBusinessDate: context.anchorBusinessDate,
      );
      if (before?.closedAt != null) {
        throw ForecastContextClosed(
          before!.forecastContextId,
          before.anchorBusinessDate,
        );
      }

      final rows = await exec.query(
        'insert into public.forecast_contexts ('
        '  forecast_context_id, operator_id, location_id, restaurant_id, '
        '  anchor_business_date, baseline_total_covers, '
        '  baseline_weekly_avg_covers, baseline_weeks_represented, '
        '  recent_three_week_total_covers, '
        '  recent_three_week_weekly_avg_covers, recent_trend_delta_covers, '
        '  resolved_weekly_forecast_covers, target_ppa, forecast_sales, '
        '  required_foh_hours, required_boh_hours, '
        '  theoretical_labor_dollars, covers_source, sales_source, '
        '  target_cycle_id, target_profile_id, context_status, built_at, '
        '  closed_at, idempotency_key, request_hash, metadata, created_by'
        ') values ('
        '  coalesce(@forecast_context_id::uuid, gen_random_uuid()), '
        '  @operator_id::uuid, @location_id::uuid, @restaurant_id, '
        '  @anchor_business_date::date, @baseline_total_covers, '
        '  @baseline_weekly_avg_covers, @baseline_weeks_represented, '
        '  @recent_three_week_total_covers, '
        '  @recent_three_week_weekly_avg_covers, '
        '  @recent_trend_delta_covers, '
        '  @resolved_weekly_forecast_covers, @target_ppa, '
        '  @forecast_sales, @required_foh_hours, @required_boh_hours, '
        '  @theoretical_labor_dollars, @covers_source, @sales_source, '
        '  @target_cycle_id::uuid, @target_profile_id::uuid, '
        '  @context_status, @built_at::timestamptz, '
        '  @closed_at::timestamptz, @idempotency_key, @request_hash, '
        '  @metadata::jsonb, @created_by::uuid'
        ') '
        'on conflict on constraint forecast_contexts_anchor_uq '
        'do update set '
        '  baseline_total_covers = excluded.baseline_total_covers, '
        '  baseline_weekly_avg_covers = excluded.baseline_weekly_avg_covers, '
        '  baseline_weeks_represented = excluded.baseline_weeks_represented, '
        '  recent_three_week_total_covers = '
        '    excluded.recent_three_week_total_covers, '
        '  recent_three_week_weekly_avg_covers = '
        '    excluded.recent_three_week_weekly_avg_covers, '
        '  recent_trend_delta_covers = excluded.recent_trend_delta_covers, '
        '  resolved_weekly_forecast_covers = '
        '    excluded.resolved_weekly_forecast_covers, '
        '  target_ppa = excluded.target_ppa, '
        '  forecast_sales = excluded.forecast_sales, '
        '  required_foh_hours = excluded.required_foh_hours, '
        '  required_boh_hours = excluded.required_boh_hours, '
        '  theoretical_labor_dollars = excluded.theoretical_labor_dollars, '
        '  covers_source = excluded.covers_source, '
        '  sales_source = excluded.sales_source, '
        '  target_cycle_id = excluded.target_cycle_id, '
        '  target_profile_id = excluded.target_profile_id, '
        '  context_status = excluded.context_status, '
        '  built_at = excluded.built_at, '
        '  closed_at = excluded.closed_at, '
        '  idempotency_key = excluded.idempotency_key, '
        '  request_hash = excluded.request_hash, '
        '  metadata = excluded.metadata, '
        '  created_by = excluded.created_by, '
        '  updated_at = now() '
        'where public.forecast_contexts.closed_at is null '
        'returning $_columns',
        parameters: context.toSqlParameters(),
      );
      if (rows.isEmpty) {
        throw ForecastContextClosedForAnchor(
          context.restaurantId,
          context.anchorBusinessDate,
        );
      }
      final row = _forecastContextRowFromMap(rows.single);
      await _insertAuditEvent(
        exec,
        operatorId: context.operatorId,
        locationId: context.locationId,
        eventType: 'forecast_context_written',
        entityId: row.forecastContextId,
        actorKind: actorKind,
        actorUserId: context.createdBy,
        reason: reason,
        idempotencyKey: context.idempotencyKey,
        beforeSnapshot: before?.toJson(),
        afterSnapshot: row.toJson(),
        metadata: <String, Object?>{
          'restaurant_id': row.restaurantId,
          'anchor_business_date': row.anchorBusinessDate,
        },
      );
      return row;
    });
  }

  Future<ForecastContextPostgresRow?> loadForAnchor({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String anchorBusinessDate,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<ForecastContextPostgresRow?>(ctx, (exec) {
      return _fetchForAnchor(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
        anchorBusinessDate: anchorBusinessDate,
      );
    });
  }

  Future<List<ForecastContextPostgresRow>> listUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) {
    _validatePositiveLimit(limit);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<ForecastContextPostgresRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_columnsWithAlias '
        'from public.forecast_contexts f '
        'where f.operator_id = @operator_id::uuid '
        '  and f.location_id = @location_id::uuid '
        '  and f.updated_at > @updated_after::timestamptz '
        'order by f.updated_at asc, f.forecast_context_id asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_after': updatedAfter.toUtc().toIso8601String(),
          'limit': limit,
        },
      );
      return <ForecastContextPostgresRow>[
        for (final row in rows) _forecastContextRowFromMap(row),
      ];
    });
  }

  Future<ForecastContextPostgresRow?> _fetchByIdempotency(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  }) async {
    final rows = await exec.query(
      'select $_columnsWithAlias '
      'from public.forecast_contexts f '
      'where f.operator_id = @operator_id::uuid '
      '  and f.location_id = @location_id::uuid '
      '  and f.idempotency_key = @idempotency_key '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'idempotency_key': idempotencyKey,
      },
    );
    if (rows.isEmpty) return null;
    return _forecastContextRowFromMap(rows.single);
  }

  Future<ForecastContextPostgresRow?> _fetchForAnchor(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String anchorBusinessDate,
  }) async {
    final rows = await exec.query(
      'select $_columnsWithAlias '
      'from public.forecast_contexts f '
      'where f.operator_id = @operator_id::uuid '
      '  and f.location_id = @location_id::uuid '
      '  and f.restaurant_id = @restaurant_id '
      '  and f.anchor_business_date = @anchor_business_date::date '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'restaurant_id': restaurantId,
        'anchor_business_date': anchorBusinessDate,
      },
    );
    if (rows.isEmpty) return null;
    return _forecastContextRowFromMap(rows.single);
  }

  Future<void> _insertAuditEvent(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String eventType,
    required String entityId,
    required String actorKind,
    required String? actorUserId,
    required String reason,
    required String idempotencyKey,
    Map<String, Object?>? beforeSnapshot,
    required Map<String, Object?> afterSnapshot,
    required Map<String, Object?> metadata,
  }) async {
    await exec.query(
      'insert into public.weekly_plan_audit_events ('
      '  operator_id, location_id, event_type, entity_table, entity_id, '
      '  actor_kind, actor_user_id, reason, idempotency_key, '
      '  before_snapshot, after_snapshot, metadata'
      ') values ('
      '  @operator_id::uuid, @location_id::uuid, @event_type, '
      "  'forecast_contexts', @entity_id::uuid, @actor_kind, "
      '  @actor_user_id::uuid, @reason, @idempotency_key, '
      '  @before_snapshot::jsonb, @after_snapshot::jsonb, @metadata::jsonb'
      ') returning audit_event_id::text as audit_event_id',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'event_type': eventType,
        'entity_id': entityId,
        'actor_kind': actorKind,
        'actor_user_id': actorUserId,
        'reason': reason,
        'idempotency_key': idempotencyKey,
        'before_snapshot': beforeSnapshot == null
            ? null
            : jsonEncode(beforeSnapshot),
        'after_snapshot': jsonEncode(afterSnapshot),
        'metadata': jsonEncode(metadata),
      },
    );
  }
}

class ForecastContextPostgresWrite {
  const ForecastContextPostgresWrite({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    this.forecastContextId,
    required this.anchorBusinessDate,
    required this.baselineTotalCovers,
    required this.baselineWeeklyAvgCovers,
    required this.baselineWeeksRepresented,
    this.recentThreeWeekTotalCovers,
    this.recentThreeWeekWeeklyAvgCovers,
    this.recentTrendDeltaCovers,
    required this.resolvedWeeklyForecastCovers,
    required this.targetPpa,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalLaborDollars,
    required this.coversSource,
    required this.salesSource,
    this.targetCycleId,
    this.targetProfileId,
    this.contextStatus = 'open',
    required this.builtAt,
    this.closedAt,
    required this.idempotencyKey,
    required this.requestHash,
    this.metadata = const <String, Object?>{},
    this.createdBy,
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String? forecastContextId;
  final String anchorBusinessDate;
  final int baselineTotalCovers;
  final int baselineWeeklyAvgCovers;
  final double baselineWeeksRepresented;
  final int? recentThreeWeekTotalCovers;
  final int? recentThreeWeekWeeklyAvgCovers;
  final int? recentTrendDeltaCovers;
  final int resolvedWeeklyForecastCovers;
  final double targetPpa;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;
  final double theoreticalLaborDollars;
  final String coversSource;
  final String salesSource;
  final String? targetCycleId;
  final String? targetProfileId;
  final String contextStatus;
  final DateTime builtAt;
  final DateTime? closedAt;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, Object?> metadata;
  final String? createdBy;

  void validate() {
    _validateNonBlank(restaurantId, 'restaurantId');
    _validateNonBlank(anchorBusinessDate, 'anchorBusinessDate');
    _validateNonBlank(coversSource, 'coversSource');
    _validateNonBlank(salesSource, 'salesSource');
    _validateNonBlank(idempotencyKey, 'idempotencyKey');
    _validateNonBlank(requestHash, 'requestHash');
    if (!const <String>{'open', 'closed'}.contains(contextStatus)) {
      throw ArgumentError.value(contextStatus, 'contextStatus');
    }
    if (contextStatus == 'closed' && closedAt == null) {
      throw ArgumentError.value(
        contextStatus,
        'contextStatus',
        'closed contexts must carry closedAt',
      );
    }
    if (contextStatus == 'open' && closedAt != null) {
      throw ArgumentError.value(
        closedAt,
        'closedAt',
        'open contexts cannot carry closedAt',
      );
    }
  }

  PostgresParameters toSqlParameters() => <String, Object?>{
    'forecast_context_id': forecastContextId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'anchor_business_date': anchorBusinessDate,
    'baseline_total_covers': baselineTotalCovers,
    'baseline_weekly_avg_covers': baselineWeeklyAvgCovers,
    'baseline_weeks_represented': baselineWeeksRepresented,
    'recent_three_week_total_covers': recentThreeWeekTotalCovers,
    'recent_three_week_weekly_avg_covers': recentThreeWeekWeeklyAvgCovers,
    'recent_trend_delta_covers': recentTrendDeltaCovers,
    'resolved_weekly_forecast_covers': resolvedWeeklyForecastCovers,
    'target_ppa': targetPpa,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_labor_dollars': theoreticalLaborDollars,
    'covers_source': coversSource,
    'sales_source': salesSource,
    'target_cycle_id': targetCycleId,
    'target_profile_id': targetProfileId,
    'context_status': contextStatus,
    'built_at': builtAt.toUtc().toIso8601String(),
    'closed_at': closedAt?.toUtc().toIso8601String(),
    'idempotency_key': idempotencyKey,
    'request_hash': requestHash,
    'metadata': jsonEncode(metadata),
    'created_by': createdBy,
  };
}

class ForecastContextPostgresRow {
  const ForecastContextPostgresRow({
    required this.forecastContextId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.anchorBusinessDate,
    required this.baselineTotalCovers,
    required this.baselineWeeklyAvgCovers,
    required this.baselineWeeksRepresented,
    required this.recentThreeWeekTotalCovers,
    required this.recentThreeWeekWeeklyAvgCovers,
    required this.recentTrendDeltaCovers,
    required this.resolvedWeeklyForecastCovers,
    required this.targetPpa,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalLaborDollars,
    required this.coversSource,
    required this.salesSource,
    required this.targetCycleId,
    required this.targetProfileId,
    required this.contextStatus,
    required this.builtAt,
    required this.closedAt,
    required this.idempotencyKey,
    required this.requestHash,
    required this.metadata,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  final String forecastContextId;
  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String anchorBusinessDate;
  final int baselineTotalCovers;
  final int baselineWeeklyAvgCovers;
  final double baselineWeeksRepresented;
  final int? recentThreeWeekTotalCovers;
  final int? recentThreeWeekWeeklyAvgCovers;
  final int? recentTrendDeltaCovers;
  final int resolvedWeeklyForecastCovers;
  final double targetPpa;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;
  final double theoreticalLaborDollars;
  final String coversSource;
  final String salesSource;
  final String? targetCycleId;
  final String? targetProfileId;
  final String contextStatus;
  final DateTime builtAt;
  final DateTime? closedAt;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, Object?> metadata;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'forecast_context_id': forecastContextId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'anchor_business_date': anchorBusinessDate,
    'baseline_total_covers': baselineTotalCovers,
    'baseline_weekly_avg_covers': baselineWeeklyAvgCovers,
    'baseline_weeks_represented': baselineWeeksRepresented,
    'recent_three_week_total_covers': recentThreeWeekTotalCovers,
    'recent_three_week_weekly_avg_covers': recentThreeWeekWeeklyAvgCovers,
    'recent_trend_delta_covers': recentTrendDeltaCovers,
    'resolved_weekly_forecast_covers': resolvedWeeklyForecastCovers,
    'target_ppa': targetPpa,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_labor_dollars': theoreticalLaborDollars,
    'covers_source': coversSource,
    'sales_source': salesSource,
    'target_cycle_id': targetCycleId,
    'target_profile_id': targetProfileId,
    'context_status': contextStatus,
    'built_at': builtAt.toUtc().toIso8601String(),
    'closed_at': closedAt?.toUtc().toIso8601String(),
    'idempotency_key': idempotencyKey,
    'request_hash': requestHash,
    'metadata': metadata,
    'created_by': createdBy,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

class ForecastContextClosed implements Exception {
  const ForecastContextClosed(this.forecastContextId, this.anchorBusinessDate);

  final String forecastContextId;
  final String anchorBusinessDate;

  @override
  String toString() {
    return 'ForecastContextClosed('
        'forecastContextId: $forecastContextId, '
        'anchorBusinessDate: $anchorBusinessDate)';
  }
}

class ForecastContextClosedForAnchor implements Exception {
  const ForecastContextClosedForAnchor(
    this.restaurantId,
    this.anchorBusinessDate,
  );

  final String restaurantId;
  final String anchorBusinessDate;

  @override
  String toString() {
    return 'ForecastContextClosedForAnchor('
        'restaurantId: $restaurantId, '
        'anchorBusinessDate: $anchorBusinessDate)';
  }
}

ForecastContextPostgresRow _forecastContextRowFromMap(PostgresRow row) {
  return ForecastContextPostgresRow(
    forecastContextId: row['forecast_context_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    restaurantId: row['restaurant_id']! as String,
    anchorBusinessDate: _dateString(row['anchor_business_date'])!,
    baselineTotalCovers: (row['baseline_total_covers']! as num).toInt(),
    baselineWeeklyAvgCovers: (row['baseline_weekly_avg_covers']! as num)
        .toInt(),
    baselineWeeksRepresented: _toDouble(row['baseline_weeks_represented']),
    recentThreeWeekTotalCovers: (row['recent_three_week_total_covers'] as num?)
        ?.toInt(),
    recentThreeWeekWeeklyAvgCovers:
        (row['recent_three_week_weekly_avg_covers'] as num?)?.toInt(),
    recentTrendDeltaCovers: (row['recent_trend_delta_covers'] as num?)?.toInt(),
    resolvedWeeklyForecastCovers:
        (row['resolved_weekly_forecast_covers']! as num).toInt(),
    targetPpa: _toDouble(row['target_ppa']),
    forecastSales: _toDouble(row['forecast_sales']),
    requiredFohHours: _toDouble(row['required_foh_hours']),
    requiredBohHours: _toDouble(row['required_boh_hours']),
    theoreticalLaborDollars: _toDouble(row['theoretical_labor_dollars']),
    coversSource: row['covers_source']! as String,
    salesSource: row['sales_source']! as String,
    targetCycleId: row['target_cycle_id'] as String?,
    targetProfileId: row['target_profile_id'] as String?,
    contextStatus: row['context_status']! as String,
    builtAt: _toDateTime(row['built_at'])!,
    closedAt: _toDateTime(row['closed_at']),
    idempotencyKey: row['idempotency_key']! as String,
    requestHash: row['request_hash']! as String,
    metadata: _jsonObjectFromValue(row['metadata']),
    createdBy: row['created_by'] as String?,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

void _validatePositiveLimit(int limit) {
  if (limit <= 0) {
    throw ArgumentError.value(limit, 'limit', 'must be positive');
  }
}

void _validateNonBlank(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must be non-blank');
  }
}

Map<String, Object?> _jsonObjectFromValue(Object? value) {
  if (value == null) return const <String, Object?>{};
  final dynamic decoded = value is String ? jsonDecode(value) : value;
  if (decoded is! Map<dynamic, dynamic>) {
    throw StateError('JSON value was not an object');
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
    return value.isEmpty ? null : value.substring(0, 10);
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
