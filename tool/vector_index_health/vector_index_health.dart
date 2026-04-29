// Phase 9.0Σ.j companion — Vector Index Health helper + filtered-search
// benchmark scaffolding (B47 in `phase_9_execution_backlog.md`).
//
// Authority:
//   * docs/phases/phase_9/phase_9_vector_index_switch_trigger.md — Q20
//     yellow / red thresholds and the locked observability field set.
//   * docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md
//     item 31 (HNSW remains default; DiskANN installed dormant).
//   * db/migrations/202604250003_advisor_vector_search.sql
//     (HNSW partial index over Voyage `voyage-4-large` 1024-dim ready
//     vectors; the partial predicate is the searchable embedding space
//     definition this helper reads against).
//   * db/migrations/202604280009_phase_9_0sigma_j_diskann_install.sql
//     (`pg_diskann` installed but no DiskANN index exists; this helper
//     therefore defaults `index_type='hnsw'`).
//
// What this helper does:
//   * Defines pure data shapes for one Vector Index Health snapshot per
//     searchable embedding space (one `(provider_id, model_id,
//     dimension)` partial-index slice such as the Voyage
//     `voyage-4-large` 1024-dim corpus).
//   * Encodes Q20 yellow / red thresholds (5M yellow, 8M red,
//     10M-projection treated as a projection signal — not an immediate
//     red threshold) so the `recommended_action` field is derived,
//     never hand-written.
//   * Maps each snapshot to the three B42 metric keys reserved for
//     11A.5 health surfaces:
//       - vector_index_size_per_corpus (one entry per corpus)
//       - vector_query_latency_ms      (p50/p95/p99 from the same row)
//       - vector_recall                (recall_score)
//   * Emits a dry-run filtered-search benchmark artifact (a SQL
//     template + an envelope JSON) the operator can later run on
//     staging through the Phase 9 migration channel. The artifact is a
//     plain file; this module never connects to a database.
//
// What this helper does NOT do (slice hard constraints):
//   * Never imports `package:postgres`. There is no live connection
//     here. CLAUDE.md forbids raw `package:postgres` imports outside
//     `lib/infrastructure/persistence/postgres/`; this tool stays on
//     the right side of that line.
//   * Never wires a proxy `/health` route. Route surface lands with
//     B42; this slice provides the data the route will read. Doing
//     otherwise would conflict with B42/B44/B45 running in parallel.
//   * Never flips the default index from HNSW to DiskANN. The Q20
//     posture is encoded explicitly (`indexTypeDefault == hnsw`,
//     `diskannIsDormant == true`). The benchmark SQL targets the
//     existing HNSW partial index only; it never references
//     `USING diskann`.
//   * Never invents recall numbers from thin air. A snapshot whose
//     `recallScore` / `latency*` fields are null reports
//     `RecommendedAction.investigate` instead of pretending the
//     metric is green.

import 'dart:convert';

/// Yellow threshold per Q20: any of these moves the decision to
/// "plan a non-destructive cutover dry run". The 5M line is the
/// active-vector count per searchable embedding space, NOT an
/// aggregate row count across corpora.
const int kYellowActiveVectorThreshold = 5000000;

/// Red threshold per Q20: any of these moves the decision to
/// "execute the cutover playbook". 8M active vectors in one
/// searchable embedding space is the launch product's red line.
const int kRedActiveVectorThreshold = 8000000;

/// Internal HNSW risk line per Q20. A growth projection that crosses
/// 10M within the operational planning window for the index moves
/// the decision into red. Important: this is a PROJECTION threshold,
/// not a current-state threshold — a snapshot whose `activeVectors`
/// is below 8M but whose `growthProjection` crosses 10M is reported
/// as `executeCutover` because the projection itself is the trigger.
const int kProjectionRiskThreshold = 10000000;

/// Default vector index strategy posture. HNSW is the active default;
/// `pg_diskann` is installed dormant per
/// 202604280009_phase_9_0sigma_j_diskann_install.sql. This constant
/// is what the helper reports out, NOT a knob to flip.
const VectorIndexType kDefaultActiveIndexType = VectorIndexType.hnsw;

/// `true` until Q20 thresholds fire AND the non-destructive cutover
/// playbook (shadow → benchmark → canary) authorizes a switch. This
/// helper does not authorize the switch and never sets this to false.
const bool kDiskannIsDormant = true;

/// The Voyage searchable embedding space frozen by 11a.6a / 11a.8.
/// Other corpora are introduced by adding more
/// `SearchableEmbeddingSpace` instances; existing ones are NOT
/// rewritten in place.
const SearchableEmbeddingSpace kVoyageVoyage4Large1024Space =
    SearchableEmbeddingSpace(
      corpusId: 'advisor_methodology',
      providerId: 'voyage',
      modelId: 'voyage-4-large',
      dimension: 1024,
      indexName: 'advisor_source_chunks_voyage_hnsw_idx',
      table: 'public.advisor_source_chunks',
      embeddingColumn: 'embedding',
      partialPredicate:
          "embedding_status = 'ready' "
          "AND embedding IS NOT NULL "
          "AND embedding_provider_id = 'voyage' "
          "AND embedding_model_id = 'voyage-4-large' "
          "AND embedding_dimension = 1024 "
          "AND active = true",
    );

/// One physical vector index strategy. Today only HNSW is active
/// (pgvector's `vector_cosine_ops`); DiskANN exists in the extension
/// list but no DiskANN index is created in this slice.
enum VectorIndexType {
  hnsw,
  diskann;

  String get sqlName {
    switch (this) {
      case VectorIndexType.hnsw:
        return 'hnsw';
      case VectorIndexType.diskann:
        return 'diskann';
    }
  }
}

/// Index build status per Q20. Mirrors the surface a Postgres-side
/// `pg_index` / pg_stat_user_indexes inspector would report.
enum BuildStatus {
  ready,
  building,
  failed,
  pending;

  String get jsonName => name;
}

/// Q20 derived recommendation. The helper computes this; callers do
/// not set it directly. Values map 1:1 to the trigger doc:
///   - hold              → all metrics inside green budget
///   - planCutover       → yellow trigger fired (investigate path)
///   - executeCutover    → red trigger fired (cutover playbook path)
///   - investigate       → metric incomplete or signal contradicts
///                         (e.g. recall null with high latency)
enum RecommendedAction {
  hold,
  planCutover,
  executeCutover,
  investigate;

  String get jsonName {
    switch (this) {
      case RecommendedAction.hold:
        return 'hold';
      case RecommendedAction.planCutover:
        return 'plan_cutover';
      case RecommendedAction.executeCutover:
        return 'execute_cutover';
      case RecommendedAction.investigate:
        return 'investigate';
    }
  }
}

/// Pure data definition of a single searchable embedding space — one
/// `(provider_id, model_id, dimension)` partial-index slice. Q20
/// triggers fire per-space, never on aggregates across spaces.
class SearchableEmbeddingSpace {
  const SearchableEmbeddingSpace({
    required this.corpusId,
    required this.providerId,
    required this.modelId,
    required this.dimension,
    required this.indexName,
    required this.table,
    required this.embeddingColumn,
    required this.partialPredicate,
  });

  /// Operator-facing corpus name (`advisor_methodology` today; future
  /// surfaces such as workflow-pattern corpora would have their own).
  final String corpusId;

  /// Embedding provider id (e.g. `voyage`). Matches the partial-index
  /// predicate column so a future provider cannot silently mix in.
  final String providerId;

  /// Embedding model id (e.g. `voyage-4-large`).
  final String modelId;

  /// Embedding vector dimension (e.g. 1024). Must be > 0.
  final int dimension;

  /// On-disk index name. Today: `advisor_source_chunks_voyage_hnsw_idx`.
  final String indexName;

  /// Backing table holding the embedding column.
  final String table;

  /// Column on `table` that stores the `vector(N)` values.
  final String embeddingColumn;

  /// SQL `WHERE` clause that defines this searchable embedding space.
  /// Comes straight from 202604250003_advisor_vector_search.sql so a
  /// benchmark template exercises the same partial-index pages the
  /// production candidate retrieval reads.
  final String partialPredicate;

  Map<String, Object?> toJson() => <String, Object?>{
    'corpus_id': corpusId,
    'provider_id': providerId,
    'model_id': modelId,
    'dimension': dimension,
    'index_name': indexName,
    'table': table,
    'embedding_column': embeddingColumn,
    'partial_predicate': partialPredicate,
  };
}

/// A growth projection over a planning horizon (e.g. 90 days). Q20
/// treats this as a *projection*; the helper compares
/// `projectedActiveVectors` against `kProjectionRiskThreshold` for
/// the red 10M line, but does NOT treat the current-state count
/// against 10M as a red trigger.
class GrowthProjection {
  const GrowthProjection({
    required this.horizonDays,
    required this.projectedActiveVectors,
  });

  final int horizonDays;
  final int projectedActiveVectors;

  bool get crossesProjectionRiskLine =>
      projectedActiveVectors >= kProjectionRiskThreshold;

  Map<String, Object?> toJson() => <String, Object?>{
    'horizon_days': horizonDays,
    'projected_active_vectors': projectedActiveVectors,
    'crosses_projection_risk_line': crossesProjectionRiskLine,
    'projection_risk_threshold': kProjectionRiskThreshold,
  };
}

/// Latency / recall numbers from one benchmark run. Null fields mean
/// the benchmark has not produced a value yet (the operator has not
/// run the dry-run benchmark on staging) — `RecommendedAction` reads
/// nullness as `investigate`, not green.
class BenchmarkResult {
  const BenchmarkResult({
    this.benchmarkTimestamp,
    this.p50LatencyMs,
    this.p95LatencyMs,
    this.p99LatencyMs,
    this.timeoutRate,
    this.recallScore,
    this.filteredSearchBehavior,
  });

  final DateTime? benchmarkTimestamp;
  final double? p50LatencyMs;
  final double? p95LatencyMs;
  final double? p99LatencyMs;

  /// Fraction in `[0.0, 1.0]` of candidate-retrieval calls that
  /// exceeded the timeout budget over the benchmark window.
  final double? timeoutRate;

  /// Recall against the held-out evaluation set, in `[0.0, 1.0]`.
  final double? recallScore;

  /// Per-Q20 the filtered-search behavior is its own field because
  /// filtered HNSW recall / latency diverge from the unfiltered
  /// shape (the `scope` and `restaurant_id` predicates skew the
  /// graph traversal). The helper records the divergent numbers so
  /// the 11A.5 health surface can show both side-by-side.
  final FilteredSearchBehavior? filteredSearchBehavior;

  bool get hasLatencyMetrics =>
      p50LatencyMs != null && p95LatencyMs != null && p99LatencyMs != null;

  Map<String, Object?> toJson() => <String, Object?>{
    'benchmark_timestamp': benchmarkTimestamp?.toUtc().toIso8601String(),
    'p50_latency_ms': p50LatencyMs,
    'p95_latency_ms': p95LatencyMs,
    'p99_latency_ms': p99LatencyMs,
    'timeout_rate': timeoutRate,
    'recall_score': recallScore,
    'filtered_search_behavior': filteredSearchBehavior?.toJson(),
  };
}

/// Filtered-search recall + latency under the locked predicates
/// (`scope`, optional `restaurant_id`, plus the
/// provider/model/dimension triple). Per Q20 these diverge from the
/// unfiltered numbers and need to be reported separately.
class FilteredSearchBehavior {
  const FilteredSearchBehavior({
    this.filteredP95LatencyMs,
    this.filteredRecallScore,
    this.filterPredicateSummary,
  });

  final double? filteredP95LatencyMs;
  final double? filteredRecallScore;

  bool get hasNumbers =>
      filteredP95LatencyMs != null && filteredRecallScore != null;

  /// Short human-readable summary of which filter predicates were
  /// applied during the run (e.g. `scope=methodology;
  /// restaurant_id=[uuid]`). Stored verbatim so the health surface
  /// can show "filtered by X" next to the numbers.
  final String? filterPredicateSummary;

  Map<String, Object?> toJson() => <String, Object?>{
    'filtered_p95_latency_ms': filteredP95LatencyMs,
    'filtered_recall_score': filteredRecallScore,
    'filter_predicate_summary': filterPredicateSummary,
  };
}

/// Operational budgets the snapshot evaluator compares benchmark and
/// rebuild signals against. Q20 lists six trigger families beyond
/// active-vector counts (latency regression, rebuild-window
/// overruns, memory pressure, repeated timeouts, unacceptable
/// recall/latency, unsafe rebuilds). Encoding them as explicit
/// budgets means a snapshot cannot return `hold` while quietly
/// failing one of those families.
///
/// Every field is required. There are NO implicit defaults: the
/// caller must pass an explicit budget instance. The
/// [exampleStartingBudgets] constant below is documented as a
/// starting point — it is not a contract-locked threshold and the
/// operator tunes it per searchable embedding space. Tests pin the
/// exact thresholds they want to evaluate against.
class VectorIndexHealthBudgets {
  const VectorIndexHealthBudgets({
    required this.p50LatencyYellowMs,
    required this.p50LatencyRedMs,
    required this.p95LatencyYellowMs,
    required this.p95LatencyRedMs,
    required this.p99LatencyYellowMs,
    required this.p99LatencyRedMs,
    required this.filteredP95LatencyYellowMs,
    required this.filteredP95LatencyRedMs,
    required this.timeoutRateYellow,
    required this.timeoutRateRed,
    required this.recallScoreFloorYellow,
    required this.recallScoreFloorRed,
    required this.filteredRecallFloorYellow,
    required this.filteredRecallFloorRed,
    required this.rebuildDurationYellow,
    required this.rebuildDurationRed,
    required this.memoryPressureYellow,
    required this.memoryPressureRed,
    required this.benchmarkStaleAfter,
  });

  // Latency regression — Q20 says "sustained latency regression at
  // p50, p95, OR p99" fires the trigger, and `filtered_search_behavior`
  // (filtered p95) is its own field because filtered HNSW latency
  // diverges from the unfiltered shape. Each percentile gets its
  // own yellow / red budget so the operator can encode tail
  // tolerance separately from the median.
  final double p50LatencyYellowMs;
  final double p50LatencyRedMs;
  final double p95LatencyYellowMs;
  final double p95LatencyRedMs;
  final double p99LatencyYellowMs;
  final double p99LatencyRedMs;
  final double filteredP95LatencyYellowMs;
  final double filteredP95LatencyRedMs;

  // Repeated timeouts — fraction of candidate-retrieval calls that
  // exceeded the timeout budget. Q20 treats this as a red trigger.
  final double timeoutRateYellow;
  final double timeoutRateRed;

  // Unacceptable recall — a recall score under the floor moves the
  // recommendation. Filtered recall has its own floor because Q20
  // calls out filtered HNSW behaviour as divergent.
  final double recallScoreFloorYellow;
  final double recallScoreFloorRed;
  final double filteredRecallFloorYellow;
  final double filteredRecallFloorRed;

  // Rebuilds exceeding the maintenance window — yellow when the
  // last rebuild duration crosses the operational budget; red when
  // it crosses the unsafe-rebuild line.
  final Duration rebuildDurationYellow;
  final Duration rebuildDurationRed;

  // Memory pressure attributable to the resident HNSW graph. 0.0 is
  // idle, 1.0 saturates the budget. Q20 lists this explicitly.
  final double memoryPressureYellow;
  final double memoryPressureRed;

  // Benchmark freshness. A benchmark older than this is treated as
  // missing evidence, not as a green run.
  final Duration benchmarkStaleAfter;

  /// A documented starting set of budgets for the Voyage searchable
  /// embedding space. Operators tune per-corpus; this is intentionally
  /// not a contract-locked default and is opt-in by the caller. The
  /// helper does not consume this constant on its own.
  static const VectorIndexHealthBudgets exampleStartingBudgets =
      VectorIndexHealthBudgets(
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

  Map<String, Object?> toJson() => <String, Object?>{
    'p50_latency_yellow_ms': p50LatencyYellowMs,
    'p50_latency_red_ms': p50LatencyRedMs,
    'p95_latency_yellow_ms': p95LatencyYellowMs,
    'p95_latency_red_ms': p95LatencyRedMs,
    'p99_latency_yellow_ms': p99LatencyYellowMs,
    'p99_latency_red_ms': p99LatencyRedMs,
    'filtered_p95_latency_yellow_ms': filteredP95LatencyYellowMs,
    'filtered_p95_latency_red_ms': filteredP95LatencyRedMs,
    'timeout_rate_yellow': timeoutRateYellow,
    'timeout_rate_red': timeoutRateRed,
    'recall_score_floor_yellow': recallScoreFloorYellow,
    'recall_score_floor_red': recallScoreFloorRed,
    'filtered_recall_floor_yellow': filteredRecallFloorYellow,
    'filtered_recall_floor_red': filteredRecallFloorRed,
    'rebuild_duration_yellow_seconds': rebuildDurationYellow.inSeconds,
    'rebuild_duration_red_seconds': rebuildDurationRed.inSeconds,
    'memory_pressure_yellow': memoryPressureYellow,
    'memory_pressure_red': memoryPressureRed,
    'benchmark_stale_after_seconds': benchmarkStaleAfter.inSeconds,
  };
}

/// One Vector Index Health snapshot per searchable embedding space.
/// Carries all 14 Q20 observability fields plus the derived
/// `recommendedAction`. Field naming matches the trigger doc so
/// drift between the doc and the data shape is easy to spot.
class VectorIndexHealthSnapshot {
  VectorIndexHealthSnapshot({
    required this.space,
    required this.activeVectors,
    required this.indexType,
    required this.indexSizeBytes,
    required this.buildStatus,
    required this.lastBuild,
    required this.benchmark,
    required this.growthProjection,
    required this.affectedFunctionality,
    required this.budgets,
    required this.evaluationTime,
    this.lastRebuildDuration,
    this.memoryPressureRatio,
    this.notes,
  });

  final SearchableEmbeddingSpace space;

  /// Count of rows currently included in the partial-index predicate.
  final int activeVectors;

  /// Active index strategy. Today: `hnsw`. DiskANN MUST NOT appear
  /// here in this slice (Q20 dormant posture).
  final VectorIndexType indexType;

  /// On-disk index size in bytes. Stored as an int so the helper
  /// stays platform-portable; the trigger doc's `index_size` field
  /// is a single number per index.
  final int indexSizeBytes;

  final BuildStatus buildStatus;

  /// Timestamp of the most recent successful build. Null when the
  /// index has never built (e.g. `building` / `pending`).
  final DateTime? lastBuild;

  final BenchmarkResult benchmark;

  final GrowthProjection growthProjection;

  /// Which advisor / future-surface paths this index serves. Used by
  /// the cutover playbook to size blast radius.
  final List<String> affectedFunctionality;

  /// Operational budgets the evaluator compares benchmark + rebuild
  /// signals against. Required so the helper cannot silently grant
  /// `hold` without an explicit decision on what counts as green.
  final VectorIndexHealthBudgets budgets;

  /// Wall-clock the snapshot is being evaluated against. Used to
  /// compute benchmark staleness deterministically. Production
  /// callers pass `DateTime.now().toUtc()`; tests pin a fixed time.
  final DateTime evaluationTime;

  /// Wall-clock duration of the most recent rebuild attempt. Null
  /// when no rebuild has been observed yet (e.g. fresh install).
  /// Compared against `budgets.rebuildDuration*` to catch the
  /// rebuild-window-overrun and unsafe-rebuild Q20 triggers.
  final Duration? lastRebuildDuration;

  /// Resident graph memory pressure in `[0.0, 1.0]`. Null when the
  /// host signal is unavailable. Compared against
  /// `budgets.memoryPressure*` to catch the memory-pressure Q20
  /// trigger.
  final double? memoryPressureRatio;

  /// Free-form context (e.g. "build started 2026-04-29" or
  /// "rebuilt after schema migration"). Optional.
  final String? notes;

  /// Q20 derived recommendation. Reads ALL trigger families:
  ///
  ///   Red (executeCutover) — any of:
  ///     - `activeVectors >= 8M`
  ///     - growth projection crosses 10M
  ///     - `timeout_rate >= budgets.timeoutRateRed`
  ///     - `p50_latency_ms >= budgets.p50LatencyRedMs`
  ///     - `p95_latency_ms >= budgets.p95LatencyRedMs`
  ///     - `p99_latency_ms >= budgets.p99LatencyRedMs`
  ///     - `filtered_p95_latency_ms >= budgets.filteredP95LatencyRedMs`
  ///     - `recall_score < budgets.recallScoreFloorRed`
  ///     - `filtered_recall_score < budgets.filteredRecallFloorRed`
  ///     - `last_rebuild_duration >= budgets.rebuildDurationRed`
  ///     - `memory_pressure_ratio >= budgets.memoryPressureRed`
  ///
  ///   Investigate — incomplete evidence:
  ///     - `build_status != ready`
  ///     - `activeVectors > 0` AND (any of)
  ///         * latency p50/p95/p99 missing
  ///         * `recall_score` missing
  ///         * `timeout_rate` missing
  ///         * `benchmark_timestamp` missing OR older than
  ///           `budgets.benchmarkStaleAfter`
  ///         * filtered-search numbers missing
  ///
  ///   Yellow (planCutover) — any of:
  ///     - `activeVectors >= 5M`
  ///     - `timeout_rate >= budgets.timeoutRateYellow`
  ///     - `p50_latency_ms >= budgets.p50LatencyYellowMs`
  ///     - `p95_latency_ms >= budgets.p95LatencyYellowMs`
  ///     - `p99_latency_ms >= budgets.p99LatencyYellowMs`
  ///     - `filtered_p95_latency_ms >= budgets.filteredP95LatencyYellowMs`
  ///     - `recall_score < budgets.recallScoreFloorYellow`
  ///     - `filtered_recall_score < budgets.filteredRecallFloorYellow`
  ///     - `last_rebuild_duration >= budgets.rebuildDurationYellow`
  ///     - `memory_pressure_ratio >= budgets.memoryPressureYellow`
  ///
  ///   Hold — only when no red, investigate, or yellow trigger fired.
  ///
  /// Order matters: red fires first so a non-empty index with high
  /// p99 latency is `executeCutover`, not `investigate`.
  /// `investigate` then catches incomplete evidence so a
  /// stale/missing benchmark cannot silently pass as green.
  RecommendedAction get recommendedAction {
    final filteredP95 = benchmark.filteredSearchBehavior?.filteredP95LatencyMs;
    final filteredRecall =
        benchmark.filteredSearchBehavior?.filteredRecallScore;

    // ── Red (current state) ─────────────────────────────────────
    if (activeVectors >= kRedActiveVectorThreshold) {
      return RecommendedAction.executeCutover;
    }
    if (growthProjection.crossesProjectionRiskLine) {
      return RecommendedAction.executeCutover;
    }

    // ── Red (operational signals) ───────────────────────────────
    if (benchmark.timeoutRate != null &&
        benchmark.timeoutRate! >= budgets.timeoutRateRed) {
      return RecommendedAction.executeCutover;
    }
    if (benchmark.p50LatencyMs != null &&
        benchmark.p50LatencyMs! >= budgets.p50LatencyRedMs) {
      return RecommendedAction.executeCutover;
    }
    if (benchmark.p95LatencyMs != null &&
        benchmark.p95LatencyMs! >= budgets.p95LatencyRedMs) {
      return RecommendedAction.executeCutover;
    }
    if (benchmark.p99LatencyMs != null &&
        benchmark.p99LatencyMs! >= budgets.p99LatencyRedMs) {
      return RecommendedAction.executeCutover;
    }
    if (filteredP95 != null && filteredP95 >= budgets.filteredP95LatencyRedMs) {
      return RecommendedAction.executeCutover;
    }
    if (benchmark.recallScore != null &&
        benchmark.recallScore! < budgets.recallScoreFloorRed) {
      return RecommendedAction.executeCutover;
    }
    if (filteredRecall != null &&
        filteredRecall < budgets.filteredRecallFloorRed) {
      return RecommendedAction.executeCutover;
    }
    if (lastRebuildDuration != null &&
        lastRebuildDuration! >= budgets.rebuildDurationRed) {
      return RecommendedAction.executeCutover;
    }
    if (memoryPressureRatio != null &&
        memoryPressureRatio! >= budgets.memoryPressureRed) {
      return RecommendedAction.executeCutover;
    }

    // ── Investigate (incomplete evidence) ───────────────────────
    if (buildStatus != BuildStatus.ready) {
      return RecommendedAction.investigate;
    }
    if (activeVectors > 0) {
      if (!benchmark.hasLatencyMetrics) {
        return RecommendedAction.investigate;
      }
      if (benchmark.recallScore == null) {
        return RecommendedAction.investigate;
      }
      if (benchmark.timeoutRate == null) {
        return RecommendedAction.investigate;
      }
      final ts = benchmark.benchmarkTimestamp;
      if (ts == null) {
        return RecommendedAction.investigate;
      }
      final age = evaluationTime.difference(ts);
      if (age >= budgets.benchmarkStaleAfter) {
        return RecommendedAction.investigate;
      }
      final filtered = benchmark.filteredSearchBehavior;
      if (filtered == null || !filtered.hasNumbers) {
        return RecommendedAction.investigate;
      }
    }

    // ── Yellow (current state) ──────────────────────────────────
    if (activeVectors >= kYellowActiveVectorThreshold) {
      return RecommendedAction.planCutover;
    }

    // ── Yellow (operational signals) ────────────────────────────
    if (benchmark.timeoutRate != null &&
        benchmark.timeoutRate! >= budgets.timeoutRateYellow) {
      return RecommendedAction.planCutover;
    }
    if (benchmark.p50LatencyMs != null &&
        benchmark.p50LatencyMs! >= budgets.p50LatencyYellowMs) {
      return RecommendedAction.planCutover;
    }
    if (benchmark.p95LatencyMs != null &&
        benchmark.p95LatencyMs! >= budgets.p95LatencyYellowMs) {
      return RecommendedAction.planCutover;
    }
    if (benchmark.p99LatencyMs != null &&
        benchmark.p99LatencyMs! >= budgets.p99LatencyYellowMs) {
      return RecommendedAction.planCutover;
    }
    if (filteredP95 != null &&
        filteredP95 >= budgets.filteredP95LatencyYellowMs) {
      return RecommendedAction.planCutover;
    }
    if (benchmark.recallScore != null &&
        benchmark.recallScore! < budgets.recallScoreFloorYellow) {
      return RecommendedAction.planCutover;
    }
    if (filteredRecall != null &&
        filteredRecall < budgets.filteredRecallFloorYellow) {
      return RecommendedAction.planCutover;
    }
    if (lastRebuildDuration != null &&
        lastRebuildDuration! >= budgets.rebuildDurationYellow) {
      return RecommendedAction.planCutover;
    }
    if (memoryPressureRatio != null &&
        memoryPressureRatio! >= budgets.memoryPressureYellow) {
      return RecommendedAction.planCutover;
    }

    return RecommendedAction.hold;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'space': space.toJson(),
    'active_vectors': activeVectors,
    'index_type': indexType.sqlName,
    'index_size_bytes': indexSizeBytes,
    'build_status': buildStatus.jsonName,
    'last_build': lastBuild?.toUtc().toIso8601String(),
    'benchmark_timestamp': benchmark.benchmarkTimestamp
        ?.toUtc()
        .toIso8601String(),
    'p50_latency_ms': benchmark.p50LatencyMs,
    'p95_latency_ms': benchmark.p95LatencyMs,
    'p99_latency_ms': benchmark.p99LatencyMs,
    'timeout_rate': benchmark.timeoutRate,
    'recall_score': benchmark.recallScore,
    'filtered_search_behavior': benchmark.filteredSearchBehavior?.toJson(),
    'growth_projection': growthProjection.toJson(),
    'affected_functionality': affectedFunctionality,
    'last_rebuild_duration_seconds': lastRebuildDuration?.inSeconds,
    'memory_pressure_ratio': memoryPressureRatio,
    'evaluation_time': evaluationTime.toUtc().toIso8601String(),
    'budgets': budgets.toJson(),
    'recommended_action': recommendedAction.jsonName,
    'thresholds': <String, Object?>{
      'yellow_active_vector_threshold': kYellowActiveVectorThreshold,
      'red_active_vector_threshold': kRedActiveVectorThreshold,
      'projection_risk_threshold': kProjectionRiskThreshold,
    },
    'posture': <String, Object?>{
      'default_active_index_type': kDefaultActiveIndexType.sqlName,
      'diskann_is_dormant': kDiskannIsDormant,
    },
    if (notes != null) 'notes': notes,
  };
}

/// B42-shaped metric block produced from one snapshot. The three
/// keys mirror the slot reservations in
/// `phase_11A_operations_console_plan.md` line 16.
///
///   * `vector_index_size_per_corpus[corpusId] = indexSizeBytes`
///   * `vector_query_latency_ms[corpusId]     = p50/p95/p99 + timeout_rate`
///   * `vector_recall[corpusId]               = recall_score (+ filtered)`
///
/// One snapshot produces one entry per key. Multi-corpus aggregation
/// is the caller's job — the helper emits per-corpus rows so the
/// 11A.5 surface can render each searchable embedding space
/// independently (per Q20 "triggers fire per-space").
class B42MetricMapping {
  const B42MetricMapping({
    required this.vectorIndexSizePerCorpus,
    required this.vectorQueryLatencyMs,
    required this.vectorRecall,
  });

  final Map<String, Object?> vectorIndexSizePerCorpus;
  final Map<String, Object?> vectorQueryLatencyMs;
  final Map<String, Object?> vectorRecall;

  Map<String, Object?> toJson() => <String, Object?>{
    'vector_index_size_per_corpus': vectorIndexSizePerCorpus,
    'vector_query_latency_ms': vectorQueryLatencyMs,
    'vector_recall': vectorRecall,
  };
}

/// Builds the B42 metric mapping for a list of snapshots. Keys are
/// `corpusId` so multi-corpus operators (future surfaces) can inspect
/// each searchable embedding space independently.
B42MetricMapping mapToB42Metrics(List<VectorIndexHealthSnapshot> snapshots) {
  final size = <String, Object?>{};
  final latency = <String, Object?>{};
  final recall = <String, Object?>{};

  for (final s in snapshots) {
    final corpusId = s.space.corpusId;

    size[corpusId] = <String, Object?>{
      'index_size_bytes': s.indexSizeBytes,
      'active_vectors': s.activeVectors,
      'yellow_threshold': kYellowActiveVectorThreshold,
      'red_threshold': kRedActiveVectorThreshold,
    };

    latency[corpusId] = <String, Object?>{
      'p50_latency_ms': s.benchmark.p50LatencyMs,
      'p95_latency_ms': s.benchmark.p95LatencyMs,
      'p99_latency_ms': s.benchmark.p99LatencyMs,
      'timeout_rate': s.benchmark.timeoutRate,
      'benchmark_timestamp': s.benchmark.benchmarkTimestamp
          ?.toUtc()
          .toIso8601String(),
    };

    recall[corpusId] = <String, Object?>{
      'recall_score': s.benchmark.recallScore,
      'filtered_recall_score':
          s.benchmark.filteredSearchBehavior?.filteredRecallScore,
      'filtered_p95_latency_ms':
          s.benchmark.filteredSearchBehavior?.filteredP95LatencyMs,
      'filter_predicate_summary':
          s.benchmark.filteredSearchBehavior?.filterPredicateSummary,
    };
  }

  return B42MetricMapping(
    vectorIndexSizePerCorpus: size,
    vectorQueryLatencyMs: latency,
    vectorRecall: recall,
  );
}

// ─── Filtered-search benchmark scaffolding ───────────────────────────
//
// The benchmark scaffolding produces an artifact pair the operator can
// later run on staging through the Phase 9 migration channel:
//
//   * <output>/filtered_search_benchmark.sql       — SQL template
//   * <output>/filtered_search_benchmark.json      — envelope JSON
//
// The SQL is wrapped in a leading `RAISE NOTICE 'DRY RUN ONLY ...'`
// + `ROLLBACK` posture. It NEVER mutates production data and never
// references DiskANN. The operator runs it inside an explicit
// transaction on staging when authorized.
//
// The envelope JSON is the same `VectorIndexHealthSnapshot` set the
// helper would otherwise emit, with every benchmark numeric left as a
// placeholder so the operator records the staging numbers under the
// same keys the 11A.5 surface reads.

class FilteredSearchBenchmarkArtifact {
  const FilteredSearchBenchmarkArtifact({
    required this.sql,
    required this.envelopeJson,
  });

  final String sql;
  final String envelopeJson;
}

/// Strict allowlist for the filter `scope` value. Per the
/// `advisor_search_chunks` function in
/// `db/migrations/202604250003_advisor_vector_search.sql`, scope is
/// a short identifier-shaped string (`methodology`, `workflows`,
/// `causal`, etc.), never user-controlled free text. The pattern
/// keeps SQL injection out of the dry-run template by refusing
/// anything that does not look like an identifier.
final RegExp _filterScopePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// Strict allowlist for the optional `restaurant_id` filter. The
/// column is `uuid`; the helper rejects anything that does not match
/// the canonical 8-4-4-4-12 hex shape.
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
  r'-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Sentinel marker emitted as the default value of `:query_embedding`.
/// Reaches the server as a bare identifier `__REPLACE_ME_QUERY_EMBEDDING__`,
/// which Postgres rejects at parse time ("column does not exist"). That
/// is the intended safety stop: an operator who runs the template
/// without binding `:query_embedding` does not silently exercise the
/// zero vector — they get a parse error and stop.
const String _queryEmbeddingSentinel = '__REPLACE_ME_QUERY_EMBEDDING__';

/// Generates a dry-run-safe filtered-search benchmark artifact for
/// the supplied [snapshots]. Output is purely textual; this function
/// performs no I/O.
///
/// Filter inputs are validated against strict allowlists before any
/// string interpolation happens. A `filterScope` that is not an
/// identifier or a `filterRestaurantId` that is not a canonical UUID
/// throws [VectorIndexHealthException]; the SQL template is never
/// emitted with attacker-controlled bytes. This is the slice's
/// dry-run safety invariant: the artifact must not be able to
/// `commit;` even with malicious inputs.
///
/// The SQL template is built for the repo's psql migration channel:
///
///   * Every variable input is a psql variable (`:query_embedding`,
///     `:scope_filter`, `:restaurant_id_filter`, `:max_results`).
///     The template starts with a conditional `\set` defaults block:
///     values passed via `psql -v <name>=<value>` are preserved, and
///     missing values receive the documented defaults.
///   * `:query_embedding` defaults to the bare-identifier sentinel
///     `__REPLACE_ME_QUERY_EMBEDDING__`. If the operator runs the
///     template without binding a real query vector, the sentinel
///     reaches the server as a bare identifier and the parser
///     rejects it ("column does not exist") — that is the intended
///     safety stop. Substituting the helper-generated zero-vector
///     literal allows a syntax-only parse check, but recording
///     benchmark numbers from a zero-vector run is forbidden.
///   * `:scope_filter`, `:restaurant_id_filter`, and `:max_results`
///     default to the helper-validated filter inputs.
///   * Targets the existing HNSW partial index only; never emits
///     `USING DISKANN`.
FilteredSearchBenchmarkArtifact buildFilteredSearchBenchmarkArtifact(
  List<VectorIndexHealthSnapshot> snapshots, {
  String filterScope = 'methodology',
  String? filterRestaurantId,
  int filterMaxResults = 10,
}) {
  if (filterMaxResults <= 0 || filterMaxResults > 100) {
    throw VectorIndexHealthException(
      'filterMaxResults must be in [1, 100] (got $filterMaxResults)',
    );
  }
  if (!_filterScopePattern.hasMatch(filterScope)) {
    throw VectorIndexHealthException(
      'filterScope must match ${_filterScopePattern.pattern} '
      '(got "$filterScope"); strict allowlist refuses SQL-shaped input',
    );
  }
  if (filterRestaurantId != null &&
      !_uuidPattern.hasMatch(filterRestaurantId)) {
    throw VectorIndexHealthException(
      'filterRestaurantId must be a canonical UUID '
      '(got "$filterRestaurantId"); strict allowlist refuses SQL-shaped input',
    );
  }

  // After validation every value is a known-safe shape (identifier
  // scope / canonical UUID / positive int). The values are emitted as
  // conditional psql `\set` defaults (which substitute textually at
  // psql time) and are also recorded in a comment block at the top of
  // the file so an operator can quickly verify which inputs the
  // helper validated. The `\if :{?name}` guards are important: psql
  // processes `-v` before the script, so an unconditional `\set`
  // would overwrite command-line values.

  // psql `\set` quoted-text form: outer quotes belong to the psql
  // lexer, doubled inner quotes become single. So the literal SQL
  // text the operator wants substituted as `'methodology'` is set as
  // `\set scope_filter '''methodology'''`.
  final scopePsqlValue = "'''$filterScope'''";

  // restaurant_id may be NULL or a quoted UUID literal cast to uuid.
  final restaurantPsqlValue = filterRestaurantId == null
      ? 'NULL'
      : "'''$filterRestaurantId''::uuid'";

  final sb = StringBuffer();
  sb.writeln('-- Phase 9.0Σ.j / B47 — filtered-search benchmark template.');
  sb.writeln(
    '-- Generated by tool/vector_index_health/vector_index_health.dart.',
  );
  sb.writeln('-- DRY RUN ONLY. This template:');
  sb.writeln('--   * never connects to a database from this tool;');
  sb.writeln('--   * MUST be run inside an explicit transaction on STAGING;');
  sb.writeln('--   * MUST end with ROLLBACK so no rows are mutated;');
  sb.writeln('--   * MUST NOT be used against Production1 in this slice;');
  sb.writeln('--   * targets the existing HNSW partial index only — DiskANN');
  sb.writeln('--     remains dormant per Q20.');
  sb.writeln('--');
  sb.writeln('-- Run channel — psql:');
  sb.writeln('--');
  sb.writeln('--   Option A. Override every variable on the command line');
  sb.writeln('--   (recommended; nothing about the template needs editing):');
  sb.writeln('--');
  sb.writeln('--     psql \\');
  sb.writeln(
    '--       -v "query_embedding=\'[<float>,...]\'::vector(<dim>)" \\',
  );
  sb.writeln('--       -v "scope_filter=\'<scope>\'" \\');
  sb.writeln(
    '--       -v "restaurant_id_filter=NULL" \\   '
    '# or "\'<uuid>\'::uuid"',
  );
  sb.writeln('--       -v max_results=10 \\');
  sb.writeln('--       -f filtered_search_benchmark.sql');
  sb.writeln('--');
  sb.writeln('--   Option B. Edit the four fallback \\set lines below,');
  sb.writeln('--   then run `psql -f filtered_search_benchmark.sql`.');
  sb.writeln('--');
  sb.writeln('-- Safety stop: `:query_embedding` defaults to the bare');
  sb.writeln('-- identifier `$_queryEmbeddingSentinel`.');
  sb.writeln('-- If the operator runs without binding a real vector, the');
  sb.writeln('-- server rejects the sentinel at parse time. That is the');
  sb.writeln('-- intended dry-run safety stop — do not paper over it.');
  sb.writeln('--');
  sb.writeln('-- Operator step:');
  sb.writeln('--   1. Bind :query_embedding to a real query vector recorded');
  sb.writeln('--      against the same Voyage model. For a syntax-only');
  sb.writeln('--      parse check the operator may bind the zero-vector');
  sb.writeln('--      literal shown beside each step, BUT the resulting');
  sb.writeln('--      numbers MUST NOT be recorded as benchmark evidence.');
  sb.writeln('--   2. Bind :scope_filter and :restaurant_id_filter to the');
  sb.writeln('--      same values used at production callsites.');
  sb.writeln('--   3. Run EXPLAIN ANALYZE under a transaction; record p50,');
  sb.writeln('--      p95, p99, timeout_rate, recall_score (vs held-out');
  sb.writeln('--      eval set), and filtered_search_behavior.');
  sb.writeln('--   4. ROLLBACK.');
  sb.writeln('--   5. Record the numbers in the envelope JSON under the');
  sb.writeln('--      same keys the helper exports.');
  sb.writeln('');
  sb.writeln(
    '-- ── psql variable defaults '
    '─────────────────────────────────',
  );
  sb.writeln('-- These are textual substitutions executed by psql before');
  sb.writeln('-- the statements reach the server. `psql -v <name>=<value>`');
  sb.writeln('-- on the command line is preserved; the fallback `\\set`');
  sb.writeln('-- runs only when the variable is not already defined.');
  _writePsqlDefault(
    sb,
    name: 'query_embedding',
    value: _queryEmbeddingSentinel,
  );
  _writePsqlDefault(sb, name: 'scope_filter', value: scopePsqlValue);
  _writePsqlDefault(
    sb,
    name: 'restaurant_id_filter',
    value: restaurantPsqlValue,
  );
  _writePsqlDefault(sb, name: 'max_results', value: '$filterMaxResults');
  sb.writeln('');
  sb.writeln('-- Validated bind values (recorded for the operator):');
  sb.writeln('--   :scope_filter         = "$filterScope"');
  if (filterRestaurantId != null) {
    sb.writeln('--   :restaurant_id_filter = "$filterRestaurantId"');
  } else {
    sb.writeln('--   :restaurant_id_filter = NULL  (no restaurant scope)');
  }
  sb.writeln('--   :max_results          = $filterMaxResults');
  sb.writeln('');
  sb.writeln('begin;');
  sb.writeln('');
  sb.writeln(
    "do \$\$ begin raise notice 'DRY RUN ONLY — filtered search benchmark"
    " (B47). No production data will be mutated.'; end \$\$;",
  );
  sb.writeln('');

  for (final s in snapshots) {
    final space = s.space;
    sb.writeln(
      '-- ──── corpus: ${space.corpusId} '
      '(${space.providerId}/${space.modelId}/${space.dimension}d) ────',
    );
    sb.writeln(
      '-- Index: ${space.indexName}. Type: ${s.indexType.sqlName}. '
      'Active vectors recorded by helper: ${s.activeVectors}.',
    );
    sb.writeln('');

    sb.writeln(
      '-- 1. Confirm HNSW partial index is the active strategy '
      '(Q20 dormant posture: no alternate index type is created here).',
    );
    sb.writeln(
      "select indexname, indexdef from pg_indexes "
      "where indexname = '${space.indexName}' "
      "and indexdef ilike '%using hnsw%';",
    );
    sb.writeln('');

    sb.writeln(
      '-- 2. Index size on disk (drives vector_index_size_per_corpus).',
    );
    sb.writeln(
      "select pg_relation_size('${space.indexName}'::regclass) "
      'as index_size_bytes;',
    );
    sb.writeln('');

    sb.writeln('-- 3. Filtered EXPLAIN ANALYZE against the partial index. ');
    sb.writeln('--    Bind :query_embedding before running. Zero-vector ');
    sb.writeln('--    parse-check fallback (DO NOT record numbers): ');
    sb.writeln('--    ${_zeroVectorLiteral(space.dimension)}');

    sb.writeln('explain (analyze, buffers, format json)');
    sb.writeln(
      'select ${space.embeddingColumn} <=> :query_embedding as distance',
    );
    sb.writeln('from ${space.table}');
    sb.writeln("where ${space.partialPredicate}");
    sb.writeln('  and scope = :scope_filter');
    sb.writeln(
      '  and (:restaurant_id_filter is null '
      'or restaurant_id = :restaurant_id_filter)',
    );
    sb.writeln('order by ${space.embeddingColumn} <=> :query_embedding');
    sb.writeln('limit :max_results;');
    sb.writeln('');

    sb.writeln(
      '-- 4. Filtered behaviour: same predicates, no vector ordering, '
      'just the predicate cardinality.',
    );
    sb.writeln('select count(*) as filtered_candidate_count');
    sb.writeln('from ${space.table}');
    sb.writeln("where ${space.partialPredicate}");
    sb.writeln('  and scope = :scope_filter');
    sb.writeln(
      '  and (:restaurant_id_filter is null '
      'or restaurant_id = :restaurant_id_filter);',
    );
    sb.writeln('');
  }

  sb.writeln('-- DRY RUN POSTURE: end the transaction WITHOUT committing.');
  sb.writeln('rollback;');

  final envelope = <String, Object?>{
    'record_type': 'vector_index_health_filtered_search_benchmark',
    'preparer_version': 3,
    'apply_mode': 'dry_run_template_only',
    'run_channel': 'psql',
    'targets_index_type': kDefaultActiveIndexType.sqlName,
    'diskann_is_dormant': kDiskannIsDormant,
    'filter_inputs': <String, Object?>{
      'scope': filterScope,
      'restaurant_id': filterRestaurantId,
      'max_results': filterMaxResults,
    },
    'psql_variables': const <String>[
      'query_embedding',
      'scope_filter',
      'restaurant_id_filter',
      'max_results',
    ],
    'psql_invocation_examples': <String>[
      _psqlInvocationExample(
        filterScope: filterScope,
        filterRestaurantId: filterRestaurantId,
        filterMaxResults: filterMaxResults,
      ),
    ],
    'query_embedding_unbound_sentinel': _queryEmbeddingSentinel,
    'snapshots': snapshots.map((s) => s.toJson()).toList(),
    'b42_metric_keys': const <String>[
      'vector_index_size_per_corpus',
      'vector_query_latency_ms',
      'vector_recall',
    ],
    'b42_metrics': mapToB42Metrics(snapshots).toJson(),
    'placeholders_required_before_apply': const <String>[
      'set psql variable :query_embedding via -v or fallback \\set with a recorded query vector (sentinel default fails at parse time)',
      'set :scope_filter and :restaurant_id_filter to production values via -v or fallback \\set',
      'fill p50/p95/p99 latency_ms after EXPLAIN ANALYZE',
      'fill recall_score against the held-out eval set',
      'fill filtered_search_behavior under the same keys',
    ],
    'safety_invariants': const <String>[
      'no live endpoint calls from this helper',
      'no production mutations: SQL ends with ROLLBACK',
      'no default switch from HNSW to DiskANN',
      'filter inputs validated against strict allowlists before SQL emission',
      'executable SELECT/ORDER BY reference :query_embedding bind, not the zero-vector literal',
      ':query_embedding default is a bare-identifier sentinel that fails at server parse time when not overridden',
    ],
  };

  final encoder = const JsonEncoder.withIndent('  ');
  return FilteredSearchBenchmarkArtifact(
    sql: sb.toString(),
    envelopeJson: encoder.convert(envelope),
  );
}

/// Emits a psql conditional default. Command-line `-v name=value`
/// variables are defined before script execution, so the fallback
/// `\set` must only run when `name` is absent.
void _writePsqlDefault(
  StringBuffer sb, {
  required String name,
  required String value,
}) {
  sb.writeln('\\if :{?$name}');
  sb.writeln('\\else');
  sb.writeln('\\set $name $value');
  sb.writeln('\\endif');
}

/// Renders the canonical `psql -v ... -f filtered_search_benchmark.sql`
/// invocation as a single string. Lives in its own helper so the
/// envelope JSON can list it without tripping the
/// `no_adjacent_strings_in_list` lint.
String _psqlInvocationExample({
  required String filterScope,
  required String? filterRestaurantId,
  required int filterMaxResults,
}) {
  final restaurantValue = filterRestaurantId == null
      ? 'NULL'
      : "'$filterRestaurantId'::uuid";
  final buf = StringBuffer('psql ');
  buf.write('-v "query_embedding=\'[0.1,0.2,...]\'::vector(<dim>)" ');
  buf.write('-v "scope_filter=\'$filterScope\'" ');
  buf.write('-v "restaurant_id_filter=$restaurantValue" ');
  buf.write('-v max_results=$filterMaxResults ');
  buf.write('-f filtered_search_benchmark.sql');
  return buf.toString();
}

/// Builds a deterministic zero vector literal of the given dimension
/// so a syntax-only parse check has a copy-paste fallback. This
/// literal appears ONLY inside SQL comments — the executable SELECT
/// and ORDER BY reference the `:query_embedding` bind parameter.
String _zeroVectorLiteral(int dimension) {
  if (dimension <= 0) {
    throw VectorIndexHealthException(
      'dimension must be > 0 to build a vector literal (got $dimension)',
    );
  }
  final inner = List<String>.filled(dimension, '0').join(',');
  return "'[$inner]'::vector($dimension)";
}

/// Library-internal exception type. Keeps the helper free of generic
/// `throw 'msg'` patterns the lint rules call out.
class VectorIndexHealthException implements Exception {
  VectorIndexHealthException(this.message);
  final String message;
  @override
  String toString() => message;
}
