// Plans & Limits V1 Phase 5a — FeatureEntitlementsRepository.
//
// Persistence layer for the GLOBAL F&F-wide `feature_entitlements` table
// created in
// `db/migrations/202605241700_plans_and_limits_phase5a_feature_entitlements.sql`.
//
// IMPORTANT — this repository does NOT extend `OperatorScopedRepository`.
// Plan entitlements are platform-wide (no operator_id column, no RLS
// policy): the matrix is the same for every operator on a given tier.
// Every read/write routes through `TenantTransactionWrapper.runAsSystem`
// so the connection elevates to `forge_admin` (BYPASSRLS) for the
// lifetime of the transaction. This mirrors `PricingPlanCatalogRepository`
// exactly (the Phase 3 GLOBAL plan-pricing catalog).
//
// CLAUDE.md authority:
//   * "Service-Layer Split" — `lib/infrastructure/persistence/postgres/`
//     is the only place raw `package:postgres` imports are allowed (this
//     repository touches Postgres only through the executor; no direct
//     `package:postgres` import is needed).
//   * "RLS-Ready Schema" — operator-scoped fact tables require RLS policy
//     stubs from creation. This table is NOT operator-scoped; the
//     migration explains why no RLS policy exists. The repository
//     enforces the admin-pool posture in code by routing every call
//     through `runAsSystem`.
//   * "Proxy & API Conventions" — admin writes are idempotent at the
//     proxy layer (Idempotency-Key + `admin_request_idempotency`). The
//     repository does NOT own idempotency — the proxy route handler does.
//
// Method surface:
//   * listEntitlements — SELECT every (tier, feature) row.
//   * setEntitlement — UPSERT one (tier_key, feature_slug) row's `enabled`
//     flag, stamping updated_at + updated_by. Inserts the row when the
//     pair has no seed row yet (a feature added after the seed), so the
//     proxy never 404s a known-but-unseeded pair. Returns the resulting
//     row. The proxy validates tier_key + feature_slug against the known
//     catalog before this call, so an unknown pair never reaches here.

import '../tenant_transaction.dart';

/// One `feature_entitlements` row, projected for the admin matrix editor.
class FeatureEntitlementRow {
  const FeatureEntitlementRow({
    required this.tierKey,
    required this.featureSlug,
    required this.enabled,
    required this.updatedAt,
    required this.updatedBy,
  });

  final String tierKey;
  final String featureSlug;
  final bool enabled;
  final DateTime? updatedAt;
  final String? updatedBy;

  Map<String, Object?> toJson() => <String, Object?>{
    'tier_key': tierKey,
    'feature_slug': featureSlug,
    'enabled': enabled,
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
    'updated_by': updatedBy,
  };
}

class FeatureEntitlementsRepository {
  FeatureEntitlementsRepository(this._tenantWrapper);

  final TenantTransactionWrapper _tenantWrapper;

  /// Returns every entitlement row. Ordered by `tier_key, feature_slug`
  /// so the admin matrix renders deterministically regardless of insert
  /// order.
  Future<List<FeatureEntitlementRow>> listEntitlements({
    String reason = 'admin.pricing.entitlements_list',
  }) {
    return _tenantWrapper.runAsSystem<List<FeatureEntitlementRow>>(
      (exec) async {
        final rows = await exec.query(
          'select tier_key, feature_slug, enabled, updated_at, updated_by '
          'from public.feature_entitlements '
          'order by tier_key asc, feature_slug asc',
        );
        return <FeatureEntitlementRow>[
          for (final row in rows) _rowFromMap(row),
        ];
      },
      reason: reason,
    );
  }

  /// Sets one `(tier_key, feature_slug)` pair's `enabled` flag, stamping
  /// `updated_at = now()` + `updated_by = updatedByUserId`. Uses an UPSERT
  /// so a (tier, feature) pair that was never seeded (a feature added
  /// after the migration) is created on first toggle rather than silently
  /// missing. Returns the resulting row.
  ///
  /// The proxy validates `tier_key` against the six allowed keys and
  /// `feature_slug` against the known catalog before this call, so the DB
  /// CHECK on `tier_key` is a backstop, not the primary gate.
  Future<FeatureEntitlementRow> setEntitlement({
    required String tierKey,
    required String featureSlug,
    required bool enabled,
    required String updatedByUserId,
    String reason = 'admin.pricing.set_entitlement',
  }) {
    return _tenantWrapper.runAsSystem<FeatureEntitlementRow>(
      (exec) async {
        final rows = await exec.query(
          'insert into public.feature_entitlements '
          '(tier_key, feature_slug, enabled, updated_at, updated_by) '
          'values (@tier_key, @feature_slug, @enabled, now(), @updated_by) '
          'on conflict (tier_key, feature_slug) do update set '
          'enabled = excluded.enabled, '
          'updated_at = now(), '
          'updated_by = excluded.updated_by '
          'returning tier_key, feature_slug, enabled, updated_at, updated_by',
          parameters: <String, Object?>{
            'tier_key': tierKey,
            'feature_slug': featureSlug,
            'enabled': enabled,
            'updated_by': updatedByUserId,
          },
        );
        return _rowFromMap(rows.single);
      },
      reason: reason,
    );
  }

  FeatureEntitlementRow _rowFromMap(Map<String, Object?> row) {
    return FeatureEntitlementRow(
      tierKey: row['tier_key']! as String,
      featureSlug: row['feature_slug']! as String,
      enabled: _asBool(row['enabled']),
      updatedAt: _asNullableDateTime(row['updated_at']),
      updatedBy: row['updated_by'] as String?,
    );
  }

  static bool _asBool(Object? raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) return raw == 't' || raw.toLowerCase() == 'true';
    return false;
  }

  static DateTime? _asNullableDateTime(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }
}
