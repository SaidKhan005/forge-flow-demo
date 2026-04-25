/// Current-week read model merging closed shifts + open/projected snapshots.
library;

import '../domain/models/active_target_profile.dart';
import '../domain/models/open_shift_snapshot.dart';
import '../models/shift_record.dart';
import '../models/week_data.dart';

class CurrentWeekState {
  final WeekData weekData;
  final List<ShiftRecord> fullWeekShifts;

  const CurrentWeekState({
    required this.weekData,
    required this.fullWeekShifts,
  });

  /// Converts an OpenShiftSnapshot to a ShiftRecord-compatible shape
  /// for use in Full Week views. Target fields come from the active profile.
  ///
  /// `primaryLever` is hardcoded to `'ON_MODEL'` — a neutral placeholder,
  /// not a claim about actual-vs-target position. Open rows may carry
  /// live partial actuals that deviate from target, but row-scope driver
  /// detection is not yet modeled. Projected rows have no actuals at all.
  /// See phase_7_55m_4 audit doc; `7.55k` owns the honest row-scope
  /// driver contract.
  ///
  /// 7.56c.0: optional Plan-owned overrides come from the locked weekly
  /// plan's daypart allocation. When provided, they replace the
  /// snapshot's `forecastCovers`, forecast sales, and scheduled FOH/BOH
  /// hours so that non-closed Full Week rows render the same daypart
  /// targets Schedule renders. Falling back to the snapshot values when
  /// overrides are null preserves the legacy behaviour for callers without
  /// a locked plan in scope (tests, non-current weeks).
  static ShiftRecord shiftRecordFromSnapshot(
    OpenShiftSnapshot s,
    ActiveTargetProfile profile, {
    int? planForecastCovers,
    double? planForecastSales,
    int? planRequiredFohHours,
    int? planRequiredBohHours,
  }) {
    final forecastCovers = planForecastCovers ?? s.forecastCovers;
    final fohHours = planRequiredFohHours ?? s.scheduledFohHours;
    final bohHours = planRequiredBohHours ?? s.scheduledBohHours;
    return ShiftRecord(
      restaurantId: s.restaurantId,
      weekId: s.weekId,
      dayLabel: s.dayLabel,
      daypart: s.daypart,
      status: s.status,
      covers: s.currentCovers > 0 ? s.currentCovers : forecastCovers,
      forecastCovers: forecastCovers,
      ppa: s.currentPPA,
      cplh: s.currentCPLH,
      splh: s.currentSPLH,
      fohHours: fohHours,
      bohHours: bohHours,
      primaryLever: 'ON_MODEL',
      scheduledFohHours: fohHours,
      scheduledBohHours: bohHours,
      theoreticalLaborPct: profile.theoreticalLaborPct,
      targetProfileId: profile.targetProfileId,
      targetSourceType: profile.sourceType,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      targetPPA: profile.targetPPA,
      targetFohWage: profile.fohWage,
      targetBohWage: profile.bohWage,
      opzFloorCPLH: profile.opzFloorCPLH,
      opzCeilingCPLH: profile.opzCeilingCPLH,
      theoreticalFohLaborPct: profile.theoreticalFohLaborPct,
      theoreticalBohLaborPct: profile.theoreticalBohLaborPct,
      snapshotBlendedWage: s.blendedWage,
      planForecastSales: planForecastSales,
      businessDate: s.businessDate,
      sourceSystem: s.sourceSystem,
      sourceShiftId: s.sourceShiftId,
    );
  }
}
