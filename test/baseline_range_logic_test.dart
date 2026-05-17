// â”€â”€â”€ Baseline Range Logic Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Prompt 6.1 + 6.2 verification:
//   - Historical context metrics are stable regardless of override state
//   - Graph outer endpoints are always the 60-day historical range
//   - Active inner range reflects selected benchmark/star-shift range
//   - Graph labels are correct by override state
//   - BaselineRangeValidation status rules are deterministic

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart'
    show BenchmarkVerdict;
import 'package:forge_and_flow/services/baseline_authority_service.dart'
    show BaselineGraphButtonEmphasis;
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';

void main() {
  setUp(() async {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    await DatabaseHelper.instance.reseedDemo();
  });

  tearDown(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
  });

  // â”€â”€ A: historical context metrics do not depend on active override â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” historical context stability', () {
    test('historicalTotalCoversTracked and historicalWeeklyAvgCovers are stable across override',
        () async {
      await BaselineManagerService.instance.primeManagerOverride();

      final totalBefore = BaselineData.historicalTotalCoversTracked;
      final avgBefore = BaselineData.historicalWeeklyAvgCovers;

      // Save a non-empty override selection
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      final pick = candidates.take(3).map((c) => c.recordKey).toSet();
      await BaselineManagerService.instance.saveSelection(pick);

      expect(BaselineData.hasManagerOverride, isTrue);
      expect(BaselineData.historicalTotalCoversTracked, equals(totalBefore));
      expect(BaselineData.historicalWeeklyAvgCovers, equals(avgBefore));
    });

    test('display endpoints remain historical even with override active',
        () async {
      await BaselineManagerService.instance.primeManagerOverride();

      final histCplh =
          BaselineData.historicalContextRecords.map((r) => r.cplh).toList();
      final expectedHistMin = histCplh.reduce(math.min);
      final expectedHistMax = histCplh.reduce(math.max);

      // Save a non-empty override selection
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      final pick = candidates.take(3).map((c) => c.recordKey).toSet();
      await BaselineManagerService.instance.saveSelection(pick);

      final m = BaselineData.rangeGraphModel;
      expect(m.displayRangeStartCPLH, equals(expectedHistMin));
      expect(m.displayRangeEndCPLH, equals(expectedHistMax));
      expect(m.startLabel, equals('LOWEST CPLH LAST 60 DAYS'));
      expect(m.endLabel, equals('HIGHEST CPLH LAST 60 DAYS'));
    });
  });

  // â”€â”€ B: historical weekly average formula â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” historical weekly average formula', () {
    test('historicalWeeklyAvgCovers == (totalCovers / (60/7)).round()',
        () async {
      await BaselineManagerService.instance.primeManagerOverride();

      expect(
        BaselineData.historicalWeeklyAvgCovers,
        equals(
            (BaselineData.historicalTotalCoversTracked / (60 / 7)).round()),
      );
    });
  });

  // â”€â”€ C: graph labels by override state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C â€” graph labels by override state', () {
    test('no override: historical labels and BENCHMARK RANGE', () async {
      await BaselineManagerService.instance.primeManagerOverride();

      // Clear any existing selection so override is not active
      await BaselineManagerService.instance.saveSelection({});

      final m = BaselineData.rangeGraphModel;
      expect(m.title, equals('CPLH RANGE & TARGET'));
      expect(m.startLabel, equals('LOWEST CPLH LAST 60 DAYS'));
      expect(m.endLabel, equals('HIGHEST CPLH LAST 60 DAYS'));
      expect(m.rangeLabel, equals('BENCHMARK RANGE'));
    });

    test('with override: STAR SHIFT RANGE, same outer labels', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      final pick = candidates.take(3).map((c) => c.recordKey).toSet();
      await BaselineManagerService.instance.saveSelection(pick);

      final m = BaselineData.rangeGraphModel;
      expect(m.startLabel, equals('LOWEST CPLH LAST 60 DAYS'));
      expect(m.endLabel, equals('HIGHEST CPLH LAST 60 DAYS'));
      expect(m.rangeLabel, equals('STAR SHIFT RANGE'));
    });

    test('title remains CPLH RANGE & TARGET in both states', () async {
      // No override
      expect(BaselineData.rangeGraphModel.title, equals('CPLH RANGE & TARGET'));

      // With override
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      final pick = candidates.take(3).map((c) => c.recordKey).toSet();
      await BaselineManagerService.instance.saveSelection(pick);
      expect(BaselineData.rangeGraphModel.title, equals('CPLH RANGE & TARGET'));
    });
  });

  // â”€â”€ D: active range reflects selected star shifts â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D â€” active range under override', () {
    test('activeRange matches selected candidate min/max CPLH', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      final pick = candidates.take(4).toList();
      final expectedMin = pick.map((c) => c.cplh).reduce(math.min);
      final expectedMax = pick.map((c) => c.cplh).reduce(math.max);

      await BaselineManagerService.instance
          .saveSelection(pick.map((c) => c.recordKey).toSet());

      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeStartCPLH, equals(expectedMin));
      expect(m.activeRangeEndCPLH, equals(expectedMax));
    });
  });

  // â”€â”€ E: baseline range validation status rules â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E â€” BaselineRangeValidation status rules', () {
    tearDown(() {
      BaselineData.clearManagerOverride();
      BaselineData.clearHistoricalContext();
    });

    test('narrow range: status too_narrow', () {
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.50, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.51, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
      ]);

      final v = BaselineData.baselineRangeValidation;
      expect(v.status, equals('too_narrow'));
      expect(v.statusLabel, equals('OPZ RANGE TOO NARROW'));
      expect(v.showWarning, isTrue);
    });

    test('healthy range: status healthy', () {
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 160,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.6, splh: 181, ppa: 44, covers: 240,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.9, splh: 183, ppa: 45, covers: 250,
            isSelected: true),
      ]);

      final v = BaselineData.baselineRangeValidation;
      expect(v.status, equals('healthy'));
      expect(v.statusLabel, equals('GOOD OPZ RANGE'));
      expect(v.showWarning, isFalse);
    });

    test('wide range: status too_wide', () {
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 3.2, splh: 168, ppa: 38, covers: 140,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.4, splh: 178, ppa: 44, covers: 230,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.8, splh: 182, ppa: 45, covers: 248,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'late_night', cplh: 5.0, splh: 183, ppa: 37, covers: 92,
            isSelected: true),
      ]);

      final v = BaselineData.baselineRangeValidation;
      expect(v.status, equals('too_wide'));
      expect(v.statusLabel, equals('OPZ RANGE TOO WIDE'));
      expect(v.showWarning, isTrue);
    });
  });

  // ── F: graph active range always sits within historical context ────────────

  group('F — graph active range within historical context (7.55m.5)', () {
    // These tests use controlled data to verify graph normalization.
    // In the bridge era, primeManagerOverride() with no selections can
    // leave historicalContextRecords and records from different sources
    // (SQLite vs seed data). That is not a distortion — it is the
    // compatibility bridge working as designed. See phase_7_55m_5 doc.

    test('active range positions are normalized within [0, 1]', () {
      // Controlled data: historical context is wider than selection
      BaselineData.applyHistoricalContext([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 3.0, splh: 160, ppa: 38, covers: 130),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 6.0, splh: 195, ppa: 48, covers: 280),
      ]);
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 3.0, splh: 160, ppa: 38, covers: 130,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.5, splh: 180, ppa: 43, covers: 220,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 5.0, splh: 185, ppa: 45, covers: 240,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 6.0, splh: 195, ppa: 48, covers: 280),
      ]);

      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeStartPosition, greaterThanOrEqualTo(0.0));
      expect(m.activeRangeStartPosition, lessThanOrEqualTo(1.0));
      expect(m.activeRangeEndPosition, greaterThanOrEqualTo(0.0));
      expect(m.activeRangeEndPosition, lessThanOrEqualTo(1.0));
      expect(m.targetPosition, greaterThanOrEqualTo(0.0));
      expect(m.targetPosition, lessThanOrEqualTo(1.0));
    });

    test('active range with override stays within historical range',
        () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      final pick = candidates.take(3).map((c) => c.recordKey).toSet();
      await BaselineManagerService.instance.saveSelection(pick);

      // After saveSelection with non-empty keys, primeManagerOverride
      // is called again and both sources are consistent.
      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeStartCPLH,
          greaterThanOrEqualTo(m.historicalRangeStartCPLH));
      expect(m.activeRangeEndCPLH,
          lessThanOrEqualTo(m.historicalRangeEndCPLH));
      expect(m.activeRangeStartPosition, greaterThanOrEqualTo(0.0));
      expect(m.activeRangeEndPosition, lessThanOrEqualTo(1.0));
    });
  });

  // ── H: no-selection fallback split (7.55m.5a) ──────────────────────────────

  group('H — no-selection fallback split (7.55m.5a)', () {
    test('no selected records: range-quality is too_narrow but OPZ bounds still resolve',
        () {
      // All records, none selected — simulates the no-selection fallback
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 3.8, splh: 170, ppa: 40, covers: 150),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.5, splh: 180, ppa: 43, covers: 220),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 5.2, splh: 188, ppa: 46, covers: 260),
      ]);

      // Range-quality sees 0 selected → too_narrow
      final v = BaselineData.baselineRangeValidation;
      expect(v.status, equals('too_narrow'));
      expect(v.statusLabel, equals('OPZ RANGE TOO NARROW'));

      // OPZ bounds fall back to all records → still resolve
      expect(BaselineData.opzFloorCPLH, equals(3.8));
      expect(BaselineData.opzCeilingCPLH, equals(5.2));

      // Shift zone status still works against these fallback bounds
      expect(BaselineData.opzStatusForCplh(4.5), equals('in'));
      expect(BaselineData.opzStatusForCplh(3.0), equals('below'));
    });
  });

  // ── G: Shift zone status is independent of benchmark range quality ────────

  group('G — zone status independent of range quality (7.55m.5)', () {
    test('live CPLH below floor produces "below" even with healthy range',
        () {
      // Set up a healthy selection (CPLH width ~0.7 — within thresholds)
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 160,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.6, splh: 181, ppa: 44, covers: 240,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.9, splh: 183, ppa: 45, covers: 250,
            isSelected: true),
      ]);

      // Confirm range quality is healthy
      final v = BaselineData.baselineRangeValidation;
      expect(v.status, equals('healthy'));

      // A live CPLH below the OPZ floor should produce 'below'
      // regardless of selection quality
      final zoneStatus = BaselineData.opzStatusForCplh(3.0);
      expect(zoneStatus, equals('below'));
    });

    test('live CPLH inside OPZ produces "in" even with too-wide range', () {
      // Set up a too-wide selection (CPLH width > 1.25)
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 3.2, splh: 168, ppa: 38, covers: 140,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 5.0, splh: 183, ppa: 37, covers: 92,
            isSelected: true),
      ]);

      // Confirm range quality is too_wide
      final v = BaselineData.baselineRangeValidation;
      expect(v.status, equals('too_wide'));

      // A live CPLH inside the OPZ should produce 'in'
      // regardless of selection quality
      final zoneStatus = BaselineData.opzStatusForCplh(4.0);
      expect(zoneStatus, equals('in'));
    });
  });

  // ── I: OPZ range-quality message alignment (7.55m.6a) ─────────────────────

  group('I — OPZ range-quality message alignment (7.55m.6a)', () {
    tearDown(() {
      BaselineData.clearManagerOverride();
      BaselineData.clearHistoricalContext();
    });

    test('rangeWidth < 0.15 branch uses shortened narrow copy', () {
      // Two selected shifts with width 0.01 (< 0.15 threshold)
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.50, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.51, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
      ]);

      final v = BaselineData.baselineRangeValidation;
      expect(v.status, equals('too_narrow'));
      expect(v.message,
          equals('Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.'));
    });

    test('fewer-than-2 branch uses same shortened narrow copy', () {
      // One selected shift — hits the < 2 guard
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.50, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
      ]);

      final v = BaselineData.baselineRangeValidation;
      expect(v.status, equals('too_narrow'));
      expect(v.message,
          equals('Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.'));
    });

    test('all three messages are shortened (no old long copy remains)', () {
      // Narrow
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.50, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.51, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
      ]);
      expect(BaselineData.baselineRangeValidation.message,
          isNot(contains('repeatable standard')));

      // Healthy
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 160,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.6, splh: 181, ppa: 44, covers: 240,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.9, splh: 183, ppa: 45, covers: 250,
            isSelected: true),
      ]);
      expect(BaselineData.baselineRangeValidation.message,
          isNot(contains('Recommended target')));

      // Wide
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 3.2, splh: 168, ppa: 38, covers: 140,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 5.0, splh: 183, ppa: 37, covers: 92,
            isSelected: true),
      ]);
      expect(BaselineData.baselineRangeValidation.message,
          isNot(contains('operating range')));
    });
  });

  // ── J: Benchmark graph honesty (7.55p.5h) ─────────────────────────────────
  //
  // Covers the degenerate-state fallback on `BaselineRangeGraphModel`.
  // Manager-override branch: delegates to the existing
  // `baselineRangeValidation` derivation. Recommendation-signals branch:
  // drives honest fallback badges + copy without touching the
  // recommendation math.

  group('J — recommendation-signal honesty (7.55p.5h)', () {
    tearDown(() {
      BaselineData.clearManagerOverride();
      BaselineData.clearHistoricalContext();
      BaselineData.clearRecommendationSignals();
    });

    test('no signals + no override → graph matches existing '
        'baselineRangeValidation (preserves legacy tests)', () {
      // Fresh reseed via setUp already put us in the no-signals / no-override
      // default. The graph should produce the existing healthy copy
      // because the demo seed is GOOD.
      final v = BaselineData.baselineRangeValidation;
      final m = BaselineData.rangeGraphModel;
      expect(m.qualityTier, v.status);
      expect(m.statusBadgeLabel, v.statusLabel);
      expect(m.recommendedExplanation, v.message);
      expect(m.isDegenerate, v.showWarning);
      expect(m.degenerateFallbackMessage, isNull);
    });

    // ── SC: verdict-driven honest copy (verbatim, no em-dashes) ───────
    //
    // Behaviour change (spec §6/§8/§9, NOT a regression): the Benchmark
    // graph copy is now keyed off the single-source `verdict` SB carried
    // onto `BaselineRecommendationSignals` (the no-poisoning rollup of
    // the persisted per-period verdicts), NOT `overallQuality` or the
    // cross-daypart union. The vestigial "RANGE TOO WIDE TO TEACH" /
    // "RANGE UNCERTAIN" / "let more shifts close … will settle" states
    // are removed (spec §8 Decision 1 → 1b). Every string below is
    // asserted verbatim and must contain no em-dash.

    void expectNoEmDash(String s) =>
        expect(s.contains('—'), isFalse, reason: 'no em-dash in: $s');

    test('teachable verdict → GOOD OPZ RANGE verbatim copy', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'strong',
          unionBandWidth: 0.60,
          selectedShiftCount: 10,
          rangeFloorCPLH: 4.3,
          rangeCeilingCPLH: 4.9,
          targetCPLH: 4.6,
          verdict: BenchmarkVerdict.teachable,
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.qualityTier, 'good');
      expect(m.isDegenerate, isFalse);
      expect(m.statusBadgeLabel, 'GOOD OPZ RANGE');
      expect(
          m.recommendedExplanation,
          'Covers, sales per hour and spend were all strong together on '
          'this range.');
      expect(m.degenerateFallbackMessage, 'Coach the team to this number.');
      expect(m.buttonEmphasis, BaselineGraphButtonEmphasis.solid);
      expectNoEmDash(m.recommendedExplanation);
      expectNoEmDash(m.degenerateFallbackMessage!);
    });

    test('building_early verdict → NOT ENOUGH SHIFTS YET + ghost button',
        () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'weak',
          unionBandWidth: 0,
          selectedShiftCount: 1,
          rangeFloorCPLH: 0,
          rangeCeilingCPLH: 0,
          targetCPLH: 0,
          verdict: BenchmarkVerdict.buildingEarly,
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.qualityTier, 'building');
      expect(m.isDegenerate, isTrue);
      expect(m.statusBadgeLabel, 'NOT ENOUGH SHIFTS YET');
      expect(
          m.recommendedExplanation,
          'We need more closed shifts before we can set a number you can '
          'coach to.');
      expect(
          m.degenerateFallbackMessage,
          'Keep running the period as usual. We are just watching for '
          'now.');
      // building_early de-emphasizes the CHOOSE STAR SHIFTS button.
      expect(m.buttonEmphasis, BaselineGraphButtonEmphasis.deemphasized);
      expectNoEmDash(m.recommendedExplanation);
      expectNoEmDash(m.degenerateFallbackMessage!);
    });

    test('building_flat verdict → RANGE BUILDING + solid button', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'weak',
          unionBandWidth: 0,
          selectedShiftCount: 6,
          rangeFloorCPLH: 0,
          rangeCeilingCPLH: 0,
          targetCPLH: 0,
          verdict: BenchmarkVerdict.buildingFlat,
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.qualityTier, 'building');
      expect(m.isDegenerate, isTrue);
      expect(m.statusBadgeLabel, 'RANGE BUILDING');
      expect(
          m.recommendedExplanation,
          'There is not enough real variation between shifts yet to '
          'define a band.');
      expect(
          m.degenerateFallbackMessage,
          'For now, pick the shifts that felt best for team productivity '
          'by hand while we keep building.');
      // copy steers to manual pick → keep the button solid.
      expect(m.buttonEmphasis, BaselineGraphButtonEmphasis.solid);
      expectNoEmDash(m.recommendedExplanation);
      expectNoEmDash(m.degenerateFallbackMessage!);
    });

    test('building_few_strong verdict → NOT ENOUGH STRONG SHIFTS', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'weak',
          unionBandWidth: 0,
          selectedShiftCount: 3,
          rangeFloorCPLH: 0,
          rangeCeilingCPLH: 0,
          targetCPLH: 0,
          verdict: BenchmarkVerdict.buildingFewStrong,
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.qualityTier, 'building');
      expect(m.isDegenerate, isTrue);
      expect(m.statusBadgeLabel, 'NOT ENOUGH STRONG SHIFTS');
      expect(
          m.recommendedExplanation,
          'Only a handful of shifts had covers, sales per hour and spend '
          'all strong together. We need more before coaching to a '
          'number.');
      expect(
          m.degenerateFallbackMessage,
          'For now, pick the shifts where the floor felt good, ticket '
          'times stayed clean and checks held. Those are the ones we '
          'need more of.');
      expect(m.buttonEmphasis, BaselineGraphButtonEmphasis.solid);
      expectNoEmDash(m.recommendedExplanation);
      expectNoEmDash(m.degenerateFallbackMessage!);
    });

    test('running_hot verdict → OPERATION RUNNING HOT, no sub-line', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'adequate',
          unionBandWidth: 0.50,
          selectedShiftCount: 8,
          rangeFloorCPLH: 4.2,
          rangeCeilingCPLH: 4.7,
          targetCPLH: 4.5,
          verdict: BenchmarkVerdict.runningHot,
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.qualityTier, 'running_hot');
      expect(m.isDegenerate, isTrue);
      expect(m.statusBadgeLabel, 'OPERATION RUNNING HOT');
      expect(
          m.recommendedExplanation,
          'Your best shifts show the team running hot: high covers per '
          'hour, weaker spend and labor. Fix the staffing pressure '
          'before holding the team to this.');
      expect(m.degenerateFallbackMessage, isNull);
      expect(m.buttonEmphasis, BaselineGraphButtonEmphasis.solid);
      expectNoEmDash(m.recommendedExplanation);
    });

    test('no verdict (legacy/insufficient) → honest NOT ENOUGH SHIFTS '
        'YET, never the old "will settle" copy', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended_insufficient',
          overallQuality: 'insufficient',
          unionBandWidth: 0,
          selectedShiftCount: 0,
          rangeFloorCPLH: 3.5,
          rangeCeilingCPLH: 5.8,
          targetCPLH: 4.5,
          // verdict intentionally null (pre-verdict / insufficient).
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.qualityTier, 'building');
      expect(m.isDegenerate, isTrue);
      expect(m.statusBadgeLabel, 'NOT ENOUGH SHIFTS YET');
      // The misleading remedy lines are gone entirely.
      expect(m.recommendedExplanation.contains('let more shifts close'),
          isFalse);
      expect(m.recommendedExplanation.contains('will settle'), isFalse);
      expect((m.degenerateFallbackMessage ?? '').contains('will settle'),
          isFalse);
      expect(m.buttonEmphasis, BaselineGraphButtonEmphasis.deemphasized);
    });

    test('per-period rollup line is the approved Scenario 7 copy', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'strong',
          unionBandWidth: 0.60,
          selectedShiftCount: 10,
          rangeFloorCPLH: 4.3,
          rangeCeilingCPLH: 4.9,
          targetCPLH: 4.6,
          verdict: BenchmarkVerdict.teachable,
        ),
      );
      final m = BaselineData.rangeGraphModel;
      expect(
          m.perPeriodRollupLine,
          'Each period is graded on its own. Coach to the periods marked '
          'ready; leave the others until they settle. One period not '
          'being ready does not hold back the others.');
      expectNoEmDash(m.perPeriodRollupLine);
    });

    test('manager override wins even when signals say insufficient', () {
      // Simulate a prior recommended-path cycle that left insufficient
      // signals behind, then a manager override arrives. The graph
      // should fall back to the existing star-shift copy for the
      // manager's explicit selection.
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended_insufficient',
          overallQuality: 'insufficient',
          unionBandWidth: 0,
          selectedShiftCount: 0,
          rangeFloorCPLH: 3.5,
          rangeCeilingCPLH: 5.8,
          targetCPLH: 4.5,
        ),
      );
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 160,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.6, splh: 181, ppa: 44, covers: 240,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.9, splh: 183, ppa: 45, covers: 250,
            isSelected: true),
      ]);

      final v = BaselineData.baselineRangeValidation;
      final m = BaselineData.rangeGraphModel;

      // Manager override takes precedence — we route through
      // baselineRangeValidation (healthy here, drives tier/geometry),
      // not the insufficient recommendation signals. SC: the
      // operator-facing copy is the approved hand-picked string.
      expect(v.status, 'healthy');
      expect(m.qualityTier, 'healthy');
      expect(m.statusBadgeLabel, 'YOUR CHOSEN SHIFTS');
      expect(
          m.recommendedExplanation,
          'You are coaching to a hand-picked set of shifts. Make sure '
          'they represent good shifts.');
      expect(m.recommendedExplanation.contains('—'), isFalse);
      expect(m.isDegenerate, isFalse);
      expect(m.degenerateFallbackMessage, isNull);
      expect(m.buttonEmphasis, BaselineGraphButtonEmphasis.solid);
      // Inner range label reflects manager override.
      expect(m.rangeLabel, 'STAR SHIFT RANGE');
      // Geometry comes from the selected override records (4.2 / 4.9 /
      // avg ≈ 4.57), NOT the insufficient signals (3.5 / 5.8 / 4.5).
      expect(m.activeRangeStartCPLH, closeTo(4.2, 0.001));
      expect(m.activeRangeEndCPLH, closeTo(4.9, 0.001));
      expect(m.targetCPLH, closeTo(4.57, 0.05));
    });

    test('clearRecommendationSignals returns graph to the default branch',
        () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended_insufficient',
          overallQuality: 'insufficient',
          unionBandWidth: 0,
          selectedShiftCount: 0,
          rangeFloorCPLH: 3.5,
          rangeCeilingCPLH: 5.8,
          targetCPLH: 4.5,
        ),
      );
      expect(BaselineData.rangeGraphModel.isDegenerate, isTrue);

      BaselineData.clearRecommendationSignals();
      final v = BaselineData.baselineRangeValidation;
      final m = BaselineData.rangeGraphModel;
      expect(m.qualityTier, v.status);
      expect(m.statusBadgeLabel, v.statusLabel);
      expect(m.isDegenerate, v.showWarning);
      expect(m.degenerateFallbackMessage, isNull);
    });
  });

  // ── K: Graph geometry matches signals source truth (7.55p.5h-review-fix)
  //
  // Proves that when recommendation signals are present and no manager
  // override is active, the drawn inner band + target come from the
  // signals (which mirror the persisted cycle) rather than
  // `BaselineData.records.where(isSelected)`. This is the finding the
  // review surfaced: previously the copy said "Config Default
  // placeholder" while the geometry still drew seed-selected values.

  group('K — graph geometry matches signal source truth '
      '(7.55p.5h-review-fix)', () {
    tearDown(() {
      BaselineData.clearManagerOverride();
      BaselineData.clearHistoricalContext();
      BaselineData.clearRecommendationSignals();
    });

    test('insufficient → graph geometry reflects Config Default placeholder '
        '(3.5 / 5.8 / 4.5), not seed-selected (4.2-4.8 / ~4.58)', () {
      // Fresh reseed leaves BaselineData.records = seed records with
      // 14 isSelected shifts. Without signals the graph would draw
      // activeMin ≈ 4.2, activeMax ≈ 4.8, target ≈ 4.58. With
      // insufficient signals it must instead draw the MeridianConfig
      // placeholder.
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended_insufficient',
          overallQuality: 'insufficient',
          unionBandWidth: 0,
          selectedShiftCount: 0,
          rangeFloorCPLH: 3.5,
          rangeCeilingCPLH: 5.8,
          targetCPLH: 4.5,
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeStartCPLH, closeTo(3.5, 0.001),
          reason: 'insufficient floor must come from the signal');
      expect(m.activeRangeEndCPLH, closeTo(5.8, 0.001),
          reason: 'insufficient ceiling must come from the signal');
      expect(m.targetCPLH, closeTo(4.5, 0.001),
          reason: 'insufficient target must come from the signal');

      // Cross-check: seed-selected derivation is NOT in play here.
      final seedSelected =
          BaselineData.records.where((r) => r.isSelected).toList();
      final seedSelectedAvg =
          seedSelected.fold<double>(0, (s, r) => s + r.cplh) /
              seedSelected.length;
      expect(m.targetCPLH, isNot(closeTo(seedSelectedAvg, 0.01)),
          reason:
              'target must not match the legacy seed-selected derivation');
    });

    test('weak+wide → graph geometry reflects signal union band, not '
        'seed-selected', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'weak',
          unionBandWidth: 1.40,
          selectedShiftCount: 12,
          rangeFloorCPLH: 3.8,
          rangeCeilingCPLH: 5.2,
          targetCPLH: 4.5,
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeStartCPLH, closeTo(3.8, 0.001));
      expect(m.activeRangeEndCPLH, closeTo(5.2, 0.001));
      expect(m.targetCPLH, closeTo(4.5, 0.001));
    });

    test('strong → graph geometry still reflects the signal values '
        '(recommendation-backed)', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'strong',
          unionBandWidth: 0.60,
          selectedShiftCount: 10,
          rangeFloorCPLH: 4.30,
          rangeCeilingCPLH: 4.90,
          targetCPLH: 4.58,
        ),
      );

      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeStartCPLH, closeTo(4.30, 0.001));
      expect(m.activeRangeEndCPLH, closeTo(4.90, 0.001));
      expect(m.targetCPLH, closeTo(4.58, 0.001));
    });

    test('clearing signals restores legacy seed-selected geometry', () {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended_insufficient',
          overallQuality: 'insufficient',
          unionBandWidth: 0,
          selectedShiftCount: 0,
          rangeFloorCPLH: 3.5,
          rangeCeilingCPLH: 5.8,
          targetCPLH: 4.5,
        ),
      );
      expect(BaselineData.rangeGraphModel.targetCPLH, closeTo(4.5, 0.001));

      BaselineData.clearRecommendationSignals();
      final m = BaselineData.rangeGraphModel;
      // Back to seed-selected derivation (target ≈ 4.58 from 14 selected
      // records in the default seed).
      expect(m.targetCPLH, closeTo(BaselineData.derivedTargetCPLH, 0.001));
    });
  });
}


