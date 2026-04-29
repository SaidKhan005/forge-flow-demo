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

/// Severity bucket for the B42 `/health` envelope's
/// `rollup_freshness_per_grain` metric. Matches the standard health
/// levels other 9.0Σ surfaces use (e.g. `audit_chain_lag_seconds`,
/// `graph_p95_traversal_latency_ms`) so the 11A operations console
/// can render mixed-severity rows with one rule.
enum RollupFreshnessSeverity {
  /// Worker is keeping up. Used for `succeeded` rows whose age is
  /// below [RollupFreshnessThresholds.warningAgeFor], plus `leased`
  /// rows whose `leased_until` is still in the future (work in
  /// progress is not stale).
  ok,

  /// Worker fell behind or is in a recoverable transitional state:
  /// `stale`, `rebuilding`, `idle`, an expired `leased` row, or a
  /// `succeeded` row whose age has passed [warningAge] but not
  /// [criticalAge].
  degraded,

  /// Worker is broken or invisible: `failed`, missing
  /// `aggregation_state` row, or a `succeeded` row whose age has
  /// passed [criticalAge].
  unhealthy;

  /// Wire literal embedded in the B42 health JSON. Lower-case so it
  /// matches the existing string severities used by other
  /// `/health` metrics.
  String get sqlName {
    switch (this) {
      case RollupFreshnessSeverity.ok:
        return 'ok';
      case RollupFreshnessSeverity.degraded:
        return 'degraded';
      case RollupFreshnessSeverity.unhealthy:
        return 'unhealthy';
    }
  }
}

/// Thresholds the freshness reporter uses to bucket a `succeeded`
/// row by age. Defaults are pinned to the Q3.1 locked cadence and
/// the B38 load-test tripwires so the B42/11A health surface
/// flips to `degraded`/`unhealthy` BEFORE the alarm fires:
///
/// | Path | Q3.1 cadence | B45 warning | B45 critical | B38 alarm |
/// | ---- | ------------ | ----------- | ------------ | --------- |
/// | Hot  | 60 s         | 90 s        | 120 s        | > 120 s   |
/// | Cold | 300 s (5 m)  | 600 s (10 m)| 900 s (15 m) | > 900 s   |
///
/// `warning` lands at ~1.5×–2× the cron cadence — far enough past
/// the expected next-tick to be a real signal, close enough that
/// the operations console paints `degraded` before B38 trips.
/// `critical` matches the B38 tripwire exactly so the dashboard
/// and the alert fire on the same threshold.
///
/// The Q3.7 staleness sweep (`RollupWorker.markStale`) is the
/// SQL-side counterpart and may be configured to a different
/// window — they observe the same row from different angles and
/// either signal can flip a grain to `degraded`.
class RollupFreshnessThresholds {
  const RollupFreshnessThresholds({
    this.hotWarningAge = const Duration(seconds: 90),
    this.hotCriticalAge = const Duration(seconds: 120),
    this.coldWarningAge = const Duration(minutes: 10),
    this.coldCriticalAge = const Duration(minutes: 15),
  });

  /// Runtime sanity check — each warning age must be strictly less
  /// than its matching critical age. The constructor stays `const`
  /// so the worker / reporter can use it as a default-parameter
  /// value, which means we can't `assert` the invariant inside the
  /// initializer list (Duration's comparison operators are not
  /// const-evaluable). Callers that build a non-default
  /// [RollupFreshnessThresholds] should call [validate] in tests
  /// or at startup.
  void validate() {
    if (hotWarningAge >= hotCriticalAge) {
      throw ArgumentError.value(
        hotWarningAge,
        'hotWarningAge',
        'must be strictly less than hotCriticalAge ($hotCriticalAge)',
      );
    }
    if (coldWarningAge >= coldCriticalAge) {
      throw ArgumentError.value(
        coldWarningAge,
        'coldWarningAge',
        'must be strictly less than coldCriticalAge ($coldCriticalAge)',
      );
    }
  }

  final Duration hotWarningAge;
  final Duration hotCriticalAge;
  final Duration coldWarningAge;
  final Duration coldCriticalAge;

  Duration warningAgeFor(RollupGrain grain) =>
      grain.isHotPath ? hotWarningAge : coldWarningAge;

  Duration criticalAgeFor(RollupGrain grain) =>
      grain.isHotPath ? hotCriticalAge : coldCriticalAge;
}

/// Per-grain entry in the [RollupFreshnessReport]. One row per grain
/// in the locked Q3.3 set; a grain whose `aggregation_state` row is
/// missing surfaces as a `'missing'` status with severity
/// [RollupFreshnessSeverity.unhealthy] so the 11A operations console
/// flags the gap instead of silently omitting it.
class RollupGrainFreshness {
  const RollupGrainFreshness({
    required this.grain,
    required this.severity,
    required this.lastRunStatus,
    this.lastRunCompletedAt,
    this.ageSeconds,
    this.attemptCount = 0,
    this.leaseOwner,
    this.leasedUntil,
    this.lastErrorAt,
    this.lastErrorReason,
    this.rebuildInProgress = false,
  });

  final RollupGrain grain;
  final RollupFreshnessSeverity severity;

  /// Verbatim `aggregation_state.last_run_status` value for present
  /// rows, or the synthetic literal `'missing'` when the row is
  /// absent. The literal is intentionally outside the SQL CHECK
  /// constraint set — it can never appear in the database, so the
  /// dashboard can branch on it without ambiguity.
  final String lastRunStatus;

  /// `aggregation_state.last_run_completed_at` — the moment the last
  /// run stamped a completion, REGARDLESS of success or failure
  /// (`recordFailure` writes this column too). The reporter
  /// deliberately surfaces the raw column without renaming it
  /// `last_success_at` so a `failed` row's completion timestamp
  /// is not mistaken for the last good run. Q3.9 "last known good"
  /// data lives on the `rollup_<grain>` rows themselves
  /// (`computed_at` + `freshness_status`); the per-grain
  /// `aggregation_state` row only knows when the worker was last
  /// active.
  ///
  /// Null when the row has never run a batch (e.g. `'idle'`
  /// bootstrap rows or the synthetic `'missing'` entry).
  final DateTime? lastRunCompletedAt;

  /// `(observedAt - lastRunCompletedAt).inSeconds` rounded to a
  /// non-negative integer. Null when [lastRunCompletedAt] is null.
  /// On a `'failed'` row this is the time-since-failure, not
  /// time-since-success — see [lastRunCompletedAt] docs.
  final int? ageSeconds;

  final int attemptCount;
  final String? leaseOwner;
  final DateTime? leasedUntil;
  final DateTime? lastErrorAt;
  final String? lastErrorReason;
  final bool rebuildInProgress;

  /// Render as one entry under
  /// `rollup_freshness_per_grain.grains.<grain>` in the B42 `/health`
  /// envelope. Keys are snake_case to match the existing health-JSON
  /// convention used by `ProxyHealthStatus.toJson()`.
  ///
  /// Note: the JSON key is `last_run_completed_at` (not
  /// `last_success_at`) so consumers cannot read a failure timestamp
  /// as a success timestamp. Branch on `status` to tell the two
  /// apart.
  Map<String, Object?> toHealthJson() => <String, Object?>{
        'severity': severity.sqlName,
        'status': lastRunStatus,
        'last_run_completed_at': lastRunCompletedAt?.toUtc().toIso8601String(),
        'age_seconds': ageSeconds,
        'attempt_count': attemptCount,
        'lease_owner': leaseOwner,
        'leased_until': leasedUntil?.toUtc().toIso8601String(),
        'last_error_at': lastErrorAt?.toUtc().toIso8601String(),
        'last_error_reason': lastErrorReason,
        'rebuild_in_progress': rebuildInProgress,
      };
}

/// Top-level `rollup_freshness_per_grain` payload. Carries one
/// [RollupGrainFreshness] per locked Q3.3 grain plus an aggregate
/// [overallSeverity] worst-case across all grains.
class RollupFreshnessReport {
  const RollupFreshnessReport({
    required this.observedAt,
    required this.entries,
  });

  final DateTime observedAt;
  final List<RollupGrainFreshness> entries;

  /// Worst severity across all entries. The 11A operations console
  /// uses this as the headline color when collapsing the per-grain
  /// list. Order follows the [RollupFreshnessSeverity] enum
  /// declaration: `unhealthy > degraded > ok`.
  RollupFreshnessSeverity get overallSeverity {
    var worst = RollupFreshnessSeverity.ok;
    for (final entry in entries) {
      if (entry.severity.index > worst.index) worst = entry.severity;
    }
    return worst;
  }

  /// Render the full B42 envelope payload. Shape:
  ///
  /// ```json
  /// {
  ///   "severity": "degraded",
  ///   "observed_at": "2026-04-29T10:30:00.000Z",
  ///   "grains": {
  ///     "daypart":      { "severity": "ok", … },
  ///     "business_day": { "severity": "degraded", … },
  ///     …
  ///   }
  /// }
  /// ```
  ///
  /// The route handler embeds this under the
  /// `rollup_freshness_per_grain` key in `/health` JSON. The route
  /// itself is NOT wired in this slice (B42 owns that). The helper
  /// only locks the data shape so B42 can drop it in.
  Map<String, Object?> toHealthJson() {
    final grains = <String, Object?>{
      for (final entry in entries) entry.grain.sqlName: entry.toHealthJson(),
    };
    return <String, Object?>{
      'severity': overallSeverity.sqlName,
      'observed_at': observedAt.toUtc().toIso8601String(),
      'grains': grains,
    };
  }
}
