// Phase 9 live-closeout B17 - RolePermissionsRepository.
//
// Reads + writes the `role_permissions` rows (one row per
// (role_id, permission_key) with effect ∈ {'allow','deny'}).
// Listing happens by role; writes happen as upsert (insert on
// conflict do update) since the matrix editor (Phase 9.9 admin
// console kernel) emits cell-by-cell upserts.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// One row from `role_permissions`.
class RolePermissionRow {
  const RolePermissionRow({
    required this.roleId,
    required this.permissionKey,
    required this.effect,
    required this.createdAt,
    required this.updatedAt,
  });

  final String roleId;
  final String permissionKey;

  /// Either `'allow'` or `'deny'` per the schema CHECK.
  final String effect;

  final DateTime createdAt;
  final DateTime updatedAt;
}

class RolePermissionsRepository extends OperatorScopedRepository {
  RolePermissionsRepository(super.tenantWrapper);

  /// List every `role_permissions` row for [roleId]. The proxy uses
  /// this to project the cell state for the matrix editor.
  Future<List<RolePermissionRow>> listForRole({
    required String operatorId,
    required String locationId,
    required String roleId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<List<RolePermissionRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select role_id::text as role_id, '
        'permission_key, effect, created_at, updated_at '
        'from role_permissions '
        'where role_id = @role_id::uuid '
        'order by permission_key',
        parameters: <String, Object?>{'role_id': roleId},
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  /// Upsert a single (role_id, permission_key, effect) triple.
  /// Used by the cell-by-cell matrix editor save path.
  Future<int> upsertCell({
    required String operatorId,
    required String locationId,
    required String updatedByUserId,
    required String roleId,
    required String permissionKey,
    required String effect,
  }) {
    if (effect != 'allow' && effect != 'deny') {
      throw ArgumentError.value(
        effect,
        'effect',
        "must be 'allow' or 'deny'",
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: updatedByUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'insert into role_permissions ('
        'role_id, permission_key, effect, created_by, updated_by) '
        'values (@role_id::uuid, @permission_key, @effect, '
        '@updated_by::uuid, @updated_by::uuid) '
        'on conflict (role_id, permission_key) do update '
        'set effect = excluded.effect, updated_at = now(), '
        'updated_by = excluded.updated_by',
        parameters: <String, Object?>{
          'role_id': roleId,
          'permission_key': permissionKey,
          'effect': effect,
          'updated_by': updatedByUserId,
        },
      );
    });
  }

  /// DELETE a (role_id, permission_key) row entirely. Used by the
  /// "revert cell to inherit" path in the matrix editor.
  Future<int> deleteCell({
    required String operatorId,
    required String locationId,
    required String updatedByUserId,
    required String roleId,
    required String permissionKey,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: updatedByUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'delete from role_permissions '
        'where role_id = @role_id::uuid '
        'and permission_key = @permission_key',
        parameters: <String, Object?>{
          'role_id': roleId,
          'permission_key': permissionKey,
        },
      );
    });
  }

  static RolePermissionRow _projectRow(Map<String, Object?> row) {
    return RolePermissionRow(
      roleId: row['role_id'] as String,
      permissionKey: row['permission_key'] as String,
      effect: row['effect'] as String,
      createdAt: row['created_at'] as DateTime,
      updatedAt: row['updated_at'] as DateTime,
    );
  }
}
