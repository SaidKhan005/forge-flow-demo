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
  final String? deactivatedAt;

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
