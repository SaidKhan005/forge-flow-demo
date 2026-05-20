// Phase 7.55l.8c — BenchmarkSelectionSummary persistence tests
//
// Covers:
// A. Basic repository CRUD (upsert + fetch by targetCycleId)
// B. Upsert replaces existing summary for same cycle
// C. Null return when no summary exists

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/domain/models/benchmark_selection_summary.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_benchmark_selection_summary_repository.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(setUpSqliteDemo);

  // ── A: Basic repository CRUD ───────────────────────────────────────────

  group('A — basic repository CRUD', () {
    test('upsert and fetch by targetCycleId round-trips correctly', () async {
      const summary = BenchmarkSelectionSummary(
        summaryId: 'test_summary_001',
        restaurantId: 'demo_restaurant_001',
        targetCycleId: 'test_cycle_001',
        sourceType: 'cycle_recommended',
        selectedShiftCount: 14,
        rangeQualityLabel: 'GOOD OPZ RANGE',
        rangeQualityMessage: 'Test message.',
        createdAt: '2026-04-11T00:00:00Z',
      );

      await SqliteBenchmarkSelectionSummaryRepository.instance
          .upsert(summary);
      final loaded = await SqliteBenchmarkSelectionSummaryRepository.instance
          .getByTargetCycleId('test_cycle_001');

      expect(loaded, isNotNull);
      expect(loaded!.summaryId, 'test_summary_001');
      expect(loaded.restaurantId, 'demo_restaurant_001');
      expect(loaded.targetCycleId, 'test_cycle_001');
      expect(loaded.sourceType, 'cycle_recommended');
      expect(loaded.selectedShiftCount, 14);
      expect(loaded.rangeQualityLabel, 'GOOD OPZ RANGE');
      expect(loaded.rangeQualityMessage, 'Test message.');
      expect(loaded.createdAt, '2026-04-11T00:00:00Z');
    });

    test('returns null when no summary exists for cycle', () async {
      final loaded = await SqliteBenchmarkSelectionSummaryRepository.instance
          .getByTargetCycleId('nonexistent_cycle');
      expect(loaded, isNull);
    });
  });

  // ── B: Upsert replaces existing ────────────────────────────────────────

  group('B — upsert replaces existing summary', () {
    test('second upsert for same cycle replaces first', () async {
      const first = BenchmarkSelectionSummary(
        summaryId: 'summary_v1',
        restaurantId: 'demo_restaurant_001',
        targetCycleId: 'cycle_replace_test',
        sourceType: 'cycle_recommended',
        selectedShiftCount: 10,
        rangeQualityLabel: 'GOOD OPZ RANGE',
        rangeQualityMessage: 'First message.',
        createdAt: '2026-04-11T00:00:00Z',
      );

      const second = BenchmarkSelectionSummary(
        summaryId: 'summary_v1',
        restaurantId: 'demo_restaurant_001',
        targetCycleId: 'cycle_replace_test',
        sourceType: 'manager_override',
        selectedShiftCount: 5,
        rangeQualityLabel: 'OPZ RANGE TOO NARROW',
        rangeQualityMessage: 'Second message.',
        createdAt: '2026-04-11T01:00:00Z',
      );

      await SqliteBenchmarkSelectionSummaryRepository.instance.upsert(first);
      await SqliteBenchmarkSelectionSummaryRepository.instance.upsert(second);

      final loaded = await SqliteBenchmarkSelectionSummaryRepository.instance
          .getByTargetCycleId('cycle_replace_test');

      expect(loaded, isNotNull);
      expect(loaded!.sourceType, 'manager_override');
      expect(loaded.selectedShiftCount, 5);
      expect(loaded.rangeQualityLabel, 'OPZ RANGE TOO NARROW');
      expect(loaded.rangeQualityMessage, 'Second message.');
    });
  });

  // ── C: Multiple summaries for different cycles ─────────────────────────

  group('C — multiple summaries for different cycles', () {
    test('each cycle gets its own summary', () async {
      const s1 = BenchmarkSelectionSummary(
        summaryId: 'summary_a',
        restaurantId: 'demo_restaurant_001',
        targetCycleId: 'cycle_a',
        sourceType: 'cycle_recommended',
        selectedShiftCount: 14,
        rangeQualityLabel: 'GOOD OPZ RANGE',
        rangeQualityMessage: 'Cycle A.',
        createdAt: '2026-04-11T00:00:00Z',
      );
      const s2 = BenchmarkSelectionSummary(
        summaryId: 'summary_b',
        restaurantId: 'demo_restaurant_001',
        targetCycleId: 'cycle_b',
        sourceType: 'manager_override',
        selectedShiftCount: 7,
        rangeQualityLabel: 'OPZ RANGE TOO WIDE',
        rangeQualityMessage: 'Cycle B.',
        createdAt: '2026-04-11T01:00:00Z',
      );

      await SqliteBenchmarkSelectionSummaryRepository.instance.upsert(s1);
      await SqliteBenchmarkSelectionSummaryRepository.instance.upsert(s2);

      final loaded1 = await SqliteBenchmarkSelectionSummaryRepository.instance
          .getByTargetCycleId('cycle_a');
      final loaded2 = await SqliteBenchmarkSelectionSummaryRepository.instance
          .getByTargetCycleId('cycle_b');

      expect(loaded1, isNotNull);
      expect(loaded1!.rangeQualityMessage, 'Cycle A.');
      expect(loaded2, isNotNull);
      expect(loaded2!.rangeQualityMessage, 'Cycle B.');
    });
  });
}
