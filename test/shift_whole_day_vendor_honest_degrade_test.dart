// Whole-day (Shift "Whole Day" lens) labor honest-degrade.
//
// Companion to `shift_period_vendor_honest_degrade_test.dart` (the
// per-period Defect 2 suite). The whole-day projection had two labor
// surfaces still flowing as bare read-model numbers with NO provenance
// gate while their CPLH / SPLH / BLENDED WAGE siblings already dashed
// on `laborSourceVendorId == null`:
//
//   1. the LABOR % tile (`_LaborVarianceData.actualPct/variancePts`)
//   2. the FOH-productivity OPZ band (`currentCPLH` + scored verdict)
//
// So a location whose Labor category is not connected (North Loop /
// Harbour) rendered a `blendedWage × scheduledHours ÷ sales` estimate
// as a connected metric — and an OPZ verdict scored off a phantom
// CPLH — right next to the "Labor: not yet connected" banner. These
// pin the fix via the `@visibleForTesting` whole-day projection probe
// (`ShiftDashboardReadModel.laborPctProvenance` getter +
// `_ShiftSectionViewData.fromWholeDay` gate). No formula change: the
// `actualLaborPct` field math is untouched (alignment suite still
// pins it); only the projection / new provenance getter gate.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/metric_provenance.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/services/schedule_forecast_demand_resolver.dart';
import 'package:forge_and_flow/domain/services/schedule_plan_resolver.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';

ActiveTargetProfile _profile() => ActiveTargetProfile(
      targetProfileId: 'test_active',
      restaurantId: 'demo_restaurant_001',
      sourceType: 'system_baseline',
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      fohWage: MeridianConfig.fohWage,
      bohWage: MeridianConfig.bohWage,
      opzFloorCPLH: BaselineData.opzFloorCPLH,
      opzCeilingCPLH: BaselineData.opzCeilingCPLH,
      theoreticalFohLaborPct: BaselineData.derivedFohTheoreticalLaborPct,
      theoreticalBohLaborPct: BaselineData.derivedBohTheoreticalLaborPct,
      theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
      builtAt: '2026-03-27T19:42:00',
    );

void main() {
  final profile = _profile();
  final demand = ScheduleForecastDemandResolver.resolve(
    targetPPA: profile.targetPPA,
    historicalWeeklyAvgCovers: BaselineData.historicalWeeklyAvgCovers,
  );
  final plan = SchedulePlanResolver.resolve(demand: demand, profile: profile)!;
  final fridayPlan = plan.dayPlans.firstWhere((d) => d.day == 'Fri');

  final lunchClosed = OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W13',
    dayLabel: 'Fri',
    daypart: 'lunch',
    status: 'closed',
    businessDate: '2026-03-27',
    forecastCovers: 180,
    currentCovers: 150,
    scheduledFohHours: 29,
    scheduledBohHours: 30,
    currentPPA: 41.00,
    currentCPLH: 5.17,
    currentSPLH: 205.0,
    blendedWage: 18.74,
    updatedAt: '2026-03-27T14:00:00',
  );
  final dinnerOpen = OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W13',
    dayLabel: 'Fri',
    daypart: 'dinner',
    status: 'open',
    businessDate: '2026-03-27',
    forecastCovers: ShiftSnapshot.shiftForecastCovers,
    currentCovers: ShiftSnapshot.actualCovers,
    scheduledFohHours: ShiftSnapshot.scheduledFohHours,
    scheduledBohHours: ShiftSnapshot.scheduledBohHours,
    currentPPA: ShiftSnapshot.actualPPA,
    currentCPLH: ShiftSnapshot.actualCPLH,
    currentSPLH: ShiftSnapshot.actualSPLH,
    blendedWage: ShiftSnapshot.blendedWage,
    timeLabel: ShiftSnapshot.time,
    serviceElapsedLabel: ShiftSnapshot.serviceElapsed,
    updatedAt: '2026-03-27T19:42:00',
  );
  final snapshots = [lunchClosed, dinnerOpen];

  ShiftDashboardReadModel buildRm({
    String? posSourceVendorId,
    String? laborSourceVendorId,
  }) =>
      ShiftDashboardReadModel.buildWholeDay(
        snapshots: snapshots,
        profile: profile,
        forecastCovers: fridayPlan.forecastCovers,
        forecastSales: fridayPlan.forecastSales,
        planFohHours: fridayPlan.requiredFohHours,
        planBohHours: fridayPlan.requiredBohHours,
        posSourceVendorId: posSourceVendorId,
        laborSourceVendorId: laborSourceVendorId,
      );

  group('whole-day labor honest-degrades on the labor-vendor signal', () {
    test('labor connected (vendor + punches) → LABOR % + OPZ render '
        'live, byte-identical to the prior whole-day render', () {
      final rm = buildRm(
        posSourceVendorId: 'square',
        laborSourceVendorId: 'lightspeed_lsk',
      );
      // The new provenance getter agrees with its CPLH/wage siblings.
      expect(rm.laborPctProvenance.state, MetricState.live);

      final p = debugShiftWholeDayProvenance(rm);
      expect(p.laborActualPctPresent, isTrue);
      expect(p.laborVariancePtsPresent, isTrue);
      expect(p.laborTheoreticalPctPresent, isTrue);
      expect(p.cplhState, MetricState.live);
      expect(p.splhState, MetricState.live);
      expect(p.blendedWageState, MetricState.live);
      // OPZ scored normally — NOT the not-connected pending state.
      expect(p.opzStatus, isNot('pending'));
      expect(p.opzLabel, isNot('LABOR NOT CONNECTED'));
      expect(p.opzLabel, isNot('AWAITING ACTUALS'));
      // POS / covers path untouched.
      expect(p.coversState, MetricState.live);
      expect(p.ppaState, MetricState.live);
    });

    test('labor NOT connected (POS connected, no labor vendor) → '
        'LABOR % dashed + OPZ "LABOR NOT CONNECTED"; theoretical '
        'standard + covers/PPA untouched', () {
      final rm = buildRm(posSourceVendorId: 'square');
      expect(rm.laborSourceVendorId, isNull);
      expect(rm.laborPctProvenance.state, MetricState.unavailable);

      final p = debugShiftWholeDayProvenance(rm);
      // The bug: these were live/scored next to "not yet connected".
      expect(p.laborActualPctPresent, isFalse);
      expect(p.laborVariancePtsPresent, isFalse);
      // The locked standard is still shown (a target is not a vendor
      // actual) — same contract as the per-period path.
      expect(p.laborTheoreticalPctPresent, isTrue);
      expect(p.opzStatus, 'pending');
      expect(p.opzLabel, 'LABOR NOT CONNECTED');
      // Siblings already dashed; LABOR %/OPZ now agree with them.
      expect(p.cplhState, MetricState.unavailable);
      expect(p.splhState, MetricState.unavailable);
      expect(p.blendedWageState, MetricState.unavailable);
      // North Loop POS IS connected — covers/PPA must stay live.
      expect(p.coversState, MetricState.live);
      expect(p.ppaState, MetricState.live);
    });

    test('labor vendor connected but zero actual hours → "AWAITING '
        'ACTUALS", never the not-connected copy', () {
      final preService = OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001',
        weekId: '2026-W13',
        dayLabel: 'Fri',
        daypart: 'dinner',
        status: 'open',
        businessDate: '2026-03-27',
        forecastCovers: 120,
        currentCovers: 0,
        scheduledFohHours: 0,
        scheduledBohHours: 0,
        currentPPA: 0.0,
        currentCPLH: 0.0,
        currentSPLH: 0.0,
        blendedWage: 0.0,
        timeLabel: '5:00 PM',
        serviceElapsedLabel: '0h',
        updatedAt: '2026-03-27T17:00:00',
      );
      final rm = ShiftDashboardReadModel.build(
        preService,
        profile,
        posSourceVendorId: 'square',
        laborSourceVendorId: 'lightspeed_lsk',
      );
      expect(rm.laborSourceVendorId, isNotNull);
      expect(rm.laborPctProvenance.state, MetricState.unavailable);

      final p = debugShiftWholeDayProvenance(rm);
      expect(p.laborActualPctPresent, isFalse);
      expect(p.opzStatus, 'pending');
      expect(p.opzLabel, 'AWAITING ACTUALS');
      expect(p.opzLabel, isNot('LABOR NOT CONNECTED'));
    });
  });
}
