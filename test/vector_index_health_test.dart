// Phase 9.0Σ.j / B47 — focused tests for the vector index health
// helper + filtered-search benchmark scaffolding.
//
// What is asserted:
//
//   1. The locked Voyage searchable embedding space helper predicate
//      matches the partial-index `WHERE` clause in
//      `db/migrations/202604250003_advisor_vector_search.sql`. The
//      test reads the migration text and compares clause sets — if
//      the migration adds, drops, or renames a clause, the test
//      fails until the helper is updated.
//   2. Q20 thresholds (current state):
//        * 5M active vectors → planCutover (yellow).
//        * 8M active vectors → executeCutover (red).
//        * A 10M growth PROJECTION → executeCutover even when
//          current state is below 8M.
//   3. Q20 operational triggers (budget-driven):
//        * Sustained latency above the red budget → executeCutover.
//        * Repeated timeouts above the red budget → executeCutover.
//        * Unacceptable recall (below floor) → executeCutover.
//        * Filtered-search recall below floor → executeCutover.
//        * Rebuild duration above red → executeCutover.
//        * Memory pressure above red → executeCutover.
//        * Same families at the yellow level → planCutover.
//        * Stale or missing benchmark on a non-empty index →
//          investigate (refusal to grant `hold` without evidence).
//   4. HNSW remains the active default. The helper's posture
//      constants do not flip mid-test.
//   5. DiskANN remains dormant. No code path in the helper or the
//      generated benchmark SQL returns or references
//      `VectorIndexType.diskann`.
//   6. The filtered-search benchmark artifact:
//        * is dry-run safe (begins with `begin;`, ends with
//          `rollback;`, never `commit;`);
//        * targets the locked HNSW index name;
//        * never emits `using diskann`;
//        * uses `:query_embedding` (and `:scope_filter`,
//          `:restaurant_id_filter`, `:max_results`) as bind
//          parameters in the executable SELECT/ORDER BY — the
//          zero-vector literal appears only in comments;
//        * rejects malicious filter inputs (apostrophes, `;`,
//          comment markers) BEFORE any string interpolation;
//        * exposes latency / recall placeholder slots in the
//          envelope JSON under the same keys the helper exports;
//        * carries the three B42 metric keys verbatim.
//   7. The helper's `mapToB42Metrics` populates exactly the three
//      reserved keys (`vector_index_size_per_corpus`,
//      `vector_query_latency_ms`, `vector_recall`) and nothing else.
//
// The tests run against the public surface of the tool — they do
// not spawn a child `dart` process and they do not touch any
// database.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/vector_index_health/vector_index_health.dart';

const VectorIndexHealthBudgets _testBudgets = VectorIndexHealthBudgets(
  p50LatencyYellowMs: 30.0,
  p50LatencyRedMs: 80.0,
  p95LatencyYellowMs: 100.0,
  p95LatencyRedMs: 250.0,
  p99LatencyYellowMs: 200.0,
  p99LatencyRedMs: 500.0,
  filteredP95LatencyYellowMs: 150.0,
  filteredP95LatencyRedMs: 350.0,
  timeoutRateYellow: 0.005,
  timeoutRateRed: 0.02,
  recallScoreFloorYellow: 0.85,
  recallScoreFloorRed: 0.75,
  filteredRecallFloorYellow: 0.80,
  filteredRecallFloorRed: 0.70,
  rebuildDurationYellow: Duration(minutes: 30),
  rebuildDurationRed: Duration(hours: 1),
  memoryPressureYellow: 0.75,
  memoryPressureRed: 0.90,
  benchmarkStaleAfter: Duration(days: 7),
);

final DateTime _now = DateTime.utc(2026, 4, 29, 12);

/// Healthy benchmark: every Q20 family inside green budget.
final BenchmarkResult _healthyBenchmark = BenchmarkResult(
  benchmarkTimestamp: DateTime.utc(2026, 4, 29, 11),
  p50LatencyMs: 12.0,
  p95LatencyMs: 28.0,
  p99LatencyMs: 55.0,
  timeoutRate: 0.0,
  recallScore: 0.92,
  filteredSearchBehavior: const FilteredSearchBehavior(
    filteredP95LatencyMs: 31.0,
    filteredRecallScore: 0.90,
    filterPredicateSummary: 'scope=methodology',
  ),
);

VectorIndexHealthSnapshot _snapshotWith({
  int activeVectors = 0,
  VectorIndexType indexType = VectorIndexType.hnsw,
  int indexSizeBytes = 0,
  BuildStatus buildStatus = BuildStatus.ready,
  DateTime? lastBuild,
  BenchmarkResult? benchmark,
  GrowthProjection? growthProjection,
  List<String>? affectedFunctionality,
  String? notes,
  SearchableEmbeddingSpace? space,
  VectorIndexHealthBudgets? budgets,
  DateTime? evaluationTime,
  Duration? lastRebuildDuration,
  double? memoryPressureRatio,
}) {
  return VectorIndexHealthSnapshot(
    space: space ?? kVoyageVoyage4Large1024Space,
    activeVectors: activeVectors,
    indexType: indexType,
    indexSizeBytes: indexSizeBytes,
    buildStatus: buildStatus,
    lastBuild: lastBuild,
    benchmark: benchmark ?? _healthyBenchmark,
    growthProjection:
        growthProjection ??
        const GrowthProjection(horizonDays: 90, projectedActiveVectors: 0),
    affectedFunctionality:
        affectedFunctionality ?? const <String>['advisor_candidate_retrieval'],
    budgets: budgets ?? _testBudgets,
    evaluationTime: evaluationTime ?? _now,
    lastRebuildDuration: lastRebuildDuration,
    memoryPressureRatio: memoryPressureRatio,
    notes: notes,
  );
}

/// Reads the locked partial-index `WHERE` clause out of the migration
/// source and returns its clauses as a normalized list. The test
/// uses this to verify the helper's `partialPredicate` matches the
/// migration without hard-coding the clause set in the test itself —
/// if the migration changes, the helper must change too.
List<String> _migrationPartialPredicateClauses() {
  final repoRoot = Directory.current.path;
  final migrationPath =
      '$repoRoot/db/migrations/202604250003_advisor_vector_search.sql';
  final migration =
      File(migrationPath).readAsStringSync().replaceAll('\r\n', '\n');

  // Find the `create index ... advisor_source_chunks_voyage_hnsw_idx`
  // statement and capture everything up to the terminating semicolon.
  final re = RegExp(
    r'create\s+index\s+if\s+not\s+exists\s+'
    r'advisor_source_chunks_voyage_hnsw_idx[\s\S]*?;',
    caseSensitive: false,
  );
  final match = re.firstMatch(migration);
  expect(
    match,
    isNotNull,
    reason: 'migration must declare advisor_source_chunks_voyage_hnsw_idx',
  );
  final block = match!.group(0)!;

  // Slice out the WHERE block and split on `and`.
  final whereIdx = RegExp(r'\bwhere\b', caseSensitive: false).firstMatch(block);
  expect(whereIdx, isNotNull, reason: 'migration index must be partial');
  final whereBody = block
      .substring(whereIdx!.end)
      .replaceAll(';', '')
      .replaceAll('\n', ' ');
  final clauses = whereBody
      .split(RegExp(r'\band\b', caseSensitive: false))
      .map(_normalizeSql)
      .where((c) => c.isNotEmpty)
      .toList();
  expect(clauses, isNotEmpty);
  return clauses;
}

List<String> _helperPartialPredicateClauses() {
  return kVoyageVoyage4Large1024Space.partialPredicate
      .split(RegExp(r'\band\b', caseSensitive: false))
      .map(_normalizeSql)
      .where((c) => c.isNotEmpty)
      .toList();
}

String _normalizeSql(String raw) =>
    raw.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

void main() {
  group('SearchableEmbeddingSpace — Voyage corpus locked predicate', () {
    test('helper predicate clauses are exactly the migration clauses '
        '(read from db/migrations/202604250003 at test time)', () {
      final migrationClauses = _migrationPartialPredicateClauses();
      final helperClauses = _helperPartialPredicateClauses();

      // Symmetric coverage: every migration clause must be present in
      // the helper, every helper clause in the migration. This
      // catches drift either direction without hard-coding the set.
      expect(
        helperClauses.toSet(),
        equals(migrationClauses.toSet()),
        reason:
            'helper.partialPredicate clauses (${helperClauses.toSet()}) '
            'must match migration clauses '
            '(${migrationClauses.toSet()}) verbatim — drift means a '
            'benchmark would exercise different index pages than '
            'production candidate retrieval.',
      );
    });

    test('helper space metadata matches the migration constants', () {
      final space = kVoyageVoyage4Large1024Space;
      expect(space.providerId, 'voyage');
      expect(space.modelId, 'voyage-4-large');
      expect(space.dimension, 1024);
      expect(space.indexName, 'advisor_source_chunks_voyage_hnsw_idx');
      expect(space.table, 'public.advisor_source_chunks');
      expect(space.embeddingColumn, 'embedding');
    });
  });

  group('Q20 thresholds — yellow / red / projection (current state)', () {
    test('yellow at exactly 5M active vectors', () {
      expect(kYellowActiveVectorThreshold, 5000000);
      final s = _snapshotWith(activeVectors: 5000000);
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('still yellow strictly above 5M but below 8M', () {
      final s = _snapshotWith(activeVectors: 7999999);
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('green strictly below 5M with healthy benchmark', () {
      final s = _snapshotWith(activeVectors: 4999999);
      expect(s.recommendedAction, RecommendedAction.hold);
    });

    test('red at exactly 8M active vectors', () {
      expect(kRedActiveVectorThreshold, 8000000);
      final s = _snapshotWith(activeVectors: 8000000);
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('red strictly above 8M', () {
      final s = _snapshotWith(activeVectors: 9000000);
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('10M growth PROJECTION trips red even when current state is '
        'below 8M (Q20 internal HNSW risk line)', () {
      final s = _snapshotWith(
        activeVectors: 6500000, // yellow band on count alone
        growthProjection: const GrowthProjection(
          horizonDays: 90,
          projectedActiveVectors: kProjectionRiskThreshold,
        ),
      );
      expect(kProjectionRiskThreshold, 10000000);
      expect(s.recommendedAction, RecommendedAction.executeCutover);
      final json = s.toJson();
      final projection = json['growth_projection']! as Map<String, Object?>;
      expect(projection['projected_active_vectors'], 10000000);
      expect(projection['crosses_projection_risk_line'], isTrue);
      // Reported as projection, not as current-state count.
      expect(json['active_vectors'], 6500000);
    });

    test('a 10M projection from a green current state still escalates '
        'to red', () {
      final s = _snapshotWith(
        activeVectors: 100000,
        growthProjection: const GrowthProjection(
          horizonDays: 30,
          projectedActiveVectors: 12000000,
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });
  });

  group('Q20 operational triggers — budget-driven', () {
    test('p50 latency above red budget → executeCutover '
        '(every percentile is its own trigger)', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 90.0, // > red 80
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('p50 latency above yellow but below red → planCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 50.0, // > yellow 30, < red 80
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('p95 latency above red budget → executeCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 300.0, // > red 250
          p99LatencyMs: 400.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 320.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('p95 latency above yellow but below red → planCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 150.0, // > yellow 100, < red 250
          p99LatencyMs: 180.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 145.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('p99 latency above red budget → executeCutover '
        '(tail spike is enough by itself)', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 600.0, // > red 500
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('p99 latency above yellow but below red → planCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 300.0, // > yellow 200, < red 500
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('filtered p95 latency above red budget → executeCutover '
        '(filtered HNSW divergence trips its own trigger)', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 400.0, // > red 350
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('filtered p95 latency above yellow but below red → planCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 200.0, // > yellow 150, < red 350
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('hold cannot be granted when only p95 + recall + timeout + '
        'rebuild + memory are green but p99 OR filtered p95 is red', () {
      // Pins the audit finding directly: a snapshot with p95 inside
      // budget but p99 above red MUST escalate.
      final p99Hot = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0, // green
          p99LatencyMs: 700.0, // RED
          timeoutRate: 0.0, // green
          recallScore: 0.95, // green
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.95,
          ),
        ),
      );
      expect(p99Hot.recommendedAction, RecommendedAction.executeCutover);

      // And: filtered_p95 above red while everything else green.
      final filteredP95Hot = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.95,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 800.0, // RED
            filteredRecallScore: 0.95,
          ),
        ),
      );
      expect(
        filteredP95Hot.recommendedAction,
        RecommendedAction.executeCutover,
      );
    });

    test('timeout rate above red budget → executeCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.05, // > red 0.02
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('timeout rate above yellow but below red → planCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.01, // > yellow 0.005, < red 0.02
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('recall score below red floor → executeCutover '
        '(unacceptable recall)', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.50, // < red floor 0.75
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('recall score below yellow floor → planCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.80, // < yellow 0.85, > red 0.75
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('filtered recall below red floor → executeCutover '
        '(filtered HNSW divergence)', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.50, // < red 0.70
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('rebuild duration above red → executeCutover '
        '(operationally unsafe rebuild)', () {
      final s = _snapshotWith(
        activeVectors: 100,
        lastRebuildDuration: const Duration(hours: 2), // > red 1h
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('rebuild duration above yellow but below red → planCutover '
        '(rebuild window overrun)', () {
      final s = _snapshotWith(
        activeVectors: 100,
        lastRebuildDuration: const Duration(
          minutes: 45,
        ), // > yellow 30m, < red 60m
      );
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('memory pressure above red → executeCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        memoryPressureRatio: 0.95, // > red 0.90
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });

    test('memory pressure above yellow but below red → planCutover', () {
      final s = _snapshotWith(
        activeVectors: 100,
        memoryPressureRatio: 0.80, // > yellow 0.75, < red 0.90
      );
      expect(s.recommendedAction, RecommendedAction.planCutover);
    });

    test('investigate when build is not ready', () {
      final s = _snapshotWith(
        activeVectors: 100,
        buildStatus: BuildStatus.building,
      );
      expect(s.recommendedAction, RecommendedAction.investigate);
    });

    test('investigate when latency / recall numbers are missing on a '
        'non-empty index (refusal to grant hold without evidence)', () {
      final s = _snapshotWith(
        activeVectors: 1000,
        benchmark: const BenchmarkResult(),
      );
      expect(s.recommendedAction, RecommendedAction.investigate);
    });

    test('investigate when benchmark timestamp is older than '
        'budgets.benchmarkStaleAfter', () {
      final s = _snapshotWith(
        activeVectors: 100,
        evaluationTime: _now,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(days: 14)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          filteredSearchBehavior: const FilteredSearchBehavior(
            filteredP95LatencyMs: 31.0,
            filteredRecallScore: 0.85,
          ),
        ),
      );
      expect(s.recommendedAction, RecommendedAction.investigate);
    });

    test('investigate when filtered-search numbers are missing', () {
      final s = _snapshotWith(
        activeVectors: 100,
        benchmark: BenchmarkResult(
          benchmarkTimestamp: _now.subtract(const Duration(hours: 1)),
          p50LatencyMs: 12.0,
          p95LatencyMs: 28.0,
          p99LatencyMs: 55.0,
          timeoutRate: 0.0,
          recallScore: 0.92,
          // filteredSearchBehavior intentionally absent.
        ),
      );
      expect(s.recommendedAction, RecommendedAction.investigate);
    });

    test('hold only when ALL Q20 trigger families are inside green '
        'budget on a non-empty index', () {
      final s = _snapshotWith(
        activeVectors: 100,
        lastRebuildDuration: const Duration(minutes: 10),
        memoryPressureRatio: 0.5,
      );
      expect(s.recommendedAction, RecommendedAction.hold);
    });

    test('current-state below 10M but at or above 8M is red on the '
        'count, not on a projection', () {
      final s = _snapshotWith(
        activeVectors: 8500000,
        growthProjection: const GrowthProjection(
          horizonDays: 365,
          projectedActiveVectors: 8500000,
        ),
      );
      expect(s.recommendedAction, RecommendedAction.executeCutover);
    });
  });

  group('Posture — HNSW active, DiskANN dormant', () {
    test('default active index type is HNSW', () {
      expect(kDefaultActiveIndexType, VectorIndexType.hnsw);
      expect(kDefaultActiveIndexType.sqlName, 'hnsw');
    });

    test('DiskANN is reported dormant by the helper constants', () {
      expect(kDiskannIsDormant, isTrue);
    });

    test('snapshot.toJson surfaces the posture under `posture`', () {
      final s = _snapshotWith(activeVectors: 100);
      final json = s.toJson();
      final posture = json['posture']! as Map<String, Object?>;
      expect(posture['default_active_index_type'], 'hnsw');
      expect(posture['diskann_is_dormant'], isTrue);
    });

    test('no helper-built snapshot reports indexType=diskann', () {
      final s = _snapshotWith(activeVectors: 100);
      expect(s.indexType, VectorIndexType.hnsw);
      expect(s.toJson()['index_type'], 'hnsw');
    });
  });

  group('B42 metric mapping — exactly three reserved keys', () {
    test('mapToB42Metrics produces vector_index_size_per_corpus, '
        'vector_query_latency_ms, vector_recall — and nothing else', () {
      final s = _snapshotWith(
        activeVectors: 1000,
        indexSizeBytes: 64 * 1024 * 1024,
      );
      final mapping = mapToB42Metrics(<VectorIndexHealthSnapshot>[s]);
      final json = mapping.toJson();
      expect(json.keys.toSet(), <String>{
        'vector_index_size_per_corpus',
        'vector_query_latency_ms',
        'vector_recall',
      });
    });

    test('vector_index_size_per_corpus is keyed by corpusId and exposes '
        'index size + active vectors', () {
      final s = _snapshotWith(activeVectors: 1234, indexSizeBytes: 999);
      final mapping = mapToB42Metrics(<VectorIndexHealthSnapshot>[s]);
      final size =
          mapping.vectorIndexSizePerCorpus[s.space.corpusId]!
              as Map<String, Object?>;
      expect(size['index_size_bytes'], 999);
      expect(size['active_vectors'], 1234);
      expect(size['yellow_threshold'], kYellowActiveVectorThreshold);
      expect(size['red_threshold'], kRedActiveVectorThreshold);
    });

    test('vector_query_latency_ms carries p50/p95/p99 + timeout_rate', () {
      final s = _snapshotWith(activeVectors: 100);
      final mapping = mapToB42Metrics(<VectorIndexHealthSnapshot>[s]);
      final latency =
          mapping.vectorQueryLatencyMs[s.space.corpusId]!
              as Map<String, Object?>;
      expect(latency['p50_latency_ms'], 12.0);
      expect(latency['p95_latency_ms'], 28.0);
      expect(latency['p99_latency_ms'], 55.0);
      expect(latency['timeout_rate'], 0.0);
      expect(latency['benchmark_timestamp'], isNotNull);
    });

    test('vector_recall carries recall_score AND the filtered behavior '
        'companions', () {
      final s = _snapshotWith(activeVectors: 100);
      final mapping = mapToB42Metrics(<VectorIndexHealthSnapshot>[s]);
      final recall =
          mapping.vectorRecall[s.space.corpusId]! as Map<String, Object?>;
      expect(recall['recall_score'], 0.92);
      expect(recall['filtered_recall_score'], 0.90);
      expect(recall['filtered_p95_latency_ms'], 31.0);
      expect(recall['filter_predicate_summary'], 'scope=methodology');
    });
  });

  group('Filtered-search benchmark artifact — dry-run safe', () {
    test('SQL begins with `begin;` and ends with `rollback;`, never '
        '`commit;`', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 100)],
      );
      final sql = artifact.sql;
      expect(sql.contains('begin;'), isTrue);
      expect(sql.contains('rollback;'), isTrue);
      expect(sql.contains('commit;'), isFalse);
      expect(sql.indexOf('begin;') < sql.indexOf('rollback;'), isTrue);
    });

    test('SQL targets the locked HNSW index name and never emits '
        '`using diskann`', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 100)],
      );
      final sql = artifact.sql;
      expect(sql.contains('advisor_source_chunks_voyage_hnsw_idx'), isTrue);
      expect(sql.contains('using hnsw'), isTrue);
      expect(sql.toLowerCase().contains('using diskann'), isFalse);
    });

    test('executable SELECT and ORDER BY use :query_embedding bind, '
        'not the zero-vector literal', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 100)],
      );
      final sql = artifact.sql;

      // Strip every `--` line so we only inspect executable bytes
      // (psql `\set` lines are NOT comments — they execute, but they
      // run client-side and never reach the server).
      final executable = sql
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('--'))
          .join('\n');

      // The executable SELECT and ORDER BY must reference the bind.
      expect(
        executable.contains('embedding <=> :query_embedding as distance'),
        isTrue,
        reason: 'SELECT must read the :query_embedding bind, not a literal',
      );
      expect(
        executable.contains('order by embedding <=> :query_embedding'),
        isTrue,
        reason: 'ORDER BY must read the :query_embedding bind, not a literal',
      );
      expect(executable.contains('limit :max_results;'), isTrue);
      expect(executable.contains('scope = :scope_filter'), isTrue);
      expect(executable.contains(':restaurant_id_filter'), isTrue);

      // The zero-vector literal can appear ONLY in commentary; no
      // server-bound statement may contain it. Strip out psql `\set`
      // lines (they run client-side) and the `\set` block before
      // checking server-bound statements for the literal.
      final serverBound = executable
          .split('\n')
          .where((line) => !line.trimLeft().startsWith(r'\set'))
          .join('\n');
      expect(
        serverBound.contains("'[0,0,"),
        isFalse,
        reason:
            'zero-vector literal must live in comments only — not in '
            'server-bound SQL statements',
      );

      // Sanity: the zero-vector reference IS present somewhere (in
      // comments) so the operator has a parse-check fallback.
      expect(sql.contains("'[0,0,"), isTrue);
    });

    test('SQL emits conditional psql `\\set` defaults so `psql -v` '
        'values are not overwritten', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 100)],
        filterScope: 'methodology',
        filterRestaurantId: '11111111-2222-3333-4444-555555555555',
        filterMaxResults: 25,
      );
      final sql = artifact.sql;
      // Conditional `\set` lines for every variable referenced in
      // the SQL. Command-line `psql -v name=value` variables are
      // defined before the file is processed, so the fallback must
      // sit in the `\else` branch instead of overwriting the value.
      expect(sql.contains(r'\if :{?query_embedding}'), isTrue);
      expect(sql.contains(r'\if :{?scope_filter}'), isTrue);
      expect(sql.contains(r'\if :{?restaurant_id_filter}'), isTrue);
      expect(sql.contains(r'\if :{?max_results}'), isTrue);
      expect(sql.contains(r'\set query_embedding '), isTrue);
      expect(sql.contains(r'\set scope_filter '), isTrue);
      expect(sql.contains(r'\set restaurant_id_filter '), isTrue);
      expect(sql.contains(r'\set max_results '), isTrue);
      expect(
        sql.indexOf(r'\if :{?query_embedding}') <
            sql.indexOf(r'\set query_embedding '),
        isTrue,
      );
      expect(
        sql.indexOf(r'\else') < sql.indexOf(r'\set query_embedding '),
        isTrue,
      );

      // `:query_embedding` defaults to a bare-identifier sentinel
      // that fails at server parse time when not overridden.
      expect(
        sql.contains(r'\set query_embedding __REPLACE_ME_QUERY_EMBEDDING__'),
        isTrue,
        reason:
            'sentinel default must reach the server as a bare '
            'identifier so the parser rejects it',
      );

      // Validated values land in the `\set` block in psql-quoted form.
      expect(
        sql.contains(r"\set scope_filter '''methodology'''"),
        isTrue,
        reason:
            'scope must be psql-quoted so :scope_filter substitutes '
            "to the SQL literal 'methodology'",
      );
      expect(
        sql.contains(
          r"\set restaurant_id_filter "
          "'''11111111-2222-3333-4444-555555555555''::uuid'",
        ),
        isTrue,
      );
      expect(sql.contains(r'\set max_results 25'), isTrue);
    });

    test('SQL records the validated bind values in a human-readable '
        'comment block', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 100)],
        filterScope: 'methodology',
        filterRestaurantId: '11111111-2222-3333-4444-555555555555',
        filterMaxResults: 25,
      );
      final sql = artifact.sql;
      expect(sql.contains(':scope_filter         = "methodology"'), isTrue);
      expect(
        sql.contains(
          ':restaurant_id_filter = "11111111-2222-3333-4444-555555555555"',
        ),
        isTrue,
      );
      expect(sql.contains(':max_results          = 25'), isTrue);
    });

    test('SQL documents the `psql -v` invocation pattern so the '
        'operator can override every variable from the command line', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 100)],
      );
      final sql = artifact.sql;
      expect(sql.contains('-v "query_embedding='), isTrue);
      expect(sql.contains('-v "scope_filter='), isTrue);
      expect(sql.contains('-v "restaurant_id_filter='), isTrue);
      expect(sql.contains('-v max_results=10'), isTrue);
      expect(sql.contains('-f filtered_search_benchmark.sql'), isTrue);
    });

    test('envelope JSON declares run_channel=psql and lists the four '
        'psql variables and the unbound-sentinel value', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 0)],
      );
      final envelope =
          jsonDecode(artifact.envelopeJson) as Map<String, Object?>;
      expect(envelope['run_channel'], 'psql');
      expect(
        envelope['query_embedding_unbound_sentinel'],
        '__REPLACE_ME_QUERY_EMBEDDING__',
      );
      final psqlVars = envelope['psql_variables']! as List<Object?>;
      expect(psqlVars, <String>[
        'query_embedding',
        'scope_filter',
        'restaurant_id_filter',
        'max_results',
      ]);
      final invocations =
          envelope['psql_invocation_examples']! as List<Object?>;
      expect(invocations, isNotEmpty);
      expect(invocations.first.toString(), contains('psql '));
      expect(
        invocations.first.toString(),
        contains('-f filtered_search_benchmark.sql'),
      );
    });

    test('strict allowlist refuses an apostrophe in filterScope before '
        'any SQL emission', () {
      expect(
        () => buildFilteredSearchBenchmarkArtifact(<VectorIndexHealthSnapshot>[
          _snapshotWith(activeVectors: 0),
        ], filterScope: "methodology' or '1'='1"),
        throwsA(isA<VectorIndexHealthException>()),
      );
    });

    test('strict allowlist refuses semicolons / commit injection in '
        'filterScope', () {
      // The exact attack from the audit finding.
      expect(
        () => buildFilteredSearchBenchmarkArtifact(<VectorIndexHealthSnapshot>[
          _snapshotWith(activeVectors: 0),
        ], filterScope: "'; commit; --"),
        throwsA(isA<VectorIndexHealthException>()),
      );
    });

    test('strict allowlist refuses non-UUID filterRestaurantId', () {
      expect(
        () => buildFilteredSearchBenchmarkArtifact(<VectorIndexHealthSnapshot>[
          _snapshotWith(activeVectors: 0),
        ], filterRestaurantId: "abc'; commit; --"),
        throwsA(isA<VectorIndexHealthException>()),
      );
    });

    test('strict allowlist refuses out-of-range filterMaxResults', () {
      expect(
        () => buildFilteredSearchBenchmarkArtifact(<VectorIndexHealthSnapshot>[
          _snapshotWith(activeVectors: 0),
        ], filterMaxResults: 0),
        throwsA(isA<VectorIndexHealthException>()),
      );
      expect(
        () => buildFilteredSearchBenchmarkArtifact(<VectorIndexHealthSnapshot>[
          _snapshotWith(activeVectors: 0),
        ], filterMaxResults: 101),
        throwsA(isA<VectorIndexHealthException>()),
      );
    });

    test('SQL applies the locked filter predicates so the run exercises '
        'filtered HNSW behaviour against the same partial-index slice', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 100)],
        filterScope: 'methodology',
      );
      final sql = artifact.sql;
      expect(sql.contains("embedding_provider_id = 'voyage'"), isTrue);
      expect(sql.contains("embedding_model_id = 'voyage-4-large'"), isTrue);
      expect(sql.contains('embedding_dimension = 1024'), isTrue);
      expect(sql.contains('explain (analyze, buffers, format json)'), isTrue);
    });

    test('envelope JSON exposes the three B42 metric keys verbatim, plus '
        'latency / recall placeholder slots', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[
          _snapshotWith(activeVectors: 0, benchmark: const BenchmarkResult()),
        ],
      );
      final envelope =
          jsonDecode(artifact.envelopeJson) as Map<String, Object?>;
      expect(
        envelope['record_type'],
        'vector_index_health_filtered_search_benchmark',
      );
      expect(envelope['apply_mode'], 'dry_run_template_only');
      expect(envelope['targets_index_type'], 'hnsw');
      expect(envelope['diskann_is_dormant'], isTrue);

      final keys = envelope['b42_metric_keys']! as List<Object?>;
      expect(keys, <String>[
        'vector_index_size_per_corpus',
        'vector_query_latency_ms',
        'vector_recall',
      ]);

      final snapshots = envelope['snapshots']! as List<Object?>;
      final first = snapshots.single! as Map<String, Object?>;
      expect(first.containsKey('p50_latency_ms'), isTrue);
      expect(first.containsKey('p95_latency_ms'), isTrue);
      expect(first.containsKey('p99_latency_ms'), isTrue);
      expect(first.containsKey('recall_score'), isTrue);
      expect(first.containsKey('filtered_search_behavior'), isTrue);
      expect(first['p50_latency_ms'], isNull);
      expect(first['p95_latency_ms'], isNull);
      expect(first['recall_score'], isNull);
    });

    test('envelope JSON safety_invariants enumerate the slice posture', () {
      final artifact = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[_snapshotWith(activeVectors: 0)],
      );
      final envelope =
          jsonDecode(artifact.envelopeJson) as Map<String, Object?>;
      final invariants = envelope['safety_invariants']! as List<Object?>;
      expect(
        invariants,
        containsAll(<String>[
          'no live endpoint calls from this helper',
          'no production mutations: SQL ends with ROLLBACK',
          'no default switch from HNSW to DiskANN',
          'filter inputs validated against strict allowlists before SQL emission',
        ]),
      );
    });

    test('non-positive dimensions cannot build the comment-only zero '
        'vector reference', () {
      final badSpace = SearchableEmbeddingSpace(
        corpusId: 'broken',
        providerId: 'voyage',
        modelId: 'voyage-4-large',
        dimension: 0,
        indexName: 'no_idx',
        table: 'public.none',
        embeddingColumn: 'embedding',
        partialPredicate: 'true',
      );
      final s = _snapshotWith(activeVectors: 0, space: badSpace);
      expect(
        () => buildFilteredSearchBenchmarkArtifact(<VectorIndexHealthSnapshot>[
          s,
        ]),
        throwsA(isA<VectorIndexHealthException>()),
      );
    });

    test('artifact stays deterministic across runs with identical inputs', () {
      final s = _snapshotWith(activeVectors: 100, indexSizeBytes: 4096);
      final a1 = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[s],
      );
      final a2 = buildFilteredSearchBenchmarkArtifact(
        <VectorIndexHealthSnapshot>[s],
      );
      expect(a1.sql, a2.sql);
      expect(a1.envelopeJson, a2.envelopeJson);
    });
  });

  group('Snapshot.toJson — every Q20 observability field present', () {
    test('all 14 trigger-doc fields are exposed plus thresholds, '
        'budgets, posture, and operational signals', () {
      final s = _snapshotWith(
        activeVectors: 100,
        indexSizeBytes: 1024,
        lastBuild: DateTime.utc(2026, 4, 28, 9),
        lastRebuildDuration: const Duration(minutes: 12),
        memoryPressureRatio: 0.4,
      );
      final json = s.toJson();
      // 14 Q20 observability fields:
      expect(json.containsKey('active_vectors'), isTrue);
      expect(json.containsKey('index_type'), isTrue);
      expect(json.containsKey('index_size_bytes'), isTrue);
      expect(json.containsKey('build_status'), isTrue);
      expect(json.containsKey('last_build'), isTrue);
      expect(json.containsKey('benchmark_timestamp'), isTrue);
      expect(json.containsKey('p50_latency_ms'), isTrue);
      expect(json.containsKey('p95_latency_ms'), isTrue);
      expect(json.containsKey('p99_latency_ms'), isTrue);
      expect(json.containsKey('timeout_rate'), isTrue);
      expect(json.containsKey('recall_score'), isTrue);
      expect(json.containsKey('filtered_search_behavior'), isTrue);
      expect(json.containsKey('growth_projection'), isTrue);
      expect(json.containsKey('affected_functionality'), isTrue);
      expect(json.containsKey('recommended_action'), isTrue);
      // Companions:
      expect(json.containsKey('thresholds'), isTrue);
      expect(json.containsKey('posture'), isTrue);
      expect(json.containsKey('space'), isTrue);
      expect(json.containsKey('budgets'), isTrue);
      expect(json.containsKey('evaluation_time'), isTrue);
      expect(json.containsKey('last_rebuild_duration_seconds'), isTrue);
      expect(json.containsKey('memory_pressure_ratio'), isTrue);
    });
  });
}
