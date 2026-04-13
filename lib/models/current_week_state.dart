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
  static ShiftRecord shiftRecordFromSnapshot(
    OpenShiftSnapshot s,
    ActiveTargetProfile profile,
  ) {
    return ShiftRecord(
      restaurantId: s.restaurantId,
      weekId: s.weekId,
      dayLabel: s.dayLabel,
      daypart: s.daypart,
      status: s.status,
      covers: s.currentCovers > 0 ? s.currentCovers : s.forecastCovers,
      forecastCovers: s.forecastCovers,
      ppa: s.currentPPA,
      cplh: s.currentCPLH,
      splh: s.currentSPLH,
      fohHours: s.scheduledFohHours,
      bohHours: s.scheduledBohHours,
      primaryLever: 'ON_MODEL',
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
      businessDate: s.businessDate,
      sourceSystem: s.sourceSystem,
      sourceShiftId: s.sourceShiftId,
    );
  }
}
