import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class BenchmarkOverridesRepository extends OperatorScopedRepository {
  BenchmarkOverridesRepository(super.tenantWrapper);

  Future<List<BenchmarkOverrideCandidate>> listCurrent({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    // B6 hierarchy editor reconciliation: locationId is still set in
    // TenantContext for audit/RLS wrapper availability, but the read itself
    // intentionally returns operator-wide, org-unit, and location rows so the
    // owner/admin UI can render effective inheritance for the whole tree.
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<List<BenchmarkOverrideCandidate>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_selectListWithAlias, '
        'coalesce(l.name, ou.name, op.business_name, bo.scope_type) '
        'as source_label '
        'from public.benchmark_overrides bo '
        'join public.operators op on op.operator_id = bo.operator_id '
        'left join public.org_units ou '
        '  on ou.operator_id = bo.operator_id and ou.id = bo.org_unit_id '
        'left join public.locations l '
        '  on l.operator_id = bo.operator_id and l.location_id = bo.location_id '
        'where bo.operator_id = @operator_id::uuid '
        '  and bo.effective_until is null '
        'order by bo.metric_key, bo.scope_type, bo.effective_from desc',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return rows.map(_rowFromMap).toList(growable: false);
    });
  }

  Future<BenchmarkOverrideResolvedValue> resolveForLocation({
    required String operatorId,
    required String locationId,
    required String metricKey,
    required double fallbackValue,
    String? actorUserId,
  }) {
    final normalizedMetric = _normalizeMetric(metricKey);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<BenchmarkOverrideResolvedValue>(ctx, (exec) async {
      final rows = await exec.query(
        'with loc as ('
        '  select location_id, parent_org_unit_id, org_unit_path '
        '  from public.locations '
        '  where operator_id = @operator_id::uuid '
        '    and location_id = @location_id::uuid'
        '), ranked as ('
        '  select bo.*, l.name as source_label, 1 as precedence, 0 as depth '
        '  from public.benchmark_overrides bo '
        '  join public.locations l '
        '    on l.operator_id = bo.operator_id '
        '   and l.location_id = bo.location_id '
        '  join loc on loc.location_id = bo.location_id '
        "  where bo.scope_type = 'location' "
        '    and bo.metric_key = @metric_key '
        '    and bo.operator_id = @operator_id::uuid '
        '    and bo.effective_until is null '
        '  union all '
        '  select bo.*, ou.name as source_label, 2 as precedence, '
        '         nlevel(ou.path) as depth '
        '  from public.benchmark_overrides bo '
        '  join public.org_units ou '
        '    on ou.operator_id = bo.operator_id and ou.id = bo.org_unit_id '
        '  join loc on loc.org_unit_path <@ ou.path '
        "  where bo.scope_type = 'org_unit' "
        '    and bo.metric_key = @metric_key '
        '    and bo.operator_id = @operator_id::uuid '
        '    and bo.effective_until is null '
        '  union all '
        '  select bo.*, op.business_name as source_label, 3 as precedence, '
        '         0 as depth '
        '  from public.benchmark_overrides bo '
        '  join public.operators op on op.operator_id = bo.operator_id '
        "  where bo.scope_type = 'operator_wide' "
        '    and bo.metric_key = @metric_key '
        '    and bo.operator_id = @operator_id::uuid '
        '    and bo.effective_until is null'
        ') '
        'select $_selectListWithAlias, source_label '
        'from ranked bo '
        'order by precedence asc, depth desc, effective_from desc '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'metric_key': normalizedMetric,
        },
      );
      if (rows.isEmpty) {
        return BenchmarkOverrideResolvedValue(
          metricKey: normalizedMetric,
          value: fallbackValue,
          inherited: false,
          sourceScopeType: BenchmarkOverrideScopeType.fallback,
          sourceScopeId: operatorId,
          sourceLabel: 'Target cycle',
          overrideId: null,
        );
      }
      return BenchmarkOverrideResolvedValue.fromCandidate(
        _rowFromMap(rows.single),
      );
    });
  }

  Future<BenchmarkOverrideCandidate> setOverride({
    required String operatorId,
    required String locationId,
    required BenchmarkOverrideScopeType scopeType,
    required String? orgUnitId,
    required String? targetLocationId,
    required String metricKey,
    required double overrideValue,
    required String createdBy,
    DateTime? effectiveFrom,
    String? actorUserId,
  }) {
    final write = _BenchmarkOverrideWrite(
      operatorId: operatorId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: targetLocationId,
      metricKey: metricKey,
      overrideValue: overrideValue,
      createdBy: createdBy,
      effectiveFrom: effectiveFrom?.toUtc(),
    )..validate();
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<BenchmarkOverrideCandidate>(ctx, (exec) async {
      await _closeCurrent(exec, write, effectiveUntil: write.effectiveFrom);
      final rows = await exec.query(
        'insert into public.benchmark_overrides ('
        'operator_id, scope_type, org_unit_id, location_id, metric_key, '
        'override_value, effective_from, created_by'
        ') values ('
        '@operator_id::uuid, @scope_type, @org_unit_id::uuid, '
        '@location_id::uuid, @metric_key, @override_value, '
        'coalesce(@effective_from::timestamptz, now()), @created_by'
        ') returning $_selectList, null::text as source_label',
        parameters: write.parameters,
      );
      if (rows.isEmpty) {
        throw StateError('benchmark_overrides insert returned no row');
      }
      return _rowFromMap(rows.single);
    });
  }

  Future<BenchmarkOverrideCandidate?> patchOverride({
    required String operatorId,
    required String locationId,
    required String overrideId,
    required double overrideValue,
    required String createdBy,
    String? actorUserId,
  }) {
    _validateUuid(overrideId, 'override_id');
    _validatePositive(overrideValue, 'override_value');
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<BenchmarkOverrideCandidate?>(ctx, (exec) async {
      final existing = await _fetchById(exec, operatorId, overrideId);
      if (existing == null || !existing.isCurrent) return null;
      final replacement = _BenchmarkOverrideWrite(
        operatorId: operatorId,
        scopeType: existing.scopeType,
        orgUnitId: existing.orgUnitId,
        locationId: existing.locationId,
        metricKey: existing.metricKey,
        overrideValue: overrideValue,
        createdBy: createdBy,
      )..validate();
      await exec.execute(
        'update public.benchmark_overrides '
        'set effective_until = now() '
        'where operator_id = @operator_id::uuid '
        'and override_id = @override_id::uuid '
        'and effective_until is null',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'override_id': overrideId,
        },
      );
      final rows = await exec.query(
        'insert into public.benchmark_overrides ('
        'operator_id, scope_type, org_unit_id, location_id, metric_key, '
        'override_value, effective_from, created_by'
        ') values ('
        '@operator_id::uuid, @scope_type, @org_unit_id::uuid, '
        '@location_id::uuid, @metric_key, @override_value, now(), @created_by'
        ') returning $_selectList, null::text as source_label',
        parameters: replacement.parameters,
      );
      if (rows.isEmpty) {
        throw StateError('benchmark_overrides patch insert returned no row');
      }
      return _rowFromMap(rows.single);
    });
  }

  Future<BenchmarkOverrideCandidate?> clearOverride({
    required String operatorId,
    required String locationId,
    required String overrideId,
    String? actorUserId,
  }) {
    _validateUuid(overrideId, 'override_id');
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<BenchmarkOverrideCandidate?>(ctx, (exec) async {
      final rows = await exec.query(
        'update public.benchmark_overrides '
        'set effective_until = now() '
        'where operator_id = @operator_id::uuid '
        'and override_id = @override_id::uuid '
        'and effective_until is null '
        'returning $_selectList, null::text as source_label',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'override_id': overrideId,
        },
      );
      if (rows.isEmpty) return null;
      return _rowFromMap(rows.single);
    });
  }

  Future<BenchmarkOverrideCandidate?> _fetchById(
    PostgresExecutor exec,
    String operatorId,
    String overrideId,
  ) async {
    final rows = await exec.query(
      'select $_selectListWithAlias, null::text as source_label '
      'from public.benchmark_overrides bo '
      'where bo.operator_id = @operator_id::uuid '
      'and bo.override_id = @override_id::uuid',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'override_id': overrideId,
      },
    );
    if (rows.isEmpty) return null;
    return _rowFromMap(rows.single);
  }

  Future<void> _closeCurrent(
    PostgresExecutor exec,
    _BenchmarkOverrideWrite write, {
    DateTime? effectiveUntil,
  }) {
    return exec.execute(
      'update public.benchmark_overrides '
      'set effective_until = coalesce(@effective_until::timestamptz, now()) '
      'where operator_id = @operator_id::uuid '
      'and metric_key = @metric_key '
      'and scope_type = @scope_type '
      'and coalesce(org_unit_id, '
      "'00000000-0000-0000-0000-000000000000'::uuid) = "
      'coalesce(@org_unit_id::uuid, '
      "'00000000-0000-0000-0000-000000000000'::uuid) "
      'and coalesce(location_id, '
      "'00000000-0000-0000-0000-000000000000'::uuid) = "
      'coalesce(@location_id::uuid, '
      "'00000000-0000-0000-0000-000000000000'::uuid) "
      'and effective_until is null',
      parameters: <String, Object?>{
        ...write.parameters,
        'effective_until': effectiveUntil,
      },
    ).then((_) {});
  }

  static const String _selectList =
      'override_id::text as override_id, '
      'operator_id::text as operator_id, '
      'scope_type, '
      'org_unit_id::text as org_unit_id, '
      'location_id::text as location_id, '
      'metric_key, '
      'override_value, '
      'effective_from, '
      'effective_until, '
      'created_by, '
      'created_at, '
      'updated_at';

  static const String _selectListWithAlias =
      'bo.override_id::text as override_id, '
      'bo.operator_id::text as operator_id, '
      'bo.scope_type, '
      'bo.org_unit_id::text as org_unit_id, '
      'bo.location_id::text as location_id, '
      'bo.metric_key, '
      'bo.override_value, '
      'bo.effective_from, '
      'bo.effective_until, '
      'bo.created_by, '
      'bo.created_at, '
      'bo.updated_at';

  static BenchmarkOverrideCandidate _rowFromMap(PostgresRow row) {
    return BenchmarkOverrideCandidate(
      overrideId: _requiredString(row, 'override_id'),
      operatorId: _requiredString(row, 'operator_id'),
      scopeType: BenchmarkOverrideScopeType.parse(
        _requiredString(row, 'scope_type'),
      ),
      orgUnitId: _optionalString(row, 'org_unit_id'),
      locationId: _optionalString(row, 'location_id'),
      metricKey: _requiredString(row, 'metric_key'),
      value: _requiredDouble(row, 'override_value'),
      effectiveFrom: _requiredDate(row, 'effective_from'),
      effectiveUntil: _optionalDate(row, 'effective_until'),
      createdBy: _requiredString(row, 'created_by'),
      sourceLabel: _optionalString(row, 'source_label'),
    );
  }

  static String _normalizeMetric(String raw) {
    final normalized = raw.trim().toLowerCase();
    if (!kBenchmarkOverrideMetricKeys.contains(normalized)) {
      throw BenchmarkOverridesInputError(
        field: 'metric_key',
        message: 'metric_key must be target_cplh, target_splh, or target_ppa',
      );
    }
    return normalized;
  }

  static void _validateUuid(String value, String field) {
    if (!_uuidPattern.hasMatch(value)) {
      throw BenchmarkOverridesInputError(
        field: field,
        message: '$field must be a lowercase UUID',
      );
    }
  }

  static void _validatePositive(double value, String field) {
    if (!value.isFinite || value <= 0) {
      throw BenchmarkOverridesInputError(
        field: field,
        message: '$field must be a positive number',
      );
    }
  }

  static String? _uuidOrNull(String? value) {
    if (value == null) return null;
    return _uuidPattern.hasMatch(value) ? value : null;
  }

  static String _requiredString(PostgresRow row, String key) {
    final value = row[key];
    if (value is String && value.isNotEmpty) return value;
    throw StateError('benchmark_overrides row missing $key');
  }

  static String? _optionalString(PostgresRow row, String key) {
    final value = row[key];
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  static double _requiredDouble(PostgresRow row, String key) {
    final value = row[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.parse(value);
    throw StateError('benchmark_overrides row missing numeric $key');
  }

  static DateTime _requiredDate(PostgresRow row, String key) {
    final value = _optionalDate(row, key);
    if (value != null) return value;
    throw StateError('benchmark_overrides row missing timestamptz $key');
  }

  static DateTime? _optionalDate(PostgresRow row, String key) {
    final value = row[key];
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    return null;
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

const Set<String> kBenchmarkOverrideMetricKeys = <String>{
  'target_cplh',
  'target_splh',
  'target_ppa',
};

class _BenchmarkOverrideWrite {
  _BenchmarkOverrideWrite({
    required this.operatorId,
    required this.scopeType,
    required this.orgUnitId,
    required this.locationId,
    required this.metricKey,
    required this.overrideValue,
    required this.createdBy,
    this.effectiveFrom,
  });

  final String operatorId;
  final BenchmarkOverrideScopeType scopeType;
  final String? orgUnitId;
  final String? locationId;
  final String metricKey;
  final double overrideValue;
  final String createdBy;
  final DateTime? effectiveFrom;

  Map<String, Object?> get parameters => <String, Object?>{
    'operator_id': operatorId,
    'scope_type': scopeType.wire,
    'org_unit_id': orgUnitId,
    'location_id': locationId,
    'metric_key': BenchmarkOverridesRepository._normalizeMetric(metricKey),
    'override_value': overrideValue,
    'created_by': createdBy,
    'effective_from': effectiveFrom,
  };

  void validate() {
    BenchmarkOverridesRepository._validateUuid(operatorId, 'operator_id');
    BenchmarkOverridesRepository._normalizeMetric(metricKey);
    BenchmarkOverridesRepository._validatePositive(
      overrideValue,
      'override_value',
    );
    if (createdBy.trim().isEmpty) {
      throw const BenchmarkOverridesInputError(
        field: 'created_by',
        message: 'created_by is required',
      );
    }
    switch (scopeType) {
      case BenchmarkOverrideScopeType.operatorWide:
        if (orgUnitId != null || locationId != null) {
          throw const BenchmarkOverridesInputError(
            field: 'scope_type',
            message: 'operator_wide scope cannot include org_unit_id or location_id',
          );
        }
      case BenchmarkOverrideScopeType.orgUnit:
        if (orgUnitId == null || locationId != null) {
          throw const BenchmarkOverridesInputError(
            field: 'org_unit_id',
            message: 'org_unit scope requires org_unit_id only',
          );
        }
        BenchmarkOverridesRepository._validateUuid(orgUnitId!, 'org_unit_id');
      case BenchmarkOverrideScopeType.location:
        if (locationId == null || orgUnitId != null) {
          throw const BenchmarkOverridesInputError(
            field: 'location_id',
            message: 'location scope requires location_id only',
          );
        }
        BenchmarkOverridesRepository._validateUuid(locationId!, 'location_id');
      case BenchmarkOverrideScopeType.fallback:
        throw const BenchmarkOverridesInputError(
          field: 'scope_type',
          message: 'fallback is read-only and cannot be written',
        );
    }
  }
}

class BenchmarkOverridesInputError implements Exception {
  const BenchmarkOverridesInputError({
    required this.field,
    required this.message,
  });

  final String field;
  final String message;

  @override
  String toString() => 'BenchmarkOverridesInputError($field): $message';
}
