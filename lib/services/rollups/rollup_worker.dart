// Phase 9.0Σ.k — rollup worker primitives.
//
// Worker-side counterpart to the SQL functions in
// `db/migrations/202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`.
// The worker:
//
//   1. Calls [claimBatch] to take/refresh the lease on one
//      `(rollup_table, grain)` row in `aggregation_state` and
//      learn the next watermark window.
//   2. Hands the window to the (vendor-specific) aggregator. The
//      aggregator returns a list of [RollupUpsertRow]s; this slice
//      does NOT define the aggregator — that lands in a later
//      7.58 / 9.0Σ.k follow-up after the vendor connector payload
//      shape is final.
//   3. Calls [flushBatch] to UPSERT the rows in one transaction
//      and (on success) advance `aggregation_state.last_processed_seq`
//      to the new high watermark.
//   4. On failure, calls [recordFailure] which leaves the watermark
//      pinned and stamps `last_run_status = 'failed'` so the next
//      poll retries the same window (Q3.6 idempotency + Q3.9 last-
//      known-good behaviour).
//
// The worker is also responsible for [markStale] sweeps run by a
// freshness watcher: when no batch has advanced for a configured
// staleness window the row's `last_run_status` flips to `'stale'`
// and the dashboard renders the "Data delayed" label (Q3.7).
//
// CLAUDE.md repository-pattern bindings:
//   * Goes through the [PostgresExecutor] seam — no direct
//     `package:postgres` import, satisfying the lint that forbids
//     the driver outside `lib/infrastructure/persistence/postgres/`.
//   * `aggregation_state` is internal infrastructure (no
//     operator_id column, not operator-scoped) so the worker runs
//     under `forge_admin` BYPASSRLS via [RollupWorker.runAsSystem]
//     instead of a tenant transaction.
//   * Statement parameters use named bindings (`@name`); never
//     string concatenation.

import 'dart:convert';

import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import 'rollup_models.dart';

/// Hook the worker uses to open a system-scope transaction. The
/// production binding wires this to
/// `OperatorScopedRepository.withSystem(reason: …)`; the tests pass
/// a fake that captures the SQL the worker runs.
typedef RollupSystemRunner = Future<R> Function<R>(
  Future<R> Function(PostgresExecutor exec) body, {
  required String reason,
});

class RollupWorker {
  RollupWorker({
    required RollupSystemRunner runAsSystem,
    required this.workerOwner,
    this.defaultBatchSize = 1000,
    this.defaultLeaseSeconds = 300,
  })  : _runAsSystem = runAsSystem,
        assert(workerOwner.isNotEmpty, 'workerOwner must be non-empty'),
        assert(defaultBatchSize > 0, 'defaultBatchSize must be positive'),
        assert(defaultLeaseSeconds > 0,
            'defaultLeaseSeconds must be positive');

  final RollupSystemRunner _runAsSystem;

  /// Worker identifier stamped into `aggregation_state.lease_owner`
  /// so Dev/Admin Health can see which worker is stuck if a lease
  /// never releases. Convention: `<host>:<pid>` or container id.
  final String workerOwner;

  /// Hard cap on rollup-row UPSERTs per [flushBatch] call. Q3.10
  /// observability rule — a pathological window cannot produce a
  /// megabatch that blocks for minutes.
  final int defaultBatchSize;

  /// Default lease window in seconds. Matches the SQL
  /// `rollup_acquire_lease` default (300s). Phase 9.0Σ.k tune-as-
  /// needed; the runbook documents how to lower it during a
  /// rebuild that wants tighter cancel semantics.
  final int defaultLeaseSeconds;

  /// Take or refresh the lease on one `(rollup_table, grain)` row
  /// in `aggregation_state`. Returns the [AggregationStateSnapshot]
  /// the worker should aggregate against, or `null` when another
  /// worker holds the lease.
  ///
  /// The implementation uses the same `rollup_acquire_lease`
  /// function the cron path uses so cron-driven and worker-driven
  /// lease takes follow identical contention rules.
  Future<AggregationStateSnapshot?> claimBatch({
    required RollupGrain grain,
    int? leaseSeconds,
  }) {
    final leaseS = leaseSeconds ?? defaultLeaseSeconds;
    return _runAsSystem<AggregationStateSnapshot?>(
      (exec) async {
        final acquired = await exec.query(
          'select public.rollup_acquire_lease('
          '@rollup_table, @grain, @lease_owner, @lease_seconds'
          ') as acquired',
          parameters: <String, Object?>{
            'rollup_table': grain.rollupTableName,
            'grain': grain.sqlName,
            'lease_owner': workerOwner,
            'lease_seconds': leaseS,
          },
        );
        if (acquired.isEmpty) return null;
        final acquiredFlag = acquired.single['acquired'];
        if (acquiredFlag != true) return null;

        final stateRows = await exec.query(
          'select rollup_table, grain, last_processed_seq, '
          'last_run_status, attempt_count, lease_owner, leased_until '
          'from public.aggregation_state '
          'where rollup_table = @rollup_table and grain = @grain',
          parameters: <String, Object?>{
            'rollup_table': grain.rollupTableName,
            'grain': grain.sqlName,
          },
        );
        if (stateRows.isEmpty) return null;
        return _projectSnapshot(stateRows.single);
      },
      reason: 'rollups.${grain.sqlName}.claim',
    );
  }

  /// UPSERT the rows in [batch] and advance the watermark to
  /// `batch.toSeqInclusive` on success. The flush runs in one
  /// system transaction so partial UPSERT + watermark mismatch is
  /// impossible; failure rolls everything back and the next poll
  /// retries the same window.
  ///
  /// **Lease-ownership CAS (P1-2 from the Codex review).** The
  /// final UPDATE filters on `lease_owner = @worker_owner`,
  /// `last_processed_seq = @expected_prior_seq`, and
  /// `rebuild_in_progress = false`. If a stale worker (whose lease
  /// expired while it was processing) tries to advance the
  /// watermark after another worker has taken over OR a Q3.8
  /// rebuild has started, the UPDATE matches zero rows and the
  /// method throws [RollupLeaseLostException]. Because the entire
  /// flush is one transaction, the throw rolls back every UPSERT
  /// the stale worker just wrote, so no `rollup_<grain>` rows are
  /// committed under a lease the worker no longer owns.
  ///
  /// Throws an [ArgumentError] if any row's `grain` does not match
  /// `batch.state.grain` — a defense against the aggregator handing
  /// back rows for the wrong table by accident.
  Future<RollupBatchResult> flushBatch({
    required RollupBatchClaim batch,
    required List<RollupUpsertRow> rows,
  }) async {
    if (rows.length > batch.maxRows) {
      throw ArgumentError(
        'rollup flush exceeds maxRows=${batch.maxRows} '
        '(rows=${rows.length}); aggregator must page within the cap',
      );
    }
    for (final row in rows) {
      if (row.grain != batch.state.grain) {
        throw ArgumentError(
          'rollup flush mixed grains: batch.grain=${batch.state.grain}, '
          'row.grain=${row.grain}',
        );
      }
    }

    return _runAsSystem<RollupBatchResult>(
      (exec) async {
        for (final row in rows) {
          await _upsertRow(exec, row);
        }
        final affected = await exec.execute(
          'update public.aggregation_state '
          'set last_processed_seq      = @new_seq, '
          '    last_run_completed_at   = now(), '
          "    last_run_status         = 'succeeded', "
          '    attempt_count           = 0, '
          '    last_error_at           = null, '
          '    last_error              = null, '
          '    lease_owner             = null, '
          '    leased_until            = null, '
          '    updated_at              = now() '
          'where rollup_table = @rollup_table '
          '  and grain = @grain '
          // P1-2 CAS guards: only advance if THIS worker still owns
          // the lease, the watermark has not moved out from under
          // us, and no rebuild has taken over.
          '  and lease_owner = @worker_owner '
          '  and last_processed_seq = @expected_prior_seq '
          '  and rebuild_in_progress = false',
          parameters: <String, Object?>{
            'new_seq': batch.toSeqInclusive,
            'rollup_table': batch.state.rollupTable,
            'grain': batch.state.grain.sqlName,
            'worker_owner': workerOwner,
            'expected_prior_seq': batch.state.lastProcessedSeq,
          },
        );
        if (affected == 0) {
          // Lease lost mid-flight (expired + reclaimed) OR a
          // rebuild took ownership. Throwing here aborts the
          // outer transaction so every UPSERT the worker just
          // wrote rolls back — we do NOT want stale-worker
          // partial state to land under another worker's lease.
          throw RollupLeaseLostException(
            grain: batch.state.grain,
            workerOwner: workerOwner,
            expectedPriorSeq: batch.state.lastProcessedSeq,
          );
        }
        return RollupBatchResult(
          batch: batch,
          success: true,
          rowsUpserted: rows.length,
        );
      },
      reason: 'rollups.${batch.state.grain.sqlName}.flush',
    );
  }

  /// Mark the last attempt as failed. Leaves `last_processed_seq`
  /// pinned at its current value (Q3.6: re-run produces the same
  /// rollup, never advances past a failure) and stamps
  /// `last_run_status = 'failed'` so Dev/Admin Health can render
  /// the failure on the dashboard (Q3.10) and the dashboard can
  /// serve the last known good rollup with a stale-data warning
  /// (Q3.7 / Q3.9).
  ///
  /// **Lease-ownership CAS (P1-2 from the Codex review).** The
  /// UPDATE filters on `lease_owner = @worker_owner` and
  /// `rebuild_in_progress = false`. If a stale worker tries to
  /// record a failure after another worker has taken over the lease
  /// or after a rebuild has started, the UPDATE matches zero rows
  /// and the method throws [RollupLeaseLostException] so the
  /// caller does not log a misleading "we marked the row failed"
  /// message. The expected-prior-seq check is omitted on this path
  /// because failure does not change `last_processed_seq`; the
  /// lease-owner check alone is sufficient to ensure the failure
  /// landed on the correct row.
  Future<RollupBatchResult> recordFailure({
    required RollupBatchClaim batch,
    required String reason,
  }) async {
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(
          reason, 'reason', 'failure reason must be non-empty');
    }
    return _runAsSystem<RollupBatchResult>(
      (exec) async {
        final affected = await exec.execute(
          'update public.aggregation_state '
          'set last_run_completed_at = now(), '
          "    last_run_status       = 'failed', "
          '    attempt_count         = attempt_count + 1, '
          '    last_error_at         = now(), '
          '    last_error            = @reason, '
          '    lease_owner           = null, '
          '    leased_until          = null, '
          '    updated_at            = now() '
          'where rollup_table = @rollup_table '
          '  and grain = @grain '
          '  and lease_owner = @worker_owner '
          '  and rebuild_in_progress = false',
          parameters: <String, Object?>{
            'reason': reason,
            'rollup_table': batch.state.rollupTable,
            'grain': batch.state.grain.sqlName,
            'worker_owner': workerOwner,
          },
        );
        if (affected == 0) {
          throw RollupLeaseLostException(
            grain: batch.state.grain,
            workerOwner: workerOwner,
            expectedPriorSeq: batch.state.lastProcessedSeq,
          );
        }
        return RollupBatchResult(
          batch: batch,
          success: false,
          rowsUpserted: 0,
          failureReason: reason,
        );
      },
      reason: 'rollups.${batch.state.grain.sqlName}.fail',
    );
  }

  /// Flip `last_run_status = 'stale'` for the watermark row of
  /// [grain] when no batch has advanced for [staleAfter]. Q3.7
  /// "Data delayed" label is downstream of this flag. The freshness
  /// sweep is the caller; the worker exposes the primitive so the
  /// sweep can run without depending on the rest of the worker
  /// surface.
  Future<void> markStale({
    required RollupGrain grain,
    required Duration staleAfter,
  }) async {
    if (staleAfter <= Duration.zero) {
      throw ArgumentError.value(
          staleAfter, 'staleAfter', 'must be positive');
    }
    await _runAsSystem<void>(
      (exec) async {
        await exec.execute(
          'update public.aggregation_state '
          "set last_run_status = 'stale', updated_at = now() "
          'where rollup_table = @rollup_table '
          '  and grain = @grain '
          "  and last_run_status not in ('leased', 'rebuilding') "
          "  and updated_at < now() - (@stale_seconds * interval '1 second')",
          parameters: <String, Object?>{
            'rollup_table': grain.rollupTableName,
            'grain': grain.sqlName,
            'stale_seconds': staleAfter.inSeconds,
          },
        );
      },
      reason: 'rollups.${grain.sqlName}.markStale',
    );
  }

  /// Inner helper — issues one deterministic UPSERT against the
  /// matching `rollup_<grain>` table. The conflict target mirrors
  /// the unique index in 202604280010_b (NULLS NOT DISTINCT so a
  /// NULL location_id collapses to one conflict target per other-
  /// key combination — Q3.6 idempotency).
  Future<void> _upsertRow(PostgresExecutor exec, RollupUpsertRow row) async {
    final grain = row.grain;
    final hasDaypart = grain == RollupGrain.daypart;

    // Conflict target columns. Daypart adds the daypart column to
    // the unique index; the SQL ON CONFLICT clause reflects that
    // exactly. Spelling them out in code keeps the worker schema
    // and the migration's unique index in lockstep — a future
    // index-shape change MUST update both sides or this UPSERT
    // throws `there is no unique or exclusion constraint matching
    // the ON CONFLICT specification`.
    final conflictCols = hasDaypart
        ? 'operator_id, scoped_org_unit_id, location_id, '
            'period_start, daypart, metric_family, dimensions_fingerprint'
        : 'operator_id, scoped_org_unit_id, location_id, '
            'period_start, metric_family, dimensions_fingerprint';

    final daypartColumn = hasDaypart ? 'daypart, ' : '';
    final daypartParam = hasDaypart ? '@daypart, ' : '';

    // jsonb columns flow through as serialized strings (matches the
    // event_outbox repository pattern). The SQL casts back via
    // `@dimensions::jsonb` so producers cannot smuggle non-JSON
    // values past the binding.
    final params = <String, Object?>{
      'operator_id': row.operatorId,
      'scoped_org_unit_id': row.scopedOrgUnitId,
      'location_id': row.locationId,
      'period_start': row.periodStart,
      'period_end': row.periodEnd,
      'business_date': row.businessDate,
      'metric_family': row.metricFamily,
      'dimensions': jsonEncode(row.dimensions),
      'metrics': jsonEncode(row.metrics),
      'source_watermark_seq': row.sourceWatermarkSeq,
      'source_watermark_at': row.sourceWatermarkAt,
      'rule_version': row.ruleVersion,
    };
    if (hasDaypart) {
      params['daypart'] = row.daypart;
    }

    await exec.execute(
      'insert into public.${grain.rollupTableName} ('
      '  operator_id, scoped_org_unit_id, location_id, '
      '  period_start, period_end, business_date, '
      '  ${daypartColumn}metric_family, dimensions, metrics, '
      '  source_watermark_seq, source_watermark_at, rule_version, '
      '  computed_at, freshness_status'
      ') values ('
      '  @operator_id::uuid, @scoped_org_unit_id::uuid, @location_id::uuid, '
      '  @period_start, @period_end, @business_date, '
      '  $daypartParam@metric_family, @dimensions::jsonb, @metrics::jsonb, '
      '  @source_watermark_seq, @source_watermark_at, @rule_version, '
      "  now(), 'fresh'"
      ') '
      'on conflict ($conflictCols) do update set '
      '  period_end           = excluded.period_end, '
      '  business_date        = excluded.business_date, '
      '  metrics              = excluded.metrics, '
      '  source_watermark_seq = excluded.source_watermark_seq, '
      '  source_watermark_at  = excluded.source_watermark_at, '
      '  rule_version         = excluded.rule_version, '
      '  computed_at          = now(), '
      "  freshness_status     = 'fresh', "
      '  last_failure_at      = null, '
      '  last_failure_reason  = null',
      parameters: params,
    );
  }

  AggregationStateSnapshot _projectSnapshot(Map<String, Object?> row) {
    final rollupTable = row['rollup_table'];
    final grainName = row['grain'];
    final seq = row['last_processed_seq'];
    final status = row['last_run_status'];
    final attempts = row['attempt_count'];
    final leaseOwner = row['lease_owner'];
    final leasedUntil = row['leased_until'];
    if (rollupTable is! String ||
        grainName is! String ||
        seq is! int ||
        status is! String ||
        attempts is! int) {
      throw StateError(
        'aggregation_state row had an unexpected shape: $row',
      );
    }
    final grain = RollupGrain.fromSqlName(grainName);
    if (grain == null) {
      throw StateError(
        'aggregation_state.grain is outside the locked Q3.3 set: '
        '$grainName',
      );
    }
    return AggregationStateSnapshot(
      rollupTable: rollupTable,
      grain: grain,
      lastProcessedSeq: seq,
      lastRunStatus: status,
      attemptCount: attempts,
      leaseOwner: leaseOwner is String ? leaseOwner : null,
      leasedUntil: leasedUntil is DateTime ? leasedUntil : null,
    );
  }
}

/// Thrown by [RollupWorker.flushBatch] / [RollupWorker.recordFailure]
/// when the CAS-style aggregation_state UPDATE matches zero rows.
/// Two scenarios produce this:
///
///   * the worker's lease expired and another worker reclaimed
///     `(rollup_table, grain)` while it was processing;
///   * a Q3.8 rebuild took ownership of the row mid-flight
///     (`rebuild_in_progress = true`).
///
/// Either way, the worker MUST NOT pretend its write succeeded.
/// Throwing here aborts the outer system transaction so any
/// rollup-row UPSERTs the worker just wrote roll back as well.
/// Callers typically log the loss and exit; the next claim cycle
/// picks up from wherever the row is now.
class RollupLeaseLostException implements Exception {
  RollupLeaseLostException({
    required this.grain,
    required this.workerOwner,
    required this.expectedPriorSeq,
  });

  final RollupGrain grain;
  final String workerOwner;
  final int expectedPriorSeq;

  @override
  String toString() {
    return 'RollupLeaseLostException(grain=${grain.sqlName}, '
        'workerOwner=$workerOwner, expectedPriorSeq=$expectedPriorSeq) — '
        'aggregation_state row was reclaimed by another worker or a '
        'rebuild took ownership';
  }
}

/// Read-only freshness reporter that produces the
/// `rollup_freshness_per_grain` payload the B42 `/health` envelope
/// surfaces and the 11A operations console renders.
///
/// The reporter is a sibling of [RollupWorker] — same
/// [RollupSystemRunner] seam, same `aggregation_state` table — but
/// it never writes. Keeping it on its own class so:
///
///   * The worker stays focused on lease + flush + fail mutations
///     (one mutation primitive per method).
///   * Read-only consumers (the B42 route, an admin CLI, a future
///     dashboard probe) can construct just the reporter without
///     wiring a `workerOwner`.
///
/// The helper translates raw `aggregation_state` rows plus a
/// configurable [RollupFreshnessThresholds] policy into a
/// [RollupFreshnessReport]. The route wiring (which key the report
/// embeds under, how it composes with other `/health` metrics) is
/// owned by B42 and intentionally NOT done here.
class RollupFreshnessReporter {
  RollupFreshnessReporter({
    required RollupSystemRunner runAsSystem,
    this.thresholds = const RollupFreshnessThresholds(),
    DateTime Function()? clock,
  })  : _runAsSystem = runAsSystem,
        _clock = clock ?? _defaultClock;

  final RollupSystemRunner _runAsSystem;
  final RollupFreshnessThresholds thresholds;
  final DateTime Function() _clock;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  /// Build a fresh [RollupFreshnessReport]. One round-trip — a single
  /// SELECT against `aggregation_state`. Missing rows surface as
  /// synthetic `'missing'` entries so the 11A operations console can
  /// flag a grain that has never bootstrapped.
  Future<RollupFreshnessReport> snapshot() {
    return _runAsSystem<RollupFreshnessReport>(
      (exec) async {
        final rows = await exec.query(
          'select rollup_table, grain, last_processed_seq, '
          'last_run_status, last_run_completed_at, last_error_at, '
          'last_error, attempt_count, lease_owner, leased_until, '
          'rebuild_in_progress '
          'from public.aggregation_state',
        );
        return _buildReport(rows);
      },
      reason: 'rollups.freshness',
    );
  }

  /// Pure helper — turns a list of `aggregation_state` rows into a
  /// [RollupFreshnessReport]. Exposed so tests can drive the
  /// severity-bucketing logic without going through a fake runner.
  RollupFreshnessReport buildReportFromRows(List<Map<String, Object?>> rows) {
    return _buildReport(rows);
  }

  RollupFreshnessReport _buildReport(List<Map<String, Object?>> rows) {
    final observedAt = _clock();
    final byGrain = <RollupGrain, RollupGrainFreshness>{};
    for (final row in rows) {
      final entry = _projectEntry(row, observedAt);
      if (entry != null) byGrain[entry.grain] = entry;
    }
    final entries = <RollupGrainFreshness>[
      for (final grain in RollupGrain.values)
        byGrain[grain] ?? _missingEntry(grain),
    ];
    return RollupFreshnessReport(observedAt: observedAt, entries: entries);
  }

  RollupGrainFreshness? _projectEntry(
    Map<String, Object?> row,
    DateTime observedAt,
  ) {
    final grainName = row['grain'];
    if (grainName is! String) return null;
    final grain = RollupGrain.fromSqlName(grainName);
    if (grain == null) return null;

    final status = row['last_run_status'] is String
        ? row['last_run_status'] as String
        : 'idle';
    // `last_run_completed_at` is stamped by BOTH `flushBatch`
    // (success) and `recordFailure` — see Q3.9. We surface it as-is
    // and let the consumer branch on `status` to tell success from
    // failure-completion.
    final lastRunCompletedAt =
        row['last_run_completed_at'] is DateTime
            ? row['last_run_completed_at'] as DateTime
            : null;
    final attemptCount =
        row['attempt_count'] is int ? row['attempt_count'] as int : 0;
    final leaseOwner =
        row['lease_owner'] is String ? row['lease_owner'] as String : null;
    final leasedUntil =
        row['leased_until'] is DateTime ? row['leased_until'] as DateTime : null;
    final lastErrorAt =
        row['last_error_at'] is DateTime ? row['last_error_at'] as DateTime : null;
    final lastError =
        row['last_error'] is String ? row['last_error'] as String : null;
    final rebuildInProgress = row['rebuild_in_progress'] == true;

    final ageSeconds = lastRunCompletedAt == null
        ? null
        : observedAt.difference(lastRunCompletedAt).inSeconds.clamp(0, 1 << 62);

    final severity = _severityFor(
      grain: grain,
      status: status,
      ageSeconds: ageSeconds,
      leasedUntil: leasedUntil,
      observedAt: observedAt,
      rebuildInProgress: rebuildInProgress,
    );

    return RollupGrainFreshness(
      grain: grain,
      severity: severity,
      lastRunStatus: status,
      lastRunCompletedAt: lastRunCompletedAt,
      ageSeconds: ageSeconds,
      attemptCount: attemptCount,
      leaseOwner: leaseOwner,
      leasedUntil: leasedUntil,
      lastErrorAt: lastErrorAt,
      lastErrorReason: lastError,
      rebuildInProgress: rebuildInProgress,
    );
  }

  RollupGrainFreshness _missingEntry(RollupGrain grain) {
    return RollupGrainFreshness(
      grain: grain,
      severity: RollupFreshnessSeverity.unhealthy,
      lastRunStatus: 'missing',
    );
  }

  RollupFreshnessSeverity _severityFor({
    required RollupGrain grain,
    required String status,
    required int? ageSeconds,
    required DateTime? leasedUntil,
    required DateTime observedAt,
    required bool rebuildInProgress,
  }) {
    // Failure dominates everything else — operator must see it red.
    if (status == 'failed') return RollupFreshnessSeverity.unhealthy;

    // Rebuild in progress (either via flag or via status) shows as
    // degraded so the dashboard can render a "Rebuilding…" label.
    if (status == 'rebuilding' || rebuildInProgress) {
      return RollupFreshnessSeverity.degraded;
    }

    // The Q3.7 staleness sweep already flipped this row.
    if (status == 'stale') return RollupFreshnessSeverity.degraded;

    // Bootstrap row that has never run a batch.
    if (status == 'idle') return RollupFreshnessSeverity.degraded;

    // Active processing: a worker holds a non-expired lease. The
    // worker is making progress; a still-valid lease is `ok`.
    // An expired lease (or a leased row whose owner died) downgrades
    // to `degraded` because `rollup_acquire_lease` will need to
    // reclaim it on the next tick.
    if (status == 'leased') {
      if (leasedUntil != null && leasedUntil.isAfter(observedAt)) {
        return RollupFreshnessSeverity.ok;
      }
      return RollupFreshnessSeverity.degraded;
    }

    // 'succeeded' — bucket by age. No success timestamp means the
    // row is in a degenerate state (succeeded without a completion
    // stamp) — treat as degraded so the operator investigates.
    if (status == 'succeeded') {
      if (ageSeconds == null) return RollupFreshnessSeverity.degraded;
      final warning = thresholds.warningAgeFor(grain).inSeconds;
      final critical = thresholds.criticalAgeFor(grain).inSeconds;
      if (ageSeconds >= critical) return RollupFreshnessSeverity.unhealthy;
      if (ageSeconds >= warning) return RollupFreshnessSeverity.degraded;
      return RollupFreshnessSeverity.ok;
    }

    // Unknown status literal — surface as degraded so the operator
    // knows something outside the locked CHECK set landed.
    return RollupFreshnessSeverity.degraded;
  }
}
