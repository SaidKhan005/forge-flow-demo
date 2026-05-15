import '../models/active_target_profile.dart';
import '../models/target_snapshot.dart';

class TargetSnapshotBuilder {
  TargetSnapshotBuilder._();

  /// Creates a [TargetSnapshot] from a persisted [ActiveTargetProfile]
  /// and a locked [targetProfileVersionId].
  ///
  /// Per-Daypart V1 (Slice 1): when [servicePeriodId] is provided AND
  /// the profile has a matching per-period row, the snapshot's
  /// `daypart*` fields are populated from that row. Otherwise they
  /// remain null and consumers fall back to the whole-day pool fields
  /// (Gap 42 fallback semantics — Design Rule 2 forbids `0` sentinels).
  ///
  /// Callers that already know they have no per-period scope (e.g.
  /// whole-day rollups) can omit [servicePeriodId] to skip the lookup.
  static TargetSnapshot fromActiveTargetProfile(
    ActiveTargetProfile profile, {
    required String targetProfileVersionId,
    String? servicePeriodId,
  }) {
    final periodRow = servicePeriodId != null
        ? profile.daypartFor(servicePeriodId)
        : null;
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
      daypartTargetCPLH: periodRow?.daypartTargetCPLH,
      daypartTargetSPLH: periodRow?.daypartTargetSPLH,
      daypartTargetPPA: periodRow?.daypartTargetPPA,
      daypartOpzFloorCPLH: periodRow?.daypartOpzFloorCPLH,
      daypartOpzCeilingCPLH: periodRow?.daypartOpzCeilingCPLH,
    );
  }
}
