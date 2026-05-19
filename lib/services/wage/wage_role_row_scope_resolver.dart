// GAP B2 — wage-row hierarchy-scope resolver (HP #11 wage slice).
//
// Mirrors lib/services/baseline/benchmark_override_resolver.dart EXACTLY
// in shape: resolve a single effective wage value for a (location,
// labor bucket, role) by walking lowest configured scope first —
// location override → nearest-first org-unit ancestors → operator-wide
// (Business) default → fallback. Returns the resolved value plus the
// source scope type + a plain-English source label so the Wage
// Authority screen can render the HP #11 selected / inherited /
// effective triple per row.
//
// Schema anchor: db/migrations/202605191200_wage_role_rows_hierarchy_
// scope_refresh.sql adds scope_type / org_unit_id /
// inherited_from_scope_id to public.wage_role_rows. A wage row's
// natural key is (operator_id, restaurant_id, role_name, labor_bucket)
// per the role-unique index; the resolver groups candidates by
// (role_name, labor_bucket) the same way the benchmark resolver groups
// by metric_key.
//
// Side-effect surface: zero. Pure Dart, no I/O, no Flutter, no
// package:postgres. Ancestor traversal is NOT re-implemented here — the
// caller supplies the nearest-first ancestor org-unit id list (built
// from lib/services/hierarchy/inheritance_descendant_cache.dart /
// OrgUnitsRepository the same way a future benchmark consumer would).

/// Hierarchy scope a wage row is configured at. Wire values match
/// `wage_role_rows.scope_type` (and the benchmark_overrides
/// vocabulary): `operator_wide` is shown to operators as "Business".
enum WageRoleRowScopeType {
  operatorWide('operator_wide'),
  orgUnit('org_unit'),
  location('location'),
  fallback('fallback');

  const WageRoleRowScopeType(this.wire);

  final String wire;

  static WageRoleRowScopeType parse(String raw) {
    return switch (raw) {
      'operator_wide' ||
      'business' ||
      'operator' => WageRoleRowScopeType.operatorWide,
      'org_unit' => WageRoleRowScopeType.orgUnit,
      'location' => WageRoleRowScopeType.location,
      'fallback' => WageRoleRowScopeType.fallback,
      _ => throw ArgumentError.value(raw, 'scope_type', 'unsupported scope'),
    };
  }
}

/// One wage row in scope-resolution candidate form. Carries enough of
/// the `wage_role_rows` projection for the resolver to pick the lowest
/// configured scope. `effectiveAt` is the tie-breaker between two rows
/// at the same scope (latest wins), mirroring the benchmark resolver's
/// `effectiveFrom` tie-break.
class WageRoleRowScopeCandidate {
  const WageRoleRowScopeCandidate({
    required this.wageRoleRowId,
    required this.operatorId,
    required this.scopeType,
    required this.orgUnitId,
    required this.locationId,
    required this.roleName,
    required this.laborBucket,
    required this.hourlyRate,
    required this.weightedHours,
    required this.effectiveAt,
    required this.isActive,
    this.sourceLabel,
  });

  final String wageRoleRowId;
  final String operatorId;
  final WageRoleRowScopeType scopeType;
  final String? orgUnitId;
  final String? locationId;
  final String roleName;

  /// `'foh' | 'boh' | 'manager'`.
  final String laborBucket;
  final double hourlyRate;
  final double weightedHours;
  final DateTime effectiveAt;
  final bool isActive;
  final String? sourceLabel;

  String get scopeId {
    return switch (scopeType) {
      WageRoleRowScopeType.operatorWide => operatorId,
      WageRoleRowScopeType.orgUnit => orgUnitId ?? operatorId,
      WageRoleRowScopeType.location => locationId ?? operatorId,
      WageRoleRowScopeType.fallback => operatorId,
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'wage_role_row_id': wageRoleRowId,
    'operator_id': operatorId,
    'scope_type': scopeType.wire,
    'org_unit_id': orgUnitId,
    'location_id': locationId,
    'role_name': roleName,
    'labor_bucket': laborBucket,
    'hourly_rate': hourlyRate,
    'weighted_hours': weightedHours,
    'effective_at': effectiveAt.toUtc().toIso8601String(),
    'is_active': isActive,
    if (sourceLabel != null) 'source_label': sourceLabel,
  };
}

/// Effective wage row after inheritance is walked. `inherited` is true
/// whenever the source scope is NOT the location the operator is
/// looking at (Business or an org-unit ancestor supplied the value),
/// matching the benchmark resolver's `inherited` semantics.
class WageRoleRowResolvedValue {
  const WageRoleRowResolvedValue({
    required this.roleName,
    required this.laborBucket,
    required this.hourlyRate,
    required this.weightedHours,
    required this.inherited,
    required this.sourceScopeType,
    required this.sourceScopeId,
    required this.sourceLabel,
    required this.wageRoleRowId,
  });

  factory WageRoleRowResolvedValue.fromCandidate(
    WageRoleRowScopeCandidate candidate,
  ) {
    return WageRoleRowResolvedValue(
      roleName: candidate.roleName,
      laborBucket: candidate.laborBucket,
      hourlyRate: candidate.hourlyRate,
      weightedHours: candidate.weightedHours,
      inherited: candidate.scopeType != WageRoleRowScopeType.location,
      sourceScopeType: candidate.scopeType,
      sourceScopeId: candidate.scopeId,
      sourceLabel: candidate.sourceLabel ?? _labelFor(candidate.scopeType),
      wageRoleRowId: candidate.wageRoleRowId,
    );
  }

  final String roleName;
  final String laborBucket;
  final double hourlyRate;
  final double weightedHours;
  final bool inherited;
  final WageRoleRowScopeType sourceScopeType;
  final String sourceScopeId;
  final String sourceLabel;

  /// Null when the effective value is the fallback (no override at any
  /// scope) — there is no backing row to point at.
  final String? wageRoleRowId;

  Map<String, Object?> toJson() => <String, Object?>{
    'role_name': roleName,
    'labor_bucket': laborBucket,
    'hourly_rate': hourlyRate,
    'weighted_hours': weightedHours,
    'inherited': inherited,
    'source_scope_type': sourceScopeType.wire,
    'source_scope_id': sourceScopeId,
    'source_label': sourceLabel,
    'wage_role_row_id': wageRoleRowId,
  };

  static String _labelFor(WageRoleRowScopeType type) {
    return switch (type) {
      WageRoleRowScopeType.operatorWide => 'Business',
      WageRoleRowScopeType.orgUnit => 'Org unit',
      WageRoleRowScopeType.location => 'Location',
      WageRoleRowScopeType.fallback => 'No wage set',
    };
  }
}

/// Resolves the effective wage row for a (role, labor bucket) at a
/// location by walking the configured scopes lowest-first. Same shape
/// + same resolution order as [BenchmarkOverrideResolver].
class WageRoleRowScopeResolver {
  const WageRoleRowScopeResolver();

  WageRoleRowResolvedValue resolve({
    required String roleName,
    required String laborBucket,
    required String operatorId,
    required List<String> ancestorOrgUnitIdsNearestFirst,
    required String? locationId,
    required List<WageRoleRowScopeCandidate> candidates,
    double? fallbackHourlyRate,
    double? fallbackWeightedHours,
  }) {
    final matching = candidates
        .where(
          (candidate) =>
              candidate.operatorId == operatorId &&
              candidate.roleName == roleName &&
              candidate.laborBucket == laborBucket &&
              candidate.isActive,
        )
        .toList(growable: false);

    final locationMatch = locationId == null
        ? null
        : _latest(
            matching.where(
              (candidate) =>
                  candidate.scopeType == WageRoleRowScopeType.location &&
                  candidate.locationId == locationId,
            ),
          );
    if (locationMatch != null) {
      return WageRoleRowResolvedValue.fromCandidate(locationMatch);
    }

    for (final orgUnitId in ancestorOrgUnitIdsNearestFirst) {
      final orgMatch = _latest(
        matching.where(
          (candidate) =>
              candidate.scopeType == WageRoleRowScopeType.orgUnit &&
              candidate.orgUnitId == orgUnitId,
        ),
      );
      if (orgMatch != null) {
        return WageRoleRowResolvedValue.fromCandidate(orgMatch);
      }
    }

    final operatorMatch = _latest(
      matching.where(
        (candidate) => candidate.scopeType == WageRoleRowScopeType.operatorWide,
      ),
    );
    if (operatorMatch != null) {
      return WageRoleRowResolvedValue.fromCandidate(operatorMatch);
    }

    return WageRoleRowResolvedValue(
      roleName: roleName,
      laborBucket: laborBucket,
      hourlyRate: fallbackHourlyRate ?? 0.0,
      weightedHours: fallbackWeightedHours ?? 0.0,
      inherited: false,
      sourceScopeType: WageRoleRowScopeType.fallback,
      sourceScopeId: operatorId,
      sourceLabel: 'No wage set',
      wageRoleRowId: null,
    );
  }

  WageRoleRowScopeCandidate? _latest(
    Iterable<WageRoleRowScopeCandidate> candidates,
  ) {
    WageRoleRowScopeCandidate? best;
    for (final candidate in candidates) {
      if (best == null || candidate.effectiveAt.isAfter(best.effectiveAt)) {
        best = candidate;
      }
    }
    return best;
  }
}
