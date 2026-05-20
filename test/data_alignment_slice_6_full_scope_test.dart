// ─── DataAlignmentAuditReadService — Slice 6 (full scope) Tests ─────────────
//
// Per-Daypart V1 / Slice 6 (full scope) — 5 missing per-period audit
// categories + the `_planRuntimeChecks` authority precedence fix.
//
// Each category covers three states:
//   - synthetic aligned → all PASS
//   - deliberate per-period mismatch → that category drifts with a clear
//     message
//   - absent per-period data → honest "no per-period rows" unavailable
//     (not a false PASS, not a hard FAIL, no fabricated 0)
//
// Groups in this file:
//   - Slice 6 (full scope) — per-period benchmark authority
//   - Slice 6 (full scope) — per-period Shift runtime
//   - Slice 6 (full scope) — per-period Variance runtime
//   - Slice 6 (full scope) — per-period locked-plan reconciliation
//   - Slice 6 (full scope) — per-period sum-to-day + actual presence
//   - Slice 6 (full scope) — _planRuntimeChecks authority precedence
//
// Pure-logic tests — no SQLite, no fixtures.
//
// Bucket 5f of the test-suite tightening audit (2026-05-20): split out of
// `test/data_alignment_audit_read_service_test.dart` (2,161 lines) into
// three focused files:
//   - data_alignment_drift_check_logic_test.dart
//   - data_alignment_audit_checks_by_category_test.dart
//   - data_alignment_slice_6_full_scope_test.dart   (this file)
//
// Library under test: `lib/services/data_alignment_audit_read_service.dart`

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/models/data_alignment_audit_check.dart';
import 'package:forge_and_flow/models/data_alignment_drift_check.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/data_alignment_audit_read_service.dart';

ActiveTargetProfile _profile({
  double cplh = 2.50,
  double splh = 100.00,
  double ppa = 40.00,
  double fohWage = 18.00,
  double bohWage = 20.00,
}) => ActiveTargetProfile.build(
  restaurantId: 'r1',
  sourceType: 'cycle_recommended',
  targetCPLH: cplh,
  targetSPLH: splh,
  targetPPA: ppa,
  fohWage: fohWage,
  bohWage: bohWage,
  opzFloorCPLH: 2.00,
  opzCeilingCPLH: 3.00,
);

void main() {
  group('Slice 6 (full scope) — per-period benchmark authority', () {
    test('aligned cycle/profile per-period pair → all PASS', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final g = checks
          .where((c) =>
              c.groupId ==
              DataAlignmentAuditGroup.perPeriodBenchmarkAuthority)
          .toList();
      expect(g, isNotEmpty);
      expect(g.any((c) => c.status == DriftCheckStatus.drifted), isFalse);
      expect(
        g.where((c) => c.status == DriftCheckStatus.aligned),
        isNotEmpty,
      );
    });

    test('per-period profile value tampered → that period drifts', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: false),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final dinnerCplh = checks.firstWhere((c) =>
          c.label == 'Period dinner: cycle CPLH -> profile CPLH');
      expect(dinnerCplh.status, DriftCheckStatus.drifted);
    });

    test('absent per-period cycle rows → honest unavailable, no false pass',
        () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: _cycleWithDayparts(consistent: true)
            .copyWith(dayparts: const []),
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final g = checks
          .where((c) =>
              c.groupId ==
              DataAlignmentAuditGroup.perPeriodBenchmarkAuthority)
          .toList();
      expect(g, isNotEmpty);
      expect(
        g.every((c) => c.status == DriftCheckStatus.unavailable),
        isTrue,
        reason: 'no per-period rows → honest unavailable, never drift',
      );
      final presence = g.firstWhere(
          (c) => c.label == 'Per-period cycle rows present');
      expect(presence.detail, '—');
    });
  });

  group('Slice 6 (full scope) — per-period Shift runtime', () {
    test('aligned per-period profile → resolved target reconciles to cycle',
        () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final g = checks.where((c) =>
          c.groupId == DataAlignmentAuditGroup.perPeriodShiftRuntime);
      expect(g, isNotEmpty);
      expect(g.any((c) => c.status == DriftCheckStatus.drifted), isFalse);
    });

    test('profile per-period absent → honest Gap-42 fallback, not a fail',
        () {
      // Profile has NO per-period rows (Gap-42), cycle does. The Shift
      // card falls back to the whole-day pool. That fallback is honest
      // — informational, never a false PASS or a hard FAIL — and the
      // whole-day pool it falls back to is itself consistent.
      final cycle = _cycleWithDayparts(consistent: true);
      final profile = _profile(
        cplh: cycle.targetCPLH,
        splh: cycle.targetSPLH,
        ppa: cycle.targetPPA,
      );
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: profile,
        targetCycle: cycle,
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final g = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.perPeriodShiftRuntime)
          .toList();
      final fallback = g.firstWhere((c) =>
          c.label == 'Period lunch: Shift card reads per-period profile row');
      expect(fallback.detail, 'Gap-42 whole-day pool fallback');
      expect(fallback.status, DriftCheckStatus.aligned,
          reason: 'honest fallback is informational, not a fail');
      // No drift anywhere — the whole-day pool fallback is consistent.
      expect(g.any((c) => c.status == DriftCheckStatus.drifted), isFalse);
    });
  });

  group('Slice 6 (full scope) — per-period Variance runtime', () {
    test('aligned per-period profile → Variance % reconciles to cycle %',
        () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final g = checks.where((c) =>
          c.groupId == DataAlignmentAuditGroup.perPeriodVarianceRuntime);
      expect(g, isNotEmpty);
      expect(g.any((c) => c.status == DriftCheckStatus.drifted), isFalse);
      expect(
        g.where((c) =>
            c.label == 'Period dinner: Variance theoretical % = cycle '
                'period %'),
        isNotEmpty,
      );
    });

    test('per-period profile rate tampered → that period % drifts', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: false),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final dinnerPct = checks.firstWhere((c) =>
          c.label ==
          'Period dinner: Variance theoretical % = cycle period %');
      expect(dinnerPct.status, DriftCheckStatus.drifted);
    });

    test('absent per-period cycle rows → honest unavailable', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final g = checks
          .where((c) =>
              c.groupId ==
              DataAlignmentAuditGroup.perPeriodVarianceRuntime)
          .toList();
      expect(g, isNotEmpty);
      expect(
        g.every((c) => c.status == DriftCheckStatus.unavailable),
        isTrue,
      );
    });
  });

  group('Slice 6 (full scope) — per-period locked-plan reconciliation', () {
    test('locked dayDayparts reconcile to lock-time cycle → all PASS', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: _snapshotWithDayDayparts(),
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final g = checks
          .where((c) =>
              c.groupId ==
              DataAlignmentAuditGroup.perPeriodLockedPlanReconciliation)
          .toList();
      expect(g, isNotEmpty);
      expect(g.any((c) => c.status == DriftCheckStatus.drifted), isFalse);
      expect(
        g.where((c) => c.status == DriftCheckStatus.aligned),
        isNotEmpty,
      );
    });

    test('tampered per-period required hours → reconciliation drifts', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: _snapshotWithDayDayparts(tamperFohHours: true),
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final foh = checks.firstWhere((c) =>
          c.label == 'Locked per-period FOH hrs = covers / period CPLH');
      expect(foh.status, DriftCheckStatus.drifted);
    });

    test('absent dayDayparts → honest unavailable, no false pass', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: _makeSnapshot(), // no dayDayparts
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final g = checks
          .where((c) =>
              c.groupId ==
              DataAlignmentAuditGroup.perPeriodLockedPlanReconciliation)
          .toList();
      expect(g, isNotEmpty);
      expect(
        g.every((c) => c.status == DriftCheckStatus.unavailable),
        isTrue,
        reason: 'no per-period locked rows → honest unavailable',
      );
    });
  });

  group('Slice 6 (full scope) — per-period sum-to-day + actual presence',
      () {
    test('per-period rows sum to whole-day locked figures → PASS', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: _snapshotWithDayDayparts(),
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final covers = checks.firstWhere((c) =>
          c.label == 'Σ(per-period covers) = whole-day locked covers');
      expect(covers.status, DriftCheckStatus.aligned);
    });

    test('per-period sum tampered → sum-to-day drifts', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: _snapshotWithDayDayparts(breakSumCovers: true),
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final covers = checks.firstWhere((c) =>
          c.label == 'Σ(per-period covers) = whole-day locked covers');
      expect(covers.status, DriftCheckStatus.drifted);
    });

    test(
        'per-period ACTUAL absence → reported missing (—), NEVER a 0 pass '
        '(Design Rule 2)', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: _snapshotWithDayDayparts(),
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final actuals = checks
          .where((c) =>
              c.groupId ==
                  DataAlignmentAuditGroup.perPeriodSumAndActuals &&
              c.label.startsWith('Per-period actual'))
          .toList();
      expect(actuals.length, 3,
          reason: 'covers / sales / FOH-BOH hours actual presence rows');
      expect(
        actuals.every((c) => c.status == DriftCheckStatus.unavailable),
        isTrue,
        reason: 'absent per-period actuals are honestly "not present", '
            'never a fabricated 0 PASS',
      );
      expect(actuals.every((c) => c.detail == '—'), isTrue);
    });
  });

  group('Slice 6 (full scope) — _planRuntimeChecks authority precedence',
      () {
    test(
        'snapshot.dayDayparts present → reconciles against LOCKED rows, '
        'not the retired allocator', () {
      final snap = _snapshotWithDayDayparts();
      final shifts = _shiftsFromDayDayparts(snap);
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profileWithDayparts(consistent: true),
        targetCycle: _cycleWithDayparts(consistent: true),
        snapshot: snap,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: shifts,
        servicePeriodDefinitions: ServicePeriodDefinitionResolver
            .demoDefinitions,
        distributionWeights: null,
      );
      final locked = checks.where((c) =>
          c.groupId == DataAlignmentAuditGroup.planRuntime &&
          c.label.contains('locked dayDayparts'));
      expect(locked, isNotEmpty,
          reason: 'locked authority path must run when dayDayparts present');
      expect(
        locked.every((c) => c.status == DriftCheckStatus.aligned),
        isTrue,
        reason: 'shifts built from the locked rows reconcile exactly',
      );
      // The retired-allocator fallback labels must NOT appear when the
      // locked authority is present.
      expect(
        checks.any((c) =>
            c.label.contains('DaypartPlanAllocator (fallback')),
        isFalse,
      );
    });

    test(
        'snapshot.dayDayparts empty → falls back to DaypartPlanAllocator',
        () {
      final snap = _makeSnapshot(); // no dayDayparts
      final shifts = <ShiftRecord>[
        ShiftRecord(
          weekId: '2026-W13',
          dayLabel: 'Mon',
          daypart: 'dinner',
          status: 'open',
          covers: 0,
          forecastCovers: 1,
          ppa: 0,
          cplh: 0,
          splh: 0,
          fohHours: 0,
          bohHours: 0,
          primaryLever: 'on_model',
          businessDate: '2026-03-23',
        ),
      ];
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: snap,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: shifts,
        servicePeriodDefinitions: ServicePeriodDefinitionResolver
            .demoDefinitions,
        distributionWeights: null,
      );
      expect(
        checks.any((c) =>
            c.groupId == DataAlignmentAuditGroup.planRuntime &&
            c.label.contains('DaypartPlanAllocator (fallback')),
        isTrue,
        reason: 'empty dayDayparts → allocator fallback path runs',
      );
      expect(
        checks.any((c) =>
            c.label.contains('= locked dayDayparts') &&
            c.detail != '—'),
        isFalse,
        reason: 'locked-authority path must NOT run when dayDayparts empty',
      );
    });
  });
}

/// A cycle with three per-period child rows. When [consistent] is true
/// the parent pool scalars equal the cover-weighted rollup of the child
/// rows (the post-write invariant). When false the parent CPLH is
/// shoved off the rollup to simulate a pool-only mutation (plan Gap 14
/// risk) so the pool-consistency check fires.
TargetCycle _cycleWithDayparts({required bool consistent}) {
  const dayparts = <TargetCycleDaypart>[
    TargetCycleDaypart(
      servicePeriodId: 'lunch',
      targetCPLH: 2.00,
      targetSPLH: 90.00,
      targetPPA: 35.00,
      opzFloorCPLH: 1.80,
      opzCeilingCPLH: 2.40,
      coverCount: 100,
    ),
    TargetCycleDaypart(
      servicePeriodId: 'dinner',
      targetCPLH: 3.00,
      targetSPLH: 120.00,
      targetPPA: 50.00,
      opzFloorCPLH: 2.60,
      opzCeilingCPLH: 3.40,
      coverCount: 300,
    ),
    TargetCycleDaypart(
      servicePeriodId: 'late_night',
      targetCPLH: 2.50,
      targetSPLH: 100.00,
      targetPPA: 40.00,
      opzFloorCPLH: 2.20,
      opzCeilingCPLH: 2.90,
      coverCount: 100,
    ),
  ];
  final pool = TargetCycleDaypartPool.fromDayparts(dayparts);
  return TargetCycle(
    cycleId: 'cycle_pool',
    restaurantId: 'r1',
    source: TargetCycleSource.recommended,
    effectiveStart: '2026-03-01',
    effectiveEnd: '2026-04-29',
    calibrationWindowStart: '2026-01-01',
    calibrationWindowEnd: '2026-02-28',
    // Parent scalars = the rollup when consistent; CPLH shoved off the
    // rollup when not.
    targetCPLH: consistent ? pool.targetCPLH : pool.targetCPLH + 0.50,
    targetSPLH: pool.targetSPLH,
    targetPPA: pool.targetPPA,
    fohWage: 18.00,
    bohWage: 20.00,
    opzFloorCPLH: pool.opzFloorCPLH,
    opzCeilingCPLH: pool.opzCeilingCPLH,
    createdAt: '2026-03-01T00:00:00Z',
    dayparts: dayparts,
  );
}

/// Builds a synthetic snapshot that satisfies the plan-formula
/// invariants checked by [DataAlignmentAuditReadService.computeAuditChecks]:
///   - forecastSales = forecastCovers x targetPPA
///   - FOH hrs       = forecastCovers / targetCPLH
///   - BOH hrs       = forecastSales  / targetSPLH
///   - FOH labor $   = FOH hrs x fohWage
///   - BOH labor $   = BOH hrs x bohWage
///
/// Pass [weeklyOverride] to force a weekly-cover total that does not
/// reconcile to the day-row sum (used to drive the reconciliation
/// drifted check).
WeeklyPlanSnapshot _makeSnapshot({
  int forecastCovers = 1400,
  double targetPPA = 40.00,
  double fohWage = 18.00,
  double bohWage = 20.00,
  double targetCPLH = 2.50,
  double targetSPLH = 100.00,
  int? weeklyOverride,
}) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final perDayCovers = forecastCovers ~/ days.length;
  final perDaySales = perDayCovers * targetPPA;
  final perDayFoh = (perDayCovers / targetCPLH).round();
  final perDayBoh = (perDaySales / targetSPLH).round();

  final dayRows = <WeeklyPlanSnapshotDay>[];
  for (var i = 0; i < days.length; i++) {
    dayRows.add(WeeklyPlanSnapshotDay(
      day: days[i],
      businessDate: '2026-03-${(23 + i).toString().padLeft(2, '0')}',
      forecastCovers: perDayCovers,
      forecastSales: perDaySales,
      requiredFohHours: perDayFoh,
      requiredBohHours: perDayBoh,
    ));
  }

  final weeklyCovers = weeklyOverride ??
      dayRows.fold<int>(0, (s, d) => s + d.forecastCovers);
  final weeklySales =
      dayRows.fold<double>(0, (s, d) => s + d.forecastSales);
  final weeklyFoh =
      dayRows.fold<int>(0, (s, d) => s + d.requiredFohHours);
  final weeklyBoh =
      dayRows.fold<int>(0, (s, d) => s + d.requiredBohHours);

  return WeeklyPlanSnapshot(
    snapshotId: 'snap_test',
    restaurantId: 'r1',
    weekStartDate: '2026-03-23',
    weekEndDate: '2026-03-29',
    targetCycleId: 'cycle_1',
    forecastCovers: weeklyCovers,
    forecastSales: weeklySales,
    requiredFohHours: weeklyFoh,
    requiredBohHours: weeklyBoh,
    theoreticalFohLaborDollars: weeklyFoh * fohWage,
    theoreticalBohLaborDollars: weeklyBoh * bohWage,
    coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    salesSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    generatedAt: '2026-03-23T00:00:00Z',
    lockedAt: '2026-03-23T00:00:01Z',
    dayRows: dayRows,
  );
}

// ── Slice 6 (full scope) per-period helpers ────────────────────────────────

/// A profile whose per-period rows mirror `_cycleWithDayparts(true)` and
/// whose whole-day scalars equal the cover-weighted pool of those rows
/// (the post-Slice-1 projection invariant). When [consistent] is false
/// the `dinner` period's CPLH is shoved off the cycle value to drive the
/// per-period benchmark-authority + Variance-% drift assertions; the
/// whole-day scalars stay on the pool so only the per-period dinner
/// checks fire.
ActiveTargetProfile _profileWithDayparts({required bool consistent}) {
  final cycle = _cycleWithDayparts(consistent: true);
  final pool = TargetCycleDaypartPool.fromDayparts(cycle.dayparts);
  final rows = cycle.dayparts.map((cd) {
    final tamper = !consistent && cd.servicePeriodId == 'dinner';
    return ActiveTargetProfileDaypart(
      servicePeriodId: cd.servicePeriodId,
      daypartTargetCPLH: cd.targetCPLH + (tamper ? 0.50 : 0.0),
      daypartTargetSPLH: cd.targetSPLH,
      daypartTargetPPA: cd.targetPPA,
      daypartOpzFloorCPLH: cd.opzFloorCPLH,
      daypartOpzCeilingCPLH: cd.opzCeilingCPLH,
    );
  }).toList();
  return ActiveTargetProfile.build(
    restaurantId: 'r1',
    sourceType: 'cycle_recommended',
    targetCPLH: pool.targetCPLH,
    targetSPLH: pool.targetSPLH,
    targetPPA: pool.targetPPA,
    fohWage: 18.00,
    bohWage: 20.00,
    opzFloorCPLH: pool.opzFloorCPLH,
    opzCeilingCPLH: pool.opzCeilingCPLH,
  ).withDayparts(rows);
}

/// One-day locked snapshot carrying per-period `dayDayparts` rows that
/// reconcile to `_cycleWithDayparts(true)` at lock time:
///   sales = covers x period PPA, FOH = covers / period CPLH,
///   BOH = sales / period SPLH. The whole-day row equals the Σ of the
///   three period rows so the sum-to-day invariant passes.
///
/// [tamperFohHours] shoves the lunch period's required FOH hours off the
/// model value to drive the locked-plan-reconciliation drift assertion.
/// [breakSumCovers] sets the whole-day covers away from the period sum
/// to drive the sum-to-day drift assertion (period rows still reconcile
/// to the cycle, so only the sum-to-day covers check fires).
WeeklyPlanSnapshot _snapshotWithDayDayparts({
  bool tamperFohHours = false,
  bool breakSumCovers = false,
}) {
  final cycle = _cycleWithDayparts(consistent: true);
  const businessDate = '2026-03-23';
  final periodRows = <WeeklyPlanSnapshotDayDaypart>[];
  for (final cd in cycle.dayparts) {
    final covers = cd.coverCount; // 100 / 300 / 100
    final sales = covers * cd.targetPPA;
    final foh = covers / cd.targetCPLH +
        (tamperFohHours && cd.servicePeriodId == 'lunch' ? 5.0 : 0.0);
    final boh = sales / cd.targetSPLH;
    periodRows.add(WeeklyPlanSnapshotDayDaypart(
      businessDate: businessDate,
      servicePeriodId: cd.servicePeriodId,
      forecastCovers: covers,
      forecastSales: sales,
      requiredFohHours: foh,
      requiredBohHours: boh,
      theoreticalFohDollars: foh * 18.00,
      theoreticalBohDollars: boh * 20.00,
    ));
  }
  final sumCovers =
      periodRows.fold<int>(0, (s, d) => s + d.forecastCovers);
  final sumSales =
      periodRows.fold<double>(0, (s, d) => s + d.forecastSales);
  final sumFoh =
      periodRows.fold<double>(0, (s, d) => s + d.requiredFohHours);
  final sumBoh =
      periodRows.fold<double>(0, (s, d) => s + d.requiredBohHours);
  final dayRow = WeeklyPlanSnapshotDay(
    day: 'Mon',
    businessDate: businessDate,
    forecastCovers: breakSumCovers ? sumCovers + 999 : sumCovers,
    forecastSales: sumSales,
    requiredFohHours: sumFoh.round(),
    requiredBohHours: sumBoh.round(),
  );
  return WeeklyPlanSnapshot(
    snapshotId: 'snap_pp',
    restaurantId: 'r1',
    weekStartDate: '2026-03-23',
    weekEndDate: '2026-03-29',
    targetCycleId: cycle.cycleId,
    forecastCovers: dayRow.forecastCovers,
    forecastSales: dayRow.forecastSales,
    requiredFohHours: dayRow.requiredFohHours,
    requiredBohHours: dayRow.requiredBohHours,
    theoreticalFohLaborDollars: sumFoh * 18.00,
    theoreticalBohLaborDollars: sumBoh * 20.00,
    coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    salesSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    generatedAt: '2026-03-23T00:00:00Z',
    lockedAt: '2026-03-23T00:00:01Z',
    dayRows: [dayRow],
    dayDayparts: periodRows,
  );
}

/// Non-closed shifts built 1:1 from a snapshot's per-period locked rows
/// so the `_planRuntimeChecks` locked-authority path reconciles exactly.
List<ShiftRecord> _shiftsFromDayDayparts(WeeklyPlanSnapshot snap) {
  return snap.dayDayparts
      .map((d) => ShiftRecord(
            weekId: '2026-W13',
            dayLabel: 'Mon',
            daypart: d.servicePeriodId,
            status: 'open',
            covers: 0,
            forecastCovers: d.forecastCovers,
            ppa: 0,
            cplh: 0,
            splh: 0,
            fohHours: d.requiredFohHours.round(),
            bohHours: d.requiredBohHours.round(),
            primaryLever: 'on_model',
            planForecastSales: d.forecastSales,
            businessDate: d.businessDate,
          ))
      .toList();
}
