import '../../data/legacy_fixture_data.dart';
import '../models/active_target_profile.dart';
import '../models/target_snapshot.dart';

class TargetSnapshotBuilder {
  TargetSnapshotBuilder._();

  /// Creates a [TargetSnapshot] from the current [BaselineData] and
  /// [MeridianConfig] values. Temporary bridge — prefer [fromActiveTargetProfile].
  static TargetSnapshot fromCurrentBaseline({
    String restaurantId = 'demo_restaurant_001',
  }) {
    return TargetSnapshot(
      restaurantId: restaurantId,
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
