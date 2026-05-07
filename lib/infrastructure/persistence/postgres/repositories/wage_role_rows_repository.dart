// Phase 8 W5.A.1 — WageRoleRowsRepository.
//
// Persistence layer for `public.wage_role_rows`. Every read / write
// goes through `OperatorScopedRepository.withTenant` so the
// per-tenant RLS policy admits the row (primary defense: repository
// pattern; backup: RLS).
//
// Authority:
//   * db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql
//     (table + UNIQUE on the (operator_id, location_id, restaurant_id,
//     role_name) 4-tuple).
//   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
//     (every operator-scoped table goes through OperatorScopedRepository;
//     no raw `package:postgres` import outside this directory).
//
// Methods:
//   * upsert      — INSERT … ON CONFLICT DO UPDATE on the natural-key
//                   4-tuple. Idempotent. Used by the operator wage
//                   editor (mobile + future op-web W3.D parity) to
//                   write the operator-controlled wage mix.
//   * softDelete  — sets `is_active = false` for a given UUID. The
//                   read path (`fetchWageRoleRows` in proxy_bootstrap)
//                   filters `is_active is true` so a soft delete hides
//                   the row from the mobile cache without losing the
//                   audit row.

import '../../../../domain/models/wage_role_row_record.dart';
import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class WageRoleRowsRepository extends OperatorScopedRepository {
  WageRoleRowsRepository(super.tenantWrapper);

  static const String _selectColumns =
      'wage_role_row_id::text as wage_role_row_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'restaurant_id, '
      'role_name, '
      'labor_bucket, '
      'hourly_rate, '
      'weighted_hours, '
      'job_code, '
      'vendor_id, '
      'vendor_role_id, '
      'source, '
      'is_active, '
      'effective_at, '
      'metadata, '
      'created_at, '
      'updated_at, '
      'updated_by';

  /// Upsert a wage row keyed by the natural 4-tuple (operator_id,
  /// location_id, restaurant_id, role_name). DO UPDATE rewrites the
  /// editable fields and bumps `updated_at` / `updated_by`.
  /// `created_at` is preserved on conflict so the audit trail keeps
  /// the original creation time. Replay yields the same final row
  /// state.
  Future<WageRoleRowRecord> upsert({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String roleName,
    required String laborBucket,
    required double hourlyRate,
    required double weightedHours,
    String? jobCode,
    String? vendorId,
    String? vendorRoleId,
    WageRoleRowSource source = WageRoleRowSource.operatorManual,
    bool isActive = true,
    Map<String, Object?> metadata = const <String, Object?>{},
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<WageRoleRowRecord>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.wage_role_rows ('
        'operator_id, location_id, restaurant_id, role_name, '
        'labor_bucket, hourly_rate, weighted_hours, '
        'job_code, vendor_id, vendor_role_id, '
        'source, is_active, metadata, updated_by) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, '
        '@restaurant_id, @role_name, '
        '@labor_bucket, @hourly_rate, @weighted_hours, '
        '@job_code, @vendor_id, @vendor_role_id, '
        '@source, @is_active, @metadata::jsonb, @updated_by) '
        'on conflict (operator_id, location_id, restaurant_id, role_name) '
        'do update set '
        'labor_bucket = excluded.labor_bucket, '
        'hourly_rate = excluded.hourly_rate, '
        'weighted_hours = excluded.weighted_hours, '
        'job_code = excluded.job_code, '
        'vendor_id = excluded.vendor_id, '
        'vendor_role_id = excluded.vendor_role_id, '
        'source = excluded.source, '
        'is_active = excluded.is_active, '
        'metadata = excluded.metadata, '
        'updated_at = now(), '
        'updated_by = excluded.updated_by '
        'returning $_selectColumns',
        parameters: <String, Object?>{
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
          'metadata': _encodeMetadata(metadata),
          'updated_by': actorUserId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'wage_role_rows upsert returned no row — RLS policy likely '
          'rejected the write for this tenant',
        );
      }
      return WageRoleRowRecord.fromRow(rows.single);
    });
  }

  /// Soft-delete a wage row by UUID. Sets `is_active = false` and
  /// bumps `updated_at`. Returns true if a row was updated, false
  /// when no row matched (already deleted, or cross-tenant —
  /// production RLS would deny first).
  Future<bool> softDelete({
    required String operatorId,
    required String locationId,
    required String wageRoleRowId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<bool>(ctx, (exec) async {
      final affected = await exec.execute(
        'update public.wage_role_rows '
        'set is_active = false, '
        'updated_at = now(), '
        'updated_by = @updated_by '
        'where wage_role_row_id = @wage_role_row_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and is_active is true',
        parameters: <String, Object?>{
          'wage_role_row_id': wageRoleRowId,
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_by': actorUserId,
        },
      );
      return affected > 0;
    });
  }

  /// Encode the `metadata` jsonb payload as a JSON string. The
  /// proxy-side parameter binding writes the value through `::jsonb`
  /// cast so an empty map round-trips as `{}` not `null`.
  static String _encodeMetadata(Map<String, Object?> metadata) {
    if (metadata.isEmpty) return '{}';
    return _stringifyJson(metadata);
  }

  static String _stringifyJson(Object? value) {
    if (value == null) return 'null';
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return value.toString();
    if (value is String) {
      final escaped = value
          .replaceAll('\\', '\\\\')
          .replaceAll('"', '\\"')
          .replaceAll('\n', '\\n')
          .replaceAll('\r', '\\r')
          .replaceAll('\t', '\\t');
      return '"$escaped"';
    }
    if (value is List) {
      final parts = value.map(_stringifyJson).join(',');
      return '[$parts]';
    }
    if (value is Map) {
      final entries = <String>[];
      for (final entry in value.entries) {
        final keyJson = _stringifyJson(entry.key.toString());
        final valueJson = _stringifyJson(entry.value);
        entries.add('$keyJson:$valueJson');
      }
      return '{${entries.join(',')}}';
    }
    return _stringifyJson(value.toString());
  }
}
