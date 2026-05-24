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

  /// DELETE one cap row, identified EITHER by [capId] (the 9.0Σ.g
  /// surrogate) OR by the full logical key `(operator_id, location_id,
  /// usage_class, staff_id, workflow_id)`. The org-unit axes are
  /// resolved against the operator's root `org_units` row exactly as
  /// [upsertCap] resolves them on write, so the delete targets the same
  /// "corp pays for corp scope" identity the admin pricing screen
  /// created. `is not distinct from` matches the
  /// `usage_caps_two_slot_uq` UNIQUE NULLS NOT DISTINCT semantics so a
  /// NULL `staff_id` / `workflow_id` ("all staff" / "all workflows")
  /// cap is matched correctly. Returns the number of rows deleted (0 or
  /// 1) so the proxy can return an idempotent no-op 200 when nothing
  /// matched.
  Future<int> deleteCap({
    required String operatorId,
    String? capId,
    String? billingOwnerOrgUnitId,
    String? scopedOrgUnitId,
    String? locationId,
    String? usageClass,
    String? staffId,
    String? workflowId,
    required String adminReason,
  }) {
    return withSystem<int>((exec) async {
      if (capId != null) {
        // Tenant-leading: operator_id is part of the surrogate PK
        // `(operator_id, cap_id)`, so scoping the delete to both keeps
        // cross-tenant misuse impossible even by cap_id.
        final rows = await exec.query(
          'delete from usage_caps '
          'where operator_id = @operator_id::uuid '
          'and cap_id = @cap_id::uuid '
          'returning cap_id::text as cap_id',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'cap_id': capId,
          },
        );
        return rows.length;
      }
      final rows = await exec.query(
        'delete from usage_caps '
        'where operator_id = @operator_id::uuid '
        'and billing_owner_org_unit_id = @billing_owner::uuid '
        'and scoped_org_unit_id = @scoped::uuid '
        'and location_id = @location_id::uuid '
        'and usage_class = @usage_class '
        'and staff_id is not distinct from @staff_id::uuid '
        'and workflow_id is not distinct from @workflow_id::uuid '
        'returning cap_id::text as cap_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'billing_owner': billingOwnerOrgUnitId,
          'scoped': scopedOrgUnitId,
          'location_id': locationId,
          'usage_class': usageClass,
          'staff_id': staffId,
          'workflow_id': workflowId,
        },
      );
      return rows.length;
    }, reason: adminReason);
  }

  /// Month-to-date spend per cap identity for one operator, LEFT JOINed
  /// to the matching `usage_caps` row. Rolls `usage_logs.cost_usd` up
  /// per `(location_id, usage_class, staff_id, workflow_id)` for
  /// `period_start = date_trunc('month', now())` — the identical
  /// SUM-for-period semantics the cap-enforcement `capStatusSelect`
  /// path uses (usage is upserted at finer dimensions per row; summing
  /// within the cap identity is what "spend vs cap" means). A FULL
  /// OUTER JOIN surfaces both caps with no usage yet (spend 0) and
  /// usage with no cap (cap null), so the admin bars are honest about
  /// each. Ordered deterministically for a stable render.
  Future<List<UsageCapSpendRow>> spendSummaryForOperator({
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<List<UsageCapSpendRow>>((exec) async {
      final rows = await exec.query(
        'with monthly_actuals as ('
        '  select '
        '    location_id, usage_class, staff_id, workflow_id, '
        '    sum(cost_usd) as monthly_used_usd '
        '  from usage_logs '
        '  where operator_id = @operator_id::uuid '
        "    and period_start = date_trunc('month', now()) "
        '  group by location_id, usage_class, staff_id, workflow_id'
        ') '
        'select '
        '  coalesce(c.location_id, a.location_id)::text as location_id, '
        '  coalesce(c.usage_class, a.usage_class) as usage_class, '
        '  coalesce(c.staff_id, a.staff_id)::text as staff_id, '
        '  coalesce(c.workflow_id, a.workflow_id)::text as workflow_id, '
        '  c.cap_id::text as cap_id, '
        '  c.monthly_cap_usd as monthly_cap_usd, '
        '  c.per_invocation_cap_usd as per_invocation_cap_usd, '
        '  coalesce(a.monthly_used_usd, 0) as monthly_used_usd '
        'from usage_caps c '
        'full outer join monthly_actuals a '
        '  on a.location_id = c.location_id '
        '  and a.usage_class = c.usage_class '
        '  and a.staff_id is not distinct from c.staff_id '
        '  and a.workflow_id is not distinct from c.workflow_id '
        'where c.operator_id = @operator_id::uuid '
        '   or c.operator_id is null '
        'order by location_id asc nulls last, usage_class asc nulls last',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return <UsageCapSpendRow>[
        for (final row in rows) _capSpendRowFromMap(row),
      ];
    }, reason: adminReason);
  }
}

/// One row of the month-to-date spend-summary: a cap identity, the
/// rolled-up `monthly_used_usd`, and (when a cap is set) its
/// `monthly_cap_usd` / `per_invocation_cap_usd`. [monthlyCapUsd] is
/// null when usage exists for an identity with no cap row, so the admin
/// bar shows the honest empty sentinel instead of a phantom \$0 cap.
class UsageCapSpendRow {
  const UsageCapSpendRow({
    required this.locationId,
    required this.usageClass,
    required this.staffId,
    required this.workflowId,
    required this.capId,
    required this.monthlyCapUsd,
    required this.perInvocationCapUsd,
    required this.monthlyUsedUsd,
  });

  final String locationId;
  final String usageClass;
  final String? staffId;
  final String? workflowId;
  final String? capId;
  final double? monthlyCapUsd;
  final double? perInvocationCapUsd;
  final double monthlyUsedUsd;

  Map<String, Object?> toJson() => <String, Object?>{
    'location_id': locationId,
    'usage_class': usageClass,
    'staff_id': staffId,
    'workflow_id': workflowId,
    'cap_id': capId,
    'monthly_cap_usd': monthlyCapUsd,
    'per_invocation_cap_usd': perInvocationCapUsd,
    'monthly_used_usd': monthlyUsedUsd,
  };
}

UsageCapSpendRow _capSpendRowFromMap(PostgresRow row) {
  return UsageCapSpendRow(
    locationId: row['location_id']! as String,
    usageClass: row['usage_class']! as String,
    staffId: row['staff_id'] as String?,
    workflowId: row['workflow_id'] as String?,
    capId: row['cap_id'] as String?,
    monthlyCapUsd: row['monthly_cap_usd'] == null
        ? null
        : _asDouble(row['monthly_cap_usd']),
    perInvocationCapUsd: row['per_invocation_cap_usd'] == null
        ? null
        : _asDouble(row['per_invocation_cap_usd']),
    monthlyUsedUsd: _asDouble(row['monthly_used_usd']),
  );
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
