// ─── DataAlignmentAuditReadService — Drift Check Tests ──────────────────────
//
// Phase 7.55r item 4 (scope expanded 2026-04-24), Tier 2.
//
// Covers:
//   - DataAlignmentDriftCheck.status (aligned / drifted / unavailable)
//   - DataAlignmentDriftCheck.delta (signed difference when available)
//   - DataAlignmentAuditReadService.computeDriftChecks null-guarding
//     (no crashes when any authority is null)
//   - DataAlignmentAuditSnapshot derived counters
//
// Phase 7.56c.1 (extended 2026-04-24):
//   - DataAlignmentAuditReadService.computeAuditChecks grouped coverage
//     across live actuals / benchmark authority / benchmark runtime /
//     locked plan ↔ projection / plan runtime.
//
// Pure-logic tests — no SQLite, no fixtures. The full end-to-end loadSnapshot
// path is covered by manual smoke via the Settings panel because it requires
// the full SQLite bootstrap chain; this suite protects the decision logic.
//
// Library under test: `lib/services/data_alignment_audit_read_service.dart`
// Model under test:   `lib/models/data_alignment_drift_check.dart`
// Audit-check model:  `lib/models/data_alignment_audit_check.dart`
// Snapshot:           `lib/models/data_alignment_audit_snapshot.dart`

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/domain/models/wage_standard_context.dart';
import 'package:forge_and_flow/domain/models/wage_standard_source.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/domain/models/benchmark_selection_summary.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_schedule_plan_projector.dart';
import 'package:forge_and_flow/models/data_alignment_audit_check.dart';
import 'package:forge_and_flow/models/data_alignment_audit_provenance.dart';
import 'package:forge_and_flow/models/data_alignment_audit_snapshot.dart';
import 'package:forge_and_flow/models/data_alignment_drift_check.dart';
import 'package:forge_and_flow/models/week_data.dart';
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

WageStandardContext _wageContext({
  double? fohWage = 18.00,
  double? bohWage = 20.00,
  WageStandardSource source = WageStandardSource.configFallback,
}) => WageStandardContext(
  restaurantId: 'r1',
  fohWage: fohWage,
  bohWage: bohWage,
  referenceBlendedWage: null,
  source: source,
  builtAt: '2026-04-24T00:00:00Z',
);

void main() {
  group('DataAlignmentDriftCheck.status', () {
    test('returns aligned when both values present and within tolerance', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: 2.50,
        comparedValue: 2.501,
        tolerance: 0.005,
        ruleReference: 'Rule 2',
      );
      expect(c.status, DriftCheckStatus.aligned);
    });

    test('returns drifted when both values present and outside tolerance', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: 2.50,
        comparedValue: 2.60,
        tolerance: 0.005,
        ruleReference: 'Rule 2',
      );
      expect(c.status, DriftCheckStatus.drifted);
    });

    test('returns unavailable when expected value null', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: null,
        comparedValue: 2.50,
        tolerance: 0.005,
        ruleReference: 'Rule 2',
      );
      expect(c.status, DriftCheckStatus.unavailable);
    });

    test('returns unavailable when compared value null', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: 2.50,
        comparedValue: null,
        tolerance: 0.005,
        ruleReference: 'Rule 2',
      );
      expect(c.status, DriftCheckStatus.unavailable);
    });

    test('returns unavailable when both values null', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: null,
        comparedValue: null,
        tolerance: 0.005,
        ruleReference: 'Rule 2',
      );
      expect(c.status, DriftCheckStatus.unavailable);
    });

    test('uses absolute tolerance (negative direction)', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: 20.5,
        comparedValue: 20.48,
        tolerance: 0.01,
        ruleReference: 'Rule 2',
      );
      // abs diff = 0.02, tolerance = 0.01 → drifted
      expect(c.status, DriftCheckStatus.drifted);
    });

    test('exactly-equal values are aligned', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: 2.50,
        comparedValue: 2.50,
        tolerance: 0.005,
        ruleReference: 'Rule 2',
      );
      expect(c.status, DriftCheckStatus.aligned);
    });
  });

  group('DataAlignmentDriftCheck.delta', () {
    test('returns signed difference when both present', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: 3.0,
        comparedValue: 2.5,
        tolerance: 0.005,
        ruleReference: 'Rule 2',
      );
      expect(c.delta, 0.5);
    });

    test('returns null when expected missing', () {
      final c = DataAlignmentDriftCheck(
        label: 't',
        expectedSource: 'A',
        comparedSource: 'B',
        expectedValue: null,
        comparedValue: 2.5,
        tolerance: 0.005,
        ruleReference: 'Rule 2',
      );
      expect(c.delta, isNull);
    });
  });

  group('DataAlignmentAuditReadService.computeDriftChecks — null guarding', () {
    test('returns empty list when all inputs null', () {
      final checks = DataAlignmentAuditReadService.computeDriftChecks(
        profile: null,
        shiftReadModel: null,
        weekData: null,
        wageContext: null,
      );
      expect(checks, isEmpty);
    });

    test('returns empty list when only profile is present', () {
      final checks = DataAlignmentAuditReadService.computeDriftChecks(
        profile: _profile(),
        shiftReadModel: null,
        weekData: null,
        wageContext: null,
      );
      // No shift/week/wage to compare against → no pairs to add.
      expect(checks, isEmpty);
    });

    test('skips wage-authority checks when wage context unavailable', () {
      final checks = DataAlignmentAuditReadService.computeDriftChecks(
        profile: _profile(),
        shiftReadModel: null,
        weekData: null,
        wageContext: _wageContext(
          source: WageStandardSource.unavailable,
          fohWage: null,
          bohWage: null,
        ),
      );
      // Wage context is present but .isAvailable is false → skip both checks.
      expect(checks, isEmpty);
    });

    test(
      'adds 2 wage-authority checks when wage context available + aligned',
      () {
        final checks = DataAlignmentAuditReadService.computeDriftChecks(
          profile: _profile(fohWage: 18.00, bohWage: 20.00),
          shiftReadModel: null,
          weekData: null,
          wageContext: _wageContext(fohWage: 18.00, bohWage: 20.00),
        );
        expect(checks.length, 2);
        expect(
          checks.every((c) => c.ruleReference == 'Wage authority'),
          isTrue,
        );
        expect(
          checks.every((c) => c.status == DriftCheckStatus.aligned),
          isTrue,
        );
      },
    );

    test('flags drifted FOH wage when profile and wage context disagree', () {
      final checks = DataAlignmentAuditReadService.computeDriftChecks(
        profile: _profile(fohWage: 18.00, bohWage: 20.00),
        shiftReadModel: null,
        weekData: null,
        wageContext: _wageContext(fohWage: 17.00, bohWage: 20.00),
      );
      expect(checks.length, 2);
      final foh = checks.firstWhere((c) => c.label == 'FOH Wage authority');
      final boh = checks.firstWhere((c) => c.label == 'BOH Wage authority');
      expect(foh.status, DriftCheckStatus.drifted);
      expect(boh.status, DriftCheckStatus.aligned);
    });

    test('drift check carries expected provenance paths', () {
      final checks = DataAlignmentAuditReadService.computeDriftChecks(
        profile: _profile(),
        shiftReadModel: null,
        weekData: null,
        wageContext: _wageContext(),
      );
      final foh = checks.firstWhere((c) => c.label == 'FOH Wage authority');
      expect(foh.expectedSource, 'ActiveTargetProfile.fohWage');
      expect(foh.comparedSource, 'WageStandardContext.fohWage');
    });
  });

  group('DataAlignmentAuditSnapshot counters', () {
    DataAlignmentAuditSnapshot makeSnapshot(
      List<DataAlignmentDriftCheck> checks,
    ) => DataAlignmentAuditSnapshot(
      profile: null,
      demandContext: null,
      plan: null,
      shiftReadModel: null,
      weekData: null,
      wageContext: null,
      driftChecks: checks,
      provenance: const DataAlignmentAuditProvenance(
        lockedWeek: null,
        targetCycle: null,
      ),
    );

    test('driftedCount / alignedCount reflect check statuses', () {
      final snap = makeSnapshot([
        DataAlignmentDriftCheck(
          label: 'a',
          expectedSource: 'X',
          comparedSource: 'Y',
          expectedValue: 1.0,
          comparedValue: 1.0,
          tolerance: 0.01,
          ruleReference: 'R',
        ),
        DataAlignmentDriftCheck(
          label: 'b',
          expectedSource: 'X',
          comparedSource: 'Y',
          expectedValue: 1.0,
          comparedValue: 2.0,
          tolerance: 0.01,
          ruleReference: 'R',
        ),
        DataAlignmentDriftCheck(
          label: 'c',
          expectedSource: 'X',
          comparedSource: 'Y',
          expectedValue: null,
          comparedValue: 1.0,
          tolerance: 0.01,
          ruleReference: 'R',
        ),
      ]);
      expect(snap.alignedCount, 1);
      expect(snap.driftedCount, 1);
      expect(snap.hasAnyDrift, isTrue);
    });

    test('hasAnyDrift is false when no drifted checks', () {
      final snap = makeSnapshot([
        DataAlignmentDriftCheck(
          label: 'a',
          expectedSource: 'X',
          comparedSource: 'Y',
          expectedValue: 1.0,
          comparedValue: 1.0,
          tolerance: 0.01,
          ruleReference: 'R',
        ),
      ]);
      expect(snap.hasAnyDrift, isFalse);
      expect(snap.driftedCount, 0);
      expect(snap.alignedCount, 1);
    });

    test('empty checks gives zero counts and no drift', () {
      final snap = makeSnapshot(const []);
      expect(snap.hasAnyDrift, isFalse);
      expect(snap.driftedCount, 0);
      expect(snap.alignedCount, 0);
    });
  });

  // ── Phase 7.55r item 4 Tier 3 — locked-week / cycle provenance ─────────
  //
  // Pure-logic coverage of DataAlignmentAuditReadService.buildProvenance
  // and DataAlignmentAuditProvenance getters. Like the drift-check
  // coverage above, this is unit-level only — the full loadSnapshot path
  // is exercised via the Settings audit-panel widget smoke.

  group('DataAlignmentAuditReadService.buildProvenance', () {
    WeeklyPlanSnapshot makeSnapshot({
      String snapshotId = 'snap_1',
      String weekStart = '2026-03-23',
      String weekEnd = '2026-03-29',
      String targetCycleId = 'cycle_1',
    }) => WeeklyPlanSnapshot(
      snapshotId: snapshotId,
      restaurantId: 'r1',
      weekStartDate: weekStart,
      weekEndDate: weekEnd,
      targetCycleId: targetCycleId,
      forecastCovers: 1000,
      forecastSales: 40000.00,
      requiredFohHours: 180,
      requiredBohHours: 120,
      theoreticalFohLaborDollars: 3240.00,
      theoreticalBohLaborDollars: 2400.00,
      coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      salesSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      generatedAt: '2026-03-23T00:00:00Z',
      lockedAt: '2026-03-23T00:00:01Z',
      dayRows: const [],
    );

    TargetCycle makeCycle({String cycleId = 'cycle_1'}) => TargetCycle(
      cycleId: cycleId,
      restaurantId: 'r1',
      source: TargetCycleSource.recommended,
      effectiveStart: '2026-03-01',
      effectiveEnd: '2026-04-29',
      calibrationWindowStart: '2026-01-01',
      calibrationWindowEnd: '2026-02-28',
      targetCPLH: 2.50,
      targetSPLH: 100.00,
      targetPPA: 40.00,
      fohWage: 18.00,
      bohWage: 20.00,
      opzFloorCPLH: 2.00,
      opzCeilingCPLH: 3.00,
      createdAt: '2026-03-01T00:00:00Z',
    );

    test('returns empty provenance when snapshot is null', () {
      final p = DataAlignmentAuditReadService.buildProvenance(
        snapshot: null,
        targetCycle: null,
      );
      expect(p.lockedWeek, isNull);
      expect(p.targetCycle, isNull);
      expect(p.lockedWeekUnavailable, isTrue);
      expect(
        p.targetCycleUnavailable,
        isFalse,
        reason:
            'targetCycleUnavailable is only meaningful when lockedWeek is '
            'present — snapshot-missing is its own unavailable state',
      );
    });

    test('populates locked-week shape from snapshot fields', () {
      final p = DataAlignmentAuditReadService.buildProvenance(
        snapshot: makeSnapshot(
          snapshotId: 'snap_x',
          weekStart: '2026-03-23',
          weekEnd: '2026-03-29',
          targetCycleId: 'cycle_x',
        ),
        targetCycle: null,
      );
      expect(p.lockedWeek, isNotNull);
      expect(p.lockedWeek!.snapshotId, 'snap_x');
      expect(p.lockedWeek!.weekStartDate, '2026-03-23');
      expect(p.lockedWeek!.weekEndDate, '2026-03-29');
      expect(p.lockedWeek!.weekKey, '2026-03-23_2026-03-29');
      expect(p.lockedWeek!.targetCycleId, 'cycle_x');
    });

    test('leaves targetCycle null when snapshot present but cycle missing', () {
      final p = DataAlignmentAuditReadService.buildProvenance(
        snapshot: makeSnapshot(),
        targetCycle: null,
      );
      expect(p.lockedWeek, isNotNull);
      expect(p.targetCycle, isNull);
      expect(p.targetCycleUnavailable, isTrue);
    });

    test('populates target-cycle shape from cycle fields', () {
      final p = DataAlignmentAuditReadService.buildProvenance(
        snapshot: makeSnapshot(targetCycleId: 'cycle_1'),
        targetCycle: makeCycle(),
      );
      expect(p.targetCycle, isNotNull);
      expect(p.targetCycle!.cycleId, 'cycle_1');
      expect(p.targetCycle!.sourceLabel, 'recommended');
      expect(p.targetCycle!.effectiveStart, '2026-03-01');
      expect(p.targetCycle!.effectiveEnd, '2026-04-29');
      expect(p.targetCycle!.calibrationWindowStart, '2026-01-01');
      expect(p.targetCycle!.calibrationWindowEnd, '2026-02-28');
      expect(p.lockedWeekUnavailable, isFalse);
      expect(p.targetCycleUnavailable, isFalse);
    });
  });

  // ── Phase 7.56c.1 — grouped audit-check coverage ───────────────────────
  //
  // The computeAuditChecks() static is the pure aggregation seam used
  // by the audit service. These tests drive synthetic authority inputs
  // and assert per-group alignment / drift / unavailable outcomes per
  // the 7.56c.1 phase doc. Live-actuals checks are presence/source-label
  // only — no operational variance in the architectural drift signal.

  group('computeAuditChecks — group: live actuals', () {
    test('all unavailable when no read models are present', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: null,
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
      final live = checks
          .where((c) => c.groupId == DataAlignmentAuditGroup.liveActuals);
      expect(live, isNotEmpty);
      expect(
        live.every((c) => c.status == DriftCheckStatus.unavailable),
        isTrue,
      );
    });

    test(
        'WTD live-actual rows align when weekData present, even without plan',
        () {
      final wd = _makeWeekData();
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: null,
        targetCycle: null,
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: wd,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final live = checks
          .where((c) => c.groupId == DataAlignmentAuditGroup.liveActuals)
          .where((c) => c.label.startsWith('WTD'));
      expect(live.length, 4);
      expect(
        live.every((c) => c.status == DriftCheckStatus.aligned),
        isTrue,
      );
      expect(
        live.every((c) => c.detail == 'closed ShiftRecord'),
        isTrue,
      );
    });
  });

  group('computeAuditChecks — group: benchmark authority', () {
    TargetCycle cycle({
      double cplh = 2.50,
      double splh = 100.00,
      double ppa = 40.00,
      double fohWage = 18.00,
      double bohWage = 20.00,
      double opzFloor = 2.00,
      double opzCeiling = 3.00,
    }) =>
        TargetCycle(
          cycleId: 'cycle_1',
          restaurantId: 'r1',
          source: TargetCycleSource.recommended,
          effectiveStart: '2026-03-01',
          effectiveEnd: '2026-04-29',
          calibrationWindowStart: '2026-01-01',
          calibrationWindowEnd: '2026-02-28',
          targetCPLH: cplh,
          targetSPLH: splh,
          targetPPA: ppa,
          fohWage: fohWage,
          bohWage: bohWage,
          opzFloorCPLH: opzFloor,
          opzCeilingCPLH: opzCeiling,
          createdAt: '2026-03-01T00:00:00Z',
        );

    test('aligned cycle/profile pair produces no drifted authority checks',
        () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: cycle(),
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
      final auth = checks
          .where(
              (c) => c.groupId == DataAlignmentAuditGroup.benchmarkAuthority)
          .toList();
      // 7 cycle->profile pairs + 4 formula invariants + 1 summary = 12.
      expect(auth.length, 12);
      // No authority drift when cycle/profile agree and formulas hold.
      expect(
        auth.where((c) => c.status == DriftCheckStatus.drifted),
        isEmpty,
      );
    });

    test('cycle drift surfaces as drifted authority check', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(cplh: 2.50),
        targetCycle: cycle(cplh: 2.99), // disagrees with profile
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
      final cplhCheck = checks.firstWhere(
          (c) => c.label == 'TargetCycle CPLH -> Profile CPLH');
      expect(cplhCheck.status, DriftCheckStatus.drifted);
    });

    test('formula invariants flag a tampered theoretical labor %', () {
      final base = _profile();
      final tampered = ActiveTargetProfile(
        targetProfileId: base.targetProfileId,
        restaurantId: base.restaurantId,
        sourceType: base.sourceType,
        targetCPLH: base.targetCPLH,
        targetSPLH: base.targetSPLH,
        targetPPA: base.targetPPA,
        fohWage: base.fohWage,
        bohWage: base.bohWage,
        opzFloorCPLH: base.opzFloorCPLH,
        opzCeilingCPLH: base.opzCeilingCPLH,
        theoreticalFohLaborPct: 999.99, // tamper
        theoreticalBohLaborPct: base.theoreticalBohLaborPct,
        theoreticalLaborPct: base.theoreticalLaborPct,
        builtAt: base.builtAt,
      );
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: tampered,
        targetCycle: cycle(),
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
      final fohFormula = checks.firstWhere(
          (c) => c.label == 'Profile theoretical FOH % matches formula');
      expect(fohFormula.status, DriftCheckStatus.drifted);
    });

    test('benchmark-selection summary: present + table available -> aligned',
        () {
      final summary = BenchmarkSelectionSummary(
        summaryId: 'bs_1',
        restaurantId: 'r1',
        targetCycleId: 'cycle_1',
        sourceType: 'recommended',
        selectedShiftCount: 12,
        rangeQualityLabel: 'GOOD OPZ RANGE',
        rangeQualityMessage: 'ok',
        createdAt: '2026-03-01T00:00:00Z',
      );
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: cycle(),
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: summary,
        benchmarkSelectionSummaryTableAvailable: true,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final summaryCheck = checks.firstWhere(
          (c) => c.label == 'Active cycle has benchmark-selection summary');
      expect(summaryCheck.status, DriftCheckStatus.aligned);
      expect(summaryCheck.detail, 'recommended');
    });

    test(
        'benchmark-selection summary: missing row + table available -> drifted',
        () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: cycle(),
        snapshot: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: true,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final summaryCheck = checks.firstWhere(
          (c) => c.label == 'Active cycle has benchmark-selection summary');
      expect(summaryCheck.status, DriftCheckStatus.drifted);
    });

    test(
        'benchmark-selection summary: table unavailable degrades to '
        'unavailable, not drift', () {
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: cycle(),
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
      final summaryCheck = checks.firstWhere(
          (c) => c.label == 'Active cycle has benchmark-selection summary');
      expect(summaryCheck.status, DriftCheckStatus.unavailable);
    });
  });

  group('computeAuditChecks — group: locked plan <-> projection', () {
    test('snapshot <-> projected plan aligned through real projector', () {
      final snap = _makeSnapshot();
      final plan = WeeklyPlanSnapshotSchedulePlanProjector.project(snap);
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: snap,
        plan: plan,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final group = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.planLockedProjection)
          .toList();
      expect(group, isNotEmpty);
      expect(
        group.where((c) => c.status == DriftCheckStatus.drifted),
        isEmpty,
        reason:
            'projector + formula-aligned snapshot must produce zero drift',
      );
    });

    test('day-row sum mismatch surfaces as drifted reconciliation row', () {
      final snap = _makeSnapshot(weeklyOverride: 9999); // off by a lot
      final plan = WeeklyPlanSnapshotSchedulePlanProjector.project(snap);
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: snap,
        plan: plan,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final reconCovers = checks.firstWhere(
          (c) => c.label == 'Sum(day-row covers) = snapshot weekly covers');
      expect(reconCovers.status, DriftCheckStatus.drifted);
    });
  });

  group('computeAuditChecks — auditGroups summary', () {
    test('snapshot.auditGroups counts aligned/drifted/unavailable per group',
        () {
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
      final snap = DataAlignmentAuditSnapshot(
        profile: null,
        demandContext: null,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        wageContext: null,
        driftChecks: const [],
        provenance: const DataAlignmentAuditProvenance(
          lockedWeek: null,
          targetCycle: null,
        ),
        auditChecks: checks,
      );
      final groups = snap.auditGroups;
      expect(groups, isNotEmpty);
      for (final g in groups) {
        final groupChecks =
            checks.where((c) => c.groupId == g.groupId).toList();
        expect(
          g.alignedCount + g.driftedCount + g.unavailableCount,
          groupChecks.length,
        );
      }
      final anyDrift =
          groups.fold<int>(0, (sum, g) => sum + g.driftedCount) > 0;
      expect(snap.hasAnyAuditDrift, anyDrift);
    });
  });

  // ── Per-Daypart V1 / Slice 6 — pool-consistency invariant ──────────────
  //
  // Design Rule 4: the whole-day pool scalars on the active TargetCycle
  // are the cover-weighted rollup of the per-period child rows. The
  // pool-consistency group recomputes the rollup from the persisted
  // child rows and flags drift when the parent scalars diverge.

  group('computeAuditChecks — group: pool consistency', () {
    test('consistent pool (parent = cover-weighted rollup) passes', () {
      final cycle = _cycleWithDayparts(consistent: true);
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
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
      final pool = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.poolConsistency)
          .toList();
      expect(pool.length, 5,
          reason: 'CPLH/SPLH/PPA + OPZ floor + OPZ ceiling = 5 invariants');
      expect(
        pool.every((c) => c.status == DriftCheckStatus.aligned),
        isTrue,
        reason: 'parent pool == cover-weighted rollup of period rows',
      );
    });

    test('pool drift (parent scalar tampered) surfaces as drifted', () {
      final cycle = _cycleWithDayparts(consistent: false);
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
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
      final cplh = checks.firstWhere(
          (c) => c.label == 'Pool CPLH = cover-weighted Σ(period CPLH)');
      expect(cplh.status, DriftCheckStatus.drifted,
          reason: 'parent CPLH was set away from the rollup');
      // OPZ band is the union (min floor / max ceiling) and was left
      // consistent, so those two invariants still align.
      final floor = checks.firstWhere(
          (c) => c.label == 'Pool OPZ floor = min(period OPZ floors)');
      expect(floor.status, DriftCheckStatus.aligned);
    });

    test('Gap 42 fallback (empty dayparts) degrades to unavailable', () {
      // A cycle written under the insufficient-recommendation fallback
      // persists NO per-period child rows. There is nothing to
      // reconcile — every invariant must be unavailable, never false
      // drift, never a sentinel 0.
      final cycle = _cycleWithDayparts(consistent: true).copyWith(
        dayparts: const [],
      );
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
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
      final pool = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.poolConsistency)
          .toList();
      expect(pool.length, 5);
      expect(
        pool.every((c) => c.status == DriftCheckStatus.unavailable),
        isTrue,
        reason:
            'no per-period rows → rollup undefined → honest unavailable',
      );
    });

    test('null cycle degrades pool group to unavailable', () {
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
      final pool = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.poolConsistency)
          .toList();
      expect(pool.length, 5);
      expect(
        pool.every((c) => c.status == DriftCheckStatus.unavailable),
        isTrue,
      );
    });
  });

  // ── Per-Daypart V1 / Slice 6 — wage-at-lock-time provenance ────────────
  //
  // Design Rule 8: locked dollar reconciliation compares against the
  // snapshot's wage_at_lock_time stamp, never the live profile wages.

  group('computeAuditChecks — group: wage-at-lock-time', () {
    test('stamped snapshot whose locked dollars reproduce -> aligned', () {
      final snap = _makeSnapshotWithWageStamp();
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: snap,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final wage = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.wageAtLockTime)
          .toList();
      expect(wage.length, 4,
          reason: 'stamp presence + FOH \$ + BOH \$ + blended wage');
      expect(
        wage.every((c) => c.status == DriftCheckStatus.aligned),
        isTrue,
      );
    });

    test('locked dollars reconcile to LOCK-TIME wages, not live profile',
        () {
      // The snapshot was locked at FOH 16 / BOH 18. The operator since
      // bumped wages — _profile() carries the *current* FOH 18 / BOH 20.
      // The check must reconcile against the stamp; comparing to the
      // live profile would have falsely flagged drift.
      final snap = _makeSnapshotWithWageStamp(fohWage: 16.00, bohWage: 18.00);
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(fohWage: 18.00, bohWage: 20.00),
        targetCycle: null,
        snapshot: snap,
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
          c.label == 'Locked FOH \$ = lock-time FOH wage x locked FOH hrs');
      expect(foh.status, DriftCheckStatus.aligned,
          reason: 'reconciled against lock-time stamp, not live profile');
    });

    test('tampered locked FOH dollars surface as drifted', () {
      final snap = _makeSnapshotWithWageStamp(tamperFohDollars: true);
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: snap,
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
          c.label == 'Locked FOH \$ = lock-time FOH wage x locked FOH hrs');
      expect(foh.status, DriftCheckStatus.drifted);
    });

    test('legacy snapshot without stamp degrades to unavailable', () {
      // _makeSnapshot() (the pre-existing helper) writes no
      // wage_at_lock_time stamp — exactly a legacy pre-Slice-1 row.
      final snap = _makeSnapshot();
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: snap,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final wage = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.wageAtLockTime)
          .toList();
      expect(wage.length, 4);
      expect(
        wage.every((c) => c.status == DriftCheckStatus.unavailable),
        isTrue,
        reason: 'missing stamp is honest absence, not drift',
      );
    });
  });

  // ── Per-Daypart V1 / Slice 6 — Gap 38 structural ordering fix ──────────
  //
  // computeAuditChecks is the pure seam; the structural-ordering bug
  // itself lives in the I/O orchestration (loadSnapshot fetched the
  // cycle only when a snapshot existed). The pure-seam consequence the
  // fix unblocks: a cycle present WITHOUT a locked snapshot must still
  // produce live (non-unavailable) benchmark-authority + pool-
  // consistency checks. Before the fix the cycle was null in that
  // window, so every such check degraded to unavailable.

  group('computeAuditChecks — Gap 38 structural-ordering consequence', () {
    test(
        'cycle present + no snapshot still produces live authority + pool '
        'checks (the state the ordering fix unblocks)', () {
      final cycle = _cycleWithDayparts(consistent: true);
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: cycle,
        snapshot: null, // no locked weekly plan yet
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final authority = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.benchmarkAuthority)
          .toList();
      final liveAuthority = authority.where(
          (c) => c.status != DriftCheckStatus.unavailable);
      expect(liveAuthority, isNotEmpty,
          reason:
              'cycle-without-snapshot must still drive TargetCycle -> '
              'Profile authority checks (Gap 38 fix)');

      final pool = checks
          .where((c) =>
              c.groupId == DataAlignmentAuditGroup.poolConsistency)
          .where((c) => c.status != DriftCheckStatus.unavailable);
      expect(pool, isNotEmpty,
          reason:
              'cycle-without-snapshot must still drive pool-consistency '
              'invariant (Gap 38 fix)');
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

/// Builds a snapshot that carries a wage-at-lock-time stamp whose
/// wages reproduce the locked theoretical labor dollars. The locked
/// FOH/BOH dollars are derived from the STAMP wages × locked hours so
/// the reconciliation passes when honest. [fohWage]/[bohWage] are the
/// LOCK-TIME wages (intentionally allowed to differ from the live
/// profile to prove Design Rule 8). [tamperFohDollars] breaks the
/// locked FOH dollars to drive the drifted assertion.
WeeklyPlanSnapshot _makeSnapshotWithWageStamp({
  double fohWage = 18.00,
  double bohWage = 20.00,
  bool tamperFohDollars = false,
}) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const perDayCovers = 200;
  const targetPPA = 40.00;
  const targetCPLH = 2.50;
  const targetSPLH = 100.00;
  const perDaySales = perDayCovers * targetPPA;
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
  final weeklyCovers =
      dayRows.fold<int>(0, (s, d) => s + d.forecastCovers);
  final weeklySales =
      dayRows.fold<double>(0, (s, d) => s + d.forecastSales);
  final weeklyFoh =
      dayRows.fold<int>(0, (s, d) => s + d.requiredFohHours);
  final weeklyBoh =
      dayRows.fold<int>(0, (s, d) => s + d.requiredBohHours);

  final fohDollars =
      (weeklyFoh * fohWage) + (tamperFohDollars ? 5000.0 : 0.0);
  final bohDollars = weeklyBoh * bohWage;
  final totalHours = weeklyFoh + weeklyBoh;
  final blended = totalHours > 0
      ? (weeklyFoh * fohWage + weeklyBoh * bohWage) / totalHours
      : 0.0;

  return WeeklyPlanSnapshot(
    snapshotId: 'snap_wage',
    restaurantId: 'r1',
    weekStartDate: '2026-03-23',
    weekEndDate: '2026-03-29',
    targetCycleId: 'cycle_1',
    forecastCovers: weeklyCovers,
    forecastSales: weeklySales,
    requiredFohHours: weeklyFoh,
    requiredBohHours: weeklyBoh,
    theoreticalFohLaborDollars: fohDollars,
    theoreticalBohLaborDollars: bohDollars,
    coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    salesSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    generatedAt: '2026-03-23T00:00:00Z',
    lockedAt: '2026-03-23T00:00:01Z',
    dayRows: dayRows,
    wageAtLockTime: WeeklyPlanSnapshotWagesAtLockTime(
      fohWage: fohWage,
      bohWage: bohWage,
      blendedWage: blended,
    ),
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

WeekData _makeWeekData() => WeekData(
      weekId: '2026-W13',
      weekLabel: 'Mar 23',
      totalCovers: 800,
      totalSales: 32000,
      totalFohHours: 320,
      totalBohHours: 320,
      shiftsCompleted: 9,
      shiftsTotal: 14,
      wtdForecastCovers: 800,
      totalWeekForecastCovers: 1400,
      wtdForecastSales: 32000,
      totalWeekForecastSales: 56000,
      primaryLeverId: 'on_model',
      lastClosedDay: 'Wednesday',
      closedDayNumber: 3,
      lastClosedBusinessDate: '2026-03-25',
      planFohHoursWtd: 240,
      planBohHoursWtd: 240,
      targetCPLH: 2.50,
      targetSPLH: 100.00,
      targetPPA: 40.00,
      targetFohWage: 18.00,
      targetBohWage: 20.00,
      theoreticalFohLaborPct: 18.00,
      theoreticalBohLaborPct: 20.00,
      theoreticalLaborPct: 38.00,
    );
