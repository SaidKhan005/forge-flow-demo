// Business Timing Live - BusinessTimingProfilesRepository.
//
// Operator-scoped persistence for `business_timing_profiles`,
// `business_timing_service_periods`, and `business_timing_audit_events`.
// Profiles are not location-RLS-gated: resolving a location must read inherited
// operator and org-unit rows before applying a location override. The repository
// still requires a full TenantContext so the wrapper injects operator/location
// audit context before RLS evaluates.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class BusinessTimingProfilesRepository extends OperatorScopedRepository {
  BusinessTimingProfilesRepository(super.tenantWrapper);

  static const String _profileColumns =
      'p.profile_id::text as profile_id, '
      'p.operator_id::text as operator_id, '
      'p.scope_type, '
      'p.scope_id::text as scope_id, '
      'p.display_name, '
      'p.business_day_start_local_time::text as business_day_start_local_time, '
      'p.week_start_day, '
      'p.close_authority, '
      'p.local_close_fallback_time::text as local_close_fallback_time, '
      'p.effective_from_business_date::text '
      'as effective_from_business_date, '
      'p.effective_until_business_date::text '
      'as effective_until_business_date, '
      'p.supersedes_profile_id::text as supersedes_profile_id, '
      'p.created_by::text as created_by, '
      'p.updated_by::text as updated_by, '
      'p.created_at, '
      'p.updated_at';

  static const String _periodJson =
      "coalesce(jsonb_agg(jsonb_build_object("
      "'service_period_id', sp.service_period_id::text, "
      "'operator_id', sp.operator_id::text, "
      "'profile_id', sp.profile_id::text, "
      "'service_period_key', sp.service_period_key, "
      "'label', sp.label, "
      "'short_label', sp.short_label, "
      "'sort_order', sp.sort_order, "
      "'start_local_time', sp.start_local_time::text, "
      "'end_local_time', sp.end_local_time::text, "
      "'rolls_past_midnight', sp.rolls_past_midnight, "
      "'applicable_weekdays', sp.applicable_weekdays"
      ") order by sp.sort_order) filter "
      "(where sp.service_period_id is not null), '[]'::jsonb) "
      'as service_periods';

  /// Lists profiles that can affect [locationId] on [businessDate], ordered in
  /// resolver precedence from operator default to org-unit ancestors to
  /// location override. [BusinessTimingProfileRow.locationTimezone] comes from
  /// `locations.timezone`; profiles intentionally do not duplicate timezone.
  Future<List<BusinessTimingProfileRow>> listCandidateProfilesForLocation({
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
    return withTenant<List<BusinessTimingProfileRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'with selected_location as ('
        '  select '
        '    loc.location_id, '
        '    loc.timezone as location_timezone, '
        '    loc.org_unit_path '
        '  from public.locations loc '
        '  where loc.operator_id = @operator_id::uuid '
        '    and loc.location_id = @location_id::uuid'
        '), candidate_scopes as ('
        "  select 'operator'::text as scope_type, "
        '         @operator_id::uuid as scope_id, '
        '         0::integer as scope_depth '
        '  union all '
        "  select 'org_unit'::text as scope_type, "
        '         ou.id as scope_id, '
        '         nlevel(ou.path)::integer as scope_depth '
        '  from public.org_units ou '
        '  join selected_location loc on ou.path @> loc.org_unit_path '
        '  where ou.operator_id = @operator_id::uuid '
        '  union all '
        "  select 'location'::text as scope_type, "
        '         loc.location_id as scope_id, '
        '         100000::integer as scope_depth '
        '  from selected_location loc'
        ') '
        'select $_profileColumns, '
        '       loc.location_timezone, '
        '       $_periodJson '
        'from public.business_timing_profiles p '
        'join candidate_scopes scope '
        '  on scope.scope_type = p.scope_type '
        ' and scope.scope_id = p.scope_id '
        'cross join selected_location loc '
        'left join public.business_timing_service_periods sp '
        '  on sp.operator_id = p.operator_id '
        ' and sp.profile_id = p.profile_id '
        'where p.operator_id = @operator_id::uuid '
        '  and p.effective_from_business_date <= @business_date::date '
        '  and ('
        '    p.effective_until_business_date is null '
        '    or @business_date::date < p.effective_until_business_date'
        '  ) '
        'group by '
        '  p.profile_id, p.operator_id, p.scope_type, p.scope_id, '
        '  p.display_name, p.business_day_start_local_time, '
        '  p.week_start_day, p.close_authority, '
        '  p.local_close_fallback_time, '
        '  p.effective_from_business_date, '
        '  p.effective_until_business_date, '
        '  p.supersedes_profile_id, p.created_by, p.updated_by, '
        '  p.created_at, p.updated_at, loc.location_timezone, '
        '  scope.scope_depth '
        'order by scope.scope_depth asc, '
        '         p.effective_from_business_date asc, '
        '         p.created_at asc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'business_date': businessDate,
        },
      );
      return <BusinessTimingProfileRow>[
        for (final row in rows) _profileRowFromMap(row),
      ];
    });
  }

  /// Creates one effective-dated profile plus its optional service-period
  /// override set, then appends a timing audit event in the same transaction.
  Future<BusinessTimingProfileRow> createProfile({
    required String operatorId,
    required String locationId,
    required String scopeType,
    required String scopeId,
    required String businessDayStartLocalTime,
    required int weekStartDay,
    required String closeAuthority,
    required String effectiveFromBusinessDate,
    String? displayName,
    String? localCloseFallbackTime,
    String? effectiveUntilBusinessDate,
    String? supersedesProfileId,
    String? actorUserId,
    String actorKind = 'operator_user',
    required String reason,
    String? idempotencyKey,
    Map<String, Object?> metadata = const <String, Object?>{},
    List<BusinessTimingServicePeriodWrite> servicePeriods =
        const <BusinessTimingServicePeriodWrite>[],
  }) {
    _validateAuditReason(reason);
    _validateServicePeriodWriteCount(servicePeriods);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<BusinessTimingProfileRow>(ctx, (exec) {
      return _createProfileWithExecutor(
        exec,
        operatorId: operatorId,
        scopeType: scopeType,
        scopeId: scopeId,
        businessDayStartLocalTime: businessDayStartLocalTime,
        weekStartDay: weekStartDay,
        closeAuthority: closeAuthority,
        effectiveFromBusinessDate: effectiveFromBusinessDate,
        displayName: displayName,
        localCloseFallbackTime: localCloseFallbackTime,
        effectiveUntilBusinessDate: effectiveUntilBusinessDate,
        supersedesProfileId: supersedesProfileId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        reason: reason,
        idempotencyKey: idempotencyKey,
        metadata: metadata,
        servicePeriods: servicePeriods,
      );
    });
  }

  /// Admin/support path for cross-tenant mutations. The caller must supply a
  /// non-blank [adminReason]; the wrapper marks the transaction as system-scope
  /// and uses forge_admin BYPASSRLS.
  Future<BusinessTimingProfileRow> createProfileAsSystem({
    required String operatorId,
    required String scopeType,
    required String scopeId,
    required String businessDayStartLocalTime,
    required int weekStartDay,
    required String closeAuthority,
    required String effectiveFromBusinessDate,
    required String adminReason,
    String? displayName,
    String? localCloseFallbackTime,
    String? effectiveUntilBusinessDate,
    String? supersedesProfileId,
    String? actorUserId,
    String actorKind = 'forge_admin',
    String? idempotencyKey,
    Map<String, Object?> metadata = const <String, Object?>{},
    List<BusinessTimingServicePeriodWrite> servicePeriods =
        const <BusinessTimingServicePeriodWrite>[],
  }) {
    _validateAuditReason(adminReason);
    _validateServicePeriodWriteCount(servicePeriods);
    return withSystem<BusinessTimingProfileRow>((exec) {
      return _createProfileWithExecutor(
        exec,
        operatorId: operatorId,
        scopeType: scopeType,
        scopeId: scopeId,
        businessDayStartLocalTime: businessDayStartLocalTime,
        weekStartDay: weekStartDay,
        closeAuthority: closeAuthority,
        effectiveFromBusinessDate: effectiveFromBusinessDate,
        displayName: displayName,
        localCloseFallbackTime: localCloseFallbackTime,
        effectiveUntilBusinessDate: effectiveUntilBusinessDate,
        supersedesProfileId: supersedesProfileId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        reason: adminReason,
        idempotencyKey: idempotencyKey,
        metadata: metadata,
        servicePeriods: servicePeriods,
      );
    }, reason: adminReason);
  }

  /// Replaces the whole service-period override set for an existing profile.
  /// An empty list clears the override so resolver inheritance can fall through
  /// to the next higher profile.
  Future<BusinessTimingProfileRow?> replaceServicePeriods({
    required String operatorId,
    required String locationId,
    required String profileId,
    required List<BusinessTimingServicePeriodWrite> servicePeriods,
    required String actorUserId,
    String actorKind = 'operator_user',
    required String reason,
    String? idempotencyKey,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    _validateAuditReason(reason);
    _validateServicePeriodWriteCount(servicePeriods);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<BusinessTimingProfileRow?>(ctx, (exec) async {
      final before = await _fetchProfileById(
        exec,
        operatorId: operatorId,
        profileId: profileId,
      );
      if (before == null) return null;
      await _replaceServicePeriodsWithExecutor(
        exec,
        operatorId: operatorId,
        profileId: profileId,
        servicePeriods: servicePeriods,
      );
      final after = await _fetchProfileById(
        exec,
        operatorId: operatorId,
        profileId: profileId,
      );
      if (after == null) {
        throw StateError('business timing profile vanished during update');
      }
      await _insertAuditEvent(
        exec,
        operatorId: operatorId,
        profileId: profileId,
        scopeType: after.scopeType,
        scopeId: after.scopeId,
        eventType: 'service_periods_replaced',
        actorKind: actorKind,
        actorUserId: actorUserId,
        reason: reason,
        idempotencyKey: idempotencyKey,
        beforeSnapshot: before.toJson(),
        afterSnapshot: after.toJson(),
        metadata: metadata,
      );
      return after;
    });
  }

  Future<BusinessTimingProfileRow> _createProfileWithExecutor(
    PostgresExecutor exec, {
    required String operatorId,
    required String scopeType,
    required String scopeId,
    required String businessDayStartLocalTime,
    required int weekStartDay,
    required String closeAuthority,
    required String effectiveFromBusinessDate,
    required String? displayName,
    required String? localCloseFallbackTime,
    required String? effectiveUntilBusinessDate,
    required String? supersedesProfileId,
    required String? actorUserId,
    required String actorKind,
    required String reason,
    required String? idempotencyKey,
    required Map<String, Object?> metadata,
    required List<BusinessTimingServicePeriodWrite> servicePeriods,
  }) async {
    final rows = await exec.query(
      'insert into public.business_timing_profiles ('
      '  operator_id, scope_type, scope_id, display_name, '
      '  business_day_start_local_time, week_start_day, '
      '  close_authority, local_close_fallback_time, '
      '  effective_from_business_date, effective_until_business_date, '
      '  supersedes_profile_id, created_by, updated_by'
      ') values ('
      '  @operator_id::uuid, @scope_type, @scope_id::uuid, @display_name, '
      '  @business_day_start_local_time::time, @week_start_day, '
      '  @close_authority, @local_close_fallback_time::time, '
      '  @effective_from_business_date::date, '
      '  @effective_until_business_date::date, '
      '  @supersedes_profile_id::uuid, @actor_user_id::uuid, '
      '  @actor_user_id::uuid'
      ') returning profile_id::text as profile_id',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'scope_type': scopeType,
        'scope_id': scopeId,
        'display_name': displayName,
        'business_day_start_local_time': businessDayStartLocalTime,
        'week_start_day': weekStartDay,
        'close_authority': closeAuthority,
        'local_close_fallback_time': localCloseFallbackTime,
        'effective_from_business_date': effectiveFromBusinessDate,
        'effective_until_business_date': effectiveUntilBusinessDate,
        'supersedes_profile_id': supersedesProfileId,
        'actor_user_id': actorUserId,
      },
    );
    if (rows.isEmpty) {
      throw StateError('business_timing_profiles insert returned no rows');
    }
    final profileId = rows.single['profile_id'];
    if (profileId is! String || profileId.isEmpty) {
      throw StateError('business_timing_profiles returned malformed id');
    }

    await _replaceServicePeriodsWithExecutor(
      exec,
      operatorId: operatorId,
      profileId: profileId,
      servicePeriods: servicePeriods,
    );
    final profile = await _fetchProfileById(
      exec,
      operatorId: operatorId,
      profileId: profileId,
    );
    if (profile == null) {
      throw StateError('business_timing_profiles inserted row was not found');
    }
    await _insertAuditEvent(
      exec,
      operatorId: operatorId,
      profileId: profileId,
      scopeType: scopeType,
      scopeId: scopeId,
      eventType: 'profile_created',
      actorKind: actorKind,
      actorUserId: actorUserId,
      reason: reason,
      idempotencyKey: idempotencyKey,
      afterSnapshot: profile.toJson(),
      metadata: metadata,
    );
    return profile;
  }

  Future<void> _replaceServicePeriodsWithExecutor(
    PostgresExecutor exec, {
    required String operatorId,
    required String profileId,
    required List<BusinessTimingServicePeriodWrite> servicePeriods,
  }) async {
    await exec.execute(
      'delete from public.business_timing_service_periods '
      'where operator_id = @operator_id::uuid '
      'and profile_id = @profile_id::uuid',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'profile_id': profileId,
      },
    );
    for (final period in servicePeriods) {
      await exec.query(
        'insert into public.business_timing_service_periods ('
        '  operator_id, profile_id, service_period_key, label, '
        '  short_label, sort_order, start_local_time, end_local_time, '
        '  rolls_past_midnight, applicable_weekdays'
        ') values ('
        '  @operator_id::uuid, @profile_id::uuid, @service_period_key, '
        '  @label, @short_label, @sort_order, @start_local_time::time, '
        '  @end_local_time::time, @rolls_past_midnight, '
        '  @applicable_weekdays::integer[]'
        ') returning service_period_id::text as service_period_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'profile_id': profileId,
          ...period.toSqlParameters(),
        },
      );
    }
  }

  Future<BusinessTimingProfileRow?> _fetchProfileById(
    PostgresExecutor exec, {
    required String operatorId,
    required String profileId,
  }) async {
    final rows = await exec.query(
      'select $_profileColumns, '
      '       null::text as location_timezone, '
      '       $_periodJson '
      'from public.business_timing_profiles p '
      'left join public.business_timing_service_periods sp '
      '  on sp.operator_id = p.operator_id '
      ' and sp.profile_id = p.profile_id '
      'where p.operator_id = @operator_id::uuid '
      'and p.profile_id = @profile_id::uuid '
      'group by '
      '  p.profile_id, p.operator_id, p.scope_type, p.scope_id, '
      '  p.display_name, p.business_day_start_local_time, '
      '  p.week_start_day, p.close_authority, '
      '  p.local_close_fallback_time, '
      '  p.effective_from_business_date, '
      '  p.effective_until_business_date, '
      '  p.supersedes_profile_id, p.created_by, p.updated_by, '
      '  p.created_at, p.updated_at',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'profile_id': profileId,
      },
    );
    if (rows.isEmpty) return null;
    return _profileRowFromMap(rows.single);
  }

  Future<void> _insertAuditEvent(
    PostgresExecutor exec, {
    required String operatorId,
    required String? profileId,
    required String scopeType,
    required String scopeId,
    required String eventType,
    required String actorKind,
    required String? actorUserId,
    required String reason,
    required String? idempotencyKey,
    Map<String, Object?>? beforeSnapshot,
    Map<String, Object?>? afterSnapshot,
    required Map<String, Object?> metadata,
  }) async {
    await exec.query(
      'insert into public.business_timing_audit_events ('
      '  operator_id, profile_id, scope_type, scope_id, event_type, '
      '  actor_kind, actor_user_id, reason, idempotency_key, '
      '  before_snapshot, after_snapshot, metadata'
      ') values ('
      '  @operator_id::uuid, @profile_id::uuid, @scope_type, '
      '  @scope_id::uuid, @event_type, @actor_kind, @actor_user_id::uuid, '
      '  @reason, @idempotency_key, @before_snapshot::jsonb, '
      '  @after_snapshot::jsonb, @metadata::jsonb'
      ') returning audit_event_id::text as audit_event_id',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'profile_id': profileId,
        'scope_type': scopeType,
        'scope_id': scopeId,
        'event_type': eventType,
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

class BusinessTimingServicePeriodWrite {
  const BusinessTimingServicePeriodWrite({
    required this.servicePeriodKey,
    required this.label,
    required this.shortLabel,
    required this.sortOrder,
    required this.startLocalTime,
    required this.endLocalTime,
    required this.rollsPastMidnight,
    required this.applicableWeekdays,
  });

  final String servicePeriodKey;
  final String label;
  final String shortLabel;
  final int sortOrder;
  final String startLocalTime;
  final String endLocalTime;
  final bool rollsPastMidnight;
  final List<int> applicableWeekdays;

  PostgresParameters toSqlParameters() => <String, Object?>{
    'service_period_key': servicePeriodKey,
    'label': label,
    'short_label': shortLabel,
    'sort_order': sortOrder,
    'start_local_time': startLocalTime,
    'end_local_time': endLocalTime,
    'rolls_past_midnight': rollsPastMidnight,
    'applicable_weekdays': applicableWeekdays,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'service_period_key': servicePeriodKey,
    'label': label,
    'short_label': shortLabel,
    'sort_order': sortOrder,
    'start_local_time': startLocalTime,
    'end_local_time': endLocalTime,
    'rolls_past_midnight': rollsPastMidnight,
    'applicable_weekdays': applicableWeekdays,
  };
}

class BusinessTimingProfileRow {
  const BusinessTimingProfileRow({
    required this.profileId,
    required this.operatorId,
    required this.scopeType,
    required this.scopeId,
    required this.displayName,
    required this.businessDayStartLocalTime,
    required this.weekStartDay,
    required this.closeAuthority,
    required this.localCloseFallbackTime,
    required this.effectiveFromBusinessDate,
    required this.effectiveUntilBusinessDate,
    required this.supersedesProfileId,
    required this.createdBy,
    required this.updatedBy,
    required this.createdAt,
    required this.updatedAt,
    required this.locationTimezone,
    required this.servicePeriods,
  });

  final String profileId;
  final String operatorId;
  final String scopeType;
  final String scopeId;
  final String? displayName;
  final String businessDayStartLocalTime;
  final int weekStartDay;
  final String closeAuthority;
  final String? localCloseFallbackTime;
  final String effectiveFromBusinessDate;
  final String? effectiveUntilBusinessDate;
  final String? supersedesProfileId;
  final String? createdBy;
  final String? updatedBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Copied from `locations.timezone` when loaded through
  /// listCandidateProfilesForLocation. Null when fetched by profile id.
  final String? locationTimezone;
  final List<BusinessTimingServicePeriodRow> servicePeriods;

  Map<String, Object?> toJson() => <String, Object?>{
    'profile_id': profileId,
    'operator_id': operatorId,
    'scope_type': scopeType,
    'scope_id': scopeId,
    'display_name': displayName,
    'business_day_start_local_time': businessDayStartLocalTime,
    'week_start_day': weekStartDay,
    'close_authority': closeAuthority,
    'local_close_fallback_time': localCloseFallbackTime,
    'effective_from_business_date': effectiveFromBusinessDate,
    'effective_until_business_date': effectiveUntilBusinessDate,
    'supersedes_profile_id': supersedesProfileId,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'location_timezone': locationTimezone,
    'service_periods': <Map<String, Object?>>[
      for (final period in servicePeriods) period.toJson(),
    ],
  };
}

class BusinessTimingServicePeriodRow {
  const BusinessTimingServicePeriodRow({
    required this.servicePeriodId,
    required this.operatorId,
    required this.profileId,
    required this.servicePeriodKey,
    required this.label,
    required this.shortLabel,
    required this.sortOrder,
    required this.startLocalTime,
    required this.endLocalTime,
    required this.rollsPastMidnight,
    required this.applicableWeekdays,
  });

  final String servicePeriodId;
  final String operatorId;
  final String profileId;
  final String servicePeriodKey;
  final String label;
  final String shortLabel;
  final int sortOrder;
  final String startLocalTime;
  final String endLocalTime;
  final bool rollsPastMidnight;
  final List<int> applicableWeekdays;

  Map<String, Object?> toJson() => <String, Object?>{
    'service_period_id': servicePeriodId,
    'operator_id': operatorId,
    'profile_id': profileId,
    'service_period_key': servicePeriodKey,
    'label': label,
    'short_label': shortLabel,
    'sort_order': sortOrder,
    'start_local_time': startLocalTime,
    'end_local_time': endLocalTime,
    'rolls_past_midnight': rollsPastMidnight,
    'applicable_weekdays': applicableWeekdays,
  };
}

BusinessTimingProfileRow _profileRowFromMap(PostgresRow row) {
  return BusinessTimingProfileRow(
    profileId: row['profile_id']! as String,
    operatorId: row['operator_id']! as String,
    scopeType: row['scope_type']! as String,
    scopeId: row['scope_id']! as String,
    displayName: row['display_name'] as String?,
    businessDayStartLocalTime: _trimTime(row['business_day_start_local_time']),
    weekStartDay: row['week_start_day']! as int,
    closeAuthority: row['close_authority']! as String,
    localCloseFallbackTime: _trimNullableTime(row['local_close_fallback_time']),
    effectiveFromBusinessDate: _dateString(
      row['effective_from_business_date'],
    )!,
    effectiveUntilBusinessDate: _dateString(
      row['effective_until_business_date'],
    ),
    supersedesProfileId: row['supersedes_profile_id'] as String?,
    createdBy: row['created_by'] as String?,
    updatedBy: row['updated_by'] as String?,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
    locationTimezone: row['location_timezone'] as String?,
    servicePeriods: _servicePeriodsFromValue(row['service_periods']),
  );
}

List<BusinessTimingServicePeriodRow> _servicePeriodsFromValue(Object? value) {
  if (value == null) return const <BusinessTimingServicePeriodRow>[];
  final dynamic decoded = value is String ? jsonDecode(value) : value;
  if (decoded is! List<dynamic>) {
    throw StateError('service_periods JSON was not a list');
  }
  return <BusinessTimingServicePeriodRow>[
    for (final item in decoded)
      _servicePeriodRowFromJson(_jsonObjectFromValue(item)),
  ];
}

BusinessTimingServicePeriodRow _servicePeriodRowFromJson(
  Map<String, Object?> json,
) {
  return BusinessTimingServicePeriodRow(
    servicePeriodId: json['service_period_id']! as String,
    operatorId: json['operator_id']! as String,
    profileId: json['profile_id']! as String,
    servicePeriodKey: json['service_period_key']! as String,
    label: json['label']! as String,
    shortLabel: json['short_label'] as String? ?? '',
    sortOrder: json['sort_order']! as int,
    startLocalTime: _trimTime(json['start_local_time']),
    endLocalTime: _trimTime(json['end_local_time']),
    rollsPastMidnight: json['rolls_past_midnight'] as bool? ?? false,
    applicableWeekdays: _intListFromValue(json['applicable_weekdays']),
  );
}

Map<String, Object?> _jsonObjectFromValue(Object? value) {
  final dynamic decoded = value is String ? jsonDecode(value) : value;
  if (decoded is! Map<dynamic, dynamic>) {
    throw StateError('JSON value was not an object');
  }
  return <String, Object?>{
    for (final entry in decoded.entries) entry.key.toString(): entry.value,
  };
}

List<int> _intListFromValue(Object? value) {
  if (value is List<int>) return value;
  if (value is List<dynamic>) {
    return <int>[for (final item in value) (item as num).toInt()];
  }
  throw StateError('integer array value was not a list');
}

String _trimTime(Object? value) {
  final text = value as String;
  return text.length >= 5 ? text.substring(0, 5) : text;
}

String? _trimNullableTime(Object? value) {
  if (value == null) return null;
  final text = value as String;
  return text.length >= 5 ? text.substring(0, 5) : text;
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

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}

void _validateAuditReason(String reason) {
  if (reason.trim().isEmpty) {
    throw ArgumentError.value(reason, 'reason', 'must be non-blank');
  }
}

void _validateServicePeriodWriteCount(
  List<BusinessTimingServicePeriodWrite> periods,
) {
  if (periods.length > 4) {
    throw ArgumentError.value(
      periods.length,
      'servicePeriods',
      'business timing profiles support at most four service periods',
    );
  }
}
