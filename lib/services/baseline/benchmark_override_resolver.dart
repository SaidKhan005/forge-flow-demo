class BenchmarkOverrideResolver {
  const BenchmarkOverrideResolver();

  BenchmarkOverrideResolvedValue resolve({
    required String metricKey,
    required String operatorId,
    required List<String> ancestorOrgUnitIdsNearestFirst,
    required String? locationId,
    required List<BenchmarkOverrideCandidate> candidates,
    required double fallbackValue,
  }) {
    final matching = candidates
        .where(
          (candidate) =>
              candidate.operatorId == operatorId &&
              candidate.metricKey == metricKey &&
              candidate.isCurrent,
        )
        .toList(growable: false);
    final locationMatch = locationId == null
        ? null
        : _latest(
            matching.where(
              (candidate) =>
                  candidate.scopeType == BenchmarkOverrideScopeType.location &&
                  candidate.locationId == locationId,
            ),
          );
    if (locationMatch != null) {
      return BenchmarkOverrideResolvedValue.fromCandidate(locationMatch);
    }

    for (final orgUnitId in ancestorOrgUnitIdsNearestFirst) {
      final orgMatch = _latest(
        matching.where(
          (candidate) =>
              candidate.scopeType == BenchmarkOverrideScopeType.orgUnit &&
              candidate.orgUnitId == orgUnitId,
        ),
      );
      if (orgMatch != null) {
        return BenchmarkOverrideResolvedValue.fromCandidate(orgMatch);
      }
    }

    final operatorMatch = _latest(
      matching.where(
        (candidate) =>
            candidate.scopeType == BenchmarkOverrideScopeType.operatorWide,
      ),
    );
    if (operatorMatch != null) {
      return BenchmarkOverrideResolvedValue.fromCandidate(operatorMatch);
    }

    return BenchmarkOverrideResolvedValue(
      metricKey: metricKey,
      value: fallbackValue,
      inherited: false,
      sourceScopeType: BenchmarkOverrideScopeType.fallback,
      sourceScopeId: operatorId,
      sourceLabel: 'Target cycle',
      overrideId: null,
    );
  }

  BenchmarkOverrideCandidate? _latest(
    Iterable<BenchmarkOverrideCandidate> candidates,
  ) {
    BenchmarkOverrideCandidate? best;
    for (final candidate in candidates) {
      if (best == null ||
          candidate.effectiveFrom.isAfter(best.effectiveFrom)) {
        best = candidate;
      }
    }
    return best;
  }
}

enum BenchmarkOverrideScopeType {
  operatorWide('operator_wide'),
  orgUnit('org_unit'),
  location('location'),
  fallback('fallback');

  const BenchmarkOverrideScopeType(this.wire);

  final String wire;

  static BenchmarkOverrideScopeType parse(String raw) {
    return switch (raw) {
      'operator_wide' || 'business' || 'operator' =>
        BenchmarkOverrideScopeType.operatorWide,
      'org_unit' => BenchmarkOverrideScopeType.orgUnit,
      'location' => BenchmarkOverrideScopeType.location,
      'fallback' => BenchmarkOverrideScopeType.fallback,
      _ => throw ArgumentError.value(raw, 'scope_type', 'unsupported scope'),
    };
  }
}

class BenchmarkOverrideCandidate {
  const BenchmarkOverrideCandidate({
    required this.overrideId,
    required this.operatorId,
    required this.scopeType,
    required this.orgUnitId,
    required this.locationId,
    required this.metricKey,
    required this.value,
    required this.effectiveFrom,
    required this.effectiveUntil,
    required this.createdBy,
    this.sourceLabel,
  });

  final String overrideId;
  final String operatorId;
  final BenchmarkOverrideScopeType scopeType;
  final String? orgUnitId;
  final String? locationId;
  final String metricKey;
  final double value;
  final DateTime effectiveFrom;
  final DateTime? effectiveUntil;
  final String createdBy;
  final String? sourceLabel;

  bool get isCurrent => effectiveUntil == null;

  String get scopeId {
    return switch (scopeType) {
      BenchmarkOverrideScopeType.operatorWide => operatorId,
      BenchmarkOverrideScopeType.orgUnit => orgUnitId ?? operatorId,
      BenchmarkOverrideScopeType.location => locationId ?? operatorId,
      BenchmarkOverrideScopeType.fallback => operatorId,
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'override_id': overrideId,
    'operator_id': operatorId,
    'scope_type': scopeType.wire,
    'org_unit_id': orgUnitId,
    'location_id': locationId,
    'metric_key': metricKey,
    'override_value': value,
    'effective_from': effectiveFrom.toUtc().toIso8601String(),
    'effective_until': effectiveUntil?.toUtc().toIso8601String(),
    'created_by': createdBy,
    if (sourceLabel != null) 'source_label': sourceLabel,
  };
}

class BenchmarkOverrideResolvedValue {
  const BenchmarkOverrideResolvedValue({
    required this.metricKey,
    required this.value,
    required this.inherited,
    required this.sourceScopeType,
    required this.sourceScopeId,
    required this.sourceLabel,
    required this.overrideId,
  });

  factory BenchmarkOverrideResolvedValue.fromCandidate(
    BenchmarkOverrideCandidate candidate,
  ) {
    return BenchmarkOverrideResolvedValue(
      metricKey: candidate.metricKey,
      value: candidate.value,
      inherited: candidate.scopeType != BenchmarkOverrideScopeType.location,
      sourceScopeType: candidate.scopeType,
      sourceScopeId: candidate.scopeId,
      sourceLabel: candidate.sourceLabel ?? _labelFor(candidate.scopeType),
      overrideId: candidate.overrideId,
    );
  }

  final String metricKey;
  final double value;
  final bool inherited;
  final BenchmarkOverrideScopeType sourceScopeType;
  final String sourceScopeId;
  final String sourceLabel;
  final String? overrideId;

  Map<String, Object?> toJson() => <String, Object?>{
    'metric_key': metricKey,
    'value': value,
    'inherited': inherited,
    'source_scope_type': sourceScopeType.wire,
    'source_scope_id': sourceScopeId,
    'source_label': sourceLabel,
    'override_id': overrideId,
  };

  static String _labelFor(BenchmarkOverrideScopeType type) {
    return switch (type) {
      BenchmarkOverrideScopeType.operatorWide => 'Business',
      BenchmarkOverrideScopeType.orgUnit => 'Org unit',
      BenchmarkOverrideScopeType.location => 'Location',
      BenchmarkOverrideScopeType.fallback => 'Target cycle',
    };
  }
}
