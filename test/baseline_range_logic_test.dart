// ─── Baseline Range Logic Tests ──────────────────────────────────────────────
// Prompt 6.1 + 6.2 verification:
//   - Historical context metrics are stable regardless of override state
//   - Graph outer endpoints are always the 60-day historical range
//   - Active inner range reflects selected benchmark/star-shift range
//   - Graph labels are correct by override state
//   - BaselineRangeValidation status rules are deterministic

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/data/baseline_manager_service.dart';
import 'package:forge_flow_demo/data/database_helper.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';

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

  // ── A: historical context metrics do not depend on active override ────────

  group('A — historical context stability', () {
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

  // ── B: historical weekly average formula ──────────────────────────────────

  group('B — historical weekly average formula', () {
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

  // ── C: graph labels by override state ─────────────────────────────────────

  group('C — graph labels by override state', () {
    test('no override: historical labels and BENCHMARK RANGE', () async {
      await BaselineManagerService.instance.primeManagerOverride();

      // Clear any existing selection so override is not active
      await BaselineManagerService.instance.saveSelection({});

      final m = BaselineData.rangeGraphModel;
      expect(m.title, equals('RECOMMENDED TARGET'));
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

    test('title remains RECOMMENDED TARGET in both states', () async {
      // No override
      expect(BaselineData.rangeGraphModel.title, equals('RECOMMENDED TARGET'));

      // With override
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      final pick = candidates.take(3).map((c) => c.recordKey).toSet();
      await BaselineManagerService.instance.saveSelection(pick);
      expect(BaselineData.rangeGraphModel.title, equals('RECOMMENDED TARGET'));
    });
  });

  // ── D: active range reflects selected star shifts ─────────────────────────

  group('D — active range under override', () {
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

  // ── E: baseline range validation status rules ─────────────────────────────

  group('E — BaselineRangeValidation status rules', () {
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
}
