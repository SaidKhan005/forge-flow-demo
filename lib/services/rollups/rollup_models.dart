// Phase 9.0Σ.k — rollup worker models.
//
// Pure data shapes shared by `rollup_worker.dart` and the matching
// test in `test/phase_9_0sigma_k_rollups_test.dart`. The file is
// intentionally I/O-free and has no `package:postgres` import so it
// can live above the persistence layer (CLAUDE.md: only files under
// `lib/infrastructure/persistence/postgres/` may import the driver).
//
// Source decisions:
//
//   * Q3.3 Locked grain set — `daypart`, `business_day`, `week`,
//     `accounting_period`, `month`, `quarter`, `year`. The
//     [RollupGrain] enum freezes this list; a producer that tries
//     to write to a phantom grain fails at the type system.
//
//   * Q3.6 Idempotency — every UPSERT row carries a deterministic
//     key composed of operator + scope + period + metric_family +
//     dimensions fingerprint. The migration in
//     `db/migrations/202604280010_b_phase_9_0sigma_k_rollup_tables.sql`
//     mirrors the same key shape on the SQL side.
//
//   * Q3.7 Freshness — every row reports a [RollupFreshnessStatus]
//     value. Translation to operator-facing copy ("Updated just
//     now", "Data delayed", …) lives in the dashboard layer; this
//     module only locks the enum.
//
// Worker primitives consume / produce these types. The actual
// vendor → metric aggregation formulas (sales totals, labor %,
// variance dollars) are NOT defined here — they ship in a later
// 7.58 / 9.0Σ.k follow-up that depends on the vendor connector
// payload being final.

/// Locked rollup grain set per Q3.3. Order is intentional: hot
/// grains first, then cold. The Dart name matches the SQL
/// `aggregation_state.grain` literal exactly so the lookup helper
/// `RollupGrain.fromSqlName` is a one-to-one map.
enum RollupGrain {
  daypart,
  businessDay,
  week,
  accountingPeriod,
  month,
  quarter,
  year;

  /// SQL literal used in `aggregation_state.grain` and
  /// `rollup_<grain>` table names. snake_case to match the SQL CHECK
  /// constraint in 202604280010_a.
  String get sqlName {
    switch (this) {
      case RollupGrain.daypart:
        return 'daypart';
      case RollupGrain.businessDay:
        return 'business_day';
      case RollupGrain.week:
        return 'week';
      case RollupGrain.accountingPeriod:
        return 'accounting_period';
      case RollupGrain.month:
        return 'month';
      case RollupGrain.quarter:
        return 'quarter';
      case RollupGrain.year:
        return 'year';
    }
  }

  /// Physical rollup table name in 202604280010_b. Used by the
  /// worker's UPSERT statement composer.
  String get rollupTableName => 'rollup_$sqlName';

  /// Whether this grain is on the 60s hot path or the 300s cold
  /// path per Q3.1. Matches the function bodies in 202604280010_c.
  bool get isHotPath =>
      this == RollupGrain.daypart || this == RollupGrain.businessDay;

  /// Reverse lookup so a value read from `aggregation_state.grain`
  /// (or from a NOTIFY payload) can be turned back into the enum.
  /// Returns null on an unknown literal — the worker treats that
  /// as an unrecoverable error and surfaces the value to Dev/Admin
  /// Health.
  static RollupGrain? fromSqlName(String name) {
    for (final grain in RollupGrain.values) {
      if (grain.sqlName == name) return grain;
    }
    return null;
  }
}

/// Q3.7 + Q3.9 freshness contract. Matches the CHECK constraint on
/// every rollup table in 202604280010_b.
enum RollupFreshnessStatus {
  fresh,
  stale,
  failed,
  lastKnownGood,
  rebuilding;

  String get sqlName {
    switch (this) {
      case RollupFreshnessStatus.fresh:
        return 'fresh';
      case RollupFreshnessStatus.stale:
        return 'stale';
      case RollupFreshnessStatus.failed:
        return 'failed';
      case RollupFreshnessStatus.lastKnownGood:
        return 'last_known_good';
      case RollupFreshnessStatus.rebuilding:
        return 'rebuilding';
    }
  }
}

/// Snapshot of one `aggregation_state` row at the moment the worker
/// claims a batch. Carries the watermark + status the worker uses
/// to decide what window to process.
class AggregationStateSnapshot {
  const AggregationStateSnapshot({
    required this.rollupTable,
    required this.grain,
    required this.lastProcessedSeq,
    required this.lastRunStatus,
    required this.attemptCount,
    this.leaseOwner,
    this.leasedUntil,
  });

  final String rollupTable;
  final RollupGrain grain;
  final int lastProcessedSeq;
  final String lastRunStatus;
  final int attemptCount;
  final String? leaseOwner;
  final DateTime? leasedUntil;
}

/// A bounded batch of work the worker has claimed. The exact set
/// of rows is opaque here — vendor-side aggregation lives in a
/// future slice — but the watermark range that bounds the batch is
/// concrete so the worker's success / failure paths can be tested
/// without a real fact source.
class RollupBatchClaim {
  const RollupBatchClaim({
    required this.state,
    required this.fromSeqExclusive,
    required this.toSeqInclusive,
    required this.maxRows,
  });

  final AggregationStateSnapshot state;

  /// Watermark window. The worker aggregates raw facts whose
  /// sequence is `> fromSeqExclusive` and `<= toSeqInclusive`. The
  /// half-open lower bound matches PostgreSQL's `>` semantics on
  /// the watermark column and keeps re-runs idempotent — re-claiming
  /// the same window writes the same rollup rows because the UPSERT
  /// key is deterministic (Q3.6).
  final int fromSeqExclusive;
  final int toSeqInclusive;

  /// Hard cap on rollup-row UPSERTs per batch. Enforced by the
  /// worker before flushing so a pathological window does not
  /// produce a megabatch. The locked default is conservative; the
  /// runbook documents how to tune it on a long rebuild.
  final int maxRows;
}

/// One rollup row the worker is about to UPSERT. The worker collects
/// these from the (vendor-specific) aggregator and flushes them in
/// one transaction. Keeping the shape concrete here lets the test
/// assert the deterministic-UPSERT-key shape without involving any
/// vendor logic.
class RollupUpsertRow {
  const RollupUpsertRow({
    required this.grain,
    required this.operatorId,
    required this.scopedOrgUnitId,
    this.locationId,
    required this.periodStart,
    required this.periodEnd,
    required this.businessDate,
    required this.metricFamily,
    required this.dimensions,
    required this.metrics,
    required this.sourceWatermarkSeq,
    required this.sourceWatermarkAt,
    required this.ruleVersion,
    this.daypart,
  }) : assert(
          grain != RollupGrain.daypart || daypart != null,
          'daypart grain rows must carry a non-null `daypart` value',
        );

  final RollupGrain grain;
  final String operatorId;
  final String scopedOrgUnitId;
  final String? locationId;
  final DateTime periodStart;
  final DateTime periodEnd;

  /// Local business date computed at write time (Q1 storage rule).
  /// Stored as `YYYY-MM-DD` string here so the worker can hand it
  /// straight to the parameter binder; the SQL column is `DATE`.
  final String businessDate;

  final String metricFamily;
  final Map<String, Object?> dimensions;
  final Map<String, Object?> metrics;
  final int sourceWatermarkSeq;
  final DateTime sourceWatermarkAt;
  final String ruleVersion;

  /// Only set when [grain] is [RollupGrain.daypart]. The assertion
  /// in the constructor rejects `daypart` rows missing this value.
  final String? daypart;
}

/// Outcome of a worker batch. Either advanced the watermark
/// successfully or recorded a failure without advancing.
class RollupBatchResult {
  const RollupBatchResult({
    required this.batch,
    required this.success,
    required this.rowsUpserted,
    this.failureReason,
  })  : assert(
          success || failureReason != null,
          'failure result must carry a non-empty failureReason',
        ),
        assert(
          !success || failureReason == null,
          'success result must NOT carry a failureReason',
        );

  final RollupBatchClaim batch;
  final bool success;
  final int rowsUpserted;
  final String? failureReason;
}
