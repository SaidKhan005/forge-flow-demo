// Phase 11A.2 — UsageCapsRepository.
//
// Persistence layer for the cloud-foundation `usage_caps` table from
// `db/migrations/202604250005_advisor_cloud_foundation.sql` plus the
// 9.0Σ.g three-step migration:
//
//   * `..._a_..._add` — adds nullable `billing_owner_org_unit_id`,
//     `scoped_org_unit_id`, `staff_id`, `workflow_id` columns.
//   * `..._b_..._backfill` — populates the org-unit columns from the
//     operator's root org_unit row.
//   * `..._c_..._constraint_flip` — SET NOT NULL on the org-unit
//     columns, drops the legacy `(operator_id, location_id,
//     usage_class)` primary key, attaches a tenant-leading surrogate
//     PK on `(operator_id, cap_id)`, and adds
//     `usage_caps_two_slot_uq` (UNIQUE NULLS NOT DISTINCT) on the
//     locked logical key
//     `(operator_id, billing_owner_org_unit_id, scoped_org_unit_id,
//      location_id, staff_id, workflow_id, usage_class)`.
//
// This repository targets the post-flip schema: the upsert SQL writes
// the org-unit columns and uses ON CONFLICT ON CONSTRAINT
// `usage_caps_two_slot_uq` so NULL `staff_id` / `workflow_id` rows
// collide on the cap identity (UNIQUE NULLS NOT DISTINCT).
//
// The admin pricing console reads/writes caps across all operators
// (the admin browses the entire fleet, not one tenant), so every
// statement runs through `withSystem` with a non-blank [adminReason]
// string the audit marker carries via
// `app.bypass_rls_audit = 'system:<reason>'`.
//
// All writes carry the operator's UUID + the actor user ID so the
// cloud-foundation composite-FK chain keeps cross-tenant misuse
// impossible at the database layer and `created_by` / `updated_by`
// audit columns are populated.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

class UsageCapsRepository extends OperatorScopedRepository {
  UsageCapsRepository(super.tenantWrapper);

  static const String _selectColumns =
      'cap_id::text as cap_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'usage_class, '
      'monthly_cap_usd, '
      'per_invocation_cap_usd, '
      'staff_id::text as staff_id, '
      'workflow_id::text as workflow_id, '
      'billing_owner_org_unit_id::text as billing_owner_org_unit_id, '
      'scoped_org_unit_id::text as scoped_org_unit_id, '
      'created_by::text as created_by, '
      'updated_by::text as updated_by, '
      'created_at, updated_at';

  /// SELECT every cap row across every operator. The pricing-admin
  /// console groups by operator after this returns.
  Future<List<UsageCapAdminRow>> listAllCaps({
    required String adminReason,
  }) {
    return withSystem<List<UsageCapAdminRow>>((exec) async {
      final rows = await exec.query(
        'select $_selectColumns from usage_caps '
        'order by operator_id asc, location_id asc, usage_class asc',
      );
      return <UsageCapAdminRow>[
        for (final row in rows) _capAdminRowFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// SELECT the cap rows for one operator.
  Future<List<UsageCapAdminRow>> listForOperator({
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<List<UsageCapAdminRow>>((exec) async {
      final rows = await exec.query(
        'select $_selectColumns from usage_caps '
        'where operator_id = @operator_id::uuid '
        'order by location_id asc, usage_class asc',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return <UsageCapAdminRow>[
        for (final row in rows) _capAdminRowFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// UPSERT one cap row keyed on the post-flip logical key
  /// `(operator_id, billing_owner_org_unit_id, scoped_org_unit_id,
  /// location_id, staff_id, workflow_id, usage_class)`. The conflict
  /// target is the named UNIQUE NULLS NOT DISTINCT constraint
  /// `usage_caps_two_slot_uq` so NULL `staff_id` / `workflow_id`
  /// rows still collide on the cap identity (one "all-staff" /
  /// "all-workflow" cap per scope).
  ///
  /// `billingOwnerOrgUnitId` and `scopedOrgUnitId` are required after
  /// 9.0Σ.g step c (`SET NOT NULL`). The admin pricing screen passes
  /// the operator's root org_unit id for both axes (corp pays for
  /// corp scope); future surfaces can pass distinct ids when corp /
  /// sub-brand billing splits are wired.
  ///
  /// The `created_by` column is preserved on conflict and `updated_by`
  /// is rewritten to [actorUserId] so the audit trail tracks the
  /// latest admin actor without losing the original creator.
  Future<UsageCapAdminRow> upsertCap({
    required String operatorId,
    required String billingOwnerOrgUnitId,
    required String scopedOrgUnitId,
    required String locationId,
    required String usageClass,
    required double monthlyCapUsd,
    required double perInvocationCapUsd,
    String? staffId,
    String? workflowId,
    required String actorUserId,
    required String adminReason,
  }) {
    return withSystem<UsageCapAdminRow>((exec) async {
      final rows = await exec.query(
        'insert into usage_caps ('
        'operator_id, '
        'billing_owner_org_unit_id, scoped_org_unit_id, '
        'location_id, usage_class, '
        'monthly_cap_usd, per_invocation_cap_usd, '
        'staff_id, workflow_id, '
        'created_by, updated_by'
        ') values ('
        '@operator_id::uuid, '
        '@billing_owner::uuid, @scoped::uuid, '
        '@location_id::uuid, @usage_class, '
        '@monthly_cap_usd, @per_invocation_cap_usd, '
        '@staff_id::uuid, @workflow_id::uuid, '
        '@actor::uuid, @actor::uuid'
        ') '
        'on conflict on constraint usage_caps_two_slot_uq do update set '
        'monthly_cap_usd = excluded.monthly_cap_usd, '
        'per_invocation_cap_usd = excluded.per_invocation_cap_usd, '
        'updated_by = excluded.updated_by, '
        'updated_at = now() '
        'returning $_selectColumns',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'billing_owner': billingOwnerOrgUnitId,
          'scoped': scopedOrgUnitId,
          'location_id': locationId,
          'usage_class': usageClass,
          'monthly_cap_usd': monthlyCapUsd,
          'per_invocation_cap_usd': perInvocationCapUsd,
          'staff_id': staffId,
          'workflow_id': workflowId,
          'actor': actorUserId,
        },
      );
      if (rows.isEmpty) {
        throw StateError('usage_caps upsert returned no rows');
      }
      return _capAdminRowFromMap(rows.single);
    }, reason: adminReason);
  }
}

class UsageCapAdminRow {
  const UsageCapAdminRow({
    required this.capId,
    required this.operatorId,
    required this.locationId,
    required this.usageClass,
    required this.monthlyCapUsd,
    required this.perInvocationCapUsd,
    required this.staffId,
    required this.workflowId,
    required this.billingOwnerOrgUnitId,
    required this.scopedOrgUnitId,
    required this.createdBy,
    required this.updatedBy,
    required this.createdAt,
    required this.updatedAt,
  });

  final String capId;
  final String operatorId;
  final String locationId;
  final String usageClass;
  final double monthlyCapUsd;
  final double perInvocationCapUsd;
  final String? staffId;
  final String? workflowId;
  final String billingOwnerOrgUnitId;
  final String scopedOrgUnitId;
  final String? createdBy;
  final String? updatedBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'cap_id': capId,
    'operator_id': operatorId,
    'location_id': locationId,
    'usage_class': usageClass,
    'monthly_cap_usd': monthlyCapUsd,
    'per_invocation_cap_usd': perInvocationCapUsd,
    'staff_id': staffId,
    'workflow_id': workflowId,
    'billing_owner_org_unit_id': billingOwnerOrgUnitId,
    'scoped_org_unit_id': scopedOrgUnitId,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

UsageCapAdminRow _capAdminRowFromMap(PostgresRow row) {
  return UsageCapAdminRow(
    capId: row['cap_id']! as String,
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    usageClass: row['usage_class']! as String,
    monthlyCapUsd: _asDouble(row['monthly_cap_usd']),
    perInvocationCapUsd: _asDouble(row['per_invocation_cap_usd']),
    staffId: row['staff_id'] as String?,
    workflowId: row['workflow_id'] as String?,
    billingOwnerOrgUnitId: row['billing_owner_org_unit_id']! as String,
    scopedOrgUnitId: row['scoped_org_unit_id']! as String,
    createdBy: row['created_by'] as String?,
    updatedBy: row['updated_by'] as String?,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

double _asDouble(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
