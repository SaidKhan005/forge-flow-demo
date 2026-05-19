// Phase 8 weekly plan server truth - weekly plan snapshot repository.
//
// The repository owns the server-side lock/replace/unlock seam for weekly
// plans. Replacements preserve superseded rows and audit the decision; mobile
// sync lanes consume these rows later as cache truth.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class WeeklyPlanSnapshotRepository extends OperatorScopedRepository {
  WeeklyPlanSnapshotRepository(super.tenantWrapper);

  static const String _columns =
      'snapshot_id::text as snapshot_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'restaurant_id, '
      'week_start_date::text as week_start_date, '
      'week_end_date::text as week_end_date, '
      'week_key, '
      'target_cycle_id::text as target_cycle_id, '
      'forecast_context_id::text as forecast_context_id, '
      'forecast_covers, '
      'forecast_sales, '
      'required_foh_hours, '
      'required_boh_hours, '
      'theoretical_foh_labor_dollars, '
      'theoretical_boh_labor_dollars, '
      'covers_source, '
      'sales_source, '
      'snapshot_status, '
      'source, '
      'generated_at, '
      'locked_at, '
      'superseded_at, '
      'superseded_by_snapshot_id::text as superseded_by_snapshot_id, '
      'supersedes_snapshot_id::text as supersedes_snapshot_id, '
      'unlocked_at, '
      'unlocked_by_user_id::text as unlocked_by_user_id, '
      'replacement_reason, '
      'idempotency_key, '
      'request_hash, '
      'wage_at_lock_time_json, '
      'metadata, '
      'created_by::text as created_by, '
      'created_at, '
      'updated_at';

  static const String _columnsWithAlias =
      's.snapshot_id::text as snapshot_id, '
      's.operator_id::text as operator_id, '
      's.location_id::text as location_id, '
      's.restaurant_id, '
      's.week_start_date::text as week_start_date, '
      's.week_end_date::text as week_end_date, '
      's.week_key, '
      's.target_cycle_id::text as target_cycle_id, '
      's.forecast_context_id::text as forecast_context_id, '
      's.forecast_covers, '
      's.forecast_sales, '
      's.required_foh_hours, '
      's.required_boh_hours, '
      's.theoretical_foh_labor_dollars, '
      's.theoretical_boh_labor_dollars, '
      's.covers_source, '
      's.sales_source, '
      's.snapshot_status, '
      's.source, '
      's.generated_at, '
      's.locked_at, '
      's.superseded_at, '
      's.superseded_by_snapshot_id::text as superseded_by_snapshot_id, '
      's.supersedes_snapshot_id::text as supersedes_snapshot_id, '
      's.unlocked_at, '
      's.unlocked_by_user_id::text as unlocked_by_user_id, '
      's.replacement_reason, '
      's.idempotency_key, '
      's.request_hash, '
      's.wage_at_lock_time_json, '
      's.metadata, '
      's.created_by::text as created_by, '
      's.created_at, '
      's.updated_at';

  static const String _dayColumns =
      'snapshot_day_id::text as snapshot_day_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'snapshot_id::text as snapshot_id, '
      'restaurant_id, '
      'day_index, '
      'day_label, '
      'business_date::text as business_date, '
      'forecast_covers, '
      'forecast_sales, '
      'required_foh_hours, '
      'required_boh_hours, '
      'created_at, '
      'updated_at';

  static const String _dayColumnsWithAlias =
      'd.snapshot_day_id::text as snapshot_day_id, '
      'd.operator_id::text as operator_id, '
      'd.location_id::text as location_id, '
      'd.snapshot_id::text as snapshot_id, '
      'd.restaurant_id, '
      'd.day_index, '
      'd.day_label, '
      'd.business_date::text as business_date, '
      'd.forecast_covers, '
      'd.forecast_sales, '
      'd.required_foh_hours, '
      'd.required_boh_hours, '
      'd.created_at, '
      'd.updated_at';

  static const String _dayDaypartColumns =
      'snapshot_id::text as snapshot_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'business_date::text as business_date, '
      'service_period_id, '
      'forecast_covers, '
      'forecast_sales, '
      'required_foh_hours, '
      'required_boh_hours, '
      'theoretical_foh_dollars, '
      'theoretical_boh_dollars, '
      'created_at, '
      'updated_at';

  static const String _dayDaypartColumnsWithAlias =
      'dd.snapshot_id::text as snapshot_id, '
      'dd.operator_id::text as operator_id, '
      'dd.location_id::text as location_id, '
      'dd.business_date::text as business_date, '
      'dd.service_period_id, '
      'dd.forecast_covers, '
      'dd.forecast_sales, '
      'dd.required_foh_hours, '
      'dd.required_boh_hours, '
      'dd.theoretical_foh_dollars, '
      'dd.theoretical_boh_dollars, '
      'dd.created_at, '
      'dd.updated_at';

  Future<WeeklyPlanSnapshotPostgresRow> lockOrReplaceSnapshot({
    required WeeklyPlanSnapshotPostgresWrite snapshot,
    List<WeeklyPlanSnapshotDayPostgresWrite> days = const [],
    List<WeeklyPlanSnapshotDayDaypartPostgresWrite> dayDayparts = const [],
    String actorKind = 'operator_user',
    required String reason,
  }) {
    snapshot.validate();
    for (final day in days) {
      day.validateForSnapshot(snapshot);
    }
    for (final dayDaypart in dayDayparts) {
      dayDaypart.validateForSnapshot(snapshot);
    }
    _validateNonBlank(reason, 'reason');
    final ctx = TenantContext(
      operatorId: snapshot.operatorId,
      locationId: snapshot.locationId,
      userId: snapshot.createdBy,
    );
    return withTenant<WeeklyPlanSnapshotPostgresRow>(ctx, (exec) async {
      final replay = await _fetchByIdempotency(
        exec,
        operatorId: snapshot.operatorId,
        locationId: snapshot.locationId,
        idempotencyKey: snapshot.idempotencyKey,
      );
      if (replay != null) return replay;

      final before = await _fetchActiveSnapshot(
        exec,
        operatorId: snapshot.operatorId,
        locationId: snapshot.locationId,
        restaurantId: snapshot.restaurantId,
        weekStartDate: snapshot.weekStartDate,
      );
      await exec.execute(
        'update public.weekly_plan_snapshots '
        "set snapshot_status = 'superseded', "
        '    superseded_at = coalesce(superseded_at, now()), '
        '    updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and restaurant_id = @restaurant_id '
        '  and week_start_date = @week_start_date::date '
        "  and snapshot_status = 'active' "
        'returning $_columns',
        parameters: <String, Object?>{
          'operator_id': snapshot.operatorId,
          'location_id': snapshot.locationId,
          'restaurant_id': snapshot.restaurantId,
          'week_start_date': snapshot.weekStartDate,
        },
      );

      final row = await _insertSnapshotWithExecutor(
        exec,
        snapshot,
        sourceOverride: before == null
            ? snapshot.source
            : _replacementSource(snapshot.source),
        supersedesSnapshotId:
            snapshot.supersedesSnapshotId ?? before?.snapshotId,
      );
      if (before != null) {
        await exec.execute(
          'update public.weekly_plan_snapshots '
          'set superseded_by_snapshot_id = @superseded_by_snapshot_id::uuid, '
          '    updated_at = now() '
          'where operator_id = @operator_id::uuid '
          '  and snapshot_id = @snapshot_id::uuid',
          parameters: <String, Object?>{
            'operator_id': snapshot.operatorId,
            'snapshot_id': before.snapshotId,
            'superseded_by_snapshot_id': row.snapshotId,
          },
        );
      }
      for (final day in days) {
        await _insertDayWithExecutor(exec, day, row.snapshotId);
      }
      for (final dayDaypart in dayDayparts) {
        await _insertDayDaypartWithExecutor(
          exec,
          dayDaypart,
          row.snapshotId,
        );
      }
      await _insertAuditEvent(
        exec,
        operatorId: snapshot.operatorId,
        locationId: snapshot.locationId,
        eventType: before == null
            ? 'weekly_plan_locked'
            : 'weekly_plan_replaced',
        entityId: row.snapshotId,
        actorKind: actorKind,
        actorUserId: snapshot.createdBy,
        reason: reason,
        idempotencyKey: snapshot.idempotencyKey,
        beforeSnapshot: before?.toJson(),
        afterSnapshot: row.toJson(),
        metadata: <String, Object?>{
          'restaurant_id': row.restaurantId,
          'week_start_date': row.weekStartDate,
          'target_cycle_id': row.targetCycleId,
          'forecast_context_id': row.forecastContextId,
          'day_row_count': days.length,
          'day_daypart_row_count': dayDayparts.length,
        },
      );
      return row;
    });
  }

  Future<WeeklyPlanSnapshotPostgresRow?> unlockActiveSnapshot({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String weekStartDate,
    required String actorUserId,
    required String reason,
    required String idempotencyKey,
    String actorKind = 'operator_user',
  }) {
    _validateNonBlank(reason, 'reason');
    _validateNonBlank(idempotencyKey, 'idempotencyKey');
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<WeeklyPlanSnapshotPostgresRow?>(ctx, (exec) async {
      final replayEntityId = await _fetchAuditEntityByIdempotency(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        idempotencyKey: idempotencyKey,
      );
      if (replayEntityId != null) {
        return _fetchBySnapshotId(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          snapshotId: replayEntityId,
        );
      }

      final before = await _fetchActiveSnapshot(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
        weekStartDate: weekStartDate,
      );
      if (before == null) return null;

      final rows = await exec.query(
        'update public.weekly_plan_snapshots '
        "set snapshot_status = 'unlocked', "
        '    unlocked_at = now(), '
        '    unlocked_by_user_id = @actor_user_id::uuid, '
        '    replacement_reason = @reason, '
        '    updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and snapshot_id = @snapshot_id::uuid '
        "  and snapshot_status = 'active' "
        'returning $_columns',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'snapshot_id': before.snapshotId,
          'actor_user_id': actorUserId,
          'reason': reason,
        },
      );
      if (rows.isEmpty) return null;
      final after = _snapshotRowFromMap(rows.single);
      await _insertAuditEvent(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        eventType: 'weekly_plan_unlocked',
        entityId: after.snapshotId,
        actorKind: actorKind,
        actorUserId: actorUserId,
        reason: reason,
        idempotencyKey: idempotencyKey,
        beforeSnapshot: before.toJson(),
        afterSnapshot: after.toJson(),
        metadata: <String, Object?>{
          'restaurant_id': after.restaurantId,
          'week_start_date': after.weekStartDate,
        },
      );
      return after;
    });
  }

  Future<WeeklyPlanSnapshotPostgresRow?> loadActiveSnapshot({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String weekStartDate,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<WeeklyPlanSnapshotPostgresRow?>(ctx, (exec) {
      return _fetchActiveSnapshot(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
        weekStartDate: weekStartDate,
      );
    });
  }

  Future<List<WeeklyPlanSnapshotPostgresRow>> listUpdatedSince({
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
    return withTenant<List<WeeklyPlanSnapshotPostgresRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_columnsWithAlias '
        'from public.weekly_plan_snapshots s '
        'where s.operator_id = @operator_id::uuid '
        '  and s.location_id = @location_id::uuid '
        "  and s.snapshot_status = 'active' "
        '  and s.updated_at > @updated_after::timestamptz '
        'order by s.updated_at asc, s.snapshot_id asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_after': updatedAfter.toUtc().toIso8601String(),
          'limit': limit,
        },
      );
      return <WeeklyPlanSnapshotPostgresRow>[
        for (final row in rows) _snapshotRowFromMap(row),
      ];
    });
  }

  Future<List<WeeklyPlanSnapshotDayPostgresRow>> listDaysForSnapshot({
    required String operatorId,
    required String locationId,
    required String snapshotId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<WeeklyPlanSnapshotDayPostgresRow>>(ctx, (
      exec,
    ) async {
      final rows = await exec.query(
        'select $_dayColumnsWithAlias '
        'from public.weekly_plan_snapshot_days d '
        'where d.operator_id = @operator_id::uuid '
        '  and d.location_id = @location_id::uuid '
        '  and d.snapshot_id = @snapshot_id::uuid '
        'order by d.day_index asc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'snapshot_id': snapshotId,
        },
      );
      return <WeeklyPlanSnapshotDayPostgresRow>[
        for (final row in rows) _snapshotDayRowFromMap(row),
      ];
    });
  }

  Future<List<WeeklyPlanSnapshotDayDaypartPostgresRow>>
  listDayDaypartsForSnapshot({
    required String operatorId,
    required String locationId,
    required String snapshotId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<WeeklyPlanSnapshotDayDaypartPostgresRow>>(ctx, (
      exec,
    ) async {
      final rows = await exec.query(
        'select $_dayDaypartColumnsWithAlias '
        'from public.weekly_plan_snapshot_day_dayparts dd '
        'where dd.operator_id = @operator_id::uuid '
        '  and dd.location_id = @location_id::uuid '
        '  and dd.snapshot_id = @snapshot_id::uuid '
        'order by dd.business_date asc, dd.service_period_id asc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'snapshot_id': snapshotId,
        },
      );
      return <WeeklyPlanSnapshotDayDaypartPostgresRow>[
        for (final row in rows) _snapshotDayDaypartRowFromMap(row),
      ];
    });
  }

  Future<WeeklyPlanSnapshotPostgresRow?> _fetchActiveSnapshot(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String weekStartDate,
  }) async {
    final rows = await exec.query(
      'select $_columnsWithAlias '
      'from public.weekly_plan_snapshots s '
      'where s.operator_id = @operator_id::uuid '
      '  and s.location_id = @location_id::uuid '
      '  and s.restaurant_id = @restaurant_id '
      '  and s.week_start_date = @week_start_date::date '
      "  and s.snapshot_status = 'active' "
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'restaurant_id': restaurantId,
        'week_start_date': weekStartDate,
      },
    );
    if (rows.isEmpty) return null;
    return _snapshotRowFromMap(rows.single);
  }

  Future<WeeklyPlanSnapshotPostgresRow?> _fetchBySnapshotId(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String snapshotId,
  }) async {
    final rows = await exec.query(
      'select $_columnsWithAlias '
      'from public.weekly_plan_snapshots s '
      'where s.operator_id = @operator_id::uuid '
      '  and s.location_id = @location_id::uuid '
      '  and s.snapshot_id = @snapshot_id::uuid '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'snapshot_id': snapshotId,
      },
    );
    if (rows.isEmpty) return null;
    return _snapshotRowFromMap(rows.single);
  }

  Future<WeeklyPlanSnapshotPostgresRow?> _fetchByIdempotency(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  }) async {
    final rows = await exec.query(
      'select $_columnsWithAlias '
      'from public.weekly_plan_snapshots s '
      'where s.operator_id = @operator_id::uuid '
      '  and s.location_id = @location_id::uuid '
      '  and s.idempotency_key = @idempotency_key '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'idempotency_key': idempotencyKey,
      },
    );
    if (rows.isEmpty) return null;
    return _snapshotRowFromMap(rows.single);
  }

  Future<String?> _fetchAuditEntityByIdempotency(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  }) async {
    final rows = await exec.query(
      'select entity_id::text as entity_id '
      'from public.weekly_plan_audit_events '
      'where operator_id = @operator_id::uuid '
      '  and location_id = @location_id::uuid '
      '  and idempotency_key = @idempotency_key '
      "  and event_type = 'weekly_plan_unlocked' "
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'idempotency_key': idempotencyKey,
      },
    );
    if (rows.isEmpty) return null;
    return rows.single['entity_id']! as String;
  }

  Future<WeeklyPlanSnapshotPostgresRow> _insertSnapshotWithExecutor(
    PostgresExecutor exec,
    WeeklyPlanSnapshotPostgresWrite snapshot, {
    required String sourceOverride,
    String? supersedesSnapshotId,
  }) async {
    final rows = await exec.query(
      'insert into public.weekly_plan_snapshots ('
      '  snapshot_id, operator_id, location_id, restaurant_id, '
      '  week_start_date, week_end_date, week_key, target_cycle_id, '
      '  forecast_context_id, forecast_covers, forecast_sales, '
      '  required_foh_hours, required_boh_hours, '
      '  theoretical_foh_labor_dollars, theoretical_boh_labor_dollars, '
      '  covers_source, sales_source, snapshot_status, source, '
      '  generated_at, locked_at, supersedes_snapshot_id, '
      '  replacement_reason, idempotency_key, request_hash, metadata, '
      '  wage_at_lock_time_json, created_by'
      ') values ('
      '  coalesce(@snapshot_id::uuid, gen_random_uuid()), '
      '  @operator_id::uuid, @location_id::uuid, @restaurant_id, '
      '  @week_start_date::date, @week_end_date::date, @week_key, '
      '  @target_cycle_id::uuid, @forecast_context_id::uuid, '
      '  @forecast_covers, @forecast_sales, @required_foh_hours, '
      '  @required_boh_hours, @theoretical_foh_labor_dollars, '
      '  @theoretical_boh_labor_dollars, @covers_source, @sales_source, '
      "  'active', @source, @generated_at::timestamptz, "
      '  @locked_at::timestamptz, @supersedes_snapshot_id::uuid, '
      '  @replacement_reason, @idempotency_key, @request_hash, '
      '  @metadata::jsonb, @wage_at_lock_time_json::jsonb, @created_by::uuid'
      ') returning $_columns',
      parameters: snapshot.toSqlParameters(
        sourceOverride: sourceOverride,
        supersedesSnapshotId: supersedesSnapshotId,
      ),
    );
    if (rows.isEmpty) {
      throw StateError('weekly_plan_snapshots insert returned no rows');
    }
    return _snapshotRowFromMap(rows.single);
  }

  Future<void> _insertDayWithExecutor(
    PostgresExecutor exec,
    WeeklyPlanSnapshotDayPostgresWrite day,
    String snapshotId,
  ) async {
    await exec.query(
      'insert into public.weekly_plan_snapshot_days ('
      '  operator_id, location_id, snapshot_id, restaurant_id, day_index, '
      '  day_label, business_date, forecast_covers, forecast_sales, '
      '  required_foh_hours, required_boh_hours'
      ') values ('
      '  @operator_id::uuid, @location_id::uuid, @snapshot_id::uuid, '
      '  @restaurant_id, @day_index, @day_label, @business_date::date, '
      '  @forecast_covers, @forecast_sales, @required_foh_hours, '
      '  @required_boh_hours'
      ') '
      'on conflict (operator_id, location_id, snapshot_id, day_index) '
      'do nothing '
      'returning $_dayColumns',
      parameters: day.toSqlParameters(snapshotId: snapshotId),
    );
  }

  Future<void> _insertDayDaypartWithExecutor(
    PostgresExecutor exec,
    WeeklyPlanSnapshotDayDaypartPostgresWrite dayDaypart,
    String snapshotId,
  ) async {
    await exec.query(
      'insert into public.weekly_plan_snapshot_day_dayparts ('
      '  operator_id, location_id, snapshot_id, business_date, '
      '  service_period_id, forecast_covers, forecast_sales, '
      '  required_foh_hours, required_boh_hours, theoretical_foh_dollars, '
      '  theoretical_boh_dollars'
      ') values ('
      '  @operator_id::uuid, @location_id::uuid, @snapshot_id::uuid, '
      '  @business_date::date, @service_period_id, @forecast_covers, '
      '  @forecast_sales, @required_foh_hours, @required_boh_hours, '
      '  @theoretical_foh_dollars, @theoretical_boh_dollars'
      ') '
      'on conflict (snapshot_id, business_date, service_period_id) '
      'do nothing '
      'returning $_dayDaypartColumns',
      parameters: dayDaypart.toSqlParameters(snapshotId: snapshotId),
    );
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
      "  'weekly_plan_snapshots', @entity_id::uuid, @actor_kind, "
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

class WeeklyPlanSnapshotPostgresWrite {
  const WeeklyPlanSnapshotPostgresWrite({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    this.snapshotId,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.weekKey,
    required this.targetCycleId,
    this.forecastContextId,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohLaborDollars,
    required this.theoreticalBohLaborDollars,
    required this.coversSource,
    required this.salesSource,
    this.source = 'server_lock',
    required this.generatedAt,
    required this.lockedAt,
    this.supersedesSnapshotId,
    this.replacementReason,
    required this.idempotencyKey,
    required this.requestHash,
    this.wageAtLockTimeJson,
    this.metadata = const <String, Object?>{},
    this.createdBy,
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String? snapshotId;
  final String weekStartDate;
  final String weekEndDate;
  final String weekKey;
  final String targetCycleId;
  final String? forecastContextId;
  final int forecastCovers;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;
  final double theoreticalFohLaborDollars;
  final double theoreticalBohLaborDollars;
  final String coversSource;
  final String salesSource;
  final String source;
  final DateTime generatedAt;
  final DateTime lockedAt;
  final String? supersedesSnapshotId;
  final String? replacementReason;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, Object?>? wageAtLockTimeJson;
  final Map<String, Object?> metadata;
  final String? createdBy;

  void validate() {
    _validateNonBlank(restaurantId, 'restaurantId');
    _validateNonBlank(weekStartDate, 'weekStartDate');
    _validateNonBlank(weekEndDate, 'weekEndDate');
    _validateNonBlank(weekKey, 'weekKey');
    _validateNonBlank(targetCycleId, 'targetCycleId');
    _validateNonBlank(coversSource, 'coversSource');
    _validateNonBlank(salesSource, 'salesSource');
    _validateNonBlank(idempotencyKey, 'idempotencyKey');
    _validateNonBlank(requestHash, 'requestHash');
    if (!const <String>{
      'server_lock',
      'server_replace',
      'admin_replacement',
      'system_bootstrap',
    }.contains(source)) {
      throw ArgumentError.value(source, 'source');
    }
  }

  PostgresParameters toSqlParameters({
    required String sourceOverride,
    String? supersedesSnapshotId,
  }) => <String, Object?>{
    'snapshot_id': snapshotId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'week_start_date': weekStartDate,
    'week_end_date': weekEndDate,
    'week_key': weekKey,
    'target_cycle_id': targetCycleId,
    'forecast_context_id': forecastContextId,
    'forecast_covers': forecastCovers,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_foh_labor_dollars': theoreticalFohLaborDollars,
    'theoretical_boh_labor_dollars': theoreticalBohLaborDollars,
    'covers_source': coversSource,
    'sales_source': salesSource,
    'source': sourceOverride,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'locked_at': lockedAt.toUtc().toIso8601String(),
    'supersedes_snapshot_id': supersedesSnapshotId ?? this.supersedesSnapshotId,
    'replacement_reason': replacementReason,
    'idempotency_key': idempotencyKey,
    'request_hash': requestHash,
    'wage_at_lock_time_json': wageAtLockTimeJson == null
        ? null
        : jsonEncode(wageAtLockTimeJson),
    'metadata': jsonEncode(metadata),
    'created_by': createdBy,
  };
}

class WeeklyPlanSnapshotDayPostgresWrite {
  const WeeklyPlanSnapshotDayPostgresWrite({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.dayIndex,
    required this.dayLabel,
    required this.businessDate,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final int dayIndex;
  final String dayLabel;
  final String businessDate;
  final int forecastCovers;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;

  void validateForSnapshot(WeeklyPlanSnapshotPostgresWrite snapshot) {
    if (operatorId != snapshot.operatorId ||
        locationId != snapshot.locationId ||
        restaurantId != snapshot.restaurantId) {
      throw ArgumentError.value(
        '$operatorId/$locationId/$restaurantId',
        'day scope',
        'must match snapshot scope',
      );
    }
    _validateNonBlank(dayLabel, 'dayLabel');
    _validateNonBlank(businessDate, 'businessDate');
    if (dayIndex < 0 || dayIndex > 6) {
      throw ArgumentError.value(dayIndex, 'dayIndex');
    }
  }

  PostgresParameters toSqlParameters({required String snapshotId}) =>
      <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'snapshot_id': snapshotId,
        'restaurant_id': restaurantId,
        'day_index': dayIndex,
        'day_label': dayLabel,
        'business_date': businessDate,
        'forecast_covers': forecastCovers,
        'forecast_sales': forecastSales,
        'required_foh_hours': requiredFohHours,
        'required_boh_hours': requiredBohHours,
      };
}

class WeeklyPlanSnapshotDayDaypartPostgresWrite {
  const WeeklyPlanSnapshotDayDaypartPostgresWrite({
    required this.operatorId,
    required this.locationId,
    required this.businessDate,
    required this.servicePeriodId,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohDollars,
    required this.theoreticalBohDollars,
  });

  final String operatorId;
  final String locationId;
  final String businessDate;
  final String servicePeriodId;
  final int forecastCovers;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;
  final double theoreticalFohDollars;
  final double theoreticalBohDollars;

  void validateForSnapshot(WeeklyPlanSnapshotPostgresWrite snapshot) {
    if (operatorId != snapshot.operatorId || locationId != snapshot.locationId) {
      throw ArgumentError.value(
        '$operatorId/$locationId',
        'dayDaypart scope',
        'must match snapshot scope',
      );
    }
    _validateNonBlank(businessDate, 'businessDate');
    _validateNonBlank(servicePeriodId, 'servicePeriodId');
  }

  PostgresParameters toSqlParameters({required String snapshotId}) =>
      <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'snapshot_id': snapshotId,
        'business_date': businessDate,
        'service_period_id': servicePeriodId,
        'forecast_covers': forecastCovers,
        'forecast_sales': forecastSales,
        'required_foh_hours': requiredFohHours,
        'required_boh_hours': requiredBohHours,
        'theoretical_foh_dollars': theoreticalFohDollars,
        'theoretical_boh_dollars': theoreticalBohDollars,
      };
}

class WeeklyPlanSnapshotPostgresRow {
  const WeeklyPlanSnapshotPostgresRow({
    required this.snapshotId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.weekKey,
    required this.targetCycleId,
    required this.forecastContextId,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohLaborDollars,
    required this.theoreticalBohLaborDollars,
    required this.coversSource,
    required this.salesSource,
    required this.snapshotStatus,
    required this.source,
    required this.generatedAt,
    required this.lockedAt,
    required this.supersededAt,
    required this.supersededBySnapshotId,
    required this.supersedesSnapshotId,
    required this.unlockedAt,
    required this.unlockedByUserId,
    required this.replacementReason,
    required this.idempotencyKey,
    required this.requestHash,
    required this.wageAtLockTimeJson,
    required this.metadata,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  final String snapshotId;
  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String weekStartDate;
  final String weekEndDate;
  final String weekKey;
  final String targetCycleId;
  final String? forecastContextId;
  final int forecastCovers;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;
  final double theoreticalFohLaborDollars;
  final double theoreticalBohLaborDollars;
  final String coversSource;
  final String salesSource;
  final String snapshotStatus;
  final String source;
  final DateTime generatedAt;
  final DateTime lockedAt;
  final DateTime? supersededAt;
  final String? supersededBySnapshotId;
  final String? supersedesSnapshotId;
  final DateTime? unlockedAt;
  final String? unlockedByUserId;
  final String? replacementReason;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, Object?>? wageAtLockTimeJson;
  final Map<String, Object?> metadata;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'snapshot_id': snapshotId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'week_start_date': weekStartDate,
    'week_end_date': weekEndDate,
    'week_key': weekKey,
    'target_cycle_id': targetCycleId,
    'forecast_context_id': forecastContextId,
    'forecast_covers': forecastCovers,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_foh_labor_dollars': theoreticalFohLaborDollars,
    'theoretical_boh_labor_dollars': theoreticalBohLaborDollars,
    'covers_source': coversSource,
    'sales_source': salesSource,
    'snapshot_status': snapshotStatus,
    'source': source,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'locked_at': lockedAt.toUtc().toIso8601String(),
    'superseded_at': supersededAt?.toUtc().toIso8601String(),
    'superseded_by_snapshot_id': supersededBySnapshotId,
    'supersedes_snapshot_id': supersedesSnapshotId,
    'unlocked_at': unlockedAt?.toUtc().toIso8601String(),
    'unlocked_by_user_id': unlockedByUserId,
    'replacement_reason': replacementReason,
    'idempotency_key': idempotencyKey,
    'request_hash': requestHash,
    'wage_at_lock_time_json': wageAtLockTimeJson,
    'metadata': metadata,
    'created_by': createdBy,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

class WeeklyPlanSnapshotDayPostgresRow {
  const WeeklyPlanSnapshotDayPostgresRow({
    required this.snapshotDayId,
    required this.operatorId,
    required this.locationId,
    required this.snapshotId,
    required this.restaurantId,
    required this.dayIndex,
    required this.dayLabel,
    required this.businessDate,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.createdAt,
    required this.updatedAt,
  });

  final String snapshotDayId;
  final String operatorId;
  final String locationId;
  final String snapshotId;
  final String restaurantId;
  final int dayIndex;
  final String dayLabel;
  final String businessDate;
  final int forecastCovers;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'snapshot_day_id': snapshotDayId,
    'operator_id': operatorId,
    'location_id': locationId,
    'snapshot_id': snapshotId,
    'restaurant_id': restaurantId,
    'day_index': dayIndex,
    'day_label': dayLabel,
    'business_date': businessDate,
    'forecast_covers': forecastCovers,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

class WeeklyPlanSnapshotDayDaypartPostgresRow {
  const WeeklyPlanSnapshotDayDaypartPostgresRow({
    required this.snapshotId,
    required this.operatorId,
    required this.locationId,
    required this.businessDate,
    required this.servicePeriodId,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohDollars,
    required this.theoreticalBohDollars,
    required this.createdAt,
    required this.updatedAt,
  });

  final String snapshotId;
  final String operatorId;
  final String locationId;
  final String businessDate;
  final String servicePeriodId;
  final int forecastCovers;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;
  final double theoreticalFohDollars;
  final double theoreticalBohDollars;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'snapshot_id': snapshotId,
    'operator_id': operatorId,
    'location_id': locationId,
    'business_date': businessDate,
    'service_period_id': servicePeriodId,
    'forecast_covers': forecastCovers,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_foh_dollars': theoreticalFohDollars,
    'theoretical_boh_dollars': theoreticalBohDollars,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

WeeklyPlanSnapshotPostgresRow _snapshotRowFromMap(PostgresRow row) {
  return WeeklyPlanSnapshotPostgresRow(
    snapshotId: row['snapshot_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    restaurantId: row['restaurant_id']! as String,
    weekStartDate: _dateString(row['week_start_date'])!,
    weekEndDate: _dateString(row['week_end_date'])!,
    weekKey: row['week_key']! as String,
    targetCycleId: row['target_cycle_id']! as String,
    forecastContextId: row['forecast_context_id'] as String?,
    forecastCovers: (row['forecast_covers']! as num).toInt(),
    forecastSales: _toDouble(row['forecast_sales']),
    requiredFohHours: _toDouble(row['required_foh_hours']),
    requiredBohHours: _toDouble(row['required_boh_hours']),
    theoreticalFohLaborDollars: _toDouble(row['theoretical_foh_labor_dollars']),
    theoreticalBohLaborDollars: _toDouble(row['theoretical_boh_labor_dollars']),
    coversSource: row['covers_source']! as String,
    salesSource: row['sales_source']! as String,
    snapshotStatus: row['snapshot_status']! as String,
    source: row['source']! as String,
    generatedAt: _toDateTime(row['generated_at'])!,
    lockedAt: _toDateTime(row['locked_at'])!,
    supersededAt: _toDateTime(row['superseded_at']),
    supersededBySnapshotId: row['superseded_by_snapshot_id'] as String?,
    supersedesSnapshotId: row['supersedes_snapshot_id'] as String?,
    unlockedAt: _toDateTime(row['unlocked_at']),
    unlockedByUserId: row['unlocked_by_user_id'] as String?,
    replacementReason: row['replacement_reason'] as String?,
    idempotencyKey: row['idempotency_key']! as String,
    requestHash: row['request_hash']! as String,
    wageAtLockTimeJson: _nullableJsonObjectFromValue(
      row['wage_at_lock_time_json'],
    ),
    metadata: _jsonObjectFromValue(row['metadata']),
    createdBy: row['created_by'] as String?,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

WeeklyPlanSnapshotDayDaypartPostgresRow _snapshotDayDaypartRowFromMap(
  PostgresRow row,
) {
  return WeeklyPlanSnapshotDayDaypartPostgresRow(
    snapshotId: row['snapshot_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    businessDate: _dateString(row['business_date'])!,
    servicePeriodId: row['service_period_id']! as String,
    forecastCovers: (row['forecast_covers']! as num).toInt(),
    forecastSales: _toDouble(row['forecast_sales']),
    requiredFohHours: _toDouble(row['required_foh_hours']),
    requiredBohHours: _toDouble(row['required_boh_hours']),
    theoreticalFohDollars: _toDouble(row['theoretical_foh_dollars']),
    theoreticalBohDollars: _toDouble(row['theoretical_boh_dollars']),
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

WeeklyPlanSnapshotDayPostgresRow _snapshotDayRowFromMap(PostgresRow row) {
  return WeeklyPlanSnapshotDayPostgresRow(
    snapshotDayId: row['snapshot_day_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    snapshotId: row['snapshot_id']! as String,
    restaurantId: row['restaurant_id']! as String,
    dayIndex: (row['day_index']! as num).toInt(),
    dayLabel: row['day_label']! as String,
    businessDate: _dateString(row['business_date'])!,
    forecastCovers: (row['forecast_covers']! as num).toInt(),
    forecastSales: _toDouble(row['forecast_sales']),
    requiredFohHours: _toDouble(row['required_foh_hours']),
    requiredBohHours: _toDouble(row['required_boh_hours']),
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

String _replacementSource(String source) {
  return source == 'server_lock' ? 'server_replace' : source;
}

Map<String, Object?> _jsonObjectFromValue(Object? value) {
  if (value == null) return const <String, Object?>{};
  return _coerceJsonObject(value);
}

Map<String, Object?>? _nullableJsonObjectFromValue(Object? value) {
  if (value == null) return null;
  return _coerceJsonObject(value);
}

Map<String, Object?> _coerceJsonObject(Object? value) {
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
