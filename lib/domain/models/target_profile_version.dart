/// An immutable snapshot of a target profile at a point in time.
///
/// Created when a shift is closed, locking the targets that were in force.
/// Never mutated after creation.
library;

class TargetProfileVersion {
  final String targetProfileVersionId;
  final String targetProfileId;
  final String restaurantId;
  final String sourceType;
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
  final String createdAt;

  const TargetProfileVersion({
    required this.targetProfileVersionId,
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
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'target_profile_version_id': targetProfileVersionId,
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
        'created_at': createdAt,
      };

  factory TargetProfileVersion.fromMap(Map<String, dynamic> m) =>
      TargetProfileVersion(
        targetProfileVersionId: m['target_profile_version_id'] as String,
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
        createdAt: m['created_at'] as String,
      );
}
