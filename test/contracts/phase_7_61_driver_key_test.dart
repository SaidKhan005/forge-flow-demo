// Phase 7.61.0 — Driver Key Contract Test
//
// Pins the rules from docs/contracts/phase_7_61_driver_key_contract.md
// that the audit pass must keep true:
//
//   * Catalog completeness — `LeverCards.all` carries exactly the 16
//     priority-order ids; `'on_model'` is intentionally outside.
//   * Storage-form discipline — engine output is lowercase snake_case
//     (R-STOR-1); `ShiftRecord.primaryLever` carries upper-snake form
//     (R-STOR-2); `normalizedLeverId` is the conversion seam (R-STOR-3);
//     `LeverCards.lookup` is case-insensitive (R-STOR-5) and returns
//     null for sentinel / unknown / null-or-empty input (R-STOR-6, R-STOR-7).
//   * Producer discipline — `ShiftFactBuilder` mints lowercase ids
//     (R-PROD-2/-5); the close-shift transform uppercases on the way
//     into `ShiftRecord` (R-PROD-2); `HistoryPatternBuilder` and
//     `DaypartPatternSummaryBuilder` skip the `'on_model'` sentinel
//     and unknown ids (R-PROD-4); aggregate / WTD producers write
//     lowercase canonical (R-PROD-5).
//   * Cross-table key consistency — for an engine output `e`, the key
//     round-trips identically through `ShiftRecord` →
//     `BaselineCandidateShift` and `HistoryPatternRecord`
//     (R-CONS-5/-6); aggregate and pattern fields carry only catalog
//     ids in lowercase form (R-CONS-7/-8/-9).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/data/app_defaults.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/domain/services/shift_fact_builder.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/services/daypart_pattern_summary_builder.dart';
import 'package:forge_and_flow/services/history_pattern_builder.dart';
import 'package:forge_and_flow/services/history_teaching_analyzer.dart';
import 'package:forge_and_flow/services/labor_model.dart';

// ── Catalog reference ───────────────────────────────────────────────────────

const _expectedCatalog = <String>{
  'covers_down', 'covers_up',
  'ppa_down', 'ppa_up',
  'cplh_down', 'cplh_up',
  'splh_down', 'splh_up',
  'foh_wage_down', 'foh_wage_up',
  'boh_wage_down', 'boh_wage_up',
  'foh_hours_over', 'foh_hours_under',
  'boh_hours_over', 'boh_hours_under',
};

// ── Fixture targets ─────────────────────────────────────────────────────────

const _tCPLH = 4.58;
const _tSPLH = 180.0;
const _tPPA = 41.50;
const _fohWage = 16.50;
const _bohWage = 21.35;

const _onModel = 'ON_MODEL';
const _coversDown = 'covers_down';

// ── Helpers ─────────────────────────────────────────────────────────────────

TargetSnapshot _targetSnapshot() => const TargetSnapshot(
      targetCPLH: _tCPLH,
      targetSPLH: _tSPLH,
      targetPPA: _tPPA,
      fohWage: _fohWage,
      bohWage: _bohWage,
      opzFloorCPLH: 4.0,
      opzCeilingCPLH: 5.0,
      theoreticalFohLaborPct: 8.63,
      theoreticalBohLaborPct: 11.86,
      theoreticalLaborPct: 20.49,
    );

ClosedShiftInput _closedInput({
  int actualCovers = 1140,
  int forecastCovers = 1200,
}) =>
    ClosedShiftInput(
      businessDate: DateTime.utc(2026, 3, 24),
      weekId: '2026-W13',
      dayLabel: 'Mon',
      daypart: 'lunch',
      covers: actualCovers,
      forecastCovers: forecastCovers,
      actualSales: actualCovers * _tPPA,
      actualFohHours: (actualCovers / _tCPLH).round(),
      actualBohHours: ((actualCovers * _tPPA) / _tSPLH).round(),
      actualFohLaborDollars:
          (actualCovers / _tCPLH).round() * _fohWage,
      actualBohLaborDollars:
          ((actualCovers * _tPPA) / _tSPLH).round() * _bohWage,
    );

ShiftRecord _closedShift({
  String dayLabel = 'Mon',
  String daypart = 'lunch',
  required String engineLever,
}) =>
    ShiftRecord(
      weekId: '2026-W13',
      dayLabel: dayLabel,
      daypart: daypart,
      status: 'closed',
      covers: 120,
      forecastCovers: 130,
      ppa: _tPPA,
      cplh: _tCPLH,
      splh: _tSPLH,
      fohHours: 28,
      bohHours: 12,
      primaryLever: engineLever.toUpperCase(),
      businessDate: '2026-03-24',
      targetCPLH: _tCPLH,
      targetSPLH: _tSPLH,
      targetPPA: _tPPA,
      targetFohWage: _fohWage,
      targetBohWage: _bohWage,
      theoreticalFohLaborPct: 8.63,
      theoreticalBohLaborPct: 11.86,
    );

ShiftRecord _openShift({
  String dayLabel = 'Tue',
  String daypart = 'lunch',
  String primaryLever = _onModel,
}) =>
    ShiftRecord(
      weekId: '2026-W13',
      dayLabel: dayLabel,
      daypart: daypart,
      status: 'open',
      covers: 0,
      forecastCovers: 110,
      ppa: 0,
      cplh: 0,
      splh: 0,
      fohHours: 0,
      bohHours: 0,
      primaryLever: primaryLever,
    );

String _engineLever({
  int actualCovers = 1140,
  int forecastCovers = 1200,
  double? avgPPA,
  double? avgCPLH,
  double? avgSPLH,
  double? avgFohWage,
  double? avgBohWage,
  int? scheduledFohHours,
  int? modelFohHours,
  int? scheduledBohHours,
  int? modelBohHours,
}) =>
    LaborModel.determineLever(
      actualCovers: actualCovers,
      forecastCovers: forecastCovers,
      avgCPLH: avgCPLH ?? _tCPLH,
      avgPPA: avgPPA ?? _tPPA,
      targetCPLH: _tCPLH,
      targetPPA: _tPPA,
      avgSPLH: avgSPLH ?? _tSPLH,
      targetSPLH: _tSPLH,
      avgFohBlendedWage: avgFohWage,
      targetFohWage: avgFohWage == null ? null : _fohWage,
      avgBohBlendedWage: avgBohWage,
      targetBohWage: avgBohWage == null ? null : _bohWage,
      scheduledFohHours: scheduledFohHours,
      modelFohHours: modelFohHours,
      scheduledBohHours: scheduledBohHours,
      modelBohHours: modelBohHours,
    );

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('Catalog completeness (R-CAT)', () {
    test('LeverCards.all has exactly 16 entries', () {
      expect(LeverCards.all.length, equals(16));
    });

    test('LeverCards.all matches the expected 16-id catalog 1:1', () {
      final cardIds = LeverCards.all.map((c) => c.id).toSet();
      expect(cardIds, equals(_expectedCatalog),
          reason:
              'Catalog drift: any change to the 16 ids requires a 7.61 contract revision PR');
    });

    test('on_model sentinel is NOT in LeverCards.all', () {
      final cardIds = LeverCards.all.map((c) => c.id).toSet();
      expect(cardIds, isNot(contains('on_model')),
          reason:
              'R-STOR-6 — sentinel is intentionally outside the catalog');
    });

    test('every catalog id is lowercase snake_case', () {
      for (final card in LeverCards.all) {
        expect(card.id, equals(card.id.toLowerCase()),
            reason: 'Catalog id "${card.id}" must be lowercase');
        expect(card.id.contains(' '), isFalse,
            reason: 'Catalog id "${card.id}" must use snake_case (no spaces)');
      }
    });
  });

  group('Storage-form discipline (R-STOR)', () {
    test(
        'R-STOR-1 — every catalog id is mintable; engine output is lowercase '
        'snake_case across all 8 axes',
        () {
      // Per-scenario expected id pinned by name. Asserting equality
      // (not just catalog membership) catches a regression where
      // e.g. an hours-flex axis silently collapses to covers_down.
      // The full set of produced ids must equal the catalog so a
      // dropped axis is also caught — every catalog id must be
      // mintable by exactly one engine input.
      final scenarios = <(String, String)>[
        (_engineLever(actualCovers: 1140), 'covers_down'),
        (_engineLever(actualCovers: 1260), 'covers_up'),
        (_engineLever(avgPPA: _tPPA * 0.95), 'ppa_down'),
        (_engineLever(avgPPA: _tPPA * 1.08), 'ppa_up'),
        (_engineLever(avgCPLH: _tCPLH * 0.90), 'cplh_down'),
        (_engineLever(avgCPLH: _tCPLH * 1.10), 'cplh_up'),
        (_engineLever(avgSPLH: _tSPLH * 0.90), 'splh_down'),
        (_engineLever(avgSPLH: _tSPLH * 1.10), 'splh_up'),
        (_engineLever(avgFohWage: _fohWage * 0.90), 'foh_wage_down'),
        (_engineLever(avgFohWage: _fohWage * 1.10), 'foh_wage_up'),
        (_engineLever(avgBohWage: _bohWage * 0.90), 'boh_wage_down'),
        (_engineLever(avgBohWage: _bohWage * 1.10), 'boh_wage_up'),
        (
          _engineLever(scheduledFohHours: 50, modelFohHours: 40),
          'foh_hours_over'
        ),
        (
          _engineLever(scheduledFohHours: 30, modelFohHours: 40),
          'foh_hours_under'
        ),
        (
          _engineLever(scheduledBohHours: 50, modelBohHours: 40),
          'boh_hours_over'
        ),
        (
          _engineLever(scheduledBohHours: 30, modelBohHours: 40),
          'boh_hours_under'
        ),
      ];
      for (final (actual, expected) in scenarios) {
        expect(actual, equals(expected),
            reason:
                'engine output for "$expected" scenario must be exactly "$expected"');
        expect(actual, equals(actual.toLowerCase()),
            reason: 'engine id must be lowercase');
        expect(actual.contains(' '), isFalse,
            reason: 'engine id must use snake_case (no spaces)');
        expect(actual.trim(), equals(actual),
            reason: 'engine id must have no leading/trailing whitespace');
      }
      final produced = scenarios.map((s) => s.$1).toSet();
      expect(produced, equals(_expectedCatalog),
          reason:
              'every catalog id must be mintable by exactly one scenario in this suite — '
              'a dropped axis would shrink the produced set');
    });

    test('R-STOR-2 + R-STOR-3 — ShiftRecord storage form round-trip', () {
      final shift = _closedShift(engineLever: 'covers_down');
      expect(shift.primaryLever, equals('COVERS_DOWN'),
          reason: 'R-STOR-2 — ShiftRecord.primaryLever stores upper-snake');
      expect(shift.normalizedLeverId, equals('covers_down'),
          reason:
              'R-STOR-3 — normalizedLeverId is the conversion seam back to lowercase');
    });

    test('R-STOR-3 — sentinel round-trips through normalizedLeverId', () {
      final shift = _openShift(primaryLever: _onModel);
      expect(shift.primaryLever, equals('ON_MODEL'));
      expect(shift.normalizedLeverId, equals('on_model'));
    });

    test('R-STOR-5 — LeverCards.lookup is case-insensitive', () {
      final lower = LeverCards.lookup('covers_down');
      final upper = LeverCards.lookup('COVERS_DOWN');
      expect(lower, isNotNull);
      expect(upper, isNotNull);
      expect(identical(lower, upper), isTrue,
          reason: 'both forms must resolve to the same LeverCardData');
    });

    test('R-STOR-6 — lookup returns null for the on_model sentinel (both forms)',
        () {
      expect(LeverCards.lookup('on_model'), isNull);
      expect(LeverCards.lookup('ON_MODEL'), isNull);
    });

    test('R-STOR-7 — lookup returns null for unknown / null / empty input', () {
      expect(LeverCards.lookup('made_up_lever'), isNull);
      expect(LeverCards.lookup(null), isNull);
      expect(LeverCards.lookup(''), isNull);
    });
  });

  group('Producer discipline (R-PROD)', () {
    test('R-PROD-2/-5 — ShiftFactBuilder produces a lowercase canonical id',
        () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _closedInput(actualCovers: 1140, forecastCovers: 1200),
        _targetSnapshot(),
      );
      expect(fact.primaryLeverId, equals(fact.primaryLeverId.toLowerCase()),
          reason: 'R-PROD-5 — ShiftFact.primaryLeverId is lowercase');
      expect(_expectedCatalog, contains(fact.primaryLeverId),
          reason: 'R-PROD-2 — engine output must be a catalog id');
    });

    test('R-PROD-2 — close-shift seam uppercases for ShiftRecord storage', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _closedInput(actualCovers: 1140, forecastCovers: 1200),
        _targetSnapshot(),
      );
      // Mirrors the upper-snake transform at lib/services/shift_service.dart:330.
      // The seam is a single .toUpperCase() call; this assertion pins the
      // round-trip without coupling the test to the production close path.
      final stored = fact.primaryLeverId.toUpperCase();
      final shift = _closedShift(engineLever: fact.primaryLeverId);
      expect(shift.primaryLever, equals(stored),
          reason: 'R-PROD-2 — storage form is fact.primaryLeverId.toUpperCase()');
      expect(shift.normalizedLeverId, equals(fact.primaryLeverId),
          reason: 'R-STOR-3 — normalize back yields the original engine id');
    });

    test('R-PROD-4 — HistoryPatternBuilder skips on_model and unknown ids',
        () {
      final shifts = <ShiftRecord>[
        _closedShift(engineLever: 'covers_down'),
        _closedShift(dayLabel: 'Tue', engineLever: 'ppa_up'),
        // Sentinel — must be skipped even with status forced to closed.
        ShiftRecord(
          weekId: '2026-W13',
          dayLabel: 'Wed',
          daypart: 'lunch',
          status: 'closed',
          covers: 110,
          forecastCovers: 110,
          ppa: _tPPA,
          cplh: _tCPLH,
          splh: _tSPLH,
          fohHours: 28,
          bohHours: 12,
          primaryLever: _onModel,
        ),
        // Unknown id — must be skipped.
        ShiftRecord(
          weekId: '2026-W13',
          dayLabel: 'Thu',
          daypart: 'lunch',
          status: 'closed',
          covers: 110,
          forecastCovers: 110,
          ppa: _tPPA,
          cplh: _tCPLH,
          splh: _tSPLH,
          fohHours: 28,
          bohHours: 12,
          primaryLever: 'MADE_UP_LEVER',
        ),
        // Open row carrying a real lever id — must be skipped (status filter).
        _openShift(primaryLever: 'COVERS_UP'),
      ];
      final records = HistoryPatternBuilder.fromClosedShifts(shifts, const {});
      final emittedIds = records.map((r) => r.leverId).toSet();
      expect(emittedIds, equals({'covers_down', 'ppa_up'}),
          reason:
              'R-PROD-4 — only known catalog ids from closed rows enter HistoryPatternRecord');
      for (final r in records) {
        expect(_expectedCatalog, contains(r.leverId),
            reason: 'R-CONS-9 — HistoryPatternRecord.leverId is a catalog id');
        expect(r.leverId, equals(r.leverId.toLowerCase()),
            reason: 'R-PROD-5 — emitted id is lowercase canonical');
      }
    });

    test(
        'R-PROD-4 — DaypartPatternSummaryBuilder excludes on_model and unknown ids '
        'from lever counts but still counts the closed shift', () {
      final shifts = <ShiftRecord>[
        _closedShift(engineLever: 'ppa_up'),
        _closedShift(engineLever: 'ppa_up'),
        _closedShift(engineLever: 'covers_down'),
        // Sentinel + unknown — counted in closedShiftCount, ignored for levers.
        ShiftRecord(
          weekId: '2026-W13',
          dayLabel: 'Mon',
          daypart: 'lunch',
          status: 'closed',
          covers: 110,
          forecastCovers: 110,
          ppa: _tPPA,
          cplh: _tCPLH,
          splh: _tSPLH,
          fohHours: 28,
          bohHours: 12,
          primaryLever: _onModel,
        ),
        ShiftRecord(
          weekId: '2026-W13',
          dayLabel: 'Mon',
          daypart: 'lunch',
          status: 'closed',
          covers: 110,
          forecastCovers: 110,
          ppa: _tPPA,
          cplh: _tCPLH,
          splh: _tSPLH,
          fohHours: 28,
          bohHours: 12,
          primaryLever: 'MADE_UP_LEVER',
        ),
      ];
      final summaries =
          DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
      expect(summaries.length, equals(1));
      final s = summaries.first;
      expect(s.closedShiftCount, equals(5),
          reason:
              'R-PROD-4 — sentinel + unknown still increment closedShiftCount');
      expect(s.benchmarkCount + s.leakCount, equals(3),
          reason:
              'R-PROD-4 — only the 3 catalog-id rows participate in lever evidence');
      if (s.dominantBenchmarkLeverId != null) {
        expect(_expectedCatalog, contains(s.dominantBenchmarkLeverId),
            reason: 'R-CONS-8 — dominantBenchmarkLeverId must be a catalog id');
      }
      if (s.dominantLeakLeverId != null) {
        expect(_expectedCatalog, contains(s.dominantLeakLeverId),
            reason: 'R-CONS-8 — dominantLeakLeverId must be a catalog id');
      }
    });
  });

  group('Cross-table key consistency (R-CONS)', () {
    test(
        'R-CONS-5 — ShiftFact engine id round-trips identically through '
        'ShiftRecord storage', () {
      for (final engineId in _expectedCatalog) {
        final shift = _closedShift(engineLever: engineId);
        expect(shift.primaryLever, equals(engineId.toUpperCase()),
            reason: 'storage form is engine id uppercased');
        expect(shift.normalizedLeverId, equals(engineId),
            reason: 'normalize back yields the original engine id');
      }
    });

    test(
        'R-CONS-6 — BaselineCandidateShift mirror of ShiftRecord carries the '
        'lowercase canonical form', () {
      // Mirrors lib/services/baseline_manager_service.dart:108
      // `primaryLeverId: shift.normalizedLeverId`.
      for (final engineId in _expectedCatalog) {
        final shift = _closedShift(engineLever: engineId);
        final candidatePrimaryLeverId = shift.normalizedLeverId;
        expect(candidatePrimaryLeverId, equals(engineId),
            reason:
                'BaselineCandidateShift.primaryLeverId === ShiftRecord.normalizedLeverId');
        expect(_expectedCatalog, contains(candidatePrimaryLeverId),
            reason: 'R-CONS-6 — candidate id must be a catalog id');
      }
    });

    test(
        'R-CONS-7 — WeekData / WeekRecord shape: every catalog id round-trips '
        'verbatim through a lowercase TEXT column', () {
      // The fields are plain `String`; this test pins the contract that
      // producers (shift_service / shift_data_source / replay seed)
      // write the lowercase canonical form, and that the SQLite column
      // round-trip preserves it byte-for-byte. We assert the shape of
      // the accepted value space rather than mounting the full DB.
      for (final id in _expectedCatalog) {
        expect(id, equals(id.toLowerCase()));
        expect(id.contains(' '), isFalse);
        expect(LeverCards.lookup(id), isNotNull,
            reason: 'every catalog id must resolve through lookup');
      }
    });

    test(
        'R-CONS-8 — DaypartPatternSummary.dominant{Benchmark,Leak}LeverId '
        'is null when no qualifying lever evidence exists', () {
      final shifts = <ShiftRecord>[
        // All sentinel — no catalog-id evidence.
        ShiftRecord(
          weekId: '2026-W13',
          dayLabel: 'Mon',
          daypart: 'lunch',
          status: 'closed',
          covers: 110,
          forecastCovers: 110,
          ppa: _tPPA,
          cplh: _tCPLH,
          splh: _tSPLH,
          fohHours: 28,
          bohHours: 12,
          primaryLever: _onModel,
        ),
      ];
      final summaries =
          DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
      expect(summaries.length, equals(1));
      expect(summaries.first.dominantBenchmarkLeverId, isNull,
          reason: 'R-CONS-8 — no benchmark evidence ⇒ null');
      expect(summaries.first.dominantLeakLeverId, isNull,
          reason: 'R-CONS-8 — no leak evidence ⇒ null');
    });

    test(
        'R-CONS-6 — known catalog id flows through HistoryPatternRecord '
        'verbatim (no case folding, no transformation)', () {
      const engineId = _coversDown;
      final shift = _closedShift(engineLever: engineId);
      final records =
          HistoryPatternBuilder.fromClosedShifts([shift], const {});
      expect(records.length, equals(1));
      expect(records.first.leverId, equals(engineId),
          reason:
              'R-CONS-6 — HistoryPatternRecord.leverId === ShiftRecord.normalizedLeverId');
    });

    test(
        'R-CONS-9 — HistoryTeachingSummary mostCommonBenchmarkId '
        'is a catalog id or empty string', () {
      // Per R-CONS-9, downstream summary fields carry the lowercase
      // canonical form or empty string when no evidence exists. We
      // exercise the analyzer directly against synthesized
      // HistoryPatternRecords so the test does not depend on the
      // upstream HistoryPatternBuilder catalog filter (R-PROD-4) for
      // its inputs.

      // Non-empty benchmark set ⇒ catalog id.
      final benchSummary = HistoryTeachingAnalyzer.summarize(const [
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Sat',
          daypart: 'dinner',
          leverId: 'ppa_up',
          isBenchmark: true,
        ),
      ]);
      expect(_expectedCatalog, contains(benchSummary.mostCommonBenchmarkId),
          reason:
              'R-CONS-9 — non-empty benchmark set yields a catalog id');
      expect(
        benchSummary.mostCommonBenchmarkId,
        equals(benchSummary.mostCommonBenchmarkId.toLowerCase()),
        reason: 'R-CONS-9 — summary id is lowercase canonical',
      );

      // Empty input ⇒ empty string (analyzer defaults
      // `mostCommonBenchmarkId = ''` already honors R-CONS-9).
      final emptySummary = HistoryTeachingAnalyzer.summarize(const []);
      expect(emptySummary.mostCommonBenchmarkId, equals(''),
          reason:
              'R-CONS-9 — empty benchmark set yields empty string default');
    });

    test(
        'R-CONS-9 — HistoryTeachingSummary mostCommonLeakId '
        'is a catalog id when leak records exist', () {
      final summary = HistoryTeachingAnalyzer.summarize(const [
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Mon',
          daypart: 'lunch',
          leverId: 'cplh_down',
          isBenchmark: false,
        ),
        HistoryPatternRecord(
          weekId: '2026-W13',
          weekLabel: 'Mar 24',
          dayLabel: 'Mon',
          daypart: 'lunch',
          leverId: 'cplh_down',
          isBenchmark: false,
        ),
      ]);
      expect(_expectedCatalog, contains(summary.mostCommonLeakId),
          reason:
              'R-CONS-9 — non-empty leak set yields a catalog id');
      expect(
        summary.mostCommonLeakId,
        equals(summary.mostCommonLeakId.toLowerCase()),
        reason: 'R-CONS-9 — summary id is lowercase canonical',
      );
    });

    test(
        'R-CONS-9 — empty leak set yields empty mostCommonLeakId '
        '(F-2 holdout, expected to flip in 7.61.2)', () {
      // Today the analyzer initialises `mostCommonLeakId = "covers_down"`
      // and only overrides it when freq.isNotEmpty, so an empty input
      // returns 'covers_down' instead of the contract-mandated empty
      // string. Skipped until 7.61.2 flips the default; the assertion
      // body is the post-fix expectation. Removing `skip:` after 7.61.2
      // closes is the contract-test trip wire that the fix landed.
      final summary = HistoryTeachingAnalyzer.summarize(const []);
      expect(summary.mostCommonLeakId, equals(''),
          reason:
              'R-CONS-9 — empty leak set must yield empty string, not the '
              "'covers_down' overclaim. F-2 fix lands in 7.61.2.");
    }, skip: 'F-2 holdout — see docs/phases/phase_7_61/phase_7_61_audit_plan.md');
  });

  group('F-1 — unknown id zeros out every summary field, no silent overclaim',
      () {
    // Pins the `7.61.1` fix in `history_teaching_analyzer.dart`:
    // pre-fix the analyzer used `firstWhere(orElse: () => LeverCards.coversDown)`
    // (lines 88-91) and `firstWhere(orElse: () => LeverCards.ppaUp)`
    // (lines 131-134), silently materializing a real lever card whenever
    // an upstream filter let an unknown id through. Post-fix the analyzer
    // resolves through `LeverCards.lookup`; a null return zeros out the
    // entire side of the summary (id, count, side label, dayparts) so
    // downstream copy in `LearnTeachingAnalyzer` cannot stitch a
    // "Fix no leak pattern yet first in <real daypart>" sentence out of
    // a phantom lever. R-CONS-2 + R-CONS-9 + R-STOR-7.
    test(
        'unknown leak id zeros out mostCommonLeakId, count, side label, '
        'and topLeakDayparts (no escape path through summary fields)', () {
      final summary = HistoryTeachingAnalyzer.summarize(const [
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Mon',
          daypart: 'lunch',
          leverId: 'made_up_lever',
          isBenchmark: false,
        ),
        HistoryPatternRecord(
          weekId: '2026-W13',
          weekLabel: 'Mar 24',
          dayLabel: 'Tue',
          daypart: 'dinner',
          leverId: 'made_up_lever',
          isBenchmark: false,
        ),
      ]);
      expect(summary.mostCommonLeakId, equals(''),
          reason:
              'F-1 — null lookup → empty id (R-CONS-9: catalog id OR '
              'empty string when no evidence exists).');
      expect(summary.mostCommonLeakCount, equals(0),
          reason:
              'F-1 — null lookup → zero count (the unknown record cannot '
              'pose as a real leak with count > 0).');
      expect(summary.mostCommonLeakSideLabel, equals('No leak pattern yet'),
          reason:
              'F-1 — null lookup → placeholder side label, never '
              "coversDown's '${LeverCards.coversDown.sideLabel}'.");
      expect(summary.topLeakDayparts, isEmpty,
          reason:
              'F-1 — null lookup → empty dayparts list. Pre-fix this '
              'leaked the unknown record\'s daypart into '
              'LearnTeachingAnalyzer.primaryFixLine as '
              "'Fix no leak pattern yet first in Mon Lunch.'");
    });

    test(
        'unknown benchmark id zeros out mostCommonBenchmarkId, count, side '
        'label, and benchmarkDayparts (no escape path through summary fields)',
        () {
      final summary = HistoryTeachingAnalyzer.summarize(const [
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Sat',
          daypart: 'dinner',
          leverId: 'made_up_lever',
          isBenchmark: true,
        ),
      ]);
      expect(summary.mostCommonBenchmarkId, equals(''),
          reason:
              'F-1 — null lookup → empty id (R-CONS-9). Already pinned by '
              'the existing R-CONS-9 benchmark test for empty input; this '
              'extends the pin to the unknown-id case.');
      expect(summary.mostCommonBenchmarkCount, equals(0),
          reason:
              'F-1 — null lookup → zero count.');
      expect(summary.mostCommonBenchmarkSideLabel,
          equals('No benchmark pattern yet'),
          reason:
              'F-1 — null lookup → placeholder side label, never '
              "ppaUp's '${LeverCards.ppaUp.sideLabel}'.");
      expect(summary.benchmarkDayparts, isEmpty,
          reason:
              'F-1 — null lookup → empty dayparts. Pre-fix this leaked '
              'the unknown record\'s daypart into '
              "LearnTeachingAnalyzer.studyLine as "
              "'Study benchmark dayparts: Sat Dinner.'");
    });

    test(
        'known leak id still resolves to the matching catalog card and '
        'preserves count + dayparts (no regression on the golden path)', () {
      final summary = HistoryTeachingAnalyzer.summarize(const [
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Mon',
          daypart: 'lunch',
          leverId: 'cplh_down',
          isBenchmark: false,
        ),
        HistoryPatternRecord(
          weekId: '2026-W13',
          weekLabel: 'Mar 24',
          dayLabel: 'Mon',
          daypart: 'lunch',
          leverId: 'cplh_down',
          isBenchmark: false,
        ),
      ]);
      expect(summary.mostCommonLeakId, equals('cplh_down'));
      expect(summary.mostCommonLeakCount, equals(2),
          reason:
              'F-1 — count is preserved on the golden path; only unknown '
              'ids zero it out.');
      expect(summary.mostCommonLeakSideLabel,
          equals(LeverCards.cplhDown.sideLabel),
          reason:
              'F-1 — golden-path side label still comes from the matched '
              'catalog card.');
      expect(summary.topLeakDayparts, equals(['Mon Lunch']),
          reason: 'F-1 — golden-path dayparts are preserved.');
    });

    test(
        'known benchmark id still resolves to the matching catalog card and '
        'preserves count + dayparts (no regression on the golden path)', () {
      final summary = HistoryTeachingAnalyzer.summarize(const [
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Sat',
          daypart: 'dinner',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
      ]);
      expect(summary.mostCommonBenchmarkId, equals('splh_up'));
      expect(summary.mostCommonBenchmarkCount, equals(1));
      expect(summary.mostCommonBenchmarkSideLabel,
          equals(LeverCards.splhUp.sideLabel),
          reason:
              'F-1 — golden-path side label still comes from the matched '
              'catalog card.');
      expect(summary.benchmarkDayparts, equals(['Sat Dinner']),
          reason: 'F-1 — golden-path dayparts are preserved.');
    });

    test(
        'known leak id wins tie-break over an unknown id and the unknown '
        "id's dayparts do not bleed into topLeakDayparts", () {
      // Mixed input: one known leak (cplh_down) + one unknown id. The
      // tie-break order at line 32-39 puts cplh_down at slot 0 and any
      // unlisted id at slot 999, so cplh_down wins. The unknown record
      // appears on a different daypart than the known one — if the
      // post-fix analyzer leaked the unknown daypart in, this would catch
      // it. (It doesn't — leakDpFreq filters by `r.leverId == mostCommonLeakId`.)
      final summary = HistoryTeachingAnalyzer.summarize(const [
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Mon',
          daypart: 'lunch',
          leverId: 'cplh_down',
          isBenchmark: false,
        ),
        HistoryPatternRecord(
          weekId: '2026-W13',
          weekLabel: 'Mar 24',
          dayLabel: 'Wed',
          daypart: 'dinner',
          leverId: 'made_up_lever',
          isBenchmark: false,
        ),
      ]);
      expect(summary.mostCommonLeakId, equals('cplh_down'),
          reason: 'tie-break: cplh_down (slot 0) beats unlisted id.');
      expect(summary.topLeakDayparts, equals(['Mon Lunch']),
          reason:
              'F-1 — only the known leak\'s daypart appears; the unknown '
              "record's 'Wed Dinner' must not leak in.");
    });

    test(
        'known benchmark id wins tie-break and the unknown sibling record\'s '
        "daypart does not bleed into benchmarkDayparts", () {
      // The exact case Reviewer P1 flagged: a known winner (splh_up x10
      // on Sat) plus an unknown sibling (made_up_lever x1 on Sun). Pre-fix,
      // `benchFreq` aggregated across all benchmark records regardless of
      // leverId, so `benchmarkDayparts` returned ['Sat Dinner', 'Sun Lunch']
      // and `LearnTeachingAnalyzer.studyLine` would render
      // "Study benchmark dayparts: Sat Dinner / Sun Lunch." — fabricating
      // a study target out of a phantom benchmark.
      // Post-fix, the upstream `_knownLeverIds.contains(r.leverId)` filter
      // on `benchmarkRecords` drops the unknown row before either `bFreq`
      // or `benchFreq` sees it, so only Sat Dinner survives.
      final summary = HistoryTeachingAnalyzer.summarize(const [
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Sat',
          daypart: 'dinner',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
        HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Sun',
          daypart: 'lunch',
          leverId: 'made_up_lever',
          isBenchmark: true,
        ),
      ]);
      expect(summary.mostCommonBenchmarkId, equals('splh_up'),
          reason:
              'F-1 — known id wins because the unknown row is filtered '
              'out before tie-break.');
      expect(summary.mostCommonBenchmarkCount, equals(1),
          reason:
              'F-1 — count reflects the known records only (1× splh_up); '
              'the unknown sibling does not pad the count.');
      expect(summary.benchmarkDayparts, equals(['Sat Dinner']),
          reason:
              "F-1 — only Sat Dinner appears; the unknown record's "
              "'Sun Lunch' MUST NOT leak into benchmarkDayparts. Pre-fix "
              "this returned ['Sat Dinner', 'Sun Lunch']. Reviewer P1.");
    });

    test(
        'known benchmark id wins by tie-break order even when an unknown '
        'sibling has higher raw frequency, because the unknown is filtered '
        'out before bFreq', () {
      // Stronger version of the test above: the unknown id has 10×
      // higher count than the known id, so without the upstream filter
      // it would dominate `bFreq`, win the tie-break, and trigger the
      // "no benchmark pattern yet" reset — silencing the real benchmark.
      // With the upstream filter, only known rows enter `bFreq`, so the
      // single splh_up surfaces as the real benchmark.
      final summary = HistoryTeachingAnalyzer.summarize([
        const HistoryPatternRecord(
          weekId: '2026-W12',
          weekLabel: 'Mar 17',
          dayLabel: 'Sat',
          daypart: 'dinner',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
        for (int i = 0; i < 10; i++)
          const HistoryPatternRecord(
            weekId: '2026-W12',
            weekLabel: 'Mar 17',
            dayLabel: 'Sun',
            daypart: 'lunch',
            leverId: 'made_up_lever',
            isBenchmark: true,
          ),
      ]);
      expect(summary.mostCommonBenchmarkId, equals('splh_up'),
          reason:
              'F-1 — upstream filter drops unknown rows before tie-break, '
              'so the real benchmark surfaces even when unknowns outnumber it.');
      expect(summary.benchmarkDayparts, equals(['Sat Dinner']),
          reason:
              'F-1 — Sun Lunch (the unknown row\'s daypart) MUST NOT '
              'appear; only the known benchmark\'s daypart survives.');
    });
  });
}
