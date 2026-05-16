/// The locked 60-day standards cycle for a restaurant.
///
/// One active cycle exists per restaurant at any time.
/// Standards lock at cycle creation and do not drift until the cycle
/// expires or is replaced.
///
/// Phase 7.55l.1: contract only — persistence added in 7.55l.2.
///
/// Per-Daypart Targets V1 (Slice 1): the cycle now also carries a list
/// of [TargetCycleDaypart] rows (one per operator-configured service
/// period). The parent row's whole-day scalar fields (`targetCPLH`,
/// etc.) become the cover-weighted rollup of the per-period rows and
/// are recomputed inside the write path. Reads through this model are
/// non-breaking — legacy consumers that ignore [dayparts] still get the
/// rollup scalars.
library;

import 'target_cycle_source.dart';

/// Per-period locked standards inside a [TargetCycle].
///
/// One row per (cycle_id, service_period_id). Carries the period's
/// recommended CPLH/SPLH/PPA from `DaypartCohortStats` plus the
/// per-period OPZ band and a `coverCount` (per-period candidate cover
/// total at compute time, used for the cover-weighted whole-day pool
/// rollup).
class TargetCycleDaypart {
  final String servicePeriodId;
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final double opzFloorCPLH;
  final double opzCeilingCPLH;
  final int coverCount;

  const TargetCycleDaypart({
    required this.servicePeriodId,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
    required this.coverCount,
  });

  Map<String, dynamic> toMap() => {
        'service_period_id': servicePeriodId,
        'target_cplh': targetCPLH,
        'target_splh': targetSPLH,
        'target_ppa': targetPPA,
        'opz_floor_cplh': opzFloorCPLH,
        'opz_ceiling_cplh': opzCeilingCPLH,
        'cover_count': coverCount,
      };

  factory TargetCycleDaypart.fromMap(Map<String, dynamic> m) =>
      TargetCycleDaypart(
        servicePeriodId: m['service_period_id'] as String,
        targetCPLH: (m['target_cplh'] as num).toDouble(),
        targetSPLH: (m['target_splh'] as num).toDouble(),
        targetPPA: (m['target_ppa'] as num).toDouble(),
        opzFloorCPLH: (m['opz_floor_cplh'] as num).toDouble(),
        opzCeilingCPLH: (m['opz_ceiling_cplh'] as num).toDouble(),
        coverCount: (m['cover_count'] as num).toInt(),
      );
}

/// Cover-weighted whole-day pool computed from per-period
/// [TargetCycleDaypart] rows.
///
/// Per Design Rule 4: pool is derived from period rows inside the
/// cycle write path; no code path outside the write path is allowed to
/// mutate the parent pool fields directly. The pool-consistency audit
/// check (Slice 6) guards this invariant at read time.
///
/// Rollup math:
///   pooled_cplh = Σ(period.cover_count × period.target_cplh) / Σ(period.cover_count)
///   pooled_splh = same shape with target_splh
///   pooled_ppa  = same shape with target_ppa
///   pooled_opz_floor   = min over all period floors (union floor)
///   pooled_opz_ceiling = max over all period ceilings (union ceiling)
///
/// When every period has `cover_count == 0` the rollup falls back to
/// an unweighted mean so the writer still emits a stable scalar. When
/// the input list is empty the caller is responsible for supplying
/// fallback values (Gap 42 path uses `MeridianConfig`).
class TargetCycleDaypartPool {
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final double opzFloorCPLH;
  final double opzCeilingCPLH;

  const TargetCycleDaypartPool({
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
  });

  static TargetCycleDaypartPool fromDayparts(
    List<TargetCycleDaypart> dayparts,
  ) {
    if (dayparts.isEmpty) {
      throw ArgumentError(
        'TargetCycleDaypartPool.fromDayparts: dayparts must be non-empty '
        '(the Gap 42 fallback path skips per-period rows and writes '
        'MeridianConfig whole-day defaults directly; do not call this '
        'helper there).',
      );
    }
    final totalCovers = dayparts.fold<int>(0, (s, d) => s + d.coverCount);
    double cplh = 0;
    double splh = 0;
    double ppa = 0;
    if (totalCovers > 0) {
      for (final d in dayparts) {
        final w = d.coverCount / totalCovers;
        cplh += d.targetCPLH * w;
        splh += d.targetSPLH * w;
        ppa += d.targetPPA * w;
      }
    } else {
      // Zero covers across every period — unweighted mean keeps the
      // writer honest instead of dividing by zero.
      for (final d in dayparts) {
        cplh += d.targetCPLH;
        splh += d.targetSPLH;
        ppa += d.targetPPA;
      }
      final n = dayparts.length;
      cplh /= n;
      splh /= n;
      ppa /= n;
    }
    final opzFloor =
        dayparts.map((d) => d.opzFloorCPLH).reduce((a, b) => a < b ? a : b);
    final opzCeiling =
        dayparts.map((d) => d.opzCeilingCPLH).reduce((a, b) => a > b ? a : b);
    return TargetCycleDaypartPool(
      targetCPLH: cplh,
      targetSPLH: splh,
      targetPPA: ppa,
      opzFloorCPLH: opzFloor,
      opzCeilingCPLH: opzCeiling,
    );
  }
}

class TargetCycle {
  final String cycleId;
  final String restaurantId;
  final TargetCycleSource source;
  final String effectiveStart;
  final String effectiveEnd;
  final String calibrationWindowStart;
  final String calibrationWindowEnd;

  // Locked standards
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final double fohWage;
  final double bohWage;
  final double opzFloorCPLH;
  final double opzCeilingCPLH;

  // Once-per-cycle override tracking
  final bool managerOverrideUsed;
  final String? managerOverrideAt;
  final String? adminReplacedAt;

  final String createdAt;
  final String? deactivatedAt;

  /// Per-period locked standards. Empty when the cycle was written
  /// under the Gap 42 insufficient-recommendation fallback path
  /// (operator decision 2026-05-15: leave per-period child table
  /// empty; read layer falls back to the parent whole-day pool).
  final List<TargetCycleDaypart> dayparts;

  const TargetCycle({
    required this.cycleId,
    required this.restaurantId,
    required this.source,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.calibrationWindowStart,
    required this.calibrationWindowEnd,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
    this.managerOverrideUsed = false,
    this.managerOverrideAt,
    this.adminReplacedAt,
    required this.createdAt,
    this.deactivatedAt,
    this.dayparts = const [],
  });

  /// Returns the per-period row for [servicePeriodId], or `null` when
  /// no child row exists (Gap 42 fallback). Per Design Rule 2 the caller
  /// must handle null by falling back to the whole-day pool fields on
  /// the cycle — never substitute `0`.
  TargetCycleDaypart? daypartFor(String servicePeriodId) {
    for (final d in dayparts) {
      if (d.servicePeriodId == servicePeriodId) return d;
    }
    return null;
  }

  Map<String, dynamic> toMap() => {
    'cycle_id': cycleId,
    'restaurant_id': restaurantId,
    'source': source.label,
    'effective_start': effectiveStart,
    'effective_end': effectiveEnd,
    'calibration_window_start': calibrationWindowStart,
    'calibration_window_end': calibrationWindowEnd,
    'target_cplh': targetCPLH,
    'target_splh': targetSPLH,
    'target_ppa': targetPPA,
    'foh_wage': fohWage,
    'boh_wage': bohWage,
    'opz_floor_cplh': opzFloorCPLH,
    'opz_ceiling_cplh': opzCeilingCPLH,
    'manager_override_used': managerOverrideUsed ? 1 : 0,
    'manager_override_at': managerOverrideAt,
    'admin_replaced_at': adminReplacedAt,
    'created_at': createdAt,
    'deactivated_at': deactivatedAt,
  };

  factory TargetCycle.fromMap(Map<String, dynamic> m) => TargetCycle(
    cycleId: _readString(m['cycle_id'])!,
    restaurantId: _readString(m['restaurant_id'])!,
    source: TargetCycleSource.fromLabel(_readString(m['source'])!),
    effectiveStart: _readString(m['effective_start'])!,
    effectiveEnd: _readString(m['effective_end'])!,
    calibrationWindowStart: _readString(m['calibration_window_start'])!,
    calibrationWindowEnd: _readString(m['calibration_window_end'])!,
    targetCPLH: _readDouble(m['target_cplh']),
    targetSPLH: _readDouble(m['target_splh']),
    targetPPA: _readDouble(m['target_ppa']),
    fohWage: _readDouble(m['foh_wage']),
    bohWage: _readDouble(m['boh_wage']),
    opzFloorCPLH: _readDouble(m['opz_floor_cplh']),
    opzCeilingCPLH: _readDouble(m['opz_ceiling_cplh']),
    managerOverrideUsed: _readBool(m['manager_override_used']),
    managerOverrideAt: _readString(m['manager_override_at']),
    adminReplacedAt: _readString(m['admin_replaced_at']),
    createdAt: _readString(m['created_at'])!,
    deactivatedAt: _readString(m['deactivated_at']),
  );

  TargetCycle copyWith({
    TargetCycleSource? source,
    double? targetCPLH,
    double? targetSPLH,
    double? targetPPA,
    double? fohWage,
    double? bohWage,
    double? opzFloorCPLH,
    double? opzCeilingCPLH,
    bool? managerOverrideUsed,
    String? managerOverrideAt,
    String? adminReplacedAt,
    String? deactivatedAt,
    List<TargetCycleDaypart>? dayparts,
  }) => TargetCycle(
    cycleId: cycleId,
    restaurantId: restaurantId,
    source: source ?? this.source,
    effectiveStart: effectiveStart,
    effectiveEnd: effectiveEnd,
    calibrationWindowStart: calibrationWindowStart,
    calibrationWindowEnd: calibrationWindowEnd,
    targetCPLH: targetCPLH ?? this.targetCPLH,
    targetSPLH: targetSPLH ?? this.targetSPLH,
    targetPPA: targetPPA ?? this.targetPPA,
    fohWage: fohWage ?? this.fohWage,
    bohWage: bohWage ?? this.bohWage,
    opzFloorCPLH: opzFloorCPLH ?? this.opzFloorCPLH,
    opzCeilingCPLH: opzCeilingCPLH ?? this.opzCeilingCPLH,
    managerOverrideUsed: managerOverrideUsed ?? this.managerOverrideUsed,
    managerOverrideAt: managerOverrideAt ?? this.managerOverrideAt,
    adminReplacedAt: adminReplacedAt ?? this.adminReplacedAt,
    createdAt: createdAt,
    deactivatedAt: deactivatedAt ?? this.deactivatedAt,
    dayparts: dayparts ?? this.dayparts,
  );
}

String? _readString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is DateTime) return value.toUtc().toIso8601String();
  return value.toString();
}

double _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.parse(value);
  throw StateError('TargetCycle numeric field was not parseable.');
}

bool _readBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return false;
}
