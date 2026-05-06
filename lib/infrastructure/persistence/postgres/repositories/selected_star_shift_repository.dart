// Phase 8 star/target truth - selected star decision repository.
//
// This repository owns server-side manager/admin select and clear decisions.
// Recommendation candidates can be referenced as provenance, but this table
// never fabricates a manager-selected row from a recommendation.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class SelectedStarShiftRepository extends OperatorScopedRepository {
  SelectedStarShiftRepository(super.tenantWrapper);

  static const String _columns =
      'decision_id::text as decision_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'restaurant_id, '
      'record_key, '
      'week_id, '
      'day_label, '
      'daypart, '
      'business_date::text as business_date, '
      'service_period_key, '
      'target_cycle_id::text as target_cycle_id, '
      'decision_type, '
      'decision_source, '
      'actor_user_id::text as actor_user_id, '
      'decided_at, '
      'source_system, '
      'source_shift_id, '
      'source_shift_record_id, '
      'covers, '
      'cplh, '
      'splh, '
      'ppa, '
      'primary_lever_id, '
      'actual_labor_pct, '
      'has_actual_labor_pct_truth, '
      'recommendation_reference_id, '
      'candidate_snapshot, '
      'reason, '
      'idempotency_key, '
      'request_hash, '
      'metadata, '
      'created_at, '
      'updated_at';

  static const String _columnsWithAlias =
      'd.decision_id::text as decision_id, '
      'd.operator_id::text as operator_id, '
      'd.location_id::text as location_id, '
      'd.restaurant_id, '
      'd.record_key, '
      'd.week_id, '
      'd.day_label, '
      'd.daypart, '
      'd.business_date::text as business_date, '
      'd.service_period_key, '
      'd.target_cycle_id::text as target_cycle_id, '
      'd.decision_type, '
      'd.decision_source, '
      'd.actor_user_id::text as actor_user_id, '
      'd.decided_at, '
      'd.source_system, '
      'd.source_shift_id, '
      'd.source_shift_record_id, '
      'd.covers, '
      'd.cplh, '
      'd.splh, '
      'd.ppa, '
      'd.primary_lever_id, '
      'd.actual_labor_pct, '
      'd.has_actual_labor_pct_truth, '
      'd.recommendation_reference_id, '
      'd.candidate_snapshot, '
      'd.reason, '
      'd.idempotency_key, '
      'd.request_hash, '
      'd.metadata, '
      'd.created_at, '
      'd.updated_at';

  Future<SelectedStarShiftDecisionRow> recordDecision({
    required SelectedStarShiftDecisionWrite decision,
    String actorKind = 'operator_user',
  }) {
    decision.validate();
    final ctx = TenantContext(
      operatorId: decision.operatorId,
      locationId: decision.locationId,
      userId: decision.actorUserId,
    );
    return withTenant<SelectedStarShiftDecisionRow>(ctx, (exec) async {
      final rows = await exec.query(
        'with inserted as ('
        '  insert into public.selected_star_shift_decisions ('
        '    operator_id, location_id, restaurant_id, record_key, week_id, '
        '    day_label, daypart, business_date, service_period_key, '
        '    target_cycle_id, decision_type, decision_source, actor_user_id, '
        '    decided_at, source_system, source_shift_id, '
        '    source_shift_record_id, covers, cplh, splh, ppa, '
        '    primary_lever_id, actual_labor_pct, '
        '    has_actual_labor_pct_truth, recommendation_reference_id, '
        '    candidate_snapshot, reason, idempotency_key, request_hash, '
        '    metadata'
        '  ) values ('
        '    @operator_id::uuid, @location_id::uuid, @restaurant_id, '
        '    @record_key, @week_id, @day_label, @daypart, '
        '    @business_date::date, @service_period_key, '
        '    @target_cycle_id::uuid, @decision_type, @decision_source, '
        '    @actor_user_id::uuid, '
        '    coalesce(@decided_at::timestamptz, now()), '
        '    @source_system, @source_shift_id, @source_shift_record_id, '
        '    @covers, @cplh, @splh, @ppa, @primary_lever_id, '
        '    @actual_labor_pct, @has_actual_labor_pct_truth, '
        '    @recommendation_reference_id, @candidate_snapshot::jsonb, '
        '    @reason, @idempotency_key, @request_hash, @metadata::jsonb'
        '  ) '
        '  on conflict (operator_id, location_id, idempotency_key) '
        '  do nothing '
        '  returning true as inserted, $_columns'
        '), replay as ('
        '  select false as inserted, $_columnsWithAlias '
        '  from public.selected_star_shift_decisions d '
        '  where d.operator_id = @operator_id::uuid '
        '    and d.location_id = @location_id::uuid '
        '    and d.idempotency_key = @idempotency_key '
        '    and not exists (select 1 from inserted)'
        ') '
        'select * from inserted '
        'union all '
        'select * from replay '
        'limit 1',
        parameters: decision.toSqlParameters(),
      );
      if (rows.isEmpty) {
        throw StateError(
          'selected_star_shift_decisions write returned no rows',
        );
      }
      final row = _decisionRowFromMap(rows.single);
      if (rows.single['inserted'] == true) {
        await _insertAuditEvent(
          exec,
          operatorId: decision.operatorId,
          locationId: decision.locationId,
          eventType: row.isClear
              ? 'selected_star_cleared'
              : 'selected_star_selected',
          entityTable: 'selected_star_shift_decisions',
          entityId: row.decisionId,
          actorKind: actorKind,
          actorUserId: decision.actorUserId,
          reason: decision.reason ?? row.decisionType,
          idempotencyKey: decision.idempotencyKey,
          afterSnapshot: row.toJson(),
          metadata: decision.metadata,
        );
      }
      return row;
    });
  }

  Future<List<SelectedStarShiftDecisionRow>> listCurrentSelections({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
    int limit = 250,
  }) {
    _validatePositiveLimit(limit);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<SelectedStarShiftDecisionRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'with latest as ('
        '  select distinct on (d.record_key) $_columnsWithAlias '
        '  from public.selected_star_shift_decisions d '
        '  where d.operator_id = @operator_id::uuid '
        '    and d.location_id = @location_id::uuid '
        '    and d.restaurant_id = @restaurant_id '
        '  order by d.record_key, d.decided_at desc, '
        '           d.created_at desc, d.decision_id desc'
        ') '
        'select * from latest '
        "where decision_type in ('manager_selected', 'admin_selected') "
        'order by record_key asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'restaurant_id': restaurantId,
          'limit': limit,
        },
      );
      return <SelectedStarShiftDecisionRow>[
        for (final row in rows) _decisionRowFromMap(row),
      ];
    });
  }

  Future<List<SelectedStarShiftDecisionRow>> listUpdatedSince({
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
    return withTenant<List<SelectedStarShiftDecisionRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_columnsWithAlias '
        'from public.selected_star_shift_decisions d '
        'where d.operator_id = @operator_id::uuid '
        '  and d.location_id = @location_id::uuid '
        '  and d.updated_at > @updated_after::timestamptz '
        'order by d.updated_at asc, d.decision_id asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_after': updatedAfter.toUtc().toIso8601String(),
          'limit': limit,
        },
      );
      return <SelectedStarShiftDecisionRow>[
        for (final row in rows) _decisionRowFromMap(row),
      ];
    });
  }

  Future<void> _insertAuditEvent(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String eventType,
    required String entityTable,
    required String entityId,
    required String actorKind,
    required String? actorUserId,
    required String reason,
    required String idempotencyKey,
    required Map<String, Object?> afterSnapshot,
    required Map<String, Object?> metadata,
  }) async {
    await exec.query(
      'insert into public.star_target_audit_events ('
      '  operator_id, location_id, event_type, entity_table, entity_id, '
      '  actor_kind, actor_user_id, reason, idempotency_key, '
      '  after_snapshot, metadata'
      ') values ('
      '  @operator_id::uuid, @location_id::uuid, @event_type, '
      '  @entity_table, @entity_id::uuid, @actor_kind, '
      '  @actor_user_id::uuid, @reason, @idempotency_key, '
      '  @after_snapshot::jsonb, @metadata::jsonb'
      ') returning audit_event_id::text as audit_event_id',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'event_type': eventType,
        'entity_table': entityTable,
        'entity_id': entityId,
        'actor_kind': actorKind,
        'actor_user_id': actorUserId,
        'reason': reason,
        'idempotency_key': idempotencyKey,
        'after_snapshot': jsonEncode(afterSnapshot),
        'metadata': jsonEncode(metadata),
      },
    );
  }
}

class SelectedStarShiftDecisionWrite {
  const SelectedStarShiftDecisionWrite({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.recordKey,
    required this.weekId,
    required this.dayLabel,
    required this.daypart,
    required this.businessDate,
    this.servicePeriodKey,
    this.targetCycleId,
    required this.decisionType,
    required this.decisionSource,
    this.actorUserId,
    this.decidedAt,
    this.sourceSystem,
    this.sourceShiftId,
    this.sourceShiftRecordId,
    this.covers,
    this.cplh,
    this.splh,
    this.ppa,
    this.primaryLeverId,
    this.actualLaborPct,
    this.hasActualLaborPctTruth = false,
    this.recommendationReferenceId,
    this.candidateSnapshot = const <String, Object?>{},
    this.reason,
    required this.idempotencyKey,
    required this.requestHash,
    this.metadata = const <String, Object?>{},
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String recordKey;
  final String weekId;
  final String dayLabel;
  final String daypart;
  final String businessDate;
  final String? servicePeriodKey;
  final String? targetCycleId;
  final String decisionType;
  final String decisionSource;
  final String? actorUserId;
  final DateTime? decidedAt;
  final String? sourceSystem;
  final String? sourceShiftId;
  final String? sourceShiftRecordId;
  final int? covers;
  final double? cplh;
  final double? splh;
  final double? ppa;
  final String? primaryLeverId;
  final double? actualLaborPct;
  final bool hasActualLaborPctTruth;
  final String? recommendationReferenceId;
  final Map<String, Object?> candidateSnapshot;
  final String? reason;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, Object?> metadata;

  bool get isClear =>
      decisionType == 'manager_cleared' || decisionType == 'admin_cleared';

  void validate() {
    _validateNonBlank(restaurantId, 'restaurantId');
    _validateNonBlank(recordKey, 'recordKey');
    _validateNonBlank(weekId, 'weekId');
    _validateNonBlank(dayLabel, 'dayLabel');
    _validateNonBlank(daypart, 'daypart');
    _validateNonBlank(idempotencyKey, 'idempotencyKey');
    _validateNonBlank(requestHash, 'requestHash');
    if (decisionType.startsWith('manager_') && decisionSource != 'manager') {
      throw ArgumentError.value(
        decisionSource,
        'decisionSource',
        'manager decisions must use decisionSource manager',
      );
    }
    if (decisionType.startsWith('admin_') && decisionSource != 'admin') {
      throw ArgumentError.value(
        decisionSource,
        'decisionSource',
        'admin decisions must use decisionSource admin',
      );
    }
    if (!const <String>{
      'manager_selected',
      'manager_cleared',
      'admin_selected',
      'admin_cleared',
    }.contains(decisionType)) {
      throw ArgumentError.value(decisionType, 'decisionType');
    }
  }

  PostgresParameters toSqlParameters() => <String, Object?>{
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'record_key': recordKey,
    'week_id': weekId,
    'day_label': dayLabel,
    'daypart': daypart,
    'business_date': businessDate,
    'service_period_key': servicePeriodKey,
    'target_cycle_id': targetCycleId,
    'decision_type': decisionType,
    'decision_source': decisionSource,
    'actor_user_id': actorUserId,
    'decided_at': decidedAt?.toUtc().toIso8601String(),
    'source_system': sourceSystem,
    'source_shift_id': sourceShiftId,
    'source_shift_record_id': sourceShiftRecordId,
    'covers': covers,
    'cplh': cplh,
    'splh': splh,
    'ppa': ppa,
    'primary_lever_id': primaryLeverId,
    'actual_labor_pct': actualLaborPct,
    'has_actual_labor_pct_truth': hasActualLaborPctTruth,
    'recommendation_reference_id': recommendationReferenceId,
    'candidate_snapshot': jsonEncode(candidateSnapshot),
    'reason': reason,
    'idempotency_key': idempotencyKey,
    'request_hash': requestHash,
    'metadata': jsonEncode(metadata),
  };
}

class SelectedStarShiftDecisionRow {
  const SelectedStarShiftDecisionRow({
    required this.decisionId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.recordKey,
    required this.weekId,
    required this.dayLabel,
    required this.daypart,
    required this.businessDate,
    required this.servicePeriodKey,
    required this.targetCycleId,
    required this.decisionType,
    required this.decisionSource,
    required this.actorUserId,
    required this.decidedAt,
    required this.sourceSystem,
    required this.sourceShiftId,
    required this.sourceShiftRecordId,
    required this.covers,
    required this.cplh,
    required this.splh,
    required this.ppa,
    required this.primaryLeverId,
    required this.actualLaborPct,
    required this.hasActualLaborPctTruth,
    required this.recommendationReferenceId,
    required this.candidateSnapshot,
    required this.reason,
    required this.idempotencyKey,
    required this.requestHash,
    required this.metadata,
    required this.createdAt,
    required this.updatedAt,
  });

  final String decisionId;
  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String recordKey;
  final String weekId;
  final String dayLabel;
  final String daypart;
  final String businessDate;
  final String? servicePeriodKey;
  final String? targetCycleId;
  final String decisionType;
  final String decisionSource;
  final String? actorUserId;
  final DateTime decidedAt;
  final String? sourceSystem;
  final String? sourceShiftId;
  final String? sourceShiftRecordId;
  final int? covers;
  final double? cplh;
  final double? splh;
  final double? ppa;
  final String? primaryLeverId;
  final double? actualLaborPct;
  final bool hasActualLaborPctTruth;
  final String? recommendationReferenceId;
  final Map<String, Object?> candidateSnapshot;
  final String? reason;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, Object?> metadata;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isClear =>
      decisionType == 'manager_cleared' || decisionType == 'admin_cleared';

  Map<String, Object?> toJson() => <String, Object?>{
    'decision_id': decisionId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'record_key': recordKey,
    'week_id': weekId,
    'day_label': dayLabel,
    'daypart': daypart,
    'business_date': businessDate,
    'service_period_key': servicePeriodKey,
    'target_cycle_id': targetCycleId,
    'decision_type': decisionType,
    'decision_source': decisionSource,
    'actor_user_id': actorUserId,
    'decided_at': decidedAt.toUtc().toIso8601String(),
    'source_system': sourceSystem,
    'source_shift_id': sourceShiftId,
    'source_shift_record_id': sourceShiftRecordId,
    'covers': covers,
    'cplh': cplh,
    'splh': splh,
    'ppa': ppa,
    'primary_lever_id': primaryLeverId,
    'actual_labor_pct': actualLaborPct,
    'has_actual_labor_pct_truth': hasActualLaborPctTruth,
    'recommendation_reference_id': recommendationReferenceId,
    'candidate_snapshot': candidateSnapshot,
    'reason': reason,
    'idempotency_key': idempotencyKey,
    'request_hash': requestHash,
    'metadata': metadata,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

SelectedStarShiftDecisionRow _decisionRowFromMap(PostgresRow row) {
  return SelectedStarShiftDecisionRow(
    decisionId: row['decision_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    restaurantId: row['restaurant_id']! as String,
    recordKey: row['record_key']! as String,
    weekId: row['week_id']! as String,
    dayLabel: row['day_label']! as String,
    daypart: row['daypart']! as String,
    businessDate: _dateString(row['business_date'])!,
    servicePeriodKey: row['service_period_key'] as String?,
    targetCycleId: row['target_cycle_id'] as String?,
    decisionType: row['decision_type']! as String,
    decisionSource: row['decision_source']! as String,
    actorUserId: row['actor_user_id'] as String?,
    decidedAt: _toDateTime(row['decided_at'])!,
    sourceSystem: row['source_system'] as String?,
    sourceShiftId: row['source_shift_id'] as String?,
    sourceShiftRecordId: row['source_shift_record_id'] as String?,
    covers: (row['covers'] as num?)?.toInt(),
    cplh: _toNullableDouble(row['cplh']),
    splh: _toNullableDouble(row['splh']),
    ppa: _toNullableDouble(row['ppa']),
    primaryLeverId: row['primary_lever_id'] as String?,
    actualLaborPct: _toNullableDouble(row['actual_labor_pct']),
    hasActualLaborPctTruth: row['has_actual_labor_pct_truth']! as bool,
    recommendationReferenceId: row['recommendation_reference_id'] as String?,
    candidateSnapshot: _jsonObjectFromValue(row['candidate_snapshot']),
    reason: row['reason'] as String?,
    idempotencyKey: row['idempotency_key']! as String,
    requestHash: row['request_hash']! as String,
    metadata: _jsonObjectFromValue(row['metadata']),
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

double? _toNullableDouble(Object? value) {
  if (value == null) return null;
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
