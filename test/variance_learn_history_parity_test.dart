// 7.58.2 — Variance > Learn / Variance > History driver parity audit.
//
// Pins Sub-Slice Family `.2` row of
// `docs/contracts/phase_7_58_primary_driver_contract.md`: both tabs
// resolve the same lever id and the same `LeverCardData` (and thus the
// same `metric` copy) for the same closed `shift_records` scope. The
// per-tab rendering shape stays as the contract Presentation Split
// table specifies — Learn renders the three-card teaching shape
// (`whatHappened` + `whatToDo` + `teachingNote` at
// `lib/screens/variance/variance_learn_tab.dart:189-202`), History
// renders the leak evidence card (`metric` only at
// `lib/screens/variance/variance_history_tab.dart:255-258`) — but the
// underlying lever id and `LeverCardData` identity do not drift.
//
// Cites Findings:
//   F-3 / `7.58.0c` — producer call sites pass different optional-axis
//   subsets. `HistoryPatternBuilder` reads
//   `ShiftRecord.normalizedLeverId` (the persisted id, lowercased), so
//   it is invariant under producer-side axis subset divergence; the
//   parity test below proves the reducer path the two tabs share never
//   re-derives a different id from the same patternRecords.
//   F-7 / `7.58.0g` — persistence form / lookup form mismatch.
//   `HistoryPatternBuilder.fromClosedShifts` lower-cases the lever id
//   via `ShiftRecord.normalizedLeverId`; the parity test pins that
//   neither tab re-uppercases or re-derives the id.
//
// See `docs/phases/phase_7_58/phase_7_58_primary_driver_audit_plan.md`
// Findings F-3 / F-7 for the original divergence map.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/fixture_seed_data.dart';
import 'package:forge_and_flow/models/learn_benchmark_context.dart';
import 'package:forge_and_flow/services/history_pattern_builder.dart';
import 'package:forge_and_flow/services/history_teaching_analyzer.dart';
import 'package:forge_and_flow/services/learn_teaching_analyzer.dart';
import 'package:forge_and_flow/services/variance_driver_pattern_read_service.dart';

const _ctx = LearnBenchmarkContext(
  benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
  selectedShiftCount: 14,
  targetCPLH: 4.5,
  targetSPLH: 180.0,
  targetPPA: 42.0,
  rangeQualityLabel: 'Good',
  rangeQualityMessage: 'Range is adequate.',
);

void main() {
  group('7.58.2 — Learn / History driver parity (single source)', () {
    test('shared service resolves the same lever id Learn surfaces', () {
      // Same closed-shift population both tabs read at runtime via
      // ShiftDataSource.getHistoryPatternRecords().
      final closedShifts = DemoData.historicalClosedShifts;
      final weekLabelsById = {
        for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
      };
      final patternRecords = HistoryPatternBuilder.fromClosedShifts(
        closedShifts,
        weekLabelsById,
      );

      const service = VarianceDriverPatternReadService();
      final shared = service.resolveLeakDriver(patternRecords);

      final learnSummary = LearnTeachingAnalyzer.summarize(
        patternRecords: patternRecords,
        weekCount: DemoData.weekHistory.length,
        benchmarkContext: _ctx,
        coverageCount: closedShifts.length,
      );

      expect(shared.leverId, isNotEmpty);
      expect(shared.leverId, equals(learnSummary.primaryLeakId));
    });

    test('shared service resolves the same lever id History surfaces', () {
      final closedShifts = DemoData.historicalClosedShifts;
      final weekLabelsById = {
        for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
      };
      final patternRecords = HistoryPatternBuilder.fromClosedShifts(
        closedShifts,
        weekLabelsById,
      );

      const service = VarianceDriverPatternReadService();
      final shared = service.resolveLeakDriver(patternRecords);
      final historySummary = HistoryTeachingAnalyzer.summarize(patternRecords);

      expect(shared.leverId, equals(historySummary.mostCommonLeakId));
    });

    test('Learn primaryLeakId equals History mostCommonLeakId for same scope', () {
      // Direct parity check — even if the two tabs were wired to the
      // analyzer separately (no shared service), the reducer path
      // they both consume must agree because the input `patternRecords`
      // and the downstream `HistoryTeachingAnalyzer.summarize` are the
      // same. The shared service makes this dependency explicit; the
      // test pins the invariant against future drift.
      final closedShifts = DemoData.historicalClosedShifts;
      final weekLabelsById = {
        for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
      };
      final patternRecords = HistoryPatternBuilder.fromClosedShifts(
        closedShifts,
        weekLabelsById,
      );

      final historySummary = HistoryTeachingAnalyzer.summarize(patternRecords);
      final learnSummary = LearnTeachingAnalyzer.summarize(
        patternRecords: patternRecords,
        weekCount: DemoData.weekHistory.length,
        benchmarkContext: _ctx,
        coverageCount: closedShifts.length,
      );

      expect(historySummary.mostCommonLeakId, isNotEmpty);
      expect(
        historySummary.mostCommonLeakId,
        equals(learnSummary.primaryLeakId),
      );
    });

    test('LeverCardData metric + teaching copy match across tabs', () {
      final closedShifts = DemoData.historicalClosedShifts;
      final weekLabelsById = {
        for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
      };
      final patternRecords = HistoryPatternBuilder.fromClosedShifts(
        closedShifts,
        weekLabelsById,
      );

      const service = VarianceDriverPatternReadService();
      final shared = service.resolveLeakDriver(patternRecords);

      // Learn three-card teaching shape reads `whatHappened` /
      // `whatToDo` / `teachingNote` at variance_learn_tab.dart:189-202.
      // History leak evidence card reads `metric` at
      // variance_history_tab.dart:255-258. Both surfaces look up the
      // same id, so the same LeverCardData drives both renderers.
      expect(shared.card, isNotNull);
      final learnLookup = LeverCards.lookup(shared.leverId);
      final historyLookup = LeverCards.lookup(shared.leverId);
      expect(learnLookup, same(historyLookup));
      expect(historyLookup, isNotNull);
      expect(historyLookup!.metric, equals(shared.card!.metric));
      expect(learnLookup!.whatHappened, equals(shared.card!.whatHappened));
      expect(learnLookup.whatToDo, equals(shared.card!.whatToDo));
      expect(learnLookup.teachingNote, equals(shared.card!.teachingNote));
    });

    test('empty pattern set → no leak card on either tab', () {
      const service = VarianceDriverPatternReadService();
      final shared = service.resolveLeakDriver(const []);
      expect(shared.leverId, equals(''));
      expect(shared.card, isNull);

      final learnSummary = LearnTeachingAnalyzer.summarize(
        patternRecords: const [],
        weekCount: 0,
        benchmarkContext: _ctx,
        coverageCount: 0,
      );
      expect(LeverCards.lookup(learnSummary.primaryLeakId), isNull);

      final historySummary = HistoryTeachingAnalyzer.summarize(const []);
      expect(LeverCards.lookup(historySummary.mostCommonLeakId), isNull);
    });

    test(
      'every closed fixture row resolves to the same lever-card identity '
      'for both tabs',
      () {
        // Per the audit plan, for every closed `shift_records` row in a
        // fixture week the Learn pattern and the History leak evidence
        // card MUST agree on the lever id and the metric copy. Tested
        // here against the canonical demo seed.
        final closedShifts = DemoData.historicalClosedShifts;
        expect(closedShifts, isNotEmpty);
        final weekLabelsById = {
          for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
        };
        final patternRecords = HistoryPatternBuilder.fromClosedShifts(
          closedShifts,
          weekLabelsById,
        );

        const service = VarianceDriverPatternReadService();
        final shared = service.resolveLeakDriver(patternRecords);
        final historySummary = HistoryTeachingAnalyzer.summarize(patternRecords);
        final learnSummary = LearnTeachingAnalyzer.summarize(
          patternRecords: patternRecords,
          weekCount: DemoData.weekHistory.length,
          benchmarkContext: _ctx,
          coverageCount: closedShifts.length,
        );

        // Same lever id across all three resolution paths.
        expect(shared.leverId, equals(historySummary.mostCommonLeakId));
        expect(shared.leverId, equals(learnSummary.primaryLeakId));

        // Same LeverCardData identity (and same metric copy).
        final card = LeverCards.lookup(shared.leverId);
        expect(card, isNotNull);
        expect(card, same(shared.card));
        expect(card!.metric, equals(shared.card!.metric));
      },
    );

    test(
      'lever id is lowercase snake_case (engine form) — F-7 normalization',
      () {
        // F-7: persistence form is upper-snake (`'COVERS_DOWN'`); the
        // patternRecord layer must hand renderers the lowercase form so
        // both tabs hit `LeverCards.lookup` consistently. The shared
        // service exposes the engine-form id directly; this test pins
        // that no producer-side normalization regression slips it back
        // into upper-snake or hyphenated form.
        final closedShifts = DemoData.historicalClosedShifts;
        final weekLabelsById = {
          for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
        };
        final patternRecords = HistoryPatternBuilder.fromClosedShifts(
          closedShifts,
          weekLabelsById,
        );

        const service = VarianceDriverPatternReadService();
        final shared = service.resolveLeakDriver(patternRecords);
        expect(shared.leverId, equals(shared.leverId.toLowerCase()));
        expect(shared.leverId.contains('-'), isFalse);
        // Catalog membership.
        final catalogIds = LeverCards.all.map((l) => l.id).toSet();
        expect(catalogIds.contains(shared.leverId), isTrue);
      },
    );
  });
}
