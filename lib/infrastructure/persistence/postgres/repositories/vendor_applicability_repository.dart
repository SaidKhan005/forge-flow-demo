// B10.1 - VendorApplicabilityRepository.
//
// Persistence for public.vendor_applicability. Writes are temporal:
// upsert closes the current row (effective_until = timestamp) and inserts a
// fresh row in one transaction; end only closes the current row. Admin calls
// use withSystem because global F&F admins operate across tenants. Operator
// reads use withTenant and see global defaults plus their operator overrides.

import 'dart:convert';

import 'package:forge_and_flow/services/settings/applicability_metadata_schemas.dart';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class VendorApplicabilityRepository extends OperatorScopedRepository {
  VendorApplicabilityRepository(super.tenantWrapper);

  Future<List<VendorApplicabilityRow>> listAdmin({
    String? operatorId,
    String? locationId,
    String? settingKind,
    String? settingKey,
    String? vendorSlug,
    bool currentOnly = true,
    required String adminReason,
  }) {
    final normalizedOperatorId = _normalizeOptionalUuid(
      operatorId,
      'operator_id',
    );
    final normalizedLocationId = _normalizeOptionalUuid(
      locationId,
      'location_id',
    );
    final normalizedKind = _normalizeOptionalSlug(settingKind, 'setting_kind');
    final normalizedKey = _normalizeOptionalSettingKey(settingKey);
    final normalizedVendor = _normalizeOptionalSlug(vendorSlug, 'vendor_slug');
    return withSystem<List<VendorApplicabilityRow>>((exec) async {
      final params = <String, Object?>{
        'operator_id': normalizedOperatorId,
        'location_id': normalizedLocationId,
        'setting_kind': normalizedKind,
        'setting_key': normalizedKey,
        'vendor_slug': normalizedVendor,
      };
      var sql =
          'select $_selectList '
          'from public.vendor_applicability '
          'where true ';
      if (currentOnly) {
        sql += 'and effective_until is null ';
      }
      if (operatorId != null) {
        sql += 'and operator_id is not distinct from @operator_id::uuid ';
      }
      if (locationId != null) {
        sql += 'and location_id is not distinct from @location_id::uuid ';
      }
      if (normalizedKind != null) {
        sql += 'and setting_kind = @setting_kind ';
      }
      if (normalizedKey != null) {
        sql += 'and setting_key = @setting_key ';
      }
      if (normalizedVendor != null) {
        sql += 'and vendor_slug = @vendor_slug ';
      }
      sql +=
          'order by operator_id nulls first, location_id nulls first, '
          'setting_kind, setting_key, vendor_slug, effective_from desc';
      final rows = await exec.query(sql, parameters: params);
      return rows.map(VendorApplicabilityRow.fromRow).toList(growable: false);
    }, reason: adminReason);
  }

  Future<List<VendorApplicabilityRow>> listCurrentForOperator({
    required String operatorId,
    required String locationId,
    required String settingKind,
    String? settingKey,
    bool enabledOnly = false,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    final normalizedKind = _normalizeRequiredSlug(settingKind, 'setting_kind');
    final normalizedKey = _normalizeOptionalSettingKey(settingKey);
    return withTenant<List<VendorApplicabilityRow>>(ctx, (exec) async {
      final params = <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'setting_kind': normalizedKind,
        'setting_key': normalizedKey,
      };
      // `visible` admits global (operator_id null), operator-level
      // (operator_id match, location_id null), and location-specific
      // (operator_id match, location_id match) current rows. A row scoped
      // to a different location is excluded outright.
      var filter =
          '(operator_id is null or operator_id = @operator_id::uuid) '
          'and (location_id is null or location_id = @location_id::uuid) '
          'and setting_kind = @setting_kind '
          'and effective_until is null ';
      if (normalizedKey != null) {
        filter += 'and setting_key = @setting_key ';
      }
      // The enabled filter is applied to the WINNER (after precedence
      // ranking), never inside `visible`. Ranking picks the most
      // specific current row per (setting_kind, setting_key,
      // vendor_slug): location-specific beats operator-level beats
      // global, then latest effective_from. Filtering enabled before
      // ranking would let a less-specific enabled row win when a
      // more-specific row had enabled=false, silently ignoring the
      // more-specific block. Applying it to `rn = 1` means a
      // more-specific disabled row suppresses a less-specific enabled
      // vendor, while a more-specific enabled row still overrides a
      // less-specific disabled one. (PR #1247 winner-side filter,
      // extended here to the location level.)
      final winnerFilter = enabledOnly
          ? 'where rn = 1 and enabled = true '
          : 'where rn = 1 ';
      final rows = await exec.query(
        'with visible as ('
        'select $_selectList '
        'from public.vendor_applicability '
        'where $filter'
        '), ranked as ('
        'select visible.*, '
        'row_number() over ('
        'partition by setting_kind, setting_key, vendor_slug '
        'order by case '
        'when location_id = @location_id::uuid then 0 '
        'when operator_id = @operator_id::uuid then 1 '
        'else 2 end, '
        'effective_from desc'
        ') as rn '
        'from visible'
        ') '
        'select $_selectList '
        'from ranked '
        '$winnerFilter'
        'order by setting_key, vendor_slug',
        parameters: params,
      );
      return rows.map(VendorApplicabilityRow.fromRow).toList(growable: false);
    });
  }

  Future<VendorApplicabilityRow> upsert({
    String? operatorId,
    String? locationId,
    required String settingKind,
    required String settingKey,
    required String vendorSlug,
    required bool enabled,
    Map<String, Object?> metadata = const <String, Object?>{},
    DateTime? effectiveFrom,
    required String createdBy,
    required String adminReason,
    Future<void> Function(PostgresExecutor exec, VendorApplicabilityRow row)?
    onCommit,
  }) {
    final normalizedOperatorId = _normalizeOptionalUuid(
      operatorId,
      'operator_id',
    );
    final normalizedLocationId = _normalizeOptionalUuid(
      locationId,
      'location_id',
    );
    final normalizedKind = _normalizeRequiredSlug(settingKind, 'setting_kind');
    final normalizedKey = _normalizeRequiredSettingKey(settingKey);
    final normalizedVendor = _normalizeRequiredSlug(vendorSlug, 'vendor_slug');
    final normalizedCreatedBy = _normalizeRequiredUuid(createdBy, 'created_by');
    assertApplicabilityMetadataValid(
      settingKind: normalizedKind,
      metadata: metadata,
    );
    final normalizedEffectiveFrom = effectiveFrom?.toUtc();
    return withSystem<VendorApplicabilityRow>((exec) async {
      await _closeCurrent(
        exec,
        operatorId: normalizedOperatorId,
        locationId: normalizedLocationId,
        settingKind: normalizedKind,
        settingKey: normalizedKey,
        vendorSlug: normalizedVendor,
        effectiveUntil: normalizedEffectiveFrom,
      );
      final rows = await exec.query(
        'insert into public.vendor_applicability ('
        'operator_id, location_id, setting_kind, setting_key, vendor_slug, '
        'enabled, metadata, effective_from, created_by'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @setting_kind, @setting_key, '
        '@vendor_slug, @enabled, @metadata::jsonb, '
        'coalesce(@effective_from::timestamptz, now()), '
        '@created_by::uuid'
        ') returning $_selectList',
        parameters: <String, Object?>{
          'operator_id': normalizedOperatorId,
          'location_id': normalizedLocationId,
          'setting_kind': normalizedKind,
          'setting_key': normalizedKey,
          'vendor_slug': normalizedVendor,
          'enabled': enabled,
          'metadata': jsonEncode(metadata),
          'effective_from': normalizedEffectiveFrom,
          'created_by': normalizedCreatedBy,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'vendor_applicability INSERT returned no row; write was rejected',
        );
      }
      final row = VendorApplicabilityRow.fromRow(rows.single);
      await onCommit?.call(exec, row);
      return row;
    }, reason: adminReason);
  }

  Future<VendorApplicabilityRow?> end({
    String? operatorId,
    String? locationId,
    required String settingKind,
    required String settingKey,
    required String vendorSlug,
    DateTime? effectiveUntil,
    required String adminReason,
    Future<void> Function(PostgresExecutor exec, VendorApplicabilityRow row)?
    onCommit,
  }) {
    final normalizedOperatorId = _normalizeOptionalUuid(
      operatorId,
      'operator_id',
    );
    final normalizedLocationId = _normalizeOptionalUuid(
      locationId,
      'location_id',
    );
    final normalizedKind = _normalizeRequiredSlug(settingKind, 'setting_kind');
    final normalizedKey = _normalizeRequiredSettingKey(settingKey);
    final normalizedVendor = _normalizeRequiredSlug(vendorSlug, 'vendor_slug');
    return withSystem<VendorApplicabilityRow?>((exec) async {
      final rows = await _closeCurrent(
        exec,
        operatorId: normalizedOperatorId,
        locationId: normalizedLocationId,
        settingKind: normalizedKind,
        settingKey: normalizedKey,
        vendorSlug: normalizedVendor,
        effectiveUntil: effectiveUntil?.toUtc(),
        returning: true,
      );
      if (rows.isEmpty) return null;
      final row = VendorApplicabilityRow.fromRow(rows.single);
      await onCommit?.call(exec, row);
      return row;
    }, reason: adminReason);
  }

  Future<List<PostgresRow>> _closeCurrent(
    PostgresExecutor exec, {
    required String? operatorId,
    required String? locationId,
    required String settingKind,
    required String settingKey,
    required String vendorSlug,
    DateTime? effectiveUntil,
    bool returning = false,
  }) {
    // `is not distinct from` matches NULL operator_id / location_id to
    // NULL, so a temporal close targets exactly the same scope it is
    // replacing: a location-specific close never closes the operator-level
    // row, and vice versa.
    final sql =
        'update public.vendor_applicability '
        'set effective_until = coalesce(@effective_until::timestamptz, now()) '
        'where operator_id is not distinct from @operator_id::uuid '
        'and location_id is not distinct from @location_id::uuid '
        'and setting_kind = @setting_kind '
        'and setting_key = @setting_key '
        'and vendor_slug = @vendor_slug '
        'and effective_until is null '
        '${returning ? 'returning $_selectList' : ''}';
    final params = <String, Object?>{
      'operator_id': operatorId,
      'location_id': locationId,
      'setting_kind': settingKind,
      'setting_key': settingKey,
      'vendor_slug': vendorSlug,
      'effective_until': effectiveUntil,
    };
    if (returning) {
      return exec.query(sql, parameters: params);
    }
    return exec
        .execute(sql, parameters: params)
        .then((_) => const <PostgresRow>[]);
  }

  static const String _selectList =
      'id::text as id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'setting_kind, setting_key, vendor_slug, enabled, metadata, '
      'effective_from, effective_until, created_at, created_by::text as created_by';

  static String? _normalizeOptionalUuid(String? value, String field) {
    if (value == null) return null;
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    return _normalizeRequiredUuid(trimmed, field);
  }

  static String _normalizeRequiredUuid(String value, String field) {
    final trimmed = value.trim().toLowerCase();
    if (!_uuidPattern.hasMatch(trimmed)) {
      throw VendorApplicabilityRepositoryInputError(
        field: field,
        message: '$field must be a lowercase UUID',
      );
    }
    return trimmed;
  }

  static String? _normalizeOptionalSlug(String? value, String field) {
    if (value == null) return null;
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    return _normalizeRequiredSlug(trimmed, field);
  }

  static String _normalizeRequiredSlug(String value, String field) {
    final trimmed = value.trim().toLowerCase();
    if (!_slugPattern.hasMatch(trimmed) || trimmed.length > 64) {
      throw VendorApplicabilityRepositoryInputError(
        field: field,
        message: '$field must be a lowercase slug no longer than 64 characters',
      );
    }
    return trimmed;
  }

  static String? _normalizeOptionalSettingKey(String? value) {
    if (value == null) return null;
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    return _normalizeRequiredSettingKey(trimmed);
  }

  static String _normalizeRequiredSettingKey(String value) {
    final trimmed = value.trim().toLowerCase();
    if (!_settingKeyPattern.hasMatch(trimmed) || trimmed.length > 128) {
      throw VendorApplicabilityRepositoryInputError(
        field: 'setting_key',
        message:
            'setting_key must be a lowercase key no longer than 128 characters',
      );
    }
    return trimmed;
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static final RegExp _slugPattern = RegExp(r'^[a-z][a-z0-9_]*$');
  static final RegExp _settingKeyPattern = RegExp(r'^[a-z][a-z0-9_:.+-]*$');
}

class VendorApplicabilityRow {
  const VendorApplicabilityRow({
    required this.id,
    required this.operatorId,
    required this.locationId,
    required this.settingKind,
    required this.settingKey,
    required this.vendorSlug,
    required this.enabled,
    required this.metadata,
    required this.effectiveFrom,
    required this.effectiveUntil,
    required this.createdAt,
    required this.createdBy,
  });

  final String id;
  final String? operatorId;

  /// Optional location narrowing. NULL = operator-level (when
  /// [operatorId] is set) or global (when [operatorId] is null), matching
  /// pre-location behavior. A non-null value scopes the row to one
  /// location within the operator tenant.
  final String? locationId;
  final String settingKind;
  final String settingKey;
  final String vendorSlug;
  final bool enabled;
  final Map<String, Object?> metadata;
  final DateTime effectiveFrom;
  final DateTime? effectiveUntil;
  final DateTime createdAt;
  final String createdBy;

  bool get isCurrent => effectiveUntil == null;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    'location_id': locationId,
    'setting_kind': settingKind,
    'setting_key': settingKey,
    'vendor_slug': vendorSlug,
    'enabled': enabled,
    'metadata': metadata,
    'effective_from': effectiveFrom.toUtc().toIso8601String(),
    'effective_until': effectiveUntil?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'created_by': createdBy,
  };

  static VendorApplicabilityRow fromRow(PostgresRow row) {
    return VendorApplicabilityRow(
      id: _requiredString(row, 'id'),
      operatorId: _optionalString(row, 'operator_id'),
      locationId: _optionalString(row, 'location_id'),
      settingKind: _requiredString(row, 'setting_kind'),
      settingKey: _requiredString(row, 'setting_key'),
      vendorSlug: _requiredString(row, 'vendor_slug'),
      enabled: _requiredBool(row, 'enabled'),
      metadata: _metadata(row['metadata']),
      effectiveFrom: _requiredDate(row, 'effective_from'),
      effectiveUntil: _optionalDate(row, 'effective_until'),
      createdAt: _requiredDate(row, 'created_at'),
      createdBy: _requiredString(row, 'created_by'),
    );
  }

  static String _requiredString(PostgresRow row, String key) {
    final value = row[key];
    if (value is String && value.isNotEmpty) return value;
    throw StateError('vendor_applicability row missing $key');
  }

  static String? _optionalString(PostgresRow row, String key) {
    final value = row[key];
    if (value == null) return null;
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  static bool _requiredBool(PostgresRow row, String key) {
    final value = row[key];
    if (value is bool) return value;
    throw StateError('vendor_applicability row missing bool $key');
  }

  static DateTime _requiredDate(PostgresRow row, String key) {
    final parsed = _optionalDate(row, key);
    if (parsed != null) return parsed;
    throw StateError('vendor_applicability row missing timestamptz $key');
  }

  static DateTime? _optionalDate(PostgresRow row, String key) {
    final value = row[key];
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    return null;
  }

  static Map<String, Object?> _metadata(Object? value) {
    if (value == null) return const <String, Object?>{};
    if (value is Map) return value.cast<String, Object?>();
    if (value is String && value.isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) return decoded.cast<String, Object?>();
    }
    throw StateError('vendor_applicability metadata must be a JSON object');
  }
}

class VendorApplicabilityRepositoryInputError implements Exception {
  const VendorApplicabilityRepositoryInputError({
    required this.field,
    required this.message,
  });

  final String field;
  final String message;

  @override
  String toString() =>
      'VendorApplicabilityRepositoryInputError($field): $message';
}
