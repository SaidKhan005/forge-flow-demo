// Per-Daypart Targets V1 — Slice S0 (foundation).
//
// Pure model round-trip tests for the additive per-period verdict +
// verdictReason fields on:
//   * TargetCycleDaypart        (toMap / fromMap / copyWith)
//   * ActiveTargetProfileDaypart (toMap / fromMap / copyWith)
//   * DaypartCohortStats        (nullable constructor params)
//   * RecommendedBenchmarkSelection.operationVerdict (additive, nullable)
//   * BenchmarkVerdict          (shared string vocabulary)
//
// Back-compat is the headline assertion: omitting the keys yields null,
// and a non-null value round-trips byte-for-byte. No algorithm, seeder,
// widget, or copy is exercised here.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';

void main() {
  group('BenchmarkVerdict vocabulary', () {
    test('exposes the five S0 verdict constants', () {
      expect(BenchmarkVerdict.teachable, 'teachable');
      expect(BenchmarkVerdict.buildingEarly, 'building_early');
      expect(BenchmarkVerdict.buildingFlat, 'building_flat');
      expect(BenchmarkVerdict.buildingFewStrong, 'building_few_strong');
      expect(BenchmarkVerdict.runningHot, 'running_hot');
    });

    test('all contains exactly the five constants', () {
      expect(BenchmarkVerdict.all, <String>[
        'teachable',
        'building_early',
        'building_flat',
        'building_few_strong',
        'running_hot',
      ]);
    });
  });

  group('TargetCycleDaypart verdict round-trip', () {
    TargetCycleDaypart base({String? verdict, String? verdictReason}) =>
        TargetCycleDaypart(
          servicePeriodId: 'dinner',
          targetCPLH: 5.0,
          targetSPLH: 200.0,
          targetPPA: 45.0,
          opzFloorCPLH: 4.5,
          opzCeilingCPLH: 5.5,
          coverCount: 300,
          verdict: verdict,
          verdictReason: verdictReason,
        );

    test('non-null verdict + reason round-trip through toMap/fromMap', () {
      final original = base(
        verdict: BenchmarkVerdict.teachable,
        verdictReason: 'robust cohort, defensible target',
      );
      final restored = TargetCycleDaypart.fromMap(original.toMap());

      expect(restored.verdict, BenchmarkVerdict.teachable);
      expect(restored.verdictReason, 'robust cohort, defensible target');
      // Existing fields unchanged.
      expect(restored.servicePeriodId, 'dinner');
      expect(restored.targetCPLH, 5.0);
      expect(restored.coverCount, 300);
    });

    test('null verdict + reason round-trip as null', () {
      final restored = TargetCycleDaypart.fromMap(base().toMap());
      expect(restored.verdict, isNull);
      expect(restored.verdictReason, isNull);
    });

    test('omitting the keys yields null (back-compat with pre-S0 maps)',
        () {
      // Simulates a row read from a pre-S0 schema: no verdict columns.
      final preS0Map = <String, dynamic>{
        'service_period_id': 'lunch',
        'target_cplh': 4.0,
        'target_splh': 150.0,
        'target_ppa': 35.0,
        'opz_floor_cplh': 3.5,
        'opz_ceiling_cplh': 4.5,
        'cover_count': 100,
      };
      final restored = TargetCycleDaypart.fromMap(preS0Map);
      expect(restored.verdict, isNull);
      expect(restored.verdictReason, isNull);
      expect(restored.servicePeriodId, 'lunch');
      expect(restored.targetCPLH, 4.0);
    });

    test('toMap always emits both verdict keys (null when unset)', () {
      final map = base().toMap();
      expect(map.containsKey('verdict'), isTrue);
      expect(map.containsKey('verdict_reason'), isTrue);
      expect(map['verdict'], isNull);
      expect(map['verdict_reason'], isNull);
    });

    test('copyWith overrides verdict + reason additively', () {
      final updated = base().copyWith(
        verdict: BenchmarkVerdict.runningHot,
        verdictReason: 'cohort skewed hot',
      );
      expect(updated.verdict, BenchmarkVerdict.runningHot);
      expect(updated.verdictReason, 'cohort skewed hot');
      expect(updated.servicePeriodId, 'dinner');
      expect(updated.targetCPLH, 5.0);
    });
  });

  group('ActiveTargetProfileDaypart verdict round-trip', () {
    ActiveTargetProfileDaypart base({
      String? verdict,
      String? verdictReason,
    }) =>
        ActiveTargetProfileDaypart(
          servicePeriodId: 'late_night',
          daypartTargetCPLH: 3.0,
          daypartTargetSPLH: 120.0,
          daypartTargetPPA: 28.0,
          daypartOpzFloorCPLH: 2.5,
          daypartOpzCeilingCPLH: 3.5,
          verdict: verdict,
          verdictReason: verdictReason,
        );

    test('non-null verdict + reason round-trip through toMap/fromMap', () {
      final original = base(
        verdict: BenchmarkVerdict.buildingFewStrong,
        verdictReason: 'only a few strong records so far',
      );
      final restored =
          ActiveTargetProfileDaypart.fromMap(original.toMap());

      expect(restored.verdict, BenchmarkVerdict.buildingFewStrong);
      expect(restored.verdictReason, 'only a few strong records so far');
      expect(restored.servicePeriodId, 'late_night');
      expect(restored.daypartTargetCPLH, 3.0);
    });

    test('null verdict + reason round-trip as null', () {
      final restored =
          ActiveTargetProfileDaypart.fromMap(base().toMap());
      expect(restored.verdict, isNull);
      expect(restored.verdictReason, isNull);
    });

    test('omitting the keys yields null (back-compat with pre-S0 maps)',
        () {
      final preS0Map = <String, dynamic>{
        'service_period_id': 'dinner',
        'daypart_target_cplh': 5.0,
        'daypart_target_splh': 200.0,
        'daypart_target_ppa': 45.0,
        'daypart_opz_floor_cplh': 4.5,
        'daypart_opz_ceiling_cplh': 5.5,
      };
      final restored = ActiveTargetProfileDaypart.fromMap(preS0Map);
      expect(restored.verdict, isNull);
      expect(restored.verdictReason, isNull);
      expect(restored.servicePeriodId, 'dinner');
    });

    test('copyWith overrides verdict + reason additively', () {
      final updated = base().copyWith(
        verdict: BenchmarkVerdict.buildingFlat,
        verdictReason: 'range degenerate',
      );
      expect(updated.verdict, BenchmarkVerdict.buildingFlat);
      expect(updated.verdictReason, 'range degenerate');
      expect(updated.servicePeriodId, 'late_night');
    });
  });

  group('DaypartCohortStats + RecommendedBenchmarkSelection additive', () {
    test('DaypartCohortStats verdict defaults to null', () {
      const stats = DaypartCohortStats(
        daypart: 'lunch',
        eligibleCount: 12,
        outlierCount: 1,
        selectedCount: 8,
        medianCPLH: 4.0,
        madCPLH: 0.2,
        iqrCPLH: 0.5,
        medianPPA: 35.0,
        medianLaborPct: null,
        opzFloorCPLH: 3.5,
        opzCeilingCPLH: 4.5,
        recommendedTargetCPLH: 4.0,
        recommendedTargetSPLH: 150.0,
        recommendedTargetPPA: 35.0,
        cohortQuality: 'strong',
        cohortExplanation: 'robust',
      );
      expect(stats.verdict, isNull);
      expect(stats.verdictReason, isNull);
    });

    test('DaypartCohortStats accepts non-null verdict + reason', () {
      const stats = DaypartCohortStats(
        daypart: 'lunch',
        eligibleCount: 12,
        outlierCount: 1,
        selectedCount: 8,
        medianCPLH: 4.0,
        madCPLH: 0.2,
        iqrCPLH: 0.5,
        medianPPA: 35.0,
        medianLaborPct: null,
        opzFloorCPLH: 3.5,
        opzCeilingCPLH: 4.5,
        recommendedTargetCPLH: 4.0,
        recommendedTargetSPLH: 150.0,
        recommendedTargetPPA: 35.0,
        cohortQuality: 'strong',
        cohortExplanation: 'robust',
        verdict: BenchmarkVerdict.teachable,
        verdictReason: 'robust cohort',
      );
      expect(stats.verdict, BenchmarkVerdict.teachable);
      expect(stats.verdictReason, 'robust cohort');
      // Existing fields preserved unchanged.
      expect(stats.cohortQuality, 'strong');
    });

    test('RecommendedBenchmarkSelection.operationVerdict defaults null',
        () {
      const sel = RecommendedBenchmarkSelection(
        selectedRecordIds: <String>{},
        excludedOutlierIds: <String>{},
        excludedByGateIds: <String>{},
        perDaypartStats: <String, DaypartCohortStats>{},
        unionOpzFloorCPLH: 0,
        unionOpzCeilingCPLH: 0,
        pooledRecommendedTargetCPLH: 0,
        pooledRecommendedTargetSPLH: 0,
        pooledRecommendedTargetPPA: 0,
        overallQuality: 'strong',
        explanationMetadata: 'meta',
      );
      expect(sel.operationVerdict, isNull);
      // overallQuality is NOT replaced/repurposed.
      expect(sel.overallQuality, 'strong');
    });

    test('RecommendedBenchmarkSelection accepts operationVerdict', () {
      const sel = RecommendedBenchmarkSelection(
        selectedRecordIds: <String>{},
        excludedOutlierIds: <String>{},
        excludedByGateIds: <String>{},
        perDaypartStats: <String, DaypartCohortStats>{},
        unionOpzFloorCPLH: 0,
        unionOpzCeilingCPLH: 0,
        pooledRecommendedTargetCPLH: 0,
        pooledRecommendedTargetSPLH: 0,
        pooledRecommendedTargetPPA: 0,
        overallQuality: 'strong',
        explanationMetadata: 'meta',
        operationVerdict: BenchmarkVerdict.teachable,
      );
      expect(sel.operationVerdict, BenchmarkVerdict.teachable);
      expect(sel.overallQuality, 'strong');
    });

    test('insufficient factory leaves operationVerdict null (back-compat)',
        () {
      final sel = RecommendedBenchmarkSelection.insufficient(
        excludedByGateIds: const <String>{},
        reason: 'no evidence',
      );
      expect(sel.operationVerdict, isNull);
      expect(sel.isInsufficient, isTrue);
    });
  });
}
