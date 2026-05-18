// Phase 8 star/target truth - active target profile repository.
//
// Active profiles are server projections from target_cycles. The repository
// writes the current projection and its immutable version row in one tenant
// transaction so closed-shift provenance can reference stable target inputs.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class ActiveTargetProfileRepository extends OperatorScopedRepository {
  ActiveTargetProfileRepository(super.tenantWrapper);

  static const String _profileColumns =
      'target_profile_id::text as target_profile_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'restaurant_id, '
      'target_cycle_id::text as target_cycle_id, '
      'target_profile_version_id::text as target_profile_version_id, '
      'source_type, '
      'target_cplh, '
      'target_splh, '
      'target_ppa, '
      'foh_wage, '
      'boh_wage, '
      'opz_floor_cplh, '
      'opz_ceiling_cplh, '
      'theoretical_foh_labor_pct, '
      'theoretical_boh_labor_pct, '
      'theoretical_labor_pct, '
      'built_at, '
      'projection_source, '
      'created_at, '
      'updated_at';

  static const String _profileColumnsWithAlias =
      'p.target_profile_id::text as target_profile_id, '
      'p.operator_id::text as operator_id, '
      'p.location_id::text as location_id, '
      'p.restaurant_id, '
      'p.target_cycle_id::text as target_cycle_id, '
      'p.target_profile_version_id::text as target_profile_version_id, '
      'p.source_type, '
      'p.target_cplh, '
      'p.target_splh, '
      'p.target_ppa, '
      'p.foh_wage, '
      'p.boh_wage, '
      'p.opz_floor_cplh, '
      'p.opz_ceiling_cplh, '
      'p.theoretical_foh_labor_pct, '
      'p.theoretical_boh_labor_pct, '
      'p.theoretical_labor_pct, '
      'p.built_at, '
      'p.projection_source, '
      'p.created_at, '
      'p.updated_at';

  static const String _versionColumns =
      'target_profile_version_id::text as target_profile_version_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'target_profile_id::text as target_profile_id, '
      'restaurant_id, '
      'target_cycle_id::text as target_cycle_id, '
      'source_type, '
      'target_cplh, '
      'target_splh, '
      'target_ppa, '
      'foh_wage, '
      'boh_wage, '
      'opz_floor_cplh, '
      'opz_ceiling_cplh, '
      'theoretical_foh_labor_pct, '
      'theoretical_boh_labor_pct, '
      'theoretical_labor_pct, '
      'created_at, '
      'updated_at';

  static const String _versionColumnsWithAlias =
      'v.target_profile_version_id::text as target_profile_version_id, '
      'v.operator_id::text as operator_id, '
      'v.location_id::text as location_id, '
      'v.target_profile_id::text as target_profile_id, '
      'v.restaurant_id, '
      'v.target_cycle_id::text as target_cycle_id, '
      'v.source_type, '
      'v.target_cplh, '
      'v.target_splh, '
      'v.target_ppa, '
      'v.foh_wage, '
      'v.boh_wage, '
      'v.opz_floor_cplh, '
      'v.opz_ceiling_cplh, '
      'v.theoretical_foh_labor_pct, '
      'v.theoretical_boh_labor_pct, '
      'v.theoretical_labor_pct, '
      'v.created_at, '
      'v.updated_at';

  static const String _profileDaypartColumnsWithAlias =
      'd.cycle_id::text as target_cycle_id, '
      'd.service_period_id, '
      'd.target_cplh as daypart_target_cplh, '
      'd.target_splh as daypart_target_splh, '
      'd.target_ppa as daypart_target_ppa, '
      'd.opz_floor_cplh as daypart_opz_floor_cplh, '
      'd.opz_ceiling_cplh as daypart_opz_ceiling_cplh, '
      'd.verdict, '
      'd.verdict_reason';

  Future<ActiveTargetProfilePostgresRow> upsertProjection({
    required ActiveTargetProfileProjectionWrite profile,
    String actorKind = 'operator_user',
    required String reason,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    profile.validate();
    _validateNonBlank(reason, 'reason');
    final ctx = TenantContext(
      operatorId: profile.operatorId,
      locationId: profile.locationId,
      userId: profile.actorUserId,
    );
    return withTenant<ActiveTargetProfilePostgresRow>(ctx, (exec) async {
      final before = await _fetchActiveProfile(
        exec,
        operatorId: profile.operatorId,
        locationId: profile.locationId,
        restaurantId: profile.restaurantId,
      );
      final active = (await _upsertActiveProfile(
        exec,
        profile,
      )).withDayparts(profile.dayparts);
      await _insertVersionWithExecutor(exec, profile, active.targetProfileId);
      await _insertAuditEvent(
        exec,
        operatorId: profile.operatorId,
        locationId: profile.locationId,
        eventType: 'active_target_profile_projected',
        entityTable: 'active_target_profiles',
        entityId: active.targetProfileId,
        actorKind: actorKind,
        actorUserId: profile.actorUserId,
        reason: reason,
        beforeSnapshot: before?.toJson(),
        afterSnapshot: active.toJson(),
        metadata: <String, Object?>{
          ...metadata,
          'target_cycle_id': active.targetCycleId,
          'target_profile_version_id': active.targetProfileVersionId,
        },
      );
      return active;
    });
  }

  Future<ActiveTargetProfilePostgresRow?> loadActiveProfile({
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
    return withTenant<ActiveTargetProfilePostgresRow?>(ctx, (exec) {
      return _fetchActiveProfile(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
      );
    });
  }

  Future<List<ActiveTargetProfilePostgresRow>> listUpdatedSince({
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
    return withTenant<List<ActiveTargetProfilePostgresRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_profileColumnsWithAlias '
        'from public.active_target_profiles p '
        'where p.operator_id = @operator_id::uuid '
        '  and p.location_id = @location_id::uuid '
        '  and p.updated_at > @updated_after::timestamptz '
        'order by p.updated_at asc, p.target_profile_id asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_after': updatedAfter.toUtc().toIso8601String(),
          'limit': limit,
        },
      );
      return _profileRowsFromMapsWithDayparts(exec, rows);
    });
  }

  Future<List<TargetProfileVersionPostgresRow>> listVersionsUpdatedSince({
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
    return withTenant<List<TargetProfileVersionPostgresRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_versionColumnsWithAlias '
        'from public.target_profile_versions v '
        'where v.operator_id = @operator_id::uuid '
        '  and v.location_id = @location_id::uuid '
        '  and v.updated_at > @updated_after::timestamptz '
        'order by v.updated_at asc, v.target_profile_version_id asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_after': updatedAfter.toUtc().toIso8601String(),
          'limit': limit,
        },
      );
      return <TargetProfileVersionPostgresRow>[
        for (final row in rows) _versionRowFromMap(row),
      ];
    });
  }

  Future<ActiveTargetProfilePostgresRow?> _fetchActiveProfile(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) async {
    final rows = await exec.query(
      'select $_profileColumnsWithAlias '
      'from public.active_target_profiles p '
      'where p.operator_id = @operator_id::uuid '
      '  and p.location_id = @location_id::uuid '
      '  and p.restaurant_id = @restaurant_id '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'restaurant_id': restaurantId,
      },
    );
    if (rows.isEmpty) return null;
    return _profileRowWithDaypartsFromMap(exec, rows.single);
  }

  Future<ActiveTargetProfilePostgresRow> _profileRowWithDaypartsFromMap(
    PostgresExecutor exec,
    PostgresRow row,
  ) async {
    final parent = _profileRowFromMap(row);
    final dayparts = await _fetchDaypartsForTargetCycleIds(
      exec,
      operatorId: parent.operatorId,
      locationId: parent.locationId,
      targetCycleIds: <String>[parent.targetCycleId],
    );
    return parent.withDayparts(
      dayparts[parent.targetCycleId] ?? const <ActiveTargetProfileDaypartRow>[],
    );
  }

  Future<List<ActiveTargetProfilePostgresRow>>
  _profileRowsFromMapsWithDayparts(
    PostgresExecutor exec,
    List<PostgresRow> rows,
  ) async {
    if (rows.isEmpty) return const <ActiveTargetProfilePostgresRow>[];
    final parents = <ActiveTargetProfilePostgresRow>[
      for (final row in rows) _profileRowFromMap(row),
    ];
    final dayparts = await _fetchDaypartsForTargetCycleIds(
      exec,
      operatorId: parents.first.operatorId,
      locationId: parents.first.locationId,
      targetCycleIds: <String>[for (final row in parents) row.targetCycleId],
    );
    return <ActiveTargetProfilePostgresRow>[
      for (final parent in parents)
        parent.withDayparts(
          dayparts[parent.targetCycleId] ??
              const <ActiveTargetProfileDaypartRow>[],
        ),
    ];
  }

  Future<Map<String, List<ActiveTargetProfileDaypartRow>>>
  _fetchDaypartsForTargetCycleIds(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required List<String> targetCycleIds,
  }) async {
    if (targetCycleIds.isEmpty) {
      return const <String, List<ActiveTargetProfileDaypartRow>>{};
    }
    final rows = await exec.query(
      'select $_profileDaypartColumnsWithAlias '
      'from public.target_cycle_dayparts d '
      'where d.operator_id = @operator_id::uuid '
      '  and d.location_id = @location_id::uuid '
      '  and d.cycle_id = any(@target_cycle_ids::uuid[]) '
      'order by d.cycle_id asc, d.service_period_id asc',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'target_cycle_ids': targetCycleIds,
      },
    );
    final grouped = <String, List<ActiveTargetProfileDaypartRow>>{};
    for (final row in rows) {
      final daypart = _profileDaypartRowFromMap(row);
      final targetCycleId = row['target_cycle_id']! as String;
      grouped.putIfAbsent(targetCycleId, () => []).add(daypart);
    }
    return grouped;
  }

  Future<ActiveTargetProfilePostgresRow> _upsertActiveProfile(
    PostgresExecutor exec,
    ActiveTargetProfileProjectionWrite profile,
  ) async {
    final rows = await exec.query(
      'insert into public.active_target_profiles ('
      '  target_profile_id, operator_id, location_id, restaurant_id, '
      '  target_cycle_id, target_profile_version_id, source_type, '
      '  target_cplh, target_splh, target_ppa, foh_wage, boh_wage, '
      '  opz_floor_cplh, opz_ceiling_cplh, theoretical_foh_labor_pct, '
      '  theoretical_boh_labor_pct, theoretical_labor_pct, built_at'
      ') values ('
      '  coalesce(@target_profile_id::uuid, gen_random_uuid()), '
      '  @operator_id::uuid, @location_id::uuid, @restaurant_id, '
      '  @target_cycle_id::uuid, @target_profile_version_id::uuid, '
      '  @source_type, @target_cplh, @target_splh, @target_ppa, '
      '  @foh_wage, @boh_wage, @opz_floor_cplh, @opz_ceiling_cplh, '
      '  @theoretical_foh_labor_pct, @theoretical_boh_labor_pct, '
      '  @theoretical_labor_pct, @built_at::timestamptz'
      ') '
      'on conflict on constraint active_target_profiles_restaurant_uq '
      'do update set '
      '  target_cycle_id = excluded.target_cycle_id, '
      '  target_profile_version_id = excluded.target_profile_version_id, '
      '  source_type = excluded.source_type, '
      '  target_cplh = excluded.target_cplh, '
      '  target_splh = excluded.target_splh, '
      '  target_ppa = excluded.target_ppa, '
      '  foh_wage = excluded.foh_wage, '
      '  boh_wage = excluded.boh_wage, '
      '  opz_floor_cplh = excluded.opz_floor_cplh, '
      '  opz_ceiling_cplh = excluded.opz_ceiling_cplh, '
      '  theoretical_foh_labor_pct = excluded.theoretical_foh_labor_pct, '
      '  theoretical_boh_labor_pct = excluded.theoretical_boh_labor_pct, '
      '  theoretical_labor_pct = excluded.theoretical_labor_pct, '
      '  built_at = excluded.built_at, '
      '  projection_source = excluded.projection_source, '
      '  updated_at = now() '
      'returning $_profileColumns',
      parameters: profile.toSqlParameters(),
    );
    if (rows.isEmpty) {
      throw StateError('active_target_profiles upsert returned no rows');
    }
    return _profileRowFromMap(rows.single);
  }

  Future<void> _insertVersionWithExecutor(
    PostgresExecutor exec,
    ActiveTargetProfileProjectionWrite profile,
    String targetProfileId,
  ) async {
    await exec.query(
      'insert into public.target_profile_versions ('
      '  target_profile_version_id, operator_id, location_id, '
      '  target_profile_id, restaurant_id, target_cycle_id, source_type, '
      '  target_cplh, target_splh, target_ppa, foh_wage, boh_wage, '
      '  opz_floor_cplh, opz_ceiling_cplh, theoretical_foh_labor_pct, '
      '  theoretical_boh_labor_pct, theoretical_labor_pct'
      ') values ('
      '  @target_profile_version_id::uuid, @operator_id::uuid, '
      '  @location_id::uuid, @target_profile_id::uuid, @restaurant_id, '
      '  @target_cycle_id::uuid, @source_type, @target_cplh, '
      '  @target_splh, @target_ppa, @foh_wage, @boh_wage, '
      '  @opz_floor_cplh, @opz_ceiling_cplh, '
      '  @theoretical_foh_labor_pct, @theoretical_boh_labor_pct, '
      '  @theoretical_labor_pct'
      ') '
      'on conflict (operator_id, location_id, target_profile_version_id) '
      'do nothing '
      'returning $_versionColumns',
      parameters: <String, Object?>{
        ...profile.toSqlParameters(),
        'target_profile_id': targetProfileId,
      },
    );
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
    Map<String, Object?>? beforeSnapshot,
    Map<String, Object?>? afterSnapshot,
    required Map<String, Object?> metadata,
  }) async {
    await exec.query(
      'insert into public.star_target_audit_events ('
      '  operator_id, location_id, event_type, entity_table, entity_id, '
      '  actor_kind, actor_user_id, reason, before_snapshot, '
      '  after_snapshot, metadata'
      ') values ('
      '  @operator_id::uuid, @location_id::uuid, @event_type, '
      '  @entity_table, @entity_id::uuid, @actor_kind, '
      '  @actor_user_id::uuid, @reason, @before_snapshot::jsonb, '
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

class ActiveTargetProfileProjectionWrite {
  const ActiveTargetProfileProjectionWrite({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    this.targetProfileId,
    required this.targetCycleId,
    required this.targetProfileVersionId,
    required this.sourceType,
    required this.targetCplh,
    required this.targetSplh,
    required this.targetPpa,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCplh,
    required this.opzCeilingCplh,
    required this.theoreticalFohLaborPct,
    required this.theoreticalBohLaborPct,
    required this.theoreticalLaborPct,
    required this.builtAt,
    this.actorUserId,
    this.dayparts = const <ActiveTargetProfileDaypartRow>[],
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String? targetProfileId;
  final String targetCycleId;
  final String targetProfileVersionId;
  final String sourceType;
  final double targetCplh;
  final double targetSplh;
  final double targetPpa;
  final double fohWage;
  final double bohWage;
  final double opzFloorCplh;
  final double opzCeilingCplh;
  final double theoreticalFohLaborPct;
  final double theoreticalBohLaborPct;
  final double theoreticalLaborPct;
  final DateTime builtAt;
  final String? actorUserId;
  final List<ActiveTargetProfileDaypartRow> dayparts;

  void validate() {
    _validateNonBlank(restaurantId, 'restaurantId');
    if (!const <String>{
      'cycle_recommended',
      'cycle_manager_override',
      'cycle_admin_replacement',
    }.contains(sourceType)) {
      throw ArgumentError.value(sourceType, 'sourceType');
    }
  }

  PostgresParameters toSqlParameters() => <String, Object?>{
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'target_profile_id': targetProfileId,
    'target_cycle_id': targetCycleId,
    'target_profile_version_id': targetProfileVersionId,
    'source_type': sourceType,
    'target_cplh': targetCplh,
    'target_splh': targetSplh,
    'target_ppa': targetPpa,
    'foh_wage': fohWage,
    'boh_wage': bohWage,
    'opz_floor_cplh': opzFloorCplh,
    'opz_ceiling_cplh': opzCeilingCplh,
    'theoretical_foh_labor_pct': theoreticalFohLaborPct,
    'theoretical_boh_labor_pct': theoreticalBohLaborPct,
    'theoretical_labor_pct': theoreticalLaborPct,
    'built_at': builtAt.toUtc().toIso8601String(),
  };
}

class ActiveTargetProfileDaypartRow {
  const ActiveTargetProfileDaypartRow({
    required this.servicePeriodId,
    required this.daypartTargetCplh,
    required this.daypartTargetSplh,
    required this.daypartTargetPpa,
    required this.daypartOpzFloorCplh,
    required this.daypartOpzCeilingCplh,
    this.verdict,
    this.verdictReason,
  });

  final String servicePeriodId;
  final double daypartTargetCplh;
  final double daypartTargetSplh;
  final double daypartTargetPpa;
  final double daypartOpzFloorCplh;
  final double daypartOpzCeilingCplh;
  final String? verdict;
  final String? verdictReason;

  Map<String, Object?> toJson() => <String, Object?>{
    'service_period_id': servicePeriodId,
    'daypart_target_cplh': daypartTargetCplh,
    'daypart_target_splh': daypartTargetSplh,
    'daypart_target_ppa': daypartTargetPpa,
    'daypart_opz_floor_cplh': daypartOpzFloorCplh,
    'daypart_opz_ceiling_cplh': daypartOpzCeilingCplh,
    'verdict': verdict,
    'verdict_reason': verdictReason,
  };
}

class ActiveTargetProfilePostgresRow {
  const ActiveTargetProfilePostgresRow({
    required this.targetProfileId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.targetCycleId,
    required this.targetProfileVersionId,
    required this.sourceType,
    required this.targetCplh,
    required this.targetSplh,
    required this.targetPpa,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCplh,
    required this.opzCeilingCplh,
    required this.theoreticalFohLaborPct,
    required this.theoreticalBohLaborPct,
    required this.theoreticalLaborPct,
    required this.builtAt,
    required this.projectionSource,
    required this.createdAt,
    required this.updatedAt,
    this.dayparts = const <ActiveTargetProfileDaypartRow>[],
  });

  final String targetProfileId;
  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String targetCycleId;
  final String targetProfileVersionId;
  final String sourceType;
  final double targetCplh;
  final double targetSplh;
  final double targetPpa;
  final double fohWage;
  final double bohWage;
  final double opzFloorCplh;
  final double opzCeilingCplh;
  final double theoreticalFohLaborPct;
  final double theoreticalBohLaborPct;
  final double theoreticalLaborPct;
  final DateTime builtAt;
  final String projectionSource;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ActiveTargetProfileDaypartRow> dayparts;

  Map<String, Object?> toJson() => <String, Object?>{
    'target_profile_id': targetProfileId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'target_cycle_id': targetCycleId,
    'target_profile_version_id': targetProfileVersionId,
    'source_type': sourceType,
    'target_cplh': targetCplh,
    'target_splh': targetSplh,
    'target_ppa': targetPpa,
    'foh_wage': fohWage,
    'boh_wage': bohWage,
    'opz_floor_cplh': opzFloorCplh,
    'opz_ceiling_cplh': opzCeilingCplh,
    'theoretical_foh_labor_pct': theoreticalFohLaborPct,
    'theoretical_boh_labor_pct': theoreticalBohLaborPct,
    'theoretical_labor_pct': theoreticalLaborPct,
    'built_at': builtAt.toUtc().toIso8601String(),
    'projection_source': projectionSource,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'dayparts': <Map<String, Object?>>[
      for (final daypart in dayparts) daypart.toJson(),
    ],
    'active_target_profile_dayparts': <Map<String, Object?>>[
      for (final daypart in dayparts) daypart.toJson(),
    ],
  };

  ActiveTargetProfilePostgresRow withDayparts(
    List<ActiveTargetProfileDaypartRow> rows,
  ) =>
      ActiveTargetProfilePostgresRow(
        targetProfileId: targetProfileId,
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
        targetCycleId: targetCycleId,
        targetProfileVersionId: targetProfileVersionId,
        sourceType: sourceType,
        targetCplh: targetCplh,
        targetSplh: targetSplh,
        targetPpa: targetPpa,
        fohWage: fohWage,
        bohWage: bohWage,
        opzFloorCplh: opzFloorCplh,
        opzCeilingCplh: opzCeilingCplh,
        theoreticalFohLaborPct: theoreticalFohLaborPct,
        theoreticalBohLaborPct: theoreticalBohLaborPct,
        theoreticalLaborPct: theoreticalLaborPct,
        builtAt: builtAt,
        projectionSource: projectionSource,
        createdAt: createdAt,
        updatedAt: updatedAt,
        dayparts: List<ActiveTargetProfileDaypartRow>.unmodifiable(rows),
      );
}

class TargetProfileVersionPostgresRow {
  const TargetProfileVersionPostgresRow({
    required this.targetProfileVersionId,
    required this.operatorId,
    required this.locationId,
    required this.targetProfileId,
    required this.restaurantId,
    required this.targetCycleId,
    required this.sourceType,
    required this.targetCplh,
    required this.targetSplh,
    required this.targetPpa,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCplh,
    required this.opzCeilingCplh,
    required this.theoreticalFohLaborPct,
    required this.theoreticalBohLaborPct,
    required this.theoreticalLaborPct,
    required this.createdAt,
    required this.updatedAt,
  });

  final String targetProfileVersionId;
  final String operatorId;
  final String locationId;
  final String targetProfileId;
  final String restaurantId;
  final String targetCycleId;
  final String sourceType;
  final double targetCplh;
  final double targetSplh;
  final double targetPpa;
  final double fohWage;
  final double bohWage;
  final double opzFloorCplh;
  final double opzCeilingCplh;
  final double theoreticalFohLaborPct;
  final double theoreticalBohLaborPct;
  final double theoreticalLaborPct;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'target_profile_version_id': targetProfileVersionId,
    'operator_id': operatorId,
    'location_id': locationId,
    'target_profile_id': targetProfileId,
    'restaurant_id': restaurantId,
    'target_cycle_id': targetCycleId,
    'source_type': sourceType,
    'target_cplh': targetCplh,
    'target_splh': targetSplh,
    'target_ppa': targetPpa,
    'foh_wage': fohWage,
    'boh_wage': bohWage,
    'opz_floor_cplh': opzFloorCplh,
    'opz_ceiling_cplh': opzCeilingCplh,
    'theoretical_foh_labor_pct': theoreticalFohLaborPct,
    'theoretical_boh_labor_pct': theoreticalBohLaborPct,
    'theoretical_labor_pct': theoreticalLaborPct,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

ActiveTargetProfilePostgresRow _profileRowFromMap(PostgresRow row) {
  return ActiveTargetProfilePostgresRow(
    targetProfileId: row['target_profile_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    restaurantId: row['restaurant_id']! as String,
    targetCycleId: row['target_cycle_id']! as String,
    targetProfileVersionId: row['target_profile_version_id']! as String,
    sourceType: row['source_type']! as String,
    targetCplh: _toDouble(row['target_cplh']),
    targetSplh: _toDouble(row['target_splh']),
    targetPpa: _toDouble(row['target_ppa']),
    fohWage: _toDouble(row['foh_wage']),
    bohWage: _toDouble(row['boh_wage']),
    opzFloorCplh: _toDouble(row['opz_floor_cplh']),
    opzCeilingCplh: _toDouble(row['opz_ceiling_cplh']),
    theoreticalFohLaborPct: _toDouble(row['theoretical_foh_labor_pct']),
    theoreticalBohLaborPct: _toDouble(row['theoretical_boh_labor_pct']),
    theoreticalLaborPct: _toDouble(row['theoretical_labor_pct']),
    builtAt: _toDateTime(row['built_at'])!,
    projectionSource: row['projection_source']! as String,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

ActiveTargetProfileDaypartRow _profileDaypartRowFromMap(PostgresRow row) {
  return ActiveTargetProfileDaypartRow(
    servicePeriodId: row['service_period_id']! as String,
    daypartTargetCplh: _toDouble(row['daypart_target_cplh']),
    daypartTargetSplh: _toDouble(row['daypart_target_splh']),
    daypartTargetPpa: _toDouble(row['daypart_target_ppa']),
    daypartOpzFloorCplh: _toDouble(row['daypart_opz_floor_cplh']),
    daypartOpzCeilingCplh: _toDouble(row['daypart_opz_ceiling_cplh']),
    verdict: row['verdict'] as String?,
    verdictReason: row['verdict_reason'] as String?,
  );
}

TargetProfileVersionPostgresRow _versionRowFromMap(PostgresRow row) {
  return TargetProfileVersionPostgresRow(
    targetProfileVersionId: row['target_profile_version_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    targetProfileId: row['target_profile_id']! as String,
    restaurantId: row['restaurant_id']! as String,
    targetCycleId: row['target_cycle_id']! as String,
    sourceType: row['source_type']! as String,
    targetCplh: _toDouble(row['target_cplh']),
    targetSplh: _toDouble(row['target_splh']),
    targetPpa: _toDouble(row['target_ppa']),
    fohWage: _toDouble(row['foh_wage']),
    bohWage: _toDouble(row['boh_wage']),
    opzFloorCplh: _toDouble(row['opz_floor_cplh']),
    opzCeilingCplh: _toDouble(row['opz_ceiling_cplh']),
    theoreticalFohLaborPct: _toDouble(row['theoretical_foh_labor_pct']),
    theoreticalBohLaborPct: _toDouble(row['theoretical_boh_labor_pct']),
    theoreticalLaborPct: _toDouble(row['theoretical_labor_pct']),
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
