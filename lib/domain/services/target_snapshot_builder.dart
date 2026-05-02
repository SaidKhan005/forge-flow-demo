import '../models/active_target_profile.dart';
import '../models/target_snapshot.dart';

class TargetSnapshotBuilder {
  TargetSnapshotBuilder._();

  /// Creates a [TargetSnapshot] from a persisted [ActiveTargetProfile]
  /// and a locked [targetProfileVersionId].
  static TargetSnapshot fromActiveTargetProfile(
    ActiveTargetProfile profile, {
    required String targetProfileVersionId,
  }) {
    return TargetSnapshot(
      restaurantId: profile.restaurantId,
      targetProfileId: profile.targetProfileId,
      targetProfileVersionId: targetProfileVersionId,
      sourceType: profile.sourceType,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      targetPPA: profile.targetPPA,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      opzFloorCPLH: profile.opzFloorCPLH,
      opzCeilingCPLH: profile.opzCeilingCPLH,
      theoreticalFohLaborPct: profile.theoreticalFohLaborPct,
      theoreticalBohLaborPct: profile.theoreticalBohLaborPct,
      theoreticalLaborPct: profile.theoreticalLaborPct,
    );
  }
}
