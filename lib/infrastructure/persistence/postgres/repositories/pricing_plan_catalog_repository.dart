// Plans & Limits V1 Phase 3 — PricingPlanCatalogRepository.
//
// Persistence layer for the GLOBAL F&F-wide `pricing_plan_catalog` table
// created in
// `db/migrations/202605241100_plans_and_limits_phase3_pricing_plan_catalog.sql`.
//
// IMPORTANT — this repository does NOT extend `OperatorScopedRepository`.
// Plan pricing is platform-wide (no operator_id column, no RLS policy):
// the prices are the same for every operator. Every read/write routes
// through `TenantTransactionWrapper.runAsSystem` so the connection
// elevates to `forge_admin` (BYPASSRLS) for the lifetime of the
// transaction. This mirrors `DefaultRoleCatalogVersionsRepository`
// exactly (the other GLOBAL catalog table).
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
//   * listPlans — SELECT every plan row.
//   * updatePlanPricing — UPDATE one plan's pricing fields by tier_key,
//     stamping updated_at + updated_by. Returns the updated row, or null
//     when the tier_key does not exist (so the proxy can 404 honestly).

import '../tenant_transaction.dart';

/// One `pricing_plan_catalog` row, projected for the admin pricing
/// screen. Nullable money / band fields are genuine SQL NULLs:
/// Enterprise has a null `monthlyUsd` (custom contract); no-seat plans
/// have null seat fields; self-serve / custom plans have null onboarding
/// bounds.
class PricingPlanCatalogRow {
  const PricingPlanCatalogRow({
    required this.tierKey,
    required this.monthlyUsd,
    required this.firstNSeats,
    required this.firstSeatUsd,
    required this.additionalSeatUsd,
    required this.onboardingMinUsd,
    required this.onboardingMaxUsd,
    required this.updatedAt,
    required this.updatedBy,
  });

  final String tierKey;
  final double? monthlyUsd;
  final int? firstNSeats;
  final double? firstSeatUsd;
  final double? additionalSeatUsd;
  final double? onboardingMinUsd;
  final double? onboardingMaxUsd;
  final DateTime? updatedAt;
  final String? updatedBy;

  Map<String, Object?> toJson() => <String, Object?>{
    'tier_key': tierKey,
    'monthly_usd': monthlyUsd,
    'first_n_seats': firstNSeats,
    'first_seat_usd': firstSeatUsd,
    'additional_seat_usd': additionalSeatUsd,
    'onboarding_min_usd': onboardingMinUsd,
    'onboarding_max_usd': onboardingMaxUsd,
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
    'updated_by': updatedBy,
  };
}

class PricingPlanCatalogRepository {
  PricingPlanCatalogRepository(this._tenantWrapper);

  final TenantTransactionWrapper _tenantWrapper;

  /// Returns every plan row. Ordered by `monthly_usd nulls last, tier_key`
  /// so the custom-contract plan (Enterprise, null monthly) sorts last and
  /// the rest ladder up deterministically.
  Future<List<PricingPlanCatalogRow>> listPlans({
    String reason = 'admin.pricing.plans_list',
  }) {
    return _tenantWrapper.runAsSystem<List<PricingPlanCatalogRow>>(
      (exec) async {
        final rows = await exec.query(
          'select tier_key, monthly_usd, first_n_seats, first_seat_usd, '
          'additional_seat_usd, onboarding_min_usd, onboarding_max_usd, '
          'updated_at, updated_by '
          'from public.pricing_plan_catalog '
          'order by monthly_usd asc nulls last, tier_key asc',
        );
        return <PricingPlanCatalogRow>[
          for (final row in rows) _rowFromMap(row),
        ];
      },
      reason: reason,
    );
  }

  /// Updates one plan's pricing fields by [tierKey], stamping
  /// `updated_at = now()` + `updated_by = updatedByUserId`. Returns the
  /// updated row, or null when no row matches [tierKey] (the proxy maps
  /// null to a 404). The CHECK constraint on `tier_key` is enforced by
  /// the DB; the proxy validates the key against the six allowed values
  /// before this call.
  Future<PricingPlanCatalogRow?> updatePlanPricing({
    required String tierKey,
    required double? monthlyUsd,
    required int? firstNSeats,
    required double? firstSeatUsd,
    required double? additionalSeatUsd,
    required double? onboardingMinUsd,
    required double? onboardingMaxUsd,
    required String updatedByUserId,
    String reason = 'admin.pricing.update_plan_pricing',
  }) {
    return _tenantWrapper.runAsSystem<PricingPlanCatalogRow?>(
      (exec) async {
        final rows = await exec.query(
          'update public.pricing_plan_catalog set '
          'monthly_usd = @monthly_usd, '
          'first_n_seats = @first_n_seats, '
          'first_seat_usd = @first_seat_usd, '
          'additional_seat_usd = @additional_seat_usd, '
          'onboarding_min_usd = @onboarding_min_usd, '
          'onboarding_max_usd = @onboarding_max_usd, '
          'updated_at = now(), '
          'updated_by = @updated_by '
          'where tier_key = @tier_key '
          'returning tier_key, monthly_usd, first_n_seats, first_seat_usd, '
          'additional_seat_usd, onboarding_min_usd, onboarding_max_usd, '
          'updated_at, updated_by',
          parameters: <String, Object?>{
            'tier_key': tierKey,
            'monthly_usd': monthlyUsd,
            'first_n_seats': firstNSeats,
            'first_seat_usd': firstSeatUsd,
            'additional_seat_usd': additionalSeatUsd,
            'onboarding_min_usd': onboardingMinUsd,
            'onboarding_max_usd': onboardingMaxUsd,
            'updated_by': updatedByUserId,
          },
        );
        if (rows.isEmpty) return null;
        return _rowFromMap(rows.single);
      },
      reason: reason,
    );
  }

  PricingPlanCatalogRow _rowFromMap(Map<String, Object?> row) {
    return PricingPlanCatalogRow(
      tierKey: row['tier_key']! as String,
      monthlyUsd: _asNullableDouble(row['monthly_usd']),
      firstNSeats: _asNullableInt(row['first_n_seats']),
      firstSeatUsd: _asNullableDouble(row['first_seat_usd']),
      additionalSeatUsd: _asNullableDouble(row['additional_seat_usd']),
      onboardingMinUsd: _asNullableDouble(row['onboarding_min_usd']),
      onboardingMaxUsd: _asNullableDouble(row['onboarding_max_usd']),
      updatedAt: _asNullableDateTime(row['updated_at']),
      updatedBy: row['updated_by'] as String?,
    );
  }

  static double? _asNullableDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is double) return raw;
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  static int? _asNullableInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static DateTime? _asNullableDateTime(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }
}
