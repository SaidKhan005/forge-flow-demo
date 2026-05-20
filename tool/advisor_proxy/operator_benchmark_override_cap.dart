import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';

/// Wave 2 RP-15 — manager-once cap policy for benchmark overrides.
///
/// The benchmark override surface (operator-web Benchmarks screen +
/// proxy `/v1/operator/benchmarks/overrides` routes) lets owners and
/// managers re-anchor CPLH / SPLH / PPA against the target cycle. RP-15
/// adds two guardrails on top of the existing `forgeflow.baseline.override`
/// permission gate:
///
///   1. Manager-tier roles ("Location Manager", "Supervisor") may set at
///      most one override per calendar month. The second attempt is
///      rejected with HTTP 409 `manager_override_cap_reached`. The cap
///      resets at the first of the month in UTC.
///   2. Admin-tier roles ("Owner", "General Manager", "F&F Super Admin")
///      are uncapped — they own the override surface and can undo a
///      manager's override if they disagree (see admin-undo affordance
///      shipped on the operator-web admin screen).
///
/// The cap is enforced both server-side (in
/// `operator_benchmark_overrides_routes.dart`) and surfaced client-side
/// via `OperatorWebBenchmarksGateway.getCapStatus` so the operator sees
/// the remaining count before they tap Save. Per HP #2 the in-memory
/// demo gateway honors the same policy.
class BenchmarkOverrideCapPolicy {
  const BenchmarkOverrideCapPolicy({this.managerMonthlyLimit = 1});

  /// Manager-tier role keys (location-scoped, post-R-2L). These users
  /// can edit benchmark overrides but are capped at one per calendar
  /// month. Verified against the R-2L Default Role Catalog v2 proposal
  /// (`docs/_indices/WAVE_2_R2L_DEFAULT_ROLE_CATALOG_V2_PROPOSAL.md`).
  static const Set<String> managerTierRoles = <String>{
    'location_manager',
    'supervisor',
  };

  /// Admin-tier role keys (business-wide, post-R-2L) plus the global
  /// F&F super admin. These users are uncapped and can undo a
  /// manager's override via the admin-undo affordance.
  static const Set<String> adminTierRoles = <String>{
    'operator_owner',
    'operator_admin',
    'operator_general_manager',
    'super_admin',
  };

  /// How many overrides a manager-tier user may set per calendar month.
  /// Operator-locked at 1 in 2026-05-14 RP-15 spec.
  final int managerMonthlyLimit;

  /// Returns the cap status for [actorUserId] given their [roles] and
  /// the operator's [overrides] history (current + closed rows reside
  /// in the same `benchmark_overrides` table; effective_from drives
  /// the month bucket).
  BenchmarkOverrideCapStatus evaluate({
    required String actorUserId,
    required Set<String> roles,
    required Iterable<BenchmarkOverrideCandidate> overrides,
    required DateTime now,
  }) {
    final tier = _tierFor(roles);
    if (tier == BenchmarkOverrideCapTier.admin) {
      return BenchmarkOverrideCapStatus(
        tier: tier,
        limit: -1, // unlimited
        used: 0,
        remaining: -1,
      );
    }
    if (tier == BenchmarkOverrideCapTier.none) {
      // Roles not in either tier set still get a cap of 0 — they can't
      // override at all. The route's role gate (`kOperatorWriteRoles`)
      // is the primary defense; this is belt-and-suspenders.
      return BenchmarkOverrideCapStatus(
        tier: tier,
        limit: managerMonthlyLimit,
        used: 0,
        remaining: 0,
      );
    }
    final used = overrides.where((row) {
      if (row.createdBy != actorUserId) return false;
      return _sameUtcMonth(row.effectiveFrom, now);
    }).length;
    final remaining = managerMonthlyLimit - used;
    return BenchmarkOverrideCapStatus(
      tier: tier,
      limit: managerMonthlyLimit,
      used: used,
      remaining: remaining < 0 ? 0 : remaining,
    );
  }

  BenchmarkOverrideCapTier _tierFor(Set<String> roles) {
    if (roles.any(adminTierRoles.contains)) {
      return BenchmarkOverrideCapTier.admin;
    }
    if (roles.any(managerTierRoles.contains)) {
      return BenchmarkOverrideCapTier.manager;
    }
    return BenchmarkOverrideCapTier.none;
  }

  static bool _sameUtcMonth(DateTime a, DateTime b) {
    final ua = a.toUtc();
    final ub = b.toUtc();
    return ua.year == ub.year && ua.month == ub.month;
  }
}

/// Outcome of [BenchmarkOverrideCapPolicy.evaluate]. The router emits
/// `remaining == 0` as HTTP 409; the operator-web Benchmarks screen
/// renders the remaining count as a hint and disables Save at zero.
class BenchmarkOverrideCapStatus {
  const BenchmarkOverrideCapStatus({
    required this.tier,
    required this.limit,
    required this.used,
    required this.remaining,
  });

  final BenchmarkOverrideCapTier tier;

  /// Override limit per calendar month. `-1` means unlimited (admin).
  final int limit;

  /// How many overrides this user has already set in the current
  /// calendar month. Always 0 for admins.
  final int used;

  /// How many more overrides the user may set this month. `-1` for
  /// admins (unlimited). Manager-tier users see `1` -> `0` after the
  /// first override.
  final int remaining;

  bool get isCapped =>
      tier == BenchmarkOverrideCapTier.manager && remaining <= 0;
  bool get isAdmin => tier == BenchmarkOverrideCapTier.admin;
  bool get isUnlimited => remaining < 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'tier': tier.wire,
        'limit': limit,
        'used': used,
        'remaining': remaining,
      };

  static BenchmarkOverrideCapStatus fromJson(Map<String, Object?> json) {
    return BenchmarkOverrideCapStatus(
      tier: BenchmarkOverrideCapTier.parse(
        (json['tier'] as String?) ?? 'none',
      ),
      limit: (json['limit'] as num?)?.toInt() ?? 0,
      used: (json['used'] as num?)?.toInt() ?? 0,
      remaining: (json['remaining'] as num?)?.toInt() ?? 0,
    );
  }
}

enum BenchmarkOverrideCapTier {
  admin('admin'),
  manager('manager'),
  none('none');

  const BenchmarkOverrideCapTier(this.wire);

  final String wire;

  static BenchmarkOverrideCapTier parse(String raw) {
    return switch (raw) {
      'admin' => BenchmarkOverrideCapTier.admin,
      'manager' => BenchmarkOverrideCapTier.manager,
      _ => BenchmarkOverrideCapTier.none,
    };
  }
}
