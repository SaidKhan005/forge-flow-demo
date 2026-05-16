/// The current effective target profile for a restaurant.
///
/// Canonical runtime profile projected from the active TargetCycle.
/// One active profile exists per restaurant at any time.
///
/// Per-Daypart Targets V1 (Slice 1): in addition to whole-day scalar
/// fields (kept as a cover-weighted rollup cache), the profile now
/// carries a list of [ActiveTargetProfileDaypart] rows. Per-period
/// consumers (Shift daypart card, Variance Full Week Projection
/// non-closed rows, etc.) read through the [daypartFor] accessor.
///
/// Design Rules (per `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`):
///   1. Per-period values use period-scoped naming (`daypartTargetCPLH`,
///      etc.) so the type makes the scope obvious.
///   2. `null` (or an absent map entry) means "unavailable"; never use
///      `0` as a sentinel. Whole-day scalar fields preserve the existing
///      `0.0` divide-by-zero fallback for backward compatibility with
///      legacy consumers — flagged for follow-up. Per-period consumers
///      must check `daypartFor(...)` for null before reading.
library;

/// Per-period locked target stamps for a single service period.
///
/// Field naming uses the `daypart` prefix (Design Rule 1) so consumers
/// reading these values cannot accidentally substitute whole-day pool
/// scalars without changing the call site.
class ActiveTargetProfileDaypart {
  final String servicePeriodId;
  final double daypartTargetCPLH;
  final double daypartTargetSPLH;
  final double daypartTargetPPA;
  final double daypartOpzFloorCPLH;
  final double daypartOpzCeilingCPLH;

  const ActiveTargetProfileDaypart({
    required this.servicePeriodId,
    required this.daypartTargetCPLH,
    required this.daypartTargetSPLH,
    required this.daypartTargetPPA,
    required this.daypartOpzFloorCPLH,
    required this.daypartOpzCeilingCPLH,
  });

  Map<String, dynamic> toMap() => {
        'service_period_id': servicePeriodId,
        'daypart_target_cplh': daypartTargetCPLH,
        'daypart_target_splh': daypartTargetSPLH,
        'daypart_target_ppa': daypartTargetPPA,
        'daypart_opz_floor_cplh': daypartOpzFloorCPLH,
        'daypart_opz_ceiling_cplh': daypartOpzCeilingCPLH,
      };

  factory ActiveTargetProfileDaypart.fromMap(Map<String, dynamic> m) =>
      ActiveTargetProfileDaypart(
        servicePeriodId: m['service_period_id'] as String,
        daypartTargetCPLH: (m['daypart_target_cplh'] as num).toDouble(),
        daypartTargetSPLH: (m['daypart_target_splh'] as num).toDouble(),
        daypartTargetPPA: (m['daypart_target_ppa'] as num).toDouble(),
        daypartOpzFloorCPLH: (m['daypart_opz_floor_cplh'] as num).toDouble(),
        daypartOpzCeilingCPLH:
            (m['daypart_opz_ceiling_cplh'] as num).toDouble(),
      );
}

class ActiveTargetProfile {
  final String targetProfileId;
  final String restaurantId;
  final String sourceType; // e.g. cycle_recommended / cycle_manager_override
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final double fohWage;
  final double bohWage;
  final double opzFloorCPLH;
  final double opzCeilingCPLH;
  final double theoreticalFohLaborPct;
  final double theoreticalBohLaborPct;
  final double theoreticalLaborPct;
  final String builtAt;

  /// Per-period locked target rows. Empty when the cycle wrote no
  /// per-period child rows (e.g. Gap 42 insufficient-recommendation
  /// fallback — consumers read [daypartFor] which returns `null` and
  /// fall back to the whole-day pool fields above).
  final List<ActiveTargetProfileDaypart> dayparts;

  const ActiveTargetProfile({
    required this.targetProfileId,
    required this.restaurantId,
    required this.sourceType,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
    required this.theoreticalFohLaborPct,
    required this.theoreticalBohLaborPct,
    required this.theoreticalLaborPct,
    required this.builtAt,
    this.dayparts = const [],
  });

  /// Returns the per-period row for [servicePeriodId], or `null` when
  /// the cycle has no child row for that period (Gap 42 fallback path).
  ///
  /// Per Design Rule 2 the caller MUST handle null by falling back to
  /// the whole-day pool fields on the profile — never substitute `0`.
  ActiveTargetProfileDaypart? daypartFor(String servicePeriodId) {
    for (final d in dayparts) {
      if (d.servicePeriodId == servicePeriodId) return d;
    }
    return null;
  }

  /// Per-Daypart V1 (Slice 5): the per-period theoretical labor % for
  /// [servicePeriodId].
  ///
  /// Returns `null` when the cycle wrote no per-period row for the
  /// period (Gap 42 fallback path — Design Rule 2: missing means
  /// `null`, never a `0` sentinel). The caller is responsible for
  /// falling back to the whole-day [theoreticalLaborPct] pool field.
  ///
  /// Derived from the period row's rate targets and the profile's
  /// whole-day wages using the same canonical formula as [build]:
  ///   `fohPct = fohWage / (daypartTargetCPLH × daypartTargetPPA) × 100`
  ///   `bohPct = bohWage / daypartTargetSPLH × 100`
  /// Wages stay whole-day (Design Rule 5 / V1 deferral — there is no
  /// per-period wage variant); only the per-period rate targets differ
  /// from the pool. The `daypart`-prefixed name keeps Design Rule 1's
  /// scope-obvious contract: a caller cannot accidentally substitute
  /// the whole-day [theoreticalLaborPct] without changing the call
  /// site.
  ///
  /// Preserves the legacy divide-by-zero boundary from [build]
  /// (returns `0.0` for a degenerate period row whose `CPLH`/`PPA`/
  /// `SPLH` are non-positive) so this accessor matches the whole-day
  /// scalar's existing behaviour; the broader `0.0`-vs-`null` sentinel
  /// follow-up is tracked against `ActiveTargetProfile.build` and is
  /// out of scope here (read-only Slice 5, Design Rule 4).
  double? daypartTheoreticalLaborPctFor(String servicePeriodId) {
    final row = daypartFor(servicePeriodId);
    if (row == null) return null;
    final fohPct =
        (row.daypartTargetCPLH > 0 && row.daypartTargetPPA > 0)
            ? fohWage / (row.daypartTargetCPLH * row.daypartTargetPPA) * 100
            : 0.0;
    final bohPct = row.daypartTargetSPLH > 0
        ? bohWage / row.daypartTargetSPLH * 100
        : 0.0;
    return fohPct + bohPct;
  }

  /// Builds an [ActiveTargetProfile] from explicit source-of-truth inputs.
  ///
  /// This is the canonical constructor for live standards-authoring paths:
  /// callers supply benchmark rates, wages, OPZ bounds, and provenance
  /// explicitly, and this helper computes the split/theoretical labor
  /// percentages without touching bridge-era BaselineData.
  static ActiveTargetProfile build({
    required String restaurantId,
    required String sourceType,
    required double targetCPLH,
    required double targetSPLH,
    required double targetPPA,
    required double fohWage,
    required double bohWage,
    required double opzFloorCPLH,
    required double opzCeilingCPLH,
    String? targetProfileId,
    String? builtAt,
    List<ActiveTargetProfileDaypart> dayparts = const [],
  }) {
    final fohPct = (targetCPLH > 0 && targetPPA > 0)
        ? fohWage / (targetCPLH * targetPPA) * 100
        : 0.0;
    final bohPct = targetSPLH > 0 ? bohWage / targetSPLH * 100 : 0.0;

    return ActiveTargetProfile(
      targetProfileId: targetProfileId ?? '${restaurantId}_active',
      restaurantId: restaurantId,
      sourceType: sourceType,
      targetCPLH: targetCPLH,
      targetSPLH: targetSPLH,
      targetPPA: targetPPA,
      fohWage: fohWage,
      bohWage: bohWage,
      opzFloorCPLH: opzFloorCPLH,
      opzCeilingCPLH: opzCeilingCPLH,
      theoreticalFohLaborPct: fohPct,
      theoreticalBohLaborPct: bohPct,
      theoreticalLaborPct: fohPct + bohPct,
      builtAt: builtAt ?? DateTime.now().toUtc().toIso8601String(),
      dayparts: dayparts,
    );
  }

  Map<String, dynamic> toMap() => {
        'target_profile_id': targetProfileId,
        'restaurant_id': restaurantId,
        'source_type': sourceType,
        'target_cplh': targetCPLH,
        'target_splh': targetSPLH,
        'target_ppa': targetPPA,
        'foh_wage': fohWage,
        'boh_wage': bohWage,
        'opz_floor_cplh': opzFloorCPLH,
        'opz_ceiling_cplh': opzCeilingCPLH,
        'theoretical_foh_labor_pct': theoreticalFohLaborPct,
        'theoretical_boh_labor_pct': theoreticalBohLaborPct,
        'theoretical_labor_pct': theoreticalLaborPct,
        'built_at': builtAt,
        // Per-period rows are not persisted on the parent profile row
        // (they live in `active_target_profile_dayparts` once Slice 1
        // wires the repository). [toMap] / [fromMap] remain on the
        // parent row only for backward compatibility with the legacy
        // SQLite shape.
      };

  factory ActiveTargetProfile.fromMap(Map<String, dynamic> m) =>
      ActiveTargetProfile(
        targetProfileId: m['target_profile_id'] as String,
        restaurantId: m['restaurant_id'] as String,
        sourceType: m['source_type'] as String,
        targetCPLH: (m['target_cplh'] as num).toDouble(),
        targetSPLH: (m['target_splh'] as num).toDouble(),
        targetPPA: (m['target_ppa'] as num).toDouble(),
        fohWage: (m['foh_wage'] as num).toDouble(),
        bohWage: (m['boh_wage'] as num).toDouble(),
        opzFloorCPLH: (m['opz_floor_cplh'] as num).toDouble(),
        opzCeilingCPLH: (m['opz_ceiling_cplh'] as num).toDouble(),
        theoreticalFohLaborPct:
            (m['theoretical_foh_labor_pct'] as num).toDouble(),
        theoreticalBohLaborPct:
            (m['theoretical_boh_labor_pct'] as num).toDouble(),
        theoreticalLaborPct: (m['theoretical_labor_pct'] as num).toDouble(),
        builtAt: m['built_at'] as String,
      );

  /// Returns a copy of this profile with the provided per-period rows
  /// replacing the existing list. Used by the cycle write path's
  /// `_syncActiveTargetProfile` after the per-period rows are computed.
  ActiveTargetProfile withDayparts(List<ActiveTargetProfileDaypart> rows) =>
      ActiveTargetProfile(
        targetProfileId: targetProfileId,
        restaurantId: restaurantId,
        sourceType: sourceType,
        targetCPLH: targetCPLH,
        targetSPLH: targetSPLH,
        targetPPA: targetPPA,
        fohWage: fohWage,
        bohWage: bohWage,
        opzFloorCPLH: opzFloorCPLH,
        opzCeilingCPLH: opzCeilingCPLH,
        theoreticalFohLaborPct: theoreticalFohLaborPct,
        theoreticalBohLaborPct: theoreticalBohLaborPct,
        theoreticalLaborPct: theoreticalLaborPct,
        builtAt: builtAt,
        dayparts: rows,
      );

  // ── 7.55q.3: shared benchmark-target blended-wage seam ─────────────────
  //
  // Conformance Rule 2 (per `7.55q.1`): blended wage is a Benchmark-owned
  // target metric and must be derived from one shared seam, not
  // recomputed per surface. Both Benchmark (`_BaselineTargetsCard`) and
  // Variance WTD (`WeekData.theoreticalBlendedWage`) now read the same
  // formula from this class so they cannot drift.

  /// 7.55q.3: the canonical benchmark-target blended wage for the
  /// current active target state.
  ///
  /// Pure derived getter — wraps [computeTargetBlendedWage] with the
  /// profile's own rate inputs. Independent of demand volume
  /// (covers cancel out in the model-hour ratio).
  double get targetBlendedWage => computeTargetBlendedWage(
        targetCPLH: targetCPLH,
        targetSPLH: targetSPLH,
        targetPPA: targetPPA,
        fohWage: fohWage,
        bohWage: bohWage,
      );

  /// 7.55q.3: cover-independent benchmark-target blended wage formula.
  ///
  /// Substituting the model-hour expressions
  ///   `fohHours = covers / targetCPLH`
  ///   `bohHours = covers × targetPPA / targetSPLH`
  /// into the hour-weighted blended-wage formula
  ///   `(fohHours × fohWage + bohHours × bohWage) / (fohHours + bohHours)`
  /// makes `covers` cancel exactly. The result is purely a function
  /// of the rate inputs and wages — exactly the fields on
  /// `ActiveTargetProfile`.
  ///
  /// Returns 0.0 when [targetCPLH] or [targetSPLH] is non-positive
  /// (honest "no targets yet" boundary, no NaN / divide-by-zero).
  ///
  /// Static so consumers that do not have a profile in scope (e.g.
  /// `WeekData`, which has the target fields injected by
  /// `ShiftService` from the active profile) can call it directly
  /// without the seam diverging.
  static double computeTargetBlendedWage({
    required double targetCPLH,
    required double targetSPLH,
    required double targetPPA,
    required double fohWage,
    required double bohWage,
  }) {
    if (targetCPLH <= 0 || targetSPLH <= 0) return 0.0;
    final fohHourBasis = 1.0 / targetCPLH;
    final bohHourBasis = targetPPA / targetSPLH;
    final totalHourBasis = fohHourBasis + bohHourBasis;
    if (totalHourBasis <= 0) return 0.0;
    return (fohHourBasis * fohWage + bohHourBasis * bohWage) /
        totalHourBasis;
  }
}
