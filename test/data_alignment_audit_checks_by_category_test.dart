// ─── DataAlignmentAuditReadService — computeAuditChecks Category Tests ──────
//
// Phase 7.56c.1 — grouped audit-check coverage. The computeAuditChecks()
// static is the pure aggregation seam used by the audit service. These
// tests drive synthetic authority inputs and assert per-group alignment /
// drift / unavailable outcomes per the 7.56c.1 phase doc. Live-actuals
// checks are presence/source-label only — no operational variance in the
// architectural drift signal.
//
// Groups in this file:
//   - computeAuditChecks — group: live actuals
//   - computeAuditChecks — group: benchmark authority
//   - computeAuditChecks — group: locked plan <-> projection
//   - computeAuditChecks — auditGroups summary
//   - computeAuditChecks — group: pool consistency (Per-Daypart V1 / Slice 6)
//   - computeAuditChecks — group: wage-at-lock-time (Per-Daypart V1 / Slice 6)
//   - computeAuditChecks — wage-at-lock-time bottom-up reframe (mirrors #917)
//   - computeAuditChecks — Gap 38 structural-ordering consequence
//
// Pure-logic tests — no SQLite, no fixtures.
//
// Bucket 5f of the test-suite tightening audit (2026-05-20): split out of
// `test/data_alignment_audit_read_service_test.dart` (2,161 lines) into
// three focused files:
//   - data_alignment_drift_check_logic_test.dart
//   - data_alignment_audit_checks_by_category_test.dart   (this file)
//   - data_alignment_slice_6_full_scope_test.dart
//
// Library under test: `lib/services/data_alignment_audit_read_service.dart`

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
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

void main() {
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

  // ── Wage-at-lock-time bottom-up reference reframe (mirrors #917) ───────
  //
  // Integer-hours is a model constraint: snapshot.requiredFohHours is
  // `int`, the per-period rows are `double`. Post-#917/#941 the locked
  // dollars are `wage × Σ(per-period UNROUNDED hours)`. The reframed
  // check must reconcile against THAT exact basis (float epsilon), not
  // `wage × snapshot.requiredFohHours(int)` which drifts by the
  // per-day rounding deltas. Empty dayDayparts must preserve the prior
  // whole-day honest behavior (no false pass).
  group('computeAuditChecks — wage-at-lock-time bottom-up reframe', () {
    test(
        'per-period snapshot with int-rounding gap reconciles EXACTLY '
        '(old int-hours reference would have drifted)', () {
      final snap = _wageStampedSnapshotWithRoundingGap();

      // Sanity: the fixture genuinely exercises the bug — the
      // int-rounded locked hours differ from the unrounded per-period
      // sum, so the OLD `wage × int hours` reference would mis-compare
      // by more than a cent.
      final sumFoh = snap.dayDayparts
          .fold<double>(0, (s, d) => s + d.requiredFohHours);
      final oldRef = snap.requiredFohHours * snap.wageAtLockTime!.fohWage;
      expect(
        (oldRef - snap.theoreticalFohLaborDollars).abs(),
        greaterThan(0.01),
        reason: 'fixture must exhibit the int-vs-unrounded reference gap '
            'the reframe fixes (else the test proves nothing)',
      );
      expect(
        (sumFoh - snap.requiredFohHours).abs(),
        greaterThan(0.0),
        reason: 'unrounded per-period FOH hours must differ from the '
            'int-rounded snapshot field',
      );

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
          .where((c) => c.groupId == DataAlignmentAuditGroup.wageAtLockTime)
          .toList();
      expect(wage.length, 4,
          reason: 'stamp presence + FOH \$ + BOH \$ + blended wage');
      // Reframed against the unrounded per-period basis → exact, no
      // false drift from the integer-hours model constraint.
      expect(
        wage.every((c) => c.status == DriftCheckStatus.aligned),
        isTrue,
        reason: 'bottom-up basis (wage × Σ per-period unrounded hrs) '
            'reconciles exactly; the int-hours reference does not',
      );
      final foh = wage.firstWhere((c) =>
          c.label == 'Locked FOH \$ = lock-time FOH wage x locked FOH hrs');
      final boh = wage.firstWhere((c) =>
          c.label == 'Locked BOH \$ = lock-time BOH wage x locked BOH hrs');
      final blended = wage.firstWhere(
          (c) => c.label == 'Lock-time blended wage = locked \$ / locked hrs');
      expect(foh.status, DriftCheckStatus.aligned);
      expect(boh.status, DriftCheckStatus.aligned);
      expect(blended.status, DriftCheckStatus.aligned);
    });

    test('per-period snapshot with tampered locked FOH \$ still drifts', () {
      final snap = _wageStampedSnapshotWithRoundingGap(tamperFohDollars: true);
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
      expect(foh.status, DriftCheckStatus.drifted,
          reason: 'tight epsilon still catches a genuine tamper — the '
              'reframe narrows the reference, it does not loosen rigor');
    });

    test(
        'empty dayDayparts → whole-day honest path preserved exactly '
        '(legacy snapshot still PASSes, tamper still drifts)', () {
      // _makeSnapshotWithWageStamp() carries the stamp but NO
      // per-period rows: a legacy whole-day snapshot whose dollars are
      // self-consistent at the int-locked-hours scale.
      final legacy = _makeSnapshotWithWageStamp();
      final ok = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: legacy,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final okWage = ok
          .where((c) => c.groupId == DataAlignmentAuditGroup.wageAtLockTime)
          .toList();
      expect(
        okWage.every((c) => c.status == DriftCheckStatus.aligned),
        isTrue,
        reason: 'empty dayDayparts keeps the prior whole-day path; a '
            'self-consistent legacy snapshot still reconciles',
      );

      // ...and a genuinely tampered legacy snapshot still surfaces drift
      // (the empty-dayDayparts path is NOT made to falsely pass).
      final tampered = _makeSnapshotWithWageStamp(tamperFohDollars: true);
      final bad = DataAlignmentAuditReadService.computeAuditChecks(
        profile: _profile(),
        targetCycle: null,
        snapshot: tampered,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: null,
        servicePeriodDefinitions: null,
        distributionWeights: null,
      );
      final badFoh = bad.firstWhere((c) =>
          c.label == 'Locked FOH \$ = lock-time FOH wage x locked FOH hrs');
      expect(badFoh.status, DriftCheckStatus.drifted,
          reason: 'empty-dayDayparts path must not be made to falsely pass');
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

/// Builds a wage-stamped, bottom-up locked snapshot that DELIBERATELY
/// exhibits the integer-hours rounding gap the reframe addresses.
///
/// Per-period (`dayDayparts`) required hours are unrounded `double`s
/// chosen so their sum has a fractional part (e.g. covers / non-divisor
/// CPLH). `theoreticalFohLaborDollars` is the honest bottom-up basis:
/// `stamp wage × Σ(per-period UNROUNDED hours)` == `Σ(per-period
/// theoretical $)`. The whole-day `requiredFohHours` is the int-rounded
/// sum (model constraint), so the OLD `wage × int hours` audit
/// reference drifts by `wage × (Σ unrounded − round(Σ))`. The reframed
/// check reconciles against the unrounded basis and is therefore exact.
///
/// [tamperFohDollars] adds a genuine error to the locked FOH dollars so
/// the tight-epsilon reframe still surfaces real drift.
WeeklyPlanSnapshot _wageStampedSnapshotWithRoundingGap({
  bool tamperFohDollars = false,
}) {
  const fohWage = 18.00;
  const bohWage = 20.00;
  const businessDate = '2026-03-23';
  // Three periods whose covers/CPLH and sales/SPLH land on fractional
  // hours so the per-period sum does NOT equal its own integer rounding.
  const periods = <Map<String, double>>[
    {'covers': 130, 'ppa': 41, 'cplh': 3, 'splh': 97},
    {'covers': 280, 'ppa': 39, 'cplh': 3, 'splh': 97},
    {'covers': 95, 'ppa': 42, 'cplh': 3, 'splh': 97},
  ];
  final periodRows = <WeeklyPlanSnapshotDayDaypart>[];
  for (var i = 0; i < periods.length; i++) {
    final p = periods[i];
    final covers = p['covers']!.toInt();
    final sales = covers * p['ppa']!;
    final foh = covers / p['cplh']!; // intentionally non-integer
    final boh = sales / p['splh']!; // intentionally non-integer
    periodRows.add(WeeklyPlanSnapshotDayDaypart(
      businessDate: businessDate,
      servicePeriodId: 'p$i',
      forecastCovers: covers,
      forecastSales: sales,
      requiredFohHours: foh,
      requiredBohHours: boh,
      theoreticalFohDollars: foh * fohWage,
      theoreticalBohDollars: boh * bohWage,
    ));
  }
  final sumCovers = periodRows.fold<int>(0, (s, d) => s + d.forecastCovers);
  final sumSales = periodRows.fold<double>(0, (s, d) => s + d.forecastSales);
  final sumFoh = periodRows.fold<double>(0, (s, d) => s + d.requiredFohHours);
  final sumBoh = periodRows.fold<double>(0, (s, d) => s + d.requiredBohHours);
  final dayRow = WeeklyPlanSnapshotDay(
    day: 'Mon',
    businessDate: businessDate,
    forecastCovers: sumCovers,
    forecastSales: sumSales,
    requiredFohHours: sumFoh.round(), // int model constraint
    requiredBohHours: sumBoh.round(),
  );
  // Honest bottom-up locked dollars = wage × Σ(unrounded per-period hrs).
  final fohDollars =
      (sumFoh * fohWage) + (tamperFohDollars ? 250.0 : 0.0);
  final bohDollars = sumBoh * bohWage;
  final unroundedTotalHours = sumFoh + sumBoh;
  final blended =
      (sumFoh * fohWage + sumBoh * bohWage) / unroundedTotalHours;
  return WeeklyPlanSnapshot(
    snapshotId: 'snap_wage_pp',
    restaurantId: 'r1',
    weekStartDate: '2026-03-23',
    weekEndDate: '2026-03-29',
    targetCycleId: 'cycle_1',
    forecastCovers: dayRow.forecastCovers,
    forecastSales: dayRow.forecastSales,
    requiredFohHours: dayRow.requiredFohHours,
    requiredBohHours: dayRow.requiredBohHours,
    theoreticalFohLaborDollars: fohDollars,
    theoreticalBohLaborDollars: bohDollars,
    coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    salesSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    generatedAt: '2026-03-23T00:00:00Z',
    lockedAt: '2026-03-23T00:00:01Z',
    dayRows: [dayRow],
    dayDayparts: periodRows,
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
