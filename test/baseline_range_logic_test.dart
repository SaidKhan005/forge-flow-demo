// â”€â”€â”€ Baseline Range Logic Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Prompt 6.1 + 6.2 verification:
//   - Historical context metrics are stable regardless of override state
//   - Graph outer endpoints are always the 60-day historical range
//   - Active inner range reflects selected benchmark/star-shift range
//   - Graph labels are correct by override state
//   - BaselineRangeValidation status rules are deterministic

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/baseline_manager_service.dart';
import 'package:forge_and_flow/data/database_helper.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';

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
      expect(m.title, equals('CPLH TARGET'));
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

    test('title remains CPLH TARGET in both states', () async {
      // No override
      expect(BaselineData.rangeGraphModel.title, equals('CPLH TARGET'));

      // With override
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      final pick = candidates.take(3).map((c) => c.recordKey).toSet();
      await BaselineManagerService.instance.saveSelection(pick);
      expect(BaselineData.rangeGraphModel.title, equals('CPLH TARGET'));
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
          equals('Star shifts too tightly clustered. Add more for a teachable range.'));
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
          equals('Star shifts too tightly clustered. Add more for a teachable range.'));
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
}
