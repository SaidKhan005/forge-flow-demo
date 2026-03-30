// Builds a TargetSnapshot from the current app configuration.
//
// Phase 3 (close-shift ingest path) will call this at shift-close time to
// lock in the targets that were in force for that shift.
// Phase 8 live adapters will supply their own configuration; this builder
// is the demo/current-baseline entry point only.

import '../../data/meridian_data.dart';
import '../models/target_snapshot.dart';

class TargetSnapshotBuilder {
  TargetSnapshotBuilder._();

  /// Creates a [TargetSnapshot] from the current [BaselineData] and
  /// [MeridianConfig] values.
  ///
  /// Use this during Phase 3 when closing a shift against the current
  /// restaurant configuration.  The resulting snapshot is then stored
  /// alongside the closed-shift record so historical analysis always uses
  /// the targets that were live at close time.
  static TargetSnapshot fromCurrentBaseline() {
    return TargetSnapshot(
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      fohWage: MeridianConfig.fohWage,
      bohWage: MeridianConfig.bohWage,
      opzFloorCPLH: MeridianConfig.opzFloorCPLH,
      opzCeilingCPLH: MeridianConfig.opzCeilingCPLH,
      theoreticalFohLaborPct: BaselineData.derivedFohTheoreticalLaborPct,
      theoreticalBohLaborPct: BaselineData.derivedBohTheoreticalLaborPct,
      theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
    );
  }
}
