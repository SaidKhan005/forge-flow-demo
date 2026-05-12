// Phase 9.0Σ.c — OrgUnitsRepository.
//
// Persistence layer for the `org_units` table created in
// `202604280002_phase_9_0sigma_c_org_units.sql`. The table stores the
// per-operator corp/region/district/location_group hierarchy as
// Postgres ltree materialized paths (item 1 / Q2 from
// `phase_9_scalability_decisions_2026-04-27.md`).
//
// All methods route through `OperatorScopedRepository.withTenant` so
// the `org_units_per_tenant` RLS policy (which calls
// `app_current_operator()` wrapper) admits rows. Admin/system reads
// across tenants run through `withSystem` and rely on the
// `forge_admin` BYPASSRLS escape hatch.
//
// This slice intentionally exposes only the small surface needed by
// the migration's backfill verification + the upcoming 11A admin
// console hierarchy view: `listForTenant`, `getById`,
// `createRoot`, and `createChild`. Subtree enumeration
// (`path <@ ancestor`), permission inheritance lookup, and grant
// rules are downstream slices.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// One `org_units` row, narrowed to the columns the launch surface
/// needs. Timestamps are exposed as `DateTime` (the `package:postgres`
/// adapter maps `timestamptz` → `DateTime`).
class OrgUnitRow {
  const OrgUnitRow({
    required this.id,
    required this.operatorId,
    required this.parentId,
    required this.unitType,
    required this.path,
    required this.name,
    this.suspendedAt,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String operatorId;
  final String? parentId;
  final String unitType;
  final String path;
  final String name;
  final DateTime? suspendedAt;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class OrgUnitsRepository extends OperatorScopedRepository {
  OrgUnitsRepository(super.tenantWrapper);

  /// Allowed `unit_type` values per the migration's CHECK constraint.
  /// Validated in Dart so a malformed argument does not reach the
  /// database, matching the defense-in-depth posture used elsewhere
  /// (e.g. [TenantContext]).
  static const Set<String> allowedUnitTypes = <String>{
    'corp',
    'region',
    'district',
    'location_group',
  };

  /// Item 1 / Q2 depth cap: 6 levels max. Mirrored in Dart so a
  /// malformed insert is rejected before the round-trip.
  static const int maxDepth = 6;

  /// SELECT every `org_units` row visible to the tenant context.
  /// Returns rows ordered by `path` so callers can render the
  /// hierarchy in a stable order.
  Future<List<OrgUnitRow>> listForTenant({
    required String operatorId,
    required String locationId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<OrgUnitRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select id::text as id, operator_id::text as operator_id, '
        'parent_id::text as parent_id, unit_type, path::text as path, '
        'name, suspended_at, deleted_at, created_at, updated_at '
        'from org_units '
        'where deleted_at is null '
        'order by path',
      );
      return rows.map(_rowFromMap).toList(growable: false);
    });
  }

  /// SELECT a single `org_units` row by id. Returns null when the
  /// row is invisible to the tenant (RLS) or absent.
  Future<OrgUnitRow?> getById({
    required String operatorId,
    required String locationId,
    required String id,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<OrgUnitRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select id::text as id, operator_id::text as operator_id, '
        'parent_id::text as parent_id, unit_type, path::text as path, '
        'name, suspended_at, deleted_at, created_at, updated_at '
        'from org_units '
        'where id = @id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{'id': id},
      );
      if (rows.isEmpty) return null;
      return _rowFromMap(rows.single);
    });
  }

  /// INSERT a root `corp` row for a brand-new operator. Returns the
  /// generated `id`. The migration backfills one root per existing
  /// operator; this method handles operators created after the
  /// migration runs (admin console path, lands in 11A).
  ///
  /// [pathLabel] is the ltree label for the root (single segment,
  /// `[a-z0-9_]+` lowercase). Caller is responsible for sanitising
  /// the operator name; the database CHECK rejects invalid ltree.
  Future<String> createRoot({
    required String operatorId,
    required String locationId,
    required String pathLabel,
    required String name,
    String? userId,
  }) {
    _validateUnitType('corp');
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into org_units '
        '(operator_id, parent_id, unit_type, path, name) '
        'values (@operator_id::uuid, null, '
        "'corp', @path::ltree, @name) "
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'path': pathLabel,
          'name': name,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'org_units root insert returned no rows — RLS policy may '
          'have blocked the row even though SET LOCAL ran',
        );
      }
      final id = rows.single['id'];
      if (id is! String || id.isEmpty) {
        throw StateError('org_units root insert returned a malformed id');
      }
      return id;
    });
  }

  /// INSERT a child node under [parentId]. Path is computed in SQL
  /// as `parent.path || @child_label::ltree` so the materialized
  /// path stays consistent with the parent_id pointer.
  ///
  /// Pre-flight depth guard: rejects in Dart when adding a child
  /// would exceed [maxDepth], matching the migration's
  /// `CHECK (nlevel(path) <= 6)`. The DB CHECK is the authoritative
  /// gate; this Dart check just avoids the round-trip on obvious
  /// violations.
  Future<String> createChild({
    required String operatorId,
    required String locationId,
    required String parentId,
    required String unitType,
    required String childLabel,
    required String name,
    String? userId,
  }) {
    _validateUnitType(unitType);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (exec) async {
      // Parent lookup runs inside the same transaction so the SET
      // LOCAL tenant predicate applies — a cross-tenant parent_id
      // returns no rows and the insert refuses to proceed.
      final parentRows = await exec.query(
        'select path::text as path, nlevel(path) as depth '
        'from org_units '
        'where id = @parent_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{'parent_id': parentId},
      );
      if (parentRows.isEmpty) {
        throw StateError(
          'org_units parent not found in tenant scope — either the '
          'parent does not exist or RLS blocked the read',
        );
      }
      final depthValue = parentRows.single['depth'];
      final parentDepth = depthValue is int
          ? depthValue
          : int.parse(depthValue.toString());
      if (parentDepth >= maxDepth) {
        throw StateError(
          'org_units depth guard: adding a child under a parent at '
          'depth $parentDepth would exceed the locked max of $maxDepth',
        );
      }

      final rows = await exec.query(
        'insert into org_units '
        '(operator_id, parent_id, unit_type, path, name) '
        'select @operator_id::uuid, @parent_id::uuid, @unit_type, '
        'parent.path || @child_label::ltree, @name '
        'from org_units parent '
        'where parent.id = @parent_id::uuid '
        'and parent.deleted_at is null '
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'parent_id': parentId,
          'unit_type': unitType,
          'child_label': childLabel,
          'name': name,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'org_units child insert returned no rows — parent vanished '
          'between read and write or RLS blocked the row',
        );
      }
      final id = rows.single['id'];
      if (id is! String || id.isEmpty) {
        throw StateError('org_units child insert returned a malformed id');
      }
      return id;
    });
  }

  /// Phase 9.UX.4 — SELECT every `locations` row visible to the
  /// tenant context together with the denormalized `org_unit_path`
  /// the migration's `set_location_org_unit_path()` trigger keeps in
  /// sync. Returned rows are ordered by `org_unit_path` so the
  /// Settings → Team → Org Hierarchy surface can render the tree in
  /// a stable, parent-before-child order.
  Future<List<OrgLocationRow>> listLocationsForTenant({
    required String operatorId,
    required String locationId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<OrgLocationRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select l.location_id::text as location_id, '
        'l.operator_id::text as operator_id, '
        'l.parent_org_unit_id::text as parent_org_unit_id, '
        'l.org_unit_path::text as org_unit_path, l.name, '
        'l.timezone as business_timezone, l.suspended_at, l.deleted_at '
        'from locations l '
        'where l.deleted_at is null '
        'and not exists ('
        'select 1 from org_units deleted_ancestor '
        'where deleted_ancestor.operator_id = l.operator_id '
        'and deleted_ancestor.deleted_at is not null '
        'and l.org_unit_path <@ deleted_ancestor.path'
        ') '
        'order by l.org_unit_path, l.name',
      );
      return rows.map(_locationRowFromMap).toList(growable: false);
    });
  }

  /// Phase 9.UX.4 — UPDATE the `parent_org_unit_id` column on a
  /// single `locations` row. The migration's
  /// `set_location_org_unit_path()` trigger refreshes
  /// `org_unit_path` from the new parent in the same write so the
  /// denormalized path stays consistent without a second round-trip.
  ///
  /// Returns the affected-row count (0 when the location does not
  /// exist or RLS blocked the update).
  Future<int> moveLocationToOrgUnit({
    required String operatorId,
    required String locationId,
    required String targetLocationId,
    required String parentOrgUnitId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      // Same-operator parent enforcement: the parent must be visible
      // to the tenant context. RLS already filters cross-operator
      // rows; double-check here so the proxy never quietly fails the
      // FK trigger after the read.
      final parentRows = await exec.query(
        'select 1 from org_units '
        'where id = @parent_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{'parent_id': parentOrgUnitId},
      );
      if (parentRows.isEmpty) {
        throw StateError(
          'org_units parent not found in tenant scope — cross-tenant '
          'parent or RLS blocked the read',
        );
      }
      return exec.execute(
        'update locations '
        'set parent_org_unit_id = @parent_id::uuid '
        'where location_id = @location_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'parent_id': parentOrgUnitId,
          'location_id': targetLocationId,
          'operator_id': operatorId,
        },
      );
    });
  }

  Future<OrgUnitRow> moveOrgUnit({
    required String operatorId,
    required String locationId,
    required String orgUnitId,
    required String parentOrgUnitId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<OrgUnitRow>(ctx, (exec) async {
      final childRows = await exec.query(
        'select id::text as id, operator_id::text as operator_id, '
        'parent_id::text as parent_id, unit_type, path::text as path, '
        'name, suspended_at, deleted_at, created_at, updated_at, '
        'nlevel(path) as depth '
        'from org_units '
        'where id = @org_unit_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{'org_unit_id': orgUnitId},
      );
      if (childRows.isEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'unknown_org_unit',
          message: 'org unit not found in tenant scope',
          statusCode: 404,
        );
      }
      final child = _rowFromMap(childRows.single);
      if (child.parentId == null) {
        throw const OrgUnitMoveRejected(
          code: 'cannot_move_root_org_unit',
          message: 'root org unit cannot be moved',
          statusCode: 400,
        );
      }

      final parentRows = await exec.query(
        'select id::text as id, operator_id::text as operator_id, '
        'parent_id::text as parent_id, unit_type, path::text as path, '
        'name, suspended_at, deleted_at, created_at, updated_at, '
        'nlevel(path) as depth '
        'from org_units '
        'where id = @parent_org_unit_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{'parent_org_unit_id': parentOrgUnitId},
      );
      if (parentRows.isEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'unknown_parent_org_unit',
          message: 'parent org unit not found in tenant scope',
          statusCode: 404,
        );
      }
      final parent = _rowFromMap(parentRows.single);
      if (parent.path == child.path ||
          parent.path.startsWith('${child.path}.')) {
        throw const OrgUnitMoveRejected(
          code: 'org_unit_cycle',
          message: 'org unit cannot move under itself or a descendant',
          statusCode: 400,
        );
      }

      final childDepth = _intValue(childRows.single['depth']);
      final parentDepth = _intValue(parentRows.single['depth']);
      final descendantRows = await exec.query(
        'select coalesce(max(nlevel(path) - @child_depth), 0) as max_relative '
        'from org_units '
        'where path <@ @child_path::ltree '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'child_depth': childDepth,
          'child_path': child.path,
        },
      );
      final maxRelative = descendantRows.isEmpty
          ? 0
          : _intValue(descendantRows.single['max_relative']);
      if (parentDepth + 1 + maxRelative > maxDepth) {
        throw const OrgUnitMoveRejected(
          code: 'org_unit_depth_exceeded',
          message: 'move would exceed the maximum hierarchy depth',
          statusCode: 400,
        );
      }

      final rows = await exec.query(
        'with moving as ('
        '  select path as old_path, nlevel(path) as old_depth, '
        '         subpath(path, nlevel(path) - 1) as own_label '
        '    from org_units '
        '   where id = @org_unit_id::uuid'
        '     and deleted_at is null'
        '), parent as ('
        '  select path as parent_path '
        '    from org_units '
        '   where id = @parent_org_unit_id::uuid'
        '     and deleted_at is null'
        '), next_path as ('
        '  select moving.old_path, moving.old_depth, '
        '         parent.parent_path || moving.own_label as new_path '
        '    from moving, parent'
        ') '
        'update org_units ou '
        '   set parent_id = case '
        '         when ou.id = @org_unit_id::uuid then @parent_org_unit_id::uuid '
        '         else ou.parent_id '
        '       end, '
        '       path = case '
        '         when ou.id = @org_unit_id::uuid then next_path.new_path '
        '         else next_path.new_path || subpath(ou.path, next_path.old_depth) '
        '       end, '
        '       updated_at = now() '
        '  from next_path '
        ' where ou.operator_id = @operator_id::uuid '
        '   and ou.path <@ next_path.old_path '
        '   and ou.deleted_at is null '
        'returning ou.id::text as id, ou.operator_id::text as operator_id, '
        '          ou.parent_id::text as parent_id, ou.unit_type, '
        '          ou.path::text as path, ou.name, ou.suspended_at, '
        '          ou.deleted_at, ou.created_at, ou.updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'org_unit_id': orgUnitId,
          'parent_org_unit_id': parentOrgUnitId,
        },
      );
      if (rows.isEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'org_unit_move_failed',
          message: 'org unit move did not update any rows',
          statusCode: 409,
        );
      }
      await exec.execute(
        'update locations loc '
        '   set org_unit_path = ou.path '
        '  from org_units ou '
        ' where loc.operator_id = @operator_id::uuid '
        '   and ou.operator_id = loc.operator_id '
        '   and ou.id = loc.parent_org_unit_id '
        '   and loc.deleted_at is null '
        '   and ou.deleted_at is null '
        '   and loc.org_unit_path is distinct from ou.path',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return _rowFromMap(
        rows.firstWhere(
          (row) => row['id'] == orgUnitId,
          orElse: () => rows.first,
        ),
      );
    });
  }

  Future<OrgUnitRow> setOrgUnitSuspended({
    required String operatorId,
    required String locationId,
    required String orgUnitId,
    required bool suspended,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<OrgUnitRow>(ctx, (exec) async {
      final existingRows = await exec.query(
        'select id::text as id, parent_id::text as parent_id '
        'from org_units '
        'where id = @org_unit_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{'org_unit_id': orgUnitId},
      );
      if (existingRows.isEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'unknown_org_unit',
          message: 'org unit not found in tenant scope',
          statusCode: 404,
        );
      }
      if (existingRows.single['parent_id'] == null) {
        throw const OrgUnitMoveRejected(
          code: 'cannot_suspend_root_org_unit',
          message: 'business root org unit cannot be suspended',
          statusCode: 400,
        );
      }
      final rows = await exec.query(
        'update org_units '
        'set suspended_at = case when @suspended then now() else null end, '
        'updated_at = now() '
        'where id = @org_unit_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null '
        'returning id::text as id, operator_id::text as operator_id, '
        'parent_id::text as parent_id, unit_type, path::text as path, '
        'name, suspended_at, deleted_at, created_at, updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'org_unit_id': orgUnitId,
          'suspended': suspended,
        },
      );
      if (rows.isEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'org_unit_lifecycle_failed',
          message: 'org unit lifecycle update did not update any rows',
          statusCode: 409,
        );
      }
      return _rowFromMap(rows.single);
    });
  }

  Future<bool> deleteOrgUnit({
    required String operatorId,
    required String locationId,
    required String orgUnitId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<bool>(ctx, (exec) async {
      final existingRows = await exec.query(
        'select id::text as id, parent_id::text as parent_id '
        'from org_units '
        'where id = @org_unit_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{'org_unit_id': orgUnitId},
      );
      if (existingRows.isEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'unknown_org_unit',
          message: 'org unit not found in tenant scope',
          statusCode: 404,
        );
      }
      if (existingRows.single['parent_id'] == null) {
        throw const OrgUnitMoveRejected(
          code: 'cannot_delete_root_org_unit',
          message: 'business root org unit cannot be deleted',
          statusCode: 400,
        );
      }
      final childRows = await exec.query(
        'select 1 from org_units '
        'where parent_id = @org_unit_id::uuid '
        'and deleted_at is null limit 1',
        parameters: <String, Object?>{'org_unit_id': orgUnitId},
      );
      final locationRows = await exec.query(
        'select 1 from locations '
        'where parent_org_unit_id = @org_unit_id::uuid '
        'and deleted_at is null limit 1',
        parameters: <String, Object?>{'org_unit_id': orgUnitId},
      );
      if (childRows.isNotEmpty || locationRows.isNotEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'org_unit_not_empty',
          message: 'move or delete child org units and locations first',
          statusCode: 409,
        );
      }
      final activeTargets = await exec.query(
        'select source from ('
        "select 'user_roles' as source "
        'from user_roles '
        'where operator_id = @operator_id::uuid '
        'and org_unit_id = @org_unit_id::uuid '
        "and scope_type = 'org_unit' "
        'and revoked_at is null '
        'and valid_from <= now() '
        'and (valid_until is null or valid_until > now()) '
        'union all '
        "select 'auth_invites' as source "
        'from auth_invites '
        'where operator_id = @operator_id::uuid '
        'and org_unit_id = @org_unit_id::uuid '
        "and scope_type = 'org_unit' "
        'and accepted_at is null '
        'and revoked_at is null '
        'and expires_at > now()'
        ') active_targets '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'org_unit_id': orgUnitId,
        },
      );
      if (activeTargets.isNotEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'org_unit_has_active_access_targets',
          message: 'revoke or reassign active roles and invites first',
          statusCode: 409,
        );
      }
      final affected = await exec.execute(
        'update org_units '
        'set deleted_at = now(), updated_at = now() '
        'where id = @org_unit_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'org_unit_id': orgUnitId,
        },
      );
      return affected > 0;
    });
  }

  Future<OrgLocationRow> setLocationSuspended({
    required String operatorId,
    required String locationId,
    required String targetLocationId,
    required bool suspended,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<OrgLocationRow>(ctx, (exec) async {
      final rows = await exec.query(
        'update locations '
        'set suspended_at = case when @suspended then now() else null end, '
        'updated_at = now() '
        'where location_id = @location_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null '
        'returning location_id::text as location_id, '
        'operator_id::text as operator_id, '
        'parent_org_unit_id::text as parent_org_unit_id, '
        "coalesce(org_unit_path::text, '') as org_unit_path, "
        'name, timezone as business_timezone, suspended_at, deleted_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': targetLocationId,
          'suspended': suspended,
        },
      );
      if (rows.isEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'unknown_location',
          message: 'location not found in tenant scope',
          statusCode: 404,
        );
      }
      return _locationRowFromMap(rows.single);
    });
  }

  Future<bool> deleteLocation({
    required String operatorId,
    required String locationId,
    required String targetLocationId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<bool>(ctx, (exec) async {
      final primaryRows = await exec.query(
        'select 1 from operators '
        'where operator_id = @operator_id::uuid '
        'and primary_location_id = @location_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': targetLocationId,
        },
      );
      if (primaryRows.isNotEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'cannot_delete_primary_location',
          message:
              'assign a different primary location before deleting this one',
          statusCode: 400,
        );
      }
      final activeTargets = await exec.query(
        'select source from ('
        "select 'user_roles' as source "
        'from user_roles '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        "and scope_type = 'location' "
        'and revoked_at is null '
        'and valid_from <= now() '
        'and (valid_until is null or valid_until > now()) '
        'union all '
        "select 'auth_invites' as source "
        'from auth_invites '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        "and scope_type = 'location' "
        'and accepted_at is null '
        'and revoked_at is null '
        'and expires_at > now()'
        ') active_targets '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': targetLocationId,
        },
      );
      if (activeTargets.isNotEmpty) {
        throw const OrgUnitMoveRejected(
          code: 'location_has_active_access_targets',
          message: 'revoke or reassign active roles and invites first',
          statusCode: 409,
        );
      }
      final affected = await exec.execute(
        'update locations '
        'set deleted_at = now(), updated_at = now() '
        'where location_id = @location_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': targetLocationId,
        },
      );
      if (affected == 0) {
        throw const OrgUnitMoveRejected(
          code: 'unknown_location',
          message: 'location not found in tenant scope',
          statusCode: 404,
        );
      }
      return true;
    });
  }

  /// Admin/system path: SELECT every root `corp` row across operators.
  /// Used by the 11A admin console hierarchy panel + backfill
  /// verification. Runs through `withSystem` so `forge_admin`
  /// BYPASSRLS engages — the [adminReason] string is audited.
  Future<List<OrgUnitRow>> listAllRootsAsAdmin({required String adminReason}) {
    return withSystem<List<OrgUnitRow>>((exec) async {
      final rows = await exec.query(
        'select id::text as id, operator_id::text as operator_id, '
        'parent_id::text as parent_id, unit_type, path::text as path, '
        'name, suspended_at, deleted_at, created_at, updated_at '
        'from org_units '
        'where parent_id is null '
        'and deleted_at is null '
        'order by operator_id, path',
      );
      return rows.map(_rowFromMap).toList(growable: false);
    }, reason: adminReason);
  }

  /// Admin/system path: SELECT every registered location across
  /// operators for global F&F read-only mobile scope discovery. Runs
  /// through `withSystem` so the [adminReason] string is audited and
  /// tenant RLS remains closed to ordinary operator tokens.
  Future<List<OrgLocationRow>> listAllLocationsAsAdmin({
    required String adminReason,
  }) {
    return withSystem<List<OrgLocationRow>>((exec) async {
      final rows = await exec.query(
        'select l.location_id::text as location_id, '
        'l.operator_id::text as operator_id, '
        'l.parent_org_unit_id::text as parent_org_unit_id, '
        "coalesce(l.org_unit_path::text, '') as org_unit_path, "
        'l.name, l.timezone as business_timezone, '
        'l.suspended_at, l.deleted_at, '
        'o.business_name as operator_name '
        'from locations l '
        'join operators o on o.operator_id = l.operator_id '
        'where l.deleted_at is null '
        'and not exists ('
        'select 1 from org_units deleted_ancestor '
        'where deleted_ancestor.operator_id = l.operator_id '
        'and deleted_ancestor.deleted_at is not null '
        'and l.org_unit_path <@ deleted_ancestor.path'
        ') '
        'order by lower(o.business_name), l.org_unit_path, '
        'lower(l.name), l.location_id',
      );
      return rows.map(_locationRowFromMap).toList(growable: false);
    }, reason: adminReason);
  }

  static void _validateUnitType(String value) {
    if (!allowedUnitTypes.contains(value)) {
      throw ArgumentError.value(
        value,
        'unitType',
        'must be one of $allowedUnitTypes',
      );
    }
  }

  static OrgUnitRow _rowFromMap(Map<String, Object?> row) {
    return OrgUnitRow(
      id: row['id']! as String,
      operatorId: row['operator_id']! as String,
      parentId: row['parent_id'] as String?,
      unitType: row['unit_type']! as String,
      path: row['path']! as String,
      name: row['name']! as String,
      suspendedAt: _dateTimeOrNull(row['suspended_at']),
      deletedAt: _dateTimeOrNull(row['deleted_at']),
      createdAt: row['created_at']! as DateTime,
      updatedAt: row['updated_at']! as DateTime,
    );
  }

  static int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.parse(value.toString());
  }

  static OrgLocationRow _locationRowFromMap(Map<String, Object?> row) {
    return OrgLocationRow(
      locationId: row['location_id']! as String,
      operatorId: row['operator_id']! as String,
      parentOrgUnitId: row['parent_org_unit_id'] as String?,
      orgUnitPath: row['org_unit_path'] as String? ?? '',
      name: row['name']! as String,
      businessTimezone: row['business_timezone'] as String?,
      suspendedAt: _dateTimeOrNull(row['suspended_at']),
      deletedAt: _dateTimeOrNull(row['deleted_at']),
      operatorName: row['operator_name'] as String?,
    );
  }

  static DateTime? _dateTimeOrNull(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String && value.isNotEmpty) return DateTime.parse(value);
    return null;
  }
}

class OrgUnitMoveRejected implements Exception {
  const OrgUnitMoveRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() => 'OrgUnitMoveRejected($statusCode/$code): $message';
}

/// Phase 9.UX.4 — narrow projection of a `locations` row joined with
/// the denormalized `org_unit_path` column added by the
/// `202604290101_phase_9_hierarchy_access_wiring` migration. Used by
/// the Settings → Team → Org Hierarchy surface to render locations
/// underneath their parent org unit.
class OrgLocationRow {
  const OrgLocationRow({
    required this.locationId,
    required this.operatorId,
    required this.orgUnitPath,
    required this.name,
    this.parentOrgUnitId,
    this.businessTimezone,
    this.suspendedAt,
    this.deletedAt,
    this.operatorName,
  });

  final String locationId;
  final String operatorId;
  final String? parentOrgUnitId;
  final String orgUnitPath;
  final String name;
  final String? businessTimezone;
  final DateTime? suspendedAt;
  final DateTime? deletedAt;
  final String? operatorName;
}
