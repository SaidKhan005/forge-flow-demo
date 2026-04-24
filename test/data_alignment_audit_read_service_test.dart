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
// Pure-logic tests — no SQLite, no fixtures. The full end-to-end loadSnapshot
// path is covered by manual smoke via the Settings panel because it requires
// the full SQLite bootstrap chain; this suite protects the decision logic.
//
// Library under test: `lib/services/data_alignment_audit_read_service.dart`
// Model under test:   `lib/models/data_alignment_drift_check.dart`
// Snapshot:           `lib/models/data_alignment_audit_snapshot.dart`

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/wage_standard_context.dart';
import 'package:forge_and_flow/domain/models/wage_standard_source.dart';
import 'package:forge_and_flow/models/data_alignment_audit_snapshot.dart';
import 'package:forge_and_flow/models/data_alignment_drift_check.dart';
import 'package:forge_and_flow/services/data_alignment_audit_read_service.dart';

ActiveTargetProfile _profile({
  double cplh = 2.50,
  double splh = 100.00,
  double ppa = 40.00,
  double fohWage = 18.00,
  double bohWage = 20.00,
}) =>
    ActiveTargetProfile.build(
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
}) =>
    WageStandardContext(
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

    test('adds 2 wage-authority checks when wage context available + aligned',
        () {
      final checks = DataAlignmentAuditReadService.computeDriftChecks(
        profile: _profile(fohWage: 18.00, bohWage: 20.00),
        shiftReadModel: null,
        weekData: null,
        wageContext: _wageContext(fohWage: 18.00, bohWage: 20.00),
      );
      expect(checks.length, 2);
      expect(checks.every((c) => c.ruleReference == 'Wage authority'), isTrue);
      expect(checks.every((c) => c.status == DriftCheckStatus.aligned), isTrue);
    });

    test('flags drifted FOH wage when profile and wage context disagree', () {
      final checks = DataAlignmentAuditReadService.computeDriftChecks(
        profile: _profile(fohWage: 18.00, bohWage: 20.00),
        shiftReadModel: null,
        weekData: null,
        wageContext: _wageContext(fohWage: 17.00, bohWage: 20.00),
      );
      expect(checks.length, 2);
      final foh =
          checks.firstWhere((c) => c.label == 'FOH Wage authority');
      final boh =
          checks.firstWhere((c) => c.label == 'BOH Wage authority');
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
      final foh =
          checks.firstWhere((c) => c.label == 'FOH Wage authority');
      expect(foh.expectedSource, 'ActiveTargetProfile.fohWage');
      expect(foh.comparedSource, 'WageStandardContext.fohWage');
    });
  });

  group('DataAlignmentAuditSnapshot counters', () {
    DataAlignmentAuditSnapshot makeSnapshot(
        List<DataAlignmentDriftCheck> checks) =>
        DataAlignmentAuditSnapshot(
          profile: null,
          demandContext: null,
          plan: null,
          shiftReadModel: null,
          weekData: null,
          wageContext: null,
          driftChecks: checks,
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
}
