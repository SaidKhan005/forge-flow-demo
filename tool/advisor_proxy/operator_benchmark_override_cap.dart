import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';

/// Historical RP-15 manager-once cap policy for benchmark override
/// status reads.
///
/// Legacy `/v1/operator/benchmarks/overrides` mutations are disabled;
/// mobile Baseline Manager selected-star writes are the only active
/// override path. This policy remains so the read-only cap-status route
/// can report the same tier/remaining shape to any cleanup or status
/// consumers without reopening legacy writes.
class BenchmarkOverrideCapPolicy {
  const BenchmarkOverrideCapPolicy({this.managerMonthlyLimit = 1});

  /// Manager-tier role keys (location-scoped, post-R-2L). In the legacy
  /// cap-status response these users report a one-per-calendar-month
  /// budget, but the old write route itself is disabled.
  static const Set<String> managerTierRoles = <String>{
    'location_manager',
    'supervisor',
  };

  /// Admin-tier role keys (business-wide, post-R-2L) plus the global
  /// F&F super admin. The legacy cap-status response reports these
  /// users as uncapped.
  static const Set<String> adminTierRoles = <String>{
    'operator_owner',
    'operator_admin',
    'operator_general_manager',
    'super_admin',
  };

  /// Historical per-month budget shown by the legacy cap-status read.
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
      // Roles not in either tier set still report a cap of 0 in the
      // read-only compatibility envelope.
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

/// Outcome of [BenchmarkOverrideCapPolicy.evaluate] for the legacy
/// read-only cap-status response.
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

  /// Historical remaining budget for the current month. `-1` for
  /// admins (unlimited).
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
      tier: BenchmarkOverrideCapTier.parse((json['tier'] as String?) ?? 'none'),
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
