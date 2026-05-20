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
