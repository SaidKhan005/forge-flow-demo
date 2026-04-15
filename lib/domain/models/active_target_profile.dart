/// The current effective target profile for a restaurant.
///
/// Canonical runtime profile projected from the active TargetCycle.
/// One active profile exists per restaurant at any time.
library;

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
  });

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
      builtAt: builtAt ?? DateTime.now().toIso8601String(),
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
