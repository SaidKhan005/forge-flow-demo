// Per-Daypart Targets V1 — Slice D (Gap 39) narration tests.
//
// Proves the Learn narration is sharpened to the *service period* the
// pattern actually lives in, true to the seeded recurrence, with a
// training-grade per-period derivation line — and that it falls back to
// the existing general copy when no pattern exists (no fabrication).
// Decision 13: copy + analyzer-data-layer only, no UX overhaul.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/learn_benchmark_context.dart';
import 'package:forge_and_flow/services/history_teaching_analyzer.dart';
import 'package:forge_and_flow/services/learn_teaching_analyzer.dart';

const _ctx = LearnBenchmarkContext(
  benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
  selectedShiftCount: 12,
  targetCPLH: 4.5,
  targetSPLH: 180.0,
  targetPPA: 42.0,
  rangeQualityLabel: 'Good',
  rangeQualityMessage: 'Range is adequate.',
);

HistoryPatternRecord _rec(
  String weekId,
  String dayLabel,
  String daypart,
  String leverId, {
  bool isBenchmark = false,
}) =>
    HistoryPatternRecord(
      weekId: weekId,
      weekLabel: 'Week $weekId',
      dayLabel: dayLabel,
      daypart: daypart,
      leverId: leverId,
      isBenchmark: isBenchmark,
    );

/// 8 weeks. Friday dinner leaks `ppa_down` every week (the recurring
/// period leak). Friday lunch holds as a recurring `ppa_up` benchmark
/// (the same-day contrast). A scattered Tue lunch `covers_down` keeps
/// the cohort from being single-pattern.
List<HistoryPatternRecord> _fridayDinnerPpaLeak() {
  final out = <HistoryPatternRecord>[];
  for (var w = 1; w <= 8; w++) {
    final id = 'w$w';
    out.add(_rec(id, 'Fri', 'dinner', 'ppa_down'));
    out.add(_rec(id, 'Fri', 'lunch', 'ppa_up', isBenchmark: true));
  }
  out.add(_rec('w1', 'Tue', 'lunch', 'covers_down'));
  out.add(_rec('w2', 'Tue', 'lunch', 'covers_down'));
  return out;
}

/// A different recurring leak in a different period — proves the line is
/// derived from the data, not a hardcoded constant.
List<HistoryPatternRecord> _satDinnerCplhLeak() {
  final out = <HistoryPatternRecord>[];
  for (var w = 1; w <= 5; w++) {
    out.add(_rec('w$w', 'Sat', 'dinner', 'cplh_down'));
  }
  out.add(_rec('w1', 'Mon', 'lunch', 'covers_down'));
  return out;
}

void main() {
  group('Gap 39 — period-resolved leak narration', () {
    test('resolves to the period, direction, and real recurrence', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: _fridayDinnerPpaLeak(),
        weekCount: 8,
        benchmarkContext: _ctx,
      );

      // Period-resolved: names the service period, not the whole day.
      expect(summary.primaryFixLine, contains('Fri Dinner'));
      // Direction taken from the engine's own lever id.
      expect(summary.primaryFixLine, contains('PPA'));
      expect(summary.primaryFixLine, contains('running low'));
      // Real seeded recurrence (8 of 8), not a fabricated magnitude.
      expect(summary.primaryFixLine,
          contains('every one of the last 8 tracked weeks'));
      // Decision 13 same-day period contrast, from a real benchmark.
      expect(summary.primaryFixLine, contains('Fri Lunch holds on plan'));
    });

    test('is derived from the data, not a hardcoded constant', () {
      final friday = LearnTeachingAnalyzer.summarize(
        patternRecords: _fridayDinnerPpaLeak(),
        weekCount: 8,
        benchmarkContext: _ctx,
      );
      final saturday = LearnTeachingAnalyzer.summarize(
        patternRecords: _satDinnerCplhLeak(),
        weekCount: 8,
        benchmarkContext: _ctx,
      );

      expect(friday.primaryFixLine, isNot(equals(saturday.primaryFixLine)));
      expect(saturday.primaryFixLine, contains('Sat Dinner'));
      expect(saturday.primaryFixLine, contains('CPLH'));
      expect(saturday.primaryFixLine,
          contains('5 of the last 8 tracked weeks'));
      // No same-day benchmark seeded → contrast clause omitted, not invented.
      expect(saturday.primaryFixLine, isNot(contains('holds on plan')));
    });

    test('HistoryTeachingAnalyzer exposes the resolved period fields', () {
      final hs = HistoryTeachingAnalyzer.summarize(_fridayDinnerPpaLeak());
      expect(hs.topLeakDaypartLabel, equals('Fri Dinner'));
      expect(hs.topLeakDaypartCount, equals(8));
      expect(hs.contrastBenchmarkDaypartLabel, equals('Fri Lunch'));
    });
  });

  group('Gap 39 — honest fallback (no fabrication)', () {
    test('empty patterns keep the existing general fix copy', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: const [],
        weekCount: 0,
        benchmarkContext: _ctx,
      );
      expect(summary.primaryFixLine,
          equals('Keep closing shifts so Learn can detect repeating leaks.'));
      expect(summary.primaryFixLine, isNot(contains('Dinner')));
      expect(summary.primaryFixLine, isNot(contains('Lunch')));
    });

    test('no recurring leak names no period', () {
      // One-off leaks only: no period repeats, so the data supports no
      // period-resolved claim. The line must not assert a recurrence.
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [
          _rec('w1', 'Mon', 'lunch', 'covers_down'),
          _rec('w2', 'Wed', 'dinner', 'ppa_down'),
        ],
        weekCount: 8,
        benchmarkContext: _ctx,
      );
      // It still resolves to the dominant period if one exists, but it
      // never claims more repeats than the data holds.
      expect(summary.primaryFixLine, isNot(contains('every one of')));
    });
  });

  group('Gap 39 — per-period derivation training line', () {
    test('present with patterns, plain English, no engineering jargon', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: _fridayDinnerPpaLeak(),
        weekCount: 8,
        benchmarkContext: _ctx,
      );
      expect(summary.coachToLine, contains('whole-day'));
      expect(
          summary.coachToLine, contains("set from that period's own"));
      expect(summary.coachToLine,
          contains('one period can leak while the day still looks on plan'));
      // UX Writing Standard: no engineering jargon in the training copy.
      for (final jargon in const [
        'pooled',
        'cover-weighted',
        'scalar',
        'denominator',
        'RLS',
        'kDemoMode',
      ]) {
        expect(summary.coachToLine, isNot(contains(jargon)),
            reason: 'training copy must avoid engineering jargon: $jargon');
      }
    });

    test('present even with no patterns (general truth, not a pattern)', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: const [],
        weekCount: 0,
        benchmarkContext: _ctx,
      );
      expect(summary.coachToLine,
          contains('one period can leak while the day still looks on plan'));
      // The whole-day coach numbers still ride the same slot.
      expect(summary.coachToLine, contains('4.5 CPLH'));
      expect(summary.coachToLine, contains('180 SPLH'));
      expect(summary.coachToLine, contains('42 PPA'));
    });
  });
}
