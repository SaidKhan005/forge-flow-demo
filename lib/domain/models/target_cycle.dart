/// The locked 60-day standards cycle for a restaurant.
///
/// One active cycle exists per restaurant at any time.
/// Standards lock at cycle creation and do not drift until the cycle
/// expires or is replaced.
///
/// Phase 7.55l.1: contract only — persistence added in 7.55l.2.
library;

import 'target_cycle_source.dart';

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
  });

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
      };

  factory TargetCycle.fromMap(Map<String, dynamic> m) => TargetCycle(
        cycleId: m['cycle_id'] as String,
        restaurantId: m['restaurant_id'] as String,
        source: TargetCycleSource.fromLabel(m['source'] as String),
        effectiveStart: m['effective_start'] as String,
        effectiveEnd: m['effective_end'] as String,
        calibrationWindowStart: m['calibration_window_start'] as String,
        calibrationWindowEnd: m['calibration_window_end'] as String,
        targetCPLH: (m['target_cplh'] as num).toDouble(),
        targetSPLH: (m['target_splh'] as num).toDouble(),
        targetPPA: (m['target_ppa'] as num).toDouble(),
        fohWage: (m['foh_wage'] as num).toDouble(),
        bohWage: (m['boh_wage'] as num).toDouble(),
        opzFloorCPLH: (m['opz_floor_cplh'] as num).toDouble(),
        opzCeilingCPLH: (m['opz_ceiling_cplh'] as num).toDouble(),
        managerOverrideUsed: m['manager_override_used'] == 1,
        managerOverrideAt: m['manager_override_at'] as String?,
        adminReplacedAt: m['admin_replaced_at'] as String?,
        createdAt: m['created_at'] as String,
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
  }) =>
      TargetCycle(
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
      );
}
