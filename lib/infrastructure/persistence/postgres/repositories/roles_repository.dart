// Phase 9 live-closeout B17 - RolesRepository.
//
// Persistence layer for the `roles` + `role_permissions` tables.
// Reads / writes routed through the `OperatorScopedRepository` +
// `TenantTransactionWrapper` so the per-tenant RLS policies admit
// the rows.
//
// `roles` rows can be either global (operator_id NULL — seeded
// system roles) or operator-scoped (operator_id set — operator's
// custom roles). The composite PK on `(operator_id, role_key)`
// (with a separate partial index for operator_id IS NULL) is
// enforced at the DB; the repo just round-trips the values.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// One row from `roles`.
class RoleRecord {
  const RoleRecord({
    required this.roleId,
    required this.roleKey,
    required this.displayName,
    required this.description,
    required this.isSeeded,
    required this.isEditable,
    required this.createdAt,
    required this.updatedAt,
    this.operatorId,
    this.deletedAt,
  });

  final String roleId;
  final String roleKey;
  final String displayName;
  final String description;
  final bool isSeeded;
  final bool isEditable;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Null for global / seeded roles; non-null for operator-scoped
  /// custom roles.
  final String? operatorId;
  final DateTime? deletedAt;
}

class RolesRepository extends OperatorScopedRepository {
  RolesRepository(super.tenantWrapper);

  /// SELECT every role visible to the actor's tenant. Per-tenant RLS
  /// admits operator-scoped rows owned by this operator + every
  /// global (operator_id IS NULL) row, so the caller can render
  /// "global + operator-scoped" together.
  Future<List<RoleRecord>> listVisibleRoles({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<List<RoleRecord>>(ctx, (exec) async {
      final rows = await exec.query(
        'select role_id::text as role_id, '
        'operator_id::text as operator_id, '
        'role_key, display_name, description, '
        'is_seeded, is_editable, '
        'created_at, updated_at, deleted_at '
        'from roles '
        'where deleted_at is null '
        'order by case when operator_id is null then 0 else 1 end, role_key',
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  /// INSERT a new operator-scoped role. Returns the freshly minted
  /// `role_id`. The proxy validates `RoleManagementPolicy` BEFORE
  /// invoking this — the repo trusts its caller.
  Future<String> insertOperatorRole({
    required String operatorId,
    required String locationId,
    required String createdByUserId,
    required String roleKey,
    required String displayName,
    String description = '',
    bool isEditable = true,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: createdByUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into roles ('
        'operator_id, role_key, display_name, description, '
        'is_seeded, is_editable, created_by, updated_by) '
        'values (@operator_id::uuid, @role_key, @display_name, '
        '@description, false, @is_editable, '
        '@created_by::uuid, @created_by::uuid) '
        'returning role_id::text as role_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'role_key': roleKey,
          'display_name': displayName,
          'description': description,
          'is_editable': isEditable,
          'created_by': createdByUserId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'roles insert returned no rows — RLS may have blocked',
        );
      }
      final id = rows.single['role_id'];
      if (id is! String || id.isEmpty) {
        throw StateError('roles insert returned a malformed role_id');
      }
      return id;
    });
  }

  /// Soft-delete an operator-scoped role. Caller verified
  /// `RoleManagementPolicy.evaluateRoleAction(role)` first.
  /// Refuses to soft-delete a role that still has active grants;
  /// the proxy must revoke / reassign grants first.
  Future<int> softDeleteOperatorRole({
    required String operatorId,
    required String locationId,
    required String updatedByUserId,
    required String roleId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: updatedByUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      final activeGrants = await exec.query(
        'select 1 from user_roles '
        'where role_id = @role_id::uuid '
        'and revoked_at is null '
        'limit 1',
        parameters: <String, Object?>{'role_id': roleId},
      );
      if (activeGrants.isNotEmpty) {
        throw StateError(
          'roles soft-delete refused: role $roleId still has active '
          'user_roles grants; revoke them before deleting',
        );
      }
      return exec.execute(
        'update roles '
        'set deleted_at = now(), updated_at = now(), updated_by = @updated_by::uuid '
        'where role_id = @role_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'role_id': roleId,
          'updated_by': updatedByUserId,
        },
      );
    });
  }

  static RoleRecord _projectRow(Map<String, Object?> row) {
    return RoleRecord(
      roleId: row['role_id'] as String,
      operatorId: row['operator_id'] as String?,
      roleKey: row['role_key'] as String,
      displayName: row['display_name'] as String,
      description: (row['description'] as String?) ?? '',
      isSeeded: row['is_seeded'] as bool,
      isEditable: row['is_editable'] as bool,
      createdAt: row['created_at'] as DateTime,
      updatedAt: row['updated_at'] as DateTime,
      deletedAt: row['deleted_at'] as DateTime?,
    );
  }
}
