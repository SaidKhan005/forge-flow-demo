// Phase 8 W5.A.1 — server-shaped WageRoleRowRecord domain model.
//
// Mirrors `public.wage_role_rows` columns. The legacy SQLite-shaped
// `WageRoleRow` (lib/domain/models/wage_role_row.dart) carries an
// integer `id` for the local cache table; this record carries the
// server UUID `wageRoleRowId` plus the server-only fields (effective
// timestamps, source enum, metadata, audit fields) the proxy
// repository writes.
//
// Authority:
//   * db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql
//     (column shape + CHECK constraints).
//   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
//     (operator-scoped fact tables go through OperatorScopedRepository
//     and serialize through this model).
//
// Two complementary types:
//   * [WageRoleRowSource]  — wire enum mirroring the table's
//     `source` CHECK constraint (`operator_manual` / `vendor_per_position`
//     / `admin_seed` / `migration_seed`).
//   * [WageRoleRowRecord] — value class for the row payload returned
//     by `INSERT … ON CONFLICT … RETURNING`.

library;

/// Provenance of a wage row. The mobile editor writes
/// `operatorManual`, the QuickBooks Time / Humanity / Agendrix vendor
/// adapters write `vendorPerPosition`, the F&F admin seed scripts write
/// `adminSeed`, and the legacy SQLite-to-Postgres migration writes
/// `migrationSeed`.
enum WageRoleRowSource {
  operatorManual,
  vendorPerPosition,
  adminSeed,
  migrationSeed,
}

extension WageRoleRowSourceWire on WageRoleRowSource {
  /// Wire encoding matches the SQL CHECK constraint values.
  String get wire {
    switch (this) {
      case WageRoleRowSource.operatorManual:
        return 'operator_manual';
      case WageRoleRowSource.vendorPerPosition:
        return 'vendor_per_position';
      case WageRoleRowSource.adminSeed:
        return 'admin_seed';
      case WageRoleRowSource.migrationSeed:
        return 'migration_seed';
    }
  }

  static WageRoleRowSource fromWire(String value) {
    switch (value) {
      case 'operator_manual':
        return WageRoleRowSource.operatorManual;
      case 'vendor_per_position':
        return WageRoleRowSource.vendorPerPosition;
      case 'admin_seed':
        return WageRoleRowSource.adminSeed;
      case 'migration_seed':
        return WageRoleRowSource.migrationSeed;
      default:
        throw ArgumentError.value(
          value,
          'source',
          'must be one of operator_manual / vendor_per_position / '
              'admin_seed / migration_seed',
        );
    }
  }
}

/// Server-shaped wage role row. Carries the canonical UUID identity
/// plus every column the proxy upsert RETURNs.
class WageRoleRowRecord {
  WageRoleRowRecord({
    required this.wageRoleRowId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.roleName,
    required this.laborBucket,
    required this.hourlyRate,
    required this.weightedHours,
    required this.source,
    required this.isActive,
    required this.effectiveAt,
    required this.metadata,
    required this.createdAt,
    required this.updatedAt,
    this.jobCode,
    this.vendorId,
    this.vendorRoleId,
    this.updatedBy,
    this.scopeType = 'location',
    this.orgUnitId,
    this.inheritedFromScopeId,
    this.sourceLabel,
  });

  final String wageRoleRowId;
  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String roleName;

  /// `'foh' | 'boh' | 'manager'` — matches the migration CHECK.
  final String laborBucket;
  final double hourlyRate;
  final double weightedHours;
  final String? jobCode;
  final String? vendorId;
  final String? vendorRoleId;
  final WageRoleRowSource source;
  final bool isActive;
  final DateTime effectiveAt;
  final Map<String, Object?> metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? updatedBy;

  /// GAP B2 HP #11 wage scope. `'operator_wide' | 'org_unit' |
  /// 'location'`. Mirrors `wage_role_rows.scope_type`; defaults to
  /// `'location'` so legacy rows + omitting writers stay Location-
  /// scoped (matches the migration column default).
  final String scopeType;

  /// Set only when [scopeType] is `'org_unit'` — the region/group this
  /// wage row is configured at. Null for operator_wide + location.
  final String? orgUnitId;

  /// Denormalized provenance: when a value was copied down from a
  /// higher scope, the scope id it came from. Null when set at this
  /// row's own scope.
  final String? inheritedFromScopeId;

  /// Plain-English label for the configured scope that supplied this row.
  /// Read paths can attach this from locations/org_units/operators joins so
  /// UI badges name the inherited source without re-querying hierarchy data.
  final String? sourceLabel;

  /// Project from a row produced by the PostgresExecutor (UUIDs cast
  /// to text in SELECT).
  factory WageRoleRowRecord.fromRow(Map<String, Object?> row) {
    final id = row['wage_role_row_id'];
    final operatorId = row['operator_id'];
    final locationId = row['location_id'];
    final restaurantId = row['restaurant_id'];
    final roleName = row['role_name'];
    final laborBucket = row['labor_bucket'];
    final source = row['source'];
    final isActive = row['is_active'];
    final effectiveAt = row['effective_at'];
    final createdAt = row['created_at'];
    final updatedAt = row['updated_at'];

    if (id is! String ||
        operatorId is! String ||
        restaurantId is! String ||
        roleName is! String ||
        laborBucket is! String ||
        source is! String ||
        isActive is! bool ||
        effectiveAt is! DateTime ||
        createdAt is! DateTime ||
        updatedAt is! DateTime) {
      throw StateError('wage_role_rows row malformed: missing required fields');
    }

    final normalizedLocationId = locationId is String && locationId.isNotEmpty
        ? locationId
        : '';

    final hourlyRate = _coerceDouble(row['hourly_rate']);
    final weightedHours = _coerceDouble(row['weighted_hours']);
    if (hourlyRate == null || weightedHours == null) {
      throw StateError(
        'wage_role_rows row malformed: hourly_rate / weighted_hours '
        'must be numeric',
      );
    }

    final jobCode = row['job_code'];
    final vendorId = row['vendor_id'];
    final vendorRoleId = row['vendor_role_id'];
    final updatedBy = row['updated_by'];

    final scopeTypeRaw = row['scope_type'];
    final scopeType = scopeTypeRaw is String && scopeTypeRaw.isNotEmpty
        ? scopeTypeRaw
        : 'location';
    final orgUnitId = row['org_unit_id'];
    final inheritedFromScopeId = row['inherited_from_scope_id'];
    final sourceLabel = row['source_label'];

    final metadataRaw = row['metadata'];
    final metadata = metadataRaw is Map
        ? Map<String, Object?>.from(metadataRaw)
        : <String, Object?>{};

    return WageRoleRowRecord(
      wageRoleRowId: id,
      operatorId: operatorId,
      locationId: normalizedLocationId,
      restaurantId: restaurantId,
      roleName: roleName,
      laborBucket: laborBucket,
      hourlyRate: hourlyRate,
      weightedHours: weightedHours,
      jobCode: jobCode is String && jobCode.isNotEmpty ? jobCode : null,
      vendorId: vendorId is String && vendorId.isNotEmpty ? vendorId : null,
      vendorRoleId: vendorRoleId is String && vendorRoleId.isNotEmpty
          ? vendorRoleId
          : null,
      source: WageRoleRowSourceWire.fromWire(source),
      isActive: isActive,
      effectiveAt: effectiveAt,
      metadata: metadata,
      createdAt: createdAt,
      updatedAt: updatedAt,
      updatedBy: updatedBy is String && updatedBy.isNotEmpty ? updatedBy : null,
      scopeType: scopeType,
      orgUnitId: orgUnitId is String && orgUnitId.isNotEmpty ? orgUnitId : null,
      inheritedFromScopeId:
          inheritedFromScopeId is String && inheritedFromScopeId.isNotEmpty
          ? inheritedFromScopeId
          : null,
      sourceLabel: sourceLabel is String && sourceLabel.isNotEmpty
          ? sourceLabel
          : null,
    );
  }

  /// Wire-format JSON envelope for the proxy POST/DELETE responses.
  /// Matches the read-side `_wageRoleRowJson` shape in
  /// `proxy_bootstrap.dart` (server_id key + same field names) so the
  /// mobile sync cache can ingest writes the same way it ingests reads.
  Map<String, Object?> toJson() => <String, Object?>{
    'server_id': wageRoleRowId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'role_name': roleName,
    'labor_bucket': laborBucket,
    'hourly_rate': hourlyRate,
    'weighted_hours': weightedHours,
    'job_code': jobCode,
    'vendor_id': vendorId,
    'vendor_role_id': vendorRoleId,
    'source': source.wire,
    'is_active': isActive,
    'effective_at': effectiveAt.toUtc().toIso8601String(),
    'metadata': metadata,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'updated_by': updatedBy,
    'scope_type': scopeType,
    'org_unit_id': orgUnitId,
    'inherited_from_scope_id': inheritedFromScopeId,
    if (sourceLabel != null) 'source_label': sourceLabel,
  };

  static double? _coerceDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    if (raw is num) return raw.toDouble();
    if (raw is String) {
      final parsed = double.tryParse(raw);
      if (parsed != null) return parsed;
    }
    return null;
  }
}
