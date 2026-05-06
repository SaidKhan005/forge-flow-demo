// Phase 8 star/target truth - target cycle repository.
//
// Server-owned target cycles replace the old mobile-only ownership model. The
// repository keeps the once-per-cycle manager override guard on the server side
// by checking the active cycle before replacement.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class TargetCycleRepository extends OperatorScopedRepository {
  TargetCycleRepository(super.tenantWrapper);

  static const String _columns =
      'cycle_id::text as cycle_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'restaurant_id, '
      'source, '
      'effective_start::text as effective_start, '
      'effective_end::text as effective_end, '
      'calibration_window_start::text as calibration_window_start, '
      'calibration_window_end::text as calibration_window_end, '
      'target_cplh, '
      'target_splh, '
      'target_ppa, '
      'foh_wage, '
      'boh_wage, '
      'opz_floor_cplh, '
      'opz_ceiling_cplh, '
      'manager_override_used, '
      'manager_override_at, '
      'manager_override_by_user_id::text as manager_override_by_user_id, '
      'admin_replaced_at, '
      'admin_replaced_by_user_id::text as admin_replaced_by_user_id, '
      'supersedes_cycle_id::text as supersedes_cycle_id, '
      'selected_shift_count, '
      'selected_record_keys, '
      'selection_decision_ids, '
      'replacement_reason, '
      'idempotency_key, '
      'request_hash, '
      'created_by::text as created_by, '
      'created_at, '
      'updated_at, '
      'deactivated_at';

  static const String _columnsWithAlias =
      'c.cycle_id::text as cycle_id, '
      'c.operator_id::text as operator_id, '
      'c.location_id::text as location_id, '
      'c.restaurant_id, '
      'c.source, '
      'c.effective_start::text as effective_start, '
      'c.effective_end::text as effective_end, '
      'c.calibration_window_start::text as calibration_window_start, '
      'c.calibration_window_end::text as calibration_window_end, '
      'c.target_cplh, '
      'c.target_splh, '
      'c.target_ppa, '
      'c.foh_wage, '
      'c.boh_wage, '
      'c.opz_floor_cplh, '
      'c.opz_ceiling_cplh, '
      'c.manager_override_used, '
      'c.manager_override_at, '
      'c.manager_override_by_user_id::text as manager_override_by_user_id, '
      'c.admin_replaced_at, '
      'c.admin_replaced_by_user_id::text as admin_replaced_by_user_id, '
      'c.supersedes_cycle_id::text as supersedes_cycle_id, '
      'c.selected_shift_count, '
      'c.selected_record_keys, '
      'c.selection_decision_ids, '
      'c.replacement_reason, '
      'c.idempotency_key, '
      'c.request_hash, '
      'c.created_by::text as created_by, '
      'c.created_at, '
      'c.updated_at, '
      'c.deactivated_at';

  Future<TargetCyclePostgresRow?> loadActiveCycle({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<TargetCyclePostgresRow?>(ctx, (exec) {
      return _fetchActiveCycle(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
      );
    });
  }

  Future<TargetCyclePostgresRow> insertCycle({
    required TargetCyclePostgresWrite cycle,
    String actorKind = 'operator_user',
    required String reason,
  }) {
    cycle.validate();
    _validateNonBlank(reason, 'reason');
    final ctx = TenantContext(
      operatorId: cycle.operatorId,
      locationId: cycle.locationId,
      userId: cycle.createdBy,
    );
    return withTenant<TargetCyclePostgresRow>(ctx, (exec) async {
      final existing = await _fetchByIdempotency(
        exec,
        operatorId: cycle.operatorId,
        locationId: cycle.locationId,
        idempotencyKey: cycle.idempotencyKey,
      );
      if (existing != null) return existing;

      final row = await _insertCycleWithExecutor(exec, cycle);
      await _insertAuditEvent(
        exec,
        operatorId: cycle.operatorId,
        locationId: cycle.locationId,
        eventType: 'target_cycle_created',
        entityId: row.cycleId,
        actorKind: actorKind,
        actorUserId: cycle.createdBy,
        reason: reason,
        idempotencyKey: cycle.idempotencyKey,
        afterSnapshot: row.toJson(),
        metadata: <String, Object?>{
          'source': row.source,
          'restaurant_id': row.restaurantId,
        },
      );
      return row;
    });
  }

  Future<TargetCyclePostgresRow> replaceActiveCycle({
    required TargetCyclePostgresWrite replacement,
    bool enforceManagerOverrideAvailable = true,
    String actorKind = 'operator_user',
    required String reason,
  }) {
    replacement.validate();
    _validateNonBlank(reason, 'reason');
    final ctx = TenantContext(
      operatorId: replacement.operatorId,
      locationId: replacement.locationId,
      userId: replacement.createdBy,
    );
    return withTenant<TargetCyclePostgresRow>(ctx, (exec) async {
      final replay = await _fetchByIdempotency(
        exec,
        operatorId: replacement.operatorId,
        locationId: replacement.locationId,
        idempotencyKey: replacement.idempotencyKey,
      );
      if (replay != null) return replay;

      final before = await _fetchActiveCycle(
        exec,
        operatorId: replacement.operatorId,
        locationId: replacement.locationId,
        restaurantId: replacement.restaurantId,
      );
      if (enforceManagerOverrideAvailable &&
          replacement.source == 'manager_override' &&
          before?.managerOverrideUsed == true) {
        throw TargetCycleManagerOverrideAlreadyUsed(
          before!.cycleId,
          replacement.restaurantId,
        );
      }

      await exec.execute(
        'update public.target_cycles '
        'set deactivated_at = coalesce(deactivated_at, now()), '
        '    updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and restaurant_id = @restaurant_id '
        '  and deactivated_at is null',
        parameters: <String, Object?>{
          'operator_id': replacement.operatorId,
          'location_id': replacement.locationId,
          'restaurant_id': replacement.restaurantId,
        },
      );

      final row = await _insertCycleWithExecutor(
        exec,
        replacement,
        supersedesCycleId: replacement.supersedesCycleId ?? before?.cycleId,
      );
      await _insertAuditEvent(
        exec,
        operatorId: replacement.operatorId,
        locationId: replacement.locationId,
        eventType: 'target_cycle_replaced',
        entityId: row.cycleId,
        actorKind: actorKind,
        actorUserId: replacement.createdBy,
        reason: reason,
        idempotencyKey: replacement.idempotencyKey,
        beforeSnapshot: before?.toJson(),
        afterSnapshot: row.toJson(),
        metadata: <String, Object?>{
          'source': row.source,
          'restaurant_id': row.restaurantId,
          'supersedes_cycle_id': row.supersedesCycleId,
        },
      );
      return row;
    });
  }

  Future<int> deactivateActiveCycles({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String actorUserId,
    required String reason,
  }) {
    _validateNonBlank(reason, 'reason');
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      final before = await _fetchActiveCycle(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
      );
      final count = await exec.execute(
        'update public.target_cycles '
        'set deactivated_at = coalesce(deactivated_at, now()), '
        '    updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and restaurant_id = @restaurant_id '
        '  and deactivated_at is null',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'restaurant_id': restaurantId,
        },
      );
      if (before != null) {
        await _insertAuditEvent(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          eventType: 'target_cycle_deactivated',
          entityId: before.cycleId,
          actorKind: 'operator_user',
          actorUserId: actorUserId,
          reason: reason,
          idempotencyKey: before.idempotencyKey,
          beforeSnapshot: before.toJson(),
          metadata: <String, Object?>{'restaurant_id': restaurantId},
        );
      }
      return count;
    });
  }

  Future<List<TargetCyclePostgresRow>> listUpdatedSince({
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
    return withTenant<List<TargetCyclePostgresRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_columnsWithAlias '
        'from public.target_cycles c '
        'where c.operator_id = @operator_id::uuid '
        '  and c.location_id = @location_id::uuid '
        '  and c.updated_at > @updated_after::timestamptz '
        'order by c.updated_at asc, c.cycle_id asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_after': updatedAfter.toUtc().toIso8601String(),
          'limit': limit,
        },
      );
      return <TargetCyclePostgresRow>[
        for (final row in rows) _cycleRowFromMap(row),
      ];
    });
  }

  Future<TargetCyclePostgresRow?> _fetchActiveCycle(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) async {
    final rows = await exec.query(
      'select $_columnsWithAlias '
      'from public.target_cycles c '
      'where c.operator_id = @operator_id::uuid '
      '  and c.location_id = @location_id::uuid '
      '  and c.restaurant_id = @restaurant_id '
      '  and c.deactivated_at is null '
      'order by c.effective_start desc, c.created_at desc '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'restaurant_id': restaurantId,
      },
    );
    if (rows.isEmpty) return null;
    return _cycleRowFromMap(rows.single);
  }

  Future<TargetCyclePostgresRow?> _fetchByIdempotency(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  }) async {
    final rows = await exec.query(
      'select $_columnsWithAlias '
      'from public.target_cycles c '
      'where c.operator_id = @operator_id::uuid '
      '  and c.location_id = @location_id::uuid '
      '  and c.idempotency_key = @idempotency_key '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'idempotency_key': idempotencyKey,
      },
    );
    if (rows.isEmpty) return null;
    return _cycleRowFromMap(rows.single);
  }

  Future<TargetCyclePostgresRow> _insertCycleWithExecutor(
    PostgresExecutor exec,
    TargetCyclePostgresWrite cycle, {
    String? supersedesCycleId,
  }) async {
    final rows = await exec.query(
      'insert into public.target_cycles ('
      '  cycle_id, operator_id, location_id, restaurant_id, source, '
      '  effective_start, effective_end, calibration_window_start, '
      '  calibration_window_end, target_cplh, target_splh, target_ppa, '
      '  foh_wage, boh_wage, opz_floor_cplh, opz_ceiling_cplh, '
      '  manager_override_used, manager_override_at, '
      '  manager_override_by_user_id, admin_replaced_at, '
      '  admin_replaced_by_user_id, supersedes_cycle_id, '
      '  selected_shift_count, selected_record_keys, selection_decision_ids, '
      '  replacement_reason, idempotency_key, request_hash, created_by'
      ') values ('
      '  coalesce(@cycle_id::uuid, gen_random_uuid()), '
      '  @operator_id::uuid, @location_id::uuid, @restaurant_id, @source, '
      '  @effective_start::date, @effective_end::date, '
      '  @calibration_window_start::date, @calibration_window_end::date, '
      '  @target_cplh, @target_splh, @target_ppa, @foh_wage, @boh_wage, '
      '  @opz_floor_cplh, @opz_ceiling_cplh, @manager_override_used, '
      '  @manager_override_at::timestamptz, @manager_override_by_user_id::uuid, '
      '  @admin_replaced_at::timestamptz, @admin_replaced_by_user_id::uuid, '
      '  @supersedes_cycle_id::uuid, @selected_shift_count, '
      '  @selected_record_keys::jsonb, @selection_decision_ids::jsonb, '
      '  @replacement_reason, @idempotency_key, @request_hash, '
      '  @created_by::uuid'
      ') returning $_columns',
      parameters: cycle.toSqlParameters(supersedesCycleId: supersedesCycleId),
    );
    if (rows.isEmpty) {
      throw StateError('target_cycles insert returned no rows');
    }
    return _cycleRowFromMap(rows.single);
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
    Map<String, Object?>? afterSnapshot,
    required Map<String, Object?> metadata,
  }) async {
    await exec.query(
      'insert into public.star_target_audit_events ('
      '  operator_id, location_id, event_type, entity_table, entity_id, '
      '  actor_kind, actor_user_id, reason, idempotency_key, '
      '  before_snapshot, after_snapshot, metadata'
      ') values ('
      '  @operator_id::uuid, @location_id::uuid, @event_type, '
      "  'target_cycles', @entity_id::uuid, @actor_kind, "
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
        'after_snapshot': afterSnapshot == null
            ? null
            : jsonEncode(afterSnapshot),
        'metadata': jsonEncode(metadata),
      },
    );
  }
}

class TargetCyclePostgresWrite {
  const TargetCyclePostgresWrite({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    this.cycleId,
    required this.source,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.calibrationWindowStart,
    required this.calibrationWindowEnd,
    required this.targetCplh,
    required this.targetSplh,
    required this.targetPpa,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCplh,
    required this.opzCeilingCplh,
    this.managerOverrideUsed = false,
    this.managerOverrideAt,
    this.managerOverrideByUserId,
    this.adminReplacedAt,
    this.adminReplacedByUserId,
    this.supersedesCycleId,
    this.selectedShiftCount = 0,
    this.selectedRecordKeys = const <String>[],
    this.selectionDecisionIds = const <String>[],
    this.replacementReason,
    required this.idempotencyKey,
    required this.requestHash,
    this.createdBy,
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String? cycleId;
  final String source;
  final String effectiveStart;
  final String effectiveEnd;
  final String calibrationWindowStart;
  final String calibrationWindowEnd;
  final double targetCplh;
  final double targetSplh;
  final double targetPpa;
  final double fohWage;
  final double bohWage;
  final double opzFloorCplh;
  final double opzCeilingCplh;
  final bool managerOverrideUsed;
  final DateTime? managerOverrideAt;
  final String? managerOverrideByUserId;
  final DateTime? adminReplacedAt;
  final String? adminReplacedByUserId;
  final String? supersedesCycleId;
  final int selectedShiftCount;
  final List<String> selectedRecordKeys;
  final List<String> selectionDecisionIds;
  final String? replacementReason;
  final String idempotencyKey;
  final String requestHash;
  final String? createdBy;

  void validate() {
    _validateNonBlank(restaurantId, 'restaurantId');
    _validateNonBlank(idempotencyKey, 'idempotencyKey');
    _validateNonBlank(requestHash, 'requestHash');
    if (!const <String>{
      'recommended',
      'manager_override',
      'admin_replacement',
    }.contains(source)) {
      throw ArgumentError.value(source, 'source');
    }
    if (source == 'manager_override' &&
        (!managerOverrideUsed || managerOverrideAt == null)) {
      throw ArgumentError.value(
        source,
        'source',
        'manager overrides must carry manager override provenance',
      );
    }
    if (source == 'admin_replacement' && adminReplacedAt == null) {
      throw ArgumentError.value(
        source,
        'source',
        'admin replacements must carry replacement provenance',
      );
    }
  }

  PostgresParameters toSqlParameters({String? supersedesCycleId}) {
    return <String, Object?>{
      'cycle_id': cycleId,
      'operator_id': operatorId,
      'location_id': locationId,
      'restaurant_id': restaurantId,
      'source': source,
      'effective_start': effectiveStart,
      'effective_end': effectiveEnd,
      'calibration_window_start': calibrationWindowStart,
      'calibration_window_end': calibrationWindowEnd,
      'target_cplh': targetCplh,
      'target_splh': targetSplh,
      'target_ppa': targetPpa,
      'foh_wage': fohWage,
      'boh_wage': bohWage,
      'opz_floor_cplh': opzFloorCplh,
      'opz_ceiling_cplh': opzCeilingCplh,
      'manager_override_used': managerOverrideUsed,
      'manager_override_at': managerOverrideAt?.toUtc().toIso8601String(),
      'manager_override_by_user_id': managerOverrideByUserId,
      'admin_replaced_at': adminReplacedAt?.toUtc().toIso8601String(),
      'admin_replaced_by_user_id': adminReplacedByUserId,
      'supersedes_cycle_id': supersedesCycleId ?? this.supersedesCycleId,
      'selected_shift_count': selectedShiftCount,
      'selected_record_keys': jsonEncode(selectedRecordKeys),
      'selection_decision_ids': jsonEncode(selectionDecisionIds),
      'replacement_reason': replacementReason,
      'idempotency_key': idempotencyKey,
      'request_hash': requestHash,
      'created_by': createdBy,
    };
  }
}

class TargetCyclePostgresRow {
  const TargetCyclePostgresRow({
    required this.cycleId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.source,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.calibrationWindowStart,
    required this.calibrationWindowEnd,
    required this.targetCplh,
    required this.targetSplh,
    required this.targetPpa,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCplh,
    required this.opzCeilingCplh,
    required this.managerOverrideUsed,
    required this.managerOverrideAt,
    required this.managerOverrideByUserId,
    required this.adminReplacedAt,
    required this.adminReplacedByUserId,
    required this.supersedesCycleId,
    required this.selectedShiftCount,
    required this.selectedRecordKeys,
    required this.selectionDecisionIds,
    required this.replacementReason,
    required this.idempotencyKey,
    required this.requestHash,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.deactivatedAt,
  });

  final String cycleId;
  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String source;
  final String effectiveStart;
  final String effectiveEnd;
  final String calibrationWindowStart;
  final String calibrationWindowEnd;
  final double targetCplh;
  final double targetSplh;
  final double targetPpa;
  final double fohWage;
  final double bohWage;
  final double opzFloorCplh;
  final double opzCeilingCplh;
  final bool managerOverrideUsed;
  final DateTime? managerOverrideAt;
  final String? managerOverrideByUserId;
  final DateTime? adminReplacedAt;
  final String? adminReplacedByUserId;
  final String? supersedesCycleId;
  final int selectedShiftCount;
  final List<String> selectedRecordKeys;
  final List<String> selectionDecisionIds;
  final String? replacementReason;
  final String idempotencyKey;
  final String requestHash;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deactivatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'cycle_id': cycleId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'source': source,
    'effective_start': effectiveStart,
    'effective_end': effectiveEnd,
    'calibration_window_start': calibrationWindowStart,
    'calibration_window_end': calibrationWindowEnd,
    'target_cplh': targetCplh,
    'target_splh': targetSplh,
    'target_ppa': targetPpa,
    'foh_wage': fohWage,
    'boh_wage': bohWage,
    'opz_floor_cplh': opzFloorCplh,
    'opz_ceiling_cplh': opzCeilingCplh,
    'manager_override_used': managerOverrideUsed,
    'manager_override_at': managerOverrideAt?.toUtc().toIso8601String(),
    'manager_override_by_user_id': managerOverrideByUserId,
    'admin_replaced_at': adminReplacedAt?.toUtc().toIso8601String(),
    'admin_replaced_by_user_id': adminReplacedByUserId,
    'supersedes_cycle_id': supersedesCycleId,
    'selected_shift_count': selectedShiftCount,
    'selected_record_keys': selectedRecordKeys,
    'selection_decision_ids': selectionDecisionIds,
    'replacement_reason': replacementReason,
    'idempotency_key': idempotencyKey,
    'request_hash': requestHash,
    'created_by': createdBy,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'deactivated_at': deactivatedAt?.toUtc().toIso8601String(),
  };
}

class TargetCycleManagerOverrideAlreadyUsed implements Exception {
  const TargetCycleManagerOverrideAlreadyUsed(
    this.activeCycleId,
    this.restaurantId,
  );

  final String activeCycleId;
  final String restaurantId;

  @override
  String toString() {
    return 'TargetCycleManagerOverrideAlreadyUsed('
        'activeCycleId: $activeCycleId, restaurantId: $restaurantId)';
  }
}

TargetCyclePostgresRow _cycleRowFromMap(PostgresRow row) {
  return TargetCyclePostgresRow(
    cycleId: row['cycle_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    restaurantId: row['restaurant_id']! as String,
    source: row['source']! as String,
    effectiveStart: _dateString(row['effective_start'])!,
    effectiveEnd: _dateString(row['effective_end'])!,
    calibrationWindowStart: _dateString(row['calibration_window_start'])!,
    calibrationWindowEnd: _dateString(row['calibration_window_end'])!,
    targetCplh: _toDouble(row['target_cplh']),
    targetSplh: _toDouble(row['target_splh']),
    targetPpa: _toDouble(row['target_ppa']),
    fohWage: _toDouble(row['foh_wage']),
    bohWage: _toDouble(row['boh_wage']),
    opzFloorCplh: _toDouble(row['opz_floor_cplh']),
    opzCeilingCplh: _toDouble(row['opz_ceiling_cplh']),
    managerOverrideUsed: row['manager_override_used']! as bool,
    managerOverrideAt: _toDateTime(row['manager_override_at']),
    managerOverrideByUserId: row['manager_override_by_user_id'] as String?,
    adminReplacedAt: _toDateTime(row['admin_replaced_at']),
    adminReplacedByUserId: row['admin_replaced_by_user_id'] as String?,
    supersedesCycleId: row['supersedes_cycle_id'] as String?,
    selectedShiftCount: row['selected_shift_count']! as int,
    selectedRecordKeys: _stringListFromValue(row['selected_record_keys']),
    selectionDecisionIds: _stringListFromValue(row['selection_decision_ids']),
    replacementReason: row['replacement_reason'] as String?,
    idempotencyKey: row['idempotency_key']! as String,
    requestHash: row['request_hash']! as String,
    createdBy: row['created_by'] as String?,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
    deactivatedAt: _toDateTime(row['deactivated_at']),
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

List<String> _stringListFromValue(Object? value) {
  if (value == null) return const <String>[];
  final dynamic decoded = value is String ? jsonDecode(value) : value;
  if (decoded is! List<dynamic>) {
    throw StateError('JSON value was not a list');
  }
  return <String>[for (final item in decoded) item.toString()];
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
