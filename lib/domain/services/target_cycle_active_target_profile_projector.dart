/// Pure projector: [TargetCycle] -> [ActiveTargetProfile].
///
/// No persistence, no side effects. Deterministic projection of the
/// cycle's locked standards into the runtime profile format that
/// existing consumers read.
///
/// Phase 7.55l.4a: projection only — consumer migration comes later.
library;

import '../models/active_target_profile.dart';
import '../models/target_cycle.dart';
import '../models/target_cycle_source.dart';

class TargetCycleActiveTargetProfileProjector {
  const TargetCycleActiveTargetProfileProjector._();

  /// Projects a [TargetCycle] to an [ActiveTargetProfile].
  ///
  /// Maps all standards fields directly. Derives `sourceType` from the
  /// cycle source. Computes theoretical labor percentages using the
  /// standard formulas.
  static ActiveTargetProfile project(TargetCycle cycle) {
    final fohPct = (cycle.targetCPLH > 0 && cycle.targetPPA > 0)
        ? cycle.fohWage / (cycle.targetCPLH * cycle.targetPPA) * 100
        : 0.0;
    final bohPct =
        cycle.targetSPLH > 0 ? cycle.bohWage / cycle.targetSPLH * 100 : 0.0;

    return ActiveTargetProfile(
      targetProfileId: '${cycle.restaurantId}_active',
      restaurantId: cycle.restaurantId,
      sourceType: _sourceType(cycle.source),
      targetCPLH: cycle.targetCPLH,
      targetSPLH: cycle.targetSPLH,
      targetPPA: cycle.targetPPA,
      fohWage: cycle.fohWage,
      bohWage: cycle.bohWage,
      opzFloorCPLH: cycle.opzFloorCPLH,
      opzCeilingCPLH: cycle.opzCeilingCPLH,
      theoreticalFohLaborPct: fohPct,
      theoreticalBohLaborPct: bohPct,
      theoreticalLaborPct: fohPct + bohPct,
      builtAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  static String _sourceType(TargetCycleSource source) => switch (source) {
        TargetCycleSource.recommended => 'cycle_recommended',
        TargetCycleSource.managerOverride => 'cycle_manager_override',
        TargetCycleSource.adminReplacement => 'cycle_admin_replacement',
      };
}
