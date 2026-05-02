// Phase 11A.1 — OperatorAdminsRepository.
//
// Persistence layer for the cloud-foundation `operator_admins` table
// from `db/migrations/202604250005_advisor_cloud_foundation.sql`.
// Maps `(user_id, operator_id)` admin grants. Used by the F&F admin
// console during onboarding to attach a user to a freshly-created
// operator.
//
// Cross-tenant by design — the F&F super-admin lives outside the
// new operator's RLS policy when the row is being written. Every
// statement runs through `withSystem` with a non-blank
// [adminReason] string the audit marker carries via
// `app.bypass_rls_audit = 'system:<reason>'`.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

class OperatorAdminsRepository extends OperatorScopedRepository {
  OperatorAdminsRepository(super.tenantWrapper);

  /// SELECT every admin grant for one operator. Returns an empty
  /// list when the operator has no admins yet (newly-onboarded).
  Future<List<OperatorAdminGrantRow>> listForOperator({
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<List<OperatorAdminGrantRow>>((exec) async {
      final rows = await exec.query(
        'select user_id::text as user_id, '
        'operator_id::text as operator_id, '
        'is_super_admin, created_at, updated_at '
        'from operator_admins '
        'where operator_id = @operator_id::uuid '
        'order by created_at asc',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return <OperatorAdminGrantRow>[
        for (final row in rows) _adminGrantRowFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// Counts admin grants for every operator in one cross-tenant sweep.
  ///
  /// The Operators admin list only needs counts, not full grant rows. Keeping
  /// this as one `withSystem` transaction avoids an N+1 series of admin-pool
  /// borrows when staging has many operators.
  Future<Map<String, int>> countByOperator({required String adminReason}) {
    return withSystem<Map<String, int>>((exec) async {
      final rows = await exec.query(
        'select operator_id::text as operator_id, '
        'count(*)::int as admin_grant_count '
        'from operator_admins '
        'group by operator_id',
      );
      return <String, int>{
        for (final row in rows)
          row['operator_id']! as String: _toInt(row['admin_grant_count']),
      };
    }, reason: adminReason);
  }

  /// INSERT an admin grant. Idempotent via
  /// `ON CONFLICT (user_id, operator_id) DO UPDATE` so re-running
  /// the same assignment refreshes `updated_at`, `is_super_admin`,
  /// and `scope_type` without raising. Returns the resulting row.
  ///
  /// `scope_type` is required (NOT NULL) on the migrated schema
  /// (`db/migrations/202604250008_auth_schema_foundation.sql`) and
  /// must be one of `super_admin` / `ff_support` / `operator_owner`
  /// / `operator_manager`. Callers supply the value directly; the
  /// 11A.1 onboarding path uses `'super_admin'` when
  /// `is_super_admin` is true and `'operator_owner'` otherwise.
  Future<OperatorAdminGrantRow> upsertAdminGrant({
    required String userId,
    required String operatorId,
    required bool isSuperAdmin,
    required String scopeType,
    required String adminReason,
  }) {
    return withSystem<OperatorAdminGrantRow>((exec) async {
      final rows = await exec.query(
        'insert into operator_admins ('
        'user_id, operator_id, is_super_admin, scope_type'
        ') values ('
        '@user_id::uuid, @operator_id::uuid, @is_super_admin, @scope_type'
        ') '
        'on conflict (user_id, operator_id) do update set '
        'is_super_admin = excluded.is_super_admin, '
        'scope_type = excluded.scope_type, '
        'updated_at = now() '
        'returning user_id::text as user_id, '
        'operator_id::text as operator_id, '
        'is_super_admin, created_at, updated_at',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
          'is_super_admin': isSuperAdmin,
          'scope_type': scopeType,
        },
      );
      if (rows.isEmpty) {
        throw StateError('operator_admins upsert returned no rows');
      }
      return _adminGrantRowFromMap(rows.single);
    }, reason: adminReason);
  }

  /// DELETE an admin grant. Returns the affected-row count.
  Future<int> deleteAdminGrant({
    required String userId,
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<int>((exec) async {
      return exec.execute(
        'delete from operator_admins '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
        },
      );
    }, reason: adminReason);
  }
}

class OperatorAdminGrantRow {
  const OperatorAdminGrantRow({
    required this.userId,
    required this.operatorId,
    required this.isSuperAdmin,
    required this.createdAt,
    required this.updatedAt,
  });

  final String userId;
  final String operatorId;
  final bool isSuperAdmin;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'user_id': userId,
    'operator_id': operatorId,
    'is_super_admin': isSuperAdmin,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

OperatorAdminGrantRow _adminGrantRowFromMap(PostgresRow row) {
  return OperatorAdminGrantRow(
    userId: row['user_id']! as String,
    operatorId: row['operator_id']! as String,
    isSuperAdmin: row['is_super_admin'] == true,
    createdAt: _toDateTime(row['created_at']),
    updatedAt: _toDateTime(row['updated_at']),
  );
}

DateTime _toDateTime(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is String) return DateTime.parse(value).toUtc();
  throw StateError('operator_admins lookup returned a malformed timestamp');
}

int _toInt(Object? value) {
  if (value is int) return value;
  if (value is BigInt) return value.toInt();
  if (value is num) return value.toInt();
  if (value is String) return int.parse(value);
  throw StateError('operator_admins count returned a malformed count');
}
