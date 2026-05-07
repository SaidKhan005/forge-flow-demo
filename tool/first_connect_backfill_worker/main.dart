// Phase 8 gap-2 — first-connect backfill production worker.
//
// Cloud Run-deployable Dart entrypoint that closes the
// "OAuth completes -> empty data forever" gap by draining the
// durable `public.connector_backfill_jobs` queue. Pieces it relies on
// already exist on master:
//
//   * Migration `db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql`
//     creates the queue table + active-row UNIQUE + claim/status indexes
//     + RLS policy.
//   * `tool/integration_sync_worker/backfill_dispatch.dart` is the
//     adapter-aware dispatcher; it owns the claim -> dispatch -> mark
//     succeeded/resumable/failed flow per-job. We compose it; we do
//     NOT re-implement it.
//   * `lib/infrastructure/persistence/postgres/repositories/
//     connector_backfill_job_repository.dart` is the repository the
//     dispatcher's `BackfillJobStore` interface expects.
//
// What this file adds:
//
//   1. Env-driven config (`POSTGRES_URL`, etc.) — name-only logging
//      so secrets never appear in stdout/stderr.
//   2. A `WorkerScopeReader` that discovers `(operator_id, location_id)`
//      pairs with claimable backfill jobs. The repository's `claimNext`
//      requires a tenant context, so the worker must enumerate scopes
//      first via `runAsSystem` (cross-tenant by definition), then drive
//      one tenant-scoped claim per scope. Same shape as
//      `audit_anchor sweep`: enumeration is the seam, per-tenant work
//      stays inside the repository pattern.
//   3. A `RetryCappingBackfillJobStore` that wraps the production
//      [ConnectorBackfillJobStore] and turns the 11th failure into a
//      terminal dead-letter: the queue row stays at the
//      migration-allowed `status='failed'` (the migration's CHECK
//      constraint admits only 'pending'/'running'/'succeeded'/'failed';
//      see DEVIATION note in README.md), `last_error` carries the
//      `dead_lettered:cap_reached` marker, and a single
//      `public.audit_logs` row records the cap. Cap defaults to 10
//      retries (configurable via `MAX_ATTEMPTS`).
//   4. `BackfillWorkerLoop` — the infinite poll loop the Cloud Run
//      service / job runs. SIGTERM stops new claims, lets the
//      currently-claimed job finish, then exits cleanly. The dispatcher
//      already commits per-batch via the canonical sink; if we need to
//      bail mid-job, releasing the row with `releaseForResume` would
//      requeue it (the staleness-based reclaim in
//      `ConnectorBackfillJobRepository.claimNext` already covers crash
//      cases, so SIGTERM mid-claim is best-effort drain).
//
// CLI contract (the production deploy uses `daemon`; tests drive
// `runOnce` directly):
//
//   first_connect_backfill_worker daemon
//     [--max-attempts=N] [--max-jobs-per-tick=N]
//     [--poll-interval-seconds=N] [--claim-stale-seconds=N]
//
//   first_connect_backfill_worker runOnce
//     [--max-attempts=N] [--max-jobs-per-tick=N]
//
// Exit codes (mirrors audit_anchor):
//   * 0 — success (loop exited cleanly via SIGTERM).
//   * 2 — configuration error (missing env, malformed args).
//   * 3 — runtime error (DB unreachable, scope enumeration failed).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../integration_sync_worker/backfill_dispatch.dart';
import '../integration_sync_worker/dispatch.dart' show kSyncWorkerServicePrincipalId;

// Default clock — top-level so it survives in field initializer
// expressions where `() => DateTime.now().toUtc()` would parse as
// the precedence-tangle the analyzer flags.
DateTime _defaultUtcClock() => DateTime.now().toUtc();

// ─── Env names (no values ever logged) ──────────────────────────────

abstract class FirstConnectBackfillWorkerEnvNames {
  static const String postgresUrl = 'POSTGRES_URL';
  static const String pollIntervalSeconds =
      'FIRST_CONNECT_BACKFILL_WORKER_POLL_SECONDS';
  static const String maxJobsPerTick =
      'FIRST_CONNECT_BACKFILL_WORKER_MAX_JOBS_PER_TICK';
  static const String maxAttempts =
      'FIRST_CONNECT_BACKFILL_WORKER_MAX_ATTEMPTS';
  static const String claimStaleSeconds =
      'FIRST_CONNECT_BACKFILL_WORKER_CLAIM_STALE_SECONDS';
  static const String workerIdPrefix =
      'FIRST_CONNECT_BACKFILL_WORKER_ID_PREFIX';
}

// ─── CLI ────────────────────────────────────────────────────────────

enum WorkerMode { daemon, runOnce }

class WorkerCliArgs {
  WorkerCliArgs({
    required this.mode,
    this.maxAttempts,
    this.maxJobsPerTick,
    this.pollIntervalSeconds,
    this.claimStaleSeconds,
  });

  final WorkerMode mode;
  final int? maxAttempts;
  final int? maxJobsPerTick;
  final int? pollIntervalSeconds;
  final int? claimStaleSeconds;
}

class WorkerConfigError implements Exception {
  WorkerConfigError(this.envName);

  final String envName;

  @override
  String toString() =>
      'first_connect_backfill_worker: missing required env name: $envName';
}

WorkerCliArgs parseArgs(List<String> args) {
  if (args.isEmpty) {
    throw const FormatException(
      'usage: first_connect_backfill_worker <daemon|runOnce> '
      '[--max-attempts=N] [--max-jobs-per-tick=N] '
      '[--poll-interval-seconds=N] [--claim-stale-seconds=N]',
    );
  }
  final mode = switch (args.first) {
    'daemon' => WorkerMode.daemon,
    'runOnce' => WorkerMode.runOnce,
    final unknown => throw FormatException(
      'unknown mode "$unknown" (expected daemon|runOnce)',
    ),
  };
  int? maxAttempts;
  int? maxJobsPerTick;
  int? pollIntervalSeconds;
  int? claimStaleSeconds;
  for (final raw in args.skip(1)) {
    if (raw.startsWith('--max-attempts=')) {
      maxAttempts = _parsePositiveInt(
        raw.substring('--max-attempts='.length),
        'max-attempts',
      );
    } else if (raw.startsWith('--max-jobs-per-tick=')) {
      maxJobsPerTick = _parsePositiveInt(
        raw.substring('--max-jobs-per-tick='.length),
        'max-jobs-per-tick',
      );
    } else if (raw.startsWith('--poll-interval-seconds=')) {
      pollIntervalSeconds = _parsePositiveInt(
        raw.substring('--poll-interval-seconds='.length),
        'poll-interval-seconds',
      );
    } else if (raw.startsWith('--claim-stale-seconds=')) {
      claimStaleSeconds = _parsePositiveInt(
        raw.substring('--claim-stale-seconds='.length),
        'claim-stale-seconds',
      );
    } else {
      throw FormatException('unknown flag "$raw"');
    }
  }
  return WorkerCliArgs(
    mode: mode,
    maxAttempts: maxAttempts,
    maxJobsPerTick: maxJobsPerTick,
    pollIntervalSeconds: pollIntervalSeconds,
    claimStaleSeconds: claimStaleSeconds,
  );
}

int _parsePositiveInt(String raw, String label) {
  final n = int.tryParse(raw);
  if (n == null || n <= 0) {
    throw FormatException('--$label expects a positive integer; got "$raw"');
  }
  return n;
}

// ─── Runtime config ─────────────────────────────────────────────────

class WorkerRuntimeConfig {
  WorkerRuntimeConfig({
    required this.postgresUrl,
    required this.maxAttempts,
    required this.maxJobsPerTick,
    required this.pollInterval,
    required this.claimStaleAfter,
    required this.workerIdPrefix,
    required this.loadedSecretNames,
  });

  /// Resolved Postgres connection string. Never echoed.
  final String postgresUrl;
  final int maxAttempts;
  final int maxJobsPerTick;
  final Duration pollInterval;
  final Duration claimStaleAfter;
  final String workerIdPrefix;
  final List<String> loadedSecretNames;

  static const int defaultMaxAttempts = 10;
  static const int defaultMaxJobsPerTick = 5;
  static const Duration defaultPollInterval = Duration(seconds: 30);
  static const Duration defaultClaimStaleAfter =
      ConnectorBackfillJobRepository.defaultClaimStaleAfter;
  static const String defaultWorkerIdPrefix = 'first-connect-backfill';

  static WorkerRuntimeConfig fromEnvironment(
    Map<String, String> env, {
    WorkerCliArgs? cliOverrides,
  }) {
    final loaded = <String>[];
    String require(String name) {
      final value = env[name];
      if (value == null || value.isEmpty) throw WorkerConfigError(name);
      loaded.add(name);
      return value;
    }

    int optionalInt(String name, {required int fallback}) {
      final value = env[name];
      if (value == null || value.isEmpty) return fallback;
      final parsed = int.tryParse(value);
      if (parsed == null || parsed <= 0) {
        // Keep startup deterministic; misconfigured ints should not
        // silently fall back. We surface the env name (no value) and
        // exit via WorkerConfigError so the deploy fails closed.
        throw WorkerConfigError(name);
      }
      loaded.add(name);
      return parsed;
    }

    String optionalString(String name, {required String fallback}) {
      final value = env[name];
      if (value == null || value.isEmpty) return fallback;
      loaded.add(name);
      return value;
    }

    final postgresUrl = require(FirstConnectBackfillWorkerEnvNames.postgresUrl);
    final maxAttempts =
        cliOverrides?.maxAttempts ??
        optionalInt(
          FirstConnectBackfillWorkerEnvNames.maxAttempts,
          fallback: defaultMaxAttempts,
        );
    final maxJobsPerTick =
        cliOverrides?.maxJobsPerTick ??
        optionalInt(
          FirstConnectBackfillWorkerEnvNames.maxJobsPerTick,
          fallback: defaultMaxJobsPerTick,
        );
    final pollSeconds =
        cliOverrides?.pollIntervalSeconds ??
        optionalInt(
          FirstConnectBackfillWorkerEnvNames.pollIntervalSeconds,
          fallback: defaultPollInterval.inSeconds,
        );
    final claimStaleSeconds =
        cliOverrides?.claimStaleSeconds ??
        optionalInt(
          FirstConnectBackfillWorkerEnvNames.claimStaleSeconds,
          fallback: defaultClaimStaleAfter.inSeconds,
        );
    final prefix = optionalString(
      FirstConnectBackfillWorkerEnvNames.workerIdPrefix,
      fallback: defaultWorkerIdPrefix,
    );
    return WorkerRuntimeConfig(
      postgresUrl: postgresUrl,
      maxAttempts: maxAttempts,
      maxJobsPerTick: maxJobsPerTick,
      pollInterval: Duration(seconds: pollSeconds),
      claimStaleAfter: Duration(seconds: claimStaleSeconds),
      workerIdPrefix: prefix,
      loadedSecretNames: loaded,
    );
  }
}

// ─── Scope discovery ────────────────────────────────────────────────

/// One `(operator_id, location_id)` pair the worker should claim
/// against. The repository's `claimNext` method takes a tenant context,
/// so the worker enumerates scopes via `runAsSystem` first, then runs
/// one tenant-scoped claim per scope. The enumeration query reads
/// `connector_backfill_jobs` directly because that is exactly the
/// table whose claimable rows we want to drain — picking up scopes
/// from any other table would risk false negatives (a scope with only
/// new pending jobs but no live `connector_connection`) or false
/// positives.
class WorkerJobScope {
  const WorkerJobScope({required this.operatorId, required this.locationId});

  final String operatorId;
  final String locationId;
}

abstract class WorkerScopeReader {
  /// Returns the scopes that have at least one claimable
  /// (`pending`, or `running`-but-stale) backfill job. Order is stable
  /// (ascending operator_id, then location_id) so the daily Cloud Run
  /// log ordering is reproducible.
  Future<List<WorkerJobScope>> listClaimableScopes({
    required Duration claimStaleAfter,
  });
}

class PostgresWorkerScopeReader implements WorkerScopeReader {
  PostgresWorkerScopeReader({required TenantTransactionWrapper wrapper})
    : _wrapper = wrapper;

  final TenantTransactionWrapper _wrapper;

  @override
  Future<List<WorkerJobScope>> listClaimableScopes({
    required Duration claimStaleAfter,
  }) {
    return _wrapper.runAsSystem<List<WorkerJobScope>>(
      (exec) async {
        final rows = await exec.query(
          'select distinct operator_id::text as operator_id, '
          'location_id::text as location_id '
          'from public.connector_backfill_jobs '
          "where mode = 'first_backfill' "
          "and (status = 'pending' "
          "  or (status = 'running' "
          '    and (claimed_at is null '
          "      or claimed_at < now() - (@stale_seconds * interval '1 second'))"
          '  )'
          ') '
          'order by operator_id, location_id',
          parameters: <String, Object?>{
            'stale_seconds': claimStaleAfter.inSeconds,
          },
        );
        return <WorkerJobScope>[
          for (final row in rows)
            WorkerJobScope(
              operatorId: row['operator_id']! as String,
              locationId: row['location_id']! as String,
            ),
        ];
      },
      reason: 'first_connect_backfill_worker.list_scopes',
    );
  }
}

// ─── Retry-cap + dead-letter store ──────────────────────────────────

/// Wraps the production [ConnectorBackfillJobStore] so the 11th failed
/// attempt becomes terminal: the queue row stays at the
/// migration-allowed `status='failed'`, but `last_error` carries the
/// `dead_lettered:cap_reached:<reason>` marker AND a single audit-log
/// row records the cap. After that, the `connector_backfill_jobs_active_uq`
/// UNIQUE blocks new active rows for the same `(connection, window)`
/// until an explicit operator replay enqueues a fresh row.
///
/// DEVIATION: the prompt asked for `status='dead_lettered'`, but the
/// migration's CHECK constraint admits only
/// `(pending, running, succeeded, failed)` — see
/// `db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql`.
/// Adding a 5th value would touch the migration, which the prompt
/// explicitly forbids. Encoding the dead-letter terminal as
/// `failed + last_error marker + audit row` preserves the queue
/// schema and surfaces the cap in two places (the row and the audit
/// chain).
class RetryCappingBackfillJobStore implements BackfillJobStore {
  RetryCappingBackfillJobStore({
    required this.delegate,
    required this.maxAttempts,
    required this.tenantWrapper,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    DateTime Function()? clock,
  }) : _audit = auditLogsRepository,
       _clock = clock ?? _defaultUtcClock {
    if (maxAttempts <= 0) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be positive');
    }
  }

  final BackfillJobStore delegate;
  final int maxAttempts;
  final TenantTransactionWrapper tenantWrapper;
  final AuditLogsRepository _audit;
  final DateTime Function() _clock;

  /// Marker prefix `last_error` carries when the cap fired. The proxy
  /// status path keys off `'dead_lettered:cap_reached'` so operator-
  /// facing copy can render "max retries exceeded" without scanning
  /// audit_logs.
  static const String deadLetterErrorPrefix = 'dead_lettered:cap_reached';

  static const String deadLetterAuditAction = 'backfill_dead_lettered';

  @override
  Future<FirstConnectionBackfillJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    String? actorUserId,
    Duration claimStaleAfter =
        ConnectorBackfillJobRepository.defaultClaimStaleAfter,
  }) {
    return delegate.claimNext(
      operatorId: operatorId,
      locationId: locationId,
      workerId: workerId,
      actorUserId: actorUserId,
      claimStaleAfter: claimStaleAfter,
    );
  }

  @override
  Future<FirstConnectionBackfillJob?> markSucceeded({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? actorUserId,
  }) {
    return delegate.markSucceeded(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
      actorUserId: actorUserId,
    );
  }

  @override
  Future<FirstConnectionBackfillJob?> releaseForResume({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? errorMessage,
    String? actorUserId,
  }) {
    // Resume path is non-terminal — never trips the cap.
    return delegate.releaseForResume(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
      errorMessage: errorMessage,
      actorUserId: actorUserId,
    );
  }

  @override
  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  }) async {
    final updated = await delegate.markFailed(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      errorMessage: errorMessage,
      actorUserId: actorUserId,
    );
    // `attemptCount` was incremented by `claimNext`'s SQL CTE before
    // `markFailed` ran (see ConnectorBackfillJobRepository.claimNext).
    // The row's count is therefore the count of attempts INCLUDING
    // this just-failed one. Cap fires when count >= maxAttempts.
    if (updated == null) return null;
    if (updated.attemptCount < maxAttempts) return updated;

    // Cap reached. Stamp the dead-letter marker on `last_error` and
    // append a single audit row. We deliberately reuse `markFailed`
    // for the marker write (same RLS-scoped UPDATE the dispatcher
    // just exercised) so callers don't need a fresh privileged path.
    final markerMessage =
        '$deadLetterErrorPrefix:${_truncateForLastError(errorMessage)}';
    final terminal = await delegate.markFailed(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      errorMessage: markerMessage,
      actorUserId: actorUserId,
    );
    await _writeDeadLetterAuditLog(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      vendorId: updated.vendorId,
      category: updated.category,
      attemptCount: updated.attemptCount,
      reason: errorMessage,
      actorUserId: actorUserId,
    );
    return terminal ?? updated;
  }

  Future<void> _writeDeadLetterAuditLog({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String vendorId,
    required IntegrationCategory category,
    required int attemptCount,
    required String reason,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      // Audit row attribution: the worker is a service principal, not
      // a user. The audit_logs CHECK requires `actor_kind = 'service'
      // AND actor_principal_id IS NOT NULL` for service rows, so we
      // pass `actor_user_id = null`; the principal id flows through
      // the audit row below.
      userId: null,
    );
    return tenantWrapper.runInTenantContext(ctx, (exec) async {
      await _audit.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: _clock(),
        actorKind: 'service',
        actorPrincipalId:
            actorUserId == null
                ? 'sp:first_connect_backfill_worker'
                : 'sp:$actorUserId',
        targetKind: 'connector_backfill_job',
        targetId: jobId,
        action: deadLetterAuditAction,
        payload: <String, Object?>{
          'vendor_id': vendorId,
          'category': category.backfillWire,
          'attempt_count': attemptCount,
          'reason': _truncateForLastError(reason),
        },
      );
    });
  }

  /// `last_error` has a 4096-char check constraint on the migration;
  /// the marker prefix + ':' + reason must fit comfortably under.
  static String _truncateForLastError(String reason) {
    const maxLen = 1024;
    return reason.length <= maxLen ? reason : reason.substring(0, maxLen);
  }
}

// ─── Worker-side CanonicalSink ──────────────────────────────────────

/// Vendor-agnostic CanonicalSink the dispatcher's per-job code paths
/// (`advanceWatermark`, `appendSyncLog`, `evaluateDemoFlip`) call into.
/// The per-vendor adapters write their canonical fact rows through
/// THEIR OWN bespoke sinks during `adapter.backfill(command)` —
/// neither the dispatcher nor this worker write fact rows directly,
/// so the `upsertCoverFact` / `upsertLaborPunch` / `upsertReservationFact`
/// methods fail loud here. If a refactor ever calls them from this
/// surface, the failure points at the wrong layer rather than
/// silently no-op'ing.
class WorkerCanonicalSink implements CanonicalSink {
  WorkerCanonicalSink({
    required this.tenantWrapper,
    DateTime Function()? clock,
  }) : _clock = clock ?? _defaultUtcClock;

  final TenantTransactionWrapper tenantWrapper;
  final DateTime Function() _clock;

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) {
    throw StateError(
      'WorkerCanonicalSink.upsertCoverFact called; per-vendor sinks own '
      'canonical fact writes during adapter.backfill — the worker sink '
      'covers only watermark / sync log / demo flip',
    );
  }

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) {
    throw StateError(
      'WorkerCanonicalSink.upsertLaborPunch called; see upsertCoverFact',
    );
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) {
    throw StateError(
      'WorkerCanonicalSink.upsertReservationFact called; see upsertCoverFact',
    );
  }

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return tenantWrapper.runInTenantContext(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_sync_watermark ('
        'operator_id, location_id, connection_id, resource, '
        'last_synced_at, last_modified_seen, cursor_token'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        "'first_backfill', "
        '@last_synced_at::timestamptz, '
        '@last_modified_seen::timestamptz, @cursor_token'
        ') on conflict (connection_id, resource) do update set '
        'last_synced_at = excluded.last_synced_at, '
        'last_modified_seen = excluded.last_modified_seen, '
        'cursor_token = excluded.cursor_token, '
        'updated_at = now()',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'last_synced_at': _clock(),
          'last_modified_seen': lastModifiedSeen.toUtc(),
          'cursor_token': cursorToken,
        },
      );
    });
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return tenantWrapper.runInTenantContext(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'records_count, error_message, payload_preview, occurred_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@event_kind, @records_count, @error_message, '
        '@payload_preview::jsonb, @occurred_at::timestamptz'
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'event_kind': eventKind,
          'records_count': recordsCount,
          'error_message': errorMessage,
          'payload_preview':
              payloadPreview == null ? null : jsonEncode(payloadPreview),
          'occurred_at': _clock(),
        },
      );
    });
  }

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) {
    if (connectionStatus != ConnectionStatus.connected ||
        !firstBackfillCommitted ||
        backfillRecordsWritten < 1) {
      return Future<void>.value();
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return tenantWrapper.runInTenantContext(ctx, (exec) async {
      // Idempotent flip-once: the original `flipped_to_live_at` /
      // `flipped_by_connection_id` are preserved on conflict so a
      // disconnect-and-reconnect pair never resets the demo line.
      await exec.execute(
        'insert into public.demo_mode_states ('
        'operator_id, location_id, category, mode, '
        'flipped_to_live_at, flipped_by_connection_id'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @category, '
        "'live', @flipped_at::timestamptz, @connection_id::uuid"
        ') on conflict (operator_id, location_id, category) do update set '
        "mode = case when public.demo_mode_states.mode = 'live' "
        '  then public.demo_mode_states.mode '
        "  else 'live' end, "
        'flipped_to_live_at = coalesce('
        '  public.demo_mode_states.flipped_to_live_at, '
        '  excluded.flipped_to_live_at), '
        'flipped_by_connection_id = coalesce('
        '  public.demo_mode_states.flipped_by_connection_id, '
        '  excluded.flipped_by_connection_id), '
        'updated_at = now()',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': category.backfillWire,
          'flipped_at': _clock(),
          'connection_id': connectionId,
        },
      );
    });
  }
}

// ─── Adapter factory wiring ─────────────────────────────────────────

/// Resolves the adapter for one claimed job. Production wires this
/// from the per-category registries already used by the proxy and the
/// integration_sync_worker. Tests inject a closure that returns a
/// fixture adapter. The dispatcher type-checks that the returned
/// object matches `job.category`; a misconfigured factory throws.
typedef WorkerBackfillAdapterFactory =
    Object Function(FirstConnectionBackfillJob job);

// ─── One-tick run + main loop ───────────────────────────────────────

class WorkerTickResult {
  const WorkerTickResult({
    required this.scopesEnumerated,
    required this.attempted,
    required this.succeeded,
    required this.resumable,
    required this.failed,
    required this.deadLettered,
  });

  final int scopesEnumerated;
  final int attempted;
  final int succeeded;
  final int resumable;
  final int failed;
  final int deadLettered;

  Map<String, Object?> toLogFields() => <String, Object?>{
    'scopes_enumerated': scopesEnumerated,
    'attempted': attempted,
    'succeeded': succeeded,
    'resumable': resumable,
    'failed': failed,
    'dead_lettered': deadLettered,
  };
}

/// Runs one tick of the worker: enumerate claimable scopes, then per
/// scope, dispatch up to [WorkerRuntimeConfig.maxJobsPerTick] jobs.
/// Returns the tally for log lines / tests.
///
/// The cap-and-dead-letter wrap is applied here (not inside the
/// dispatcher) so the dispatcher itself stays vendor-agnostic and
/// continues to work for non-worker callsites (the harness, future
/// CLIs).
Future<WorkerTickResult> runWorkerTick({
  required WorkerScopeReader scopeReader,
  required BackfillJobStore jobStore,
  required CanonicalSink canonicalSink,
  required WorkerBackfillAdapterFactory adapterFactory,
  required String workerId,
  required int maxJobsPerTick,
  required Duration claimStaleAfter,
  IntegrationSyncWorkerBackfillDispatch dispatcher =
      const IntegrationSyncWorkerBackfillDispatch(),
  bool Function()? shouldStop,
}) async {
  final scopes = await scopeReader.listClaimableScopes(
    claimStaleAfter: claimStaleAfter,
  );
  if (scopes.isEmpty) {
    return const WorkerTickResult(
      scopesEnumerated: 0,
      attempted: 0,
      succeeded: 0,
      resumable: 0,
      failed: 0,
      deadLettered: 0,
    );
  }

  var attempted = 0;
  var succeeded = 0;
  var resumable = 0;
  var failed = 0;
  // Dead-letter count cannot be derived from the dispatcher's
  // BatchDispatchResult (it only knows succeeded/resumable/failed).
  // Tests verify dead-letter via the audit row + last_error marker;
  // production aggregates by querying `audit_logs` directly.
  const deadLettered = 0;

  for (final scope in scopes) {
    if (shouldStop?.call() ?? false) break;
    final batch = await dispatcher.dispatchAvailable(
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      workerId: workerId,
      jobStore: jobStore,
      adapterFactory: adapterFactory,
      canonicalSink: canonicalSink,
      maxJobs: maxJobsPerTick,
      claimStaleAfter: claimStaleAfter,
    );
    attempted += batch.attempted;
    succeeded += batch.succeeded;
    resumable += batch.resumable;
    failed += batch.failed;
  }

  return WorkerTickResult(
    scopesEnumerated: scopes.length,
    attempted: attempted,
    succeeded: succeeded,
    resumable: resumable,
    failed: failed,
    deadLettered: deadLettered,
  );
}

/// Daemon loop. SIGTERM triggers `shouldStop` between ticks AND
/// between scope dispatches; in-flight per-job transactions inside
/// the dispatcher complete or roll back naturally (the postgres
/// driver propagates cancellation). On exit we close the pool.
class BackfillWorkerLoop {
  BackfillWorkerLoop({
    required this.scopeReader,
    required this.jobStore,
    required this.canonicalSink,
    required this.adapterFactory,
    required this.workerId,
    required this.config,
    IntegrationSyncWorkerBackfillDispatch dispatcher =
        const IntegrationSyncWorkerBackfillDispatch(),
    IOSink? out,
    IOSink? err,
  }) : _dispatcher = dispatcher,
       _out = out ?? stdout,
       _err = err ?? stderr;

  final WorkerScopeReader scopeReader;
  final BackfillJobStore jobStore;
  final CanonicalSink canonicalSink;
  final WorkerBackfillAdapterFactory adapterFactory;
  final String workerId;
  final WorkerRuntimeConfig config;
  final IntegrationSyncWorkerBackfillDispatch _dispatcher;
  // ignore: unused_field, close_sinks
  final IOSink _out;
  final IOSink _err;

  bool _stopRequested = false;
  Completer<void>? _stoppedCompleter;

  /// Signal the loop to exit after the current tick finishes its
  /// in-flight per-scope dispatch. Idempotent.
  void requestStop() {
    _stopRequested = true;
  }

  bool get isStopRequested => _stopRequested;

  Future<void> run() async {
    _stoppedCompleter = Completer<void>();
    try {
      while (!_stopRequested) {
        try {
          final result = await runWorkerTick(
            scopeReader: scopeReader,
            jobStore: jobStore,
            canonicalSink: canonicalSink,
            adapterFactory: adapterFactory,
            workerId: workerId,
            maxJobsPerTick: config.maxJobsPerTick,
            claimStaleAfter: config.claimStaleAfter,
            dispatcher: _dispatcher,
            shouldStop: () => _stopRequested,
          );
          _out.writeln(
            'first_connect_backfill_worker tick: ${jsonEncode(result.toLogFields())}',
          );
        } catch (error, stack) {
          // Errors are written to connector_sync_log per-job by the
          // dispatcher; this top-level catch handles only catastrophic
          // failures of the scope-enumeration path. Don't crash the
          // loop — log and sleep before the next tick.
          _err.writeln(
            'first_connect_backfill_worker tick error: $error',
          );
          _err.writeln(stack.toString());
        }
        if (_stopRequested) break;
        await _sleepInterruptible(config.pollInterval);
      }
    } finally {
      _stoppedCompleter!.complete();
    }
  }

  /// Sleep that wakes immediately if `requestStop` fired.
  Future<void> _sleepInterruptible(Duration total) async {
    const tick = Duration(milliseconds: 200);
    var slept = Duration.zero;
    while (slept < total && !_stopRequested) {
      final remaining = total - slept;
      await Future<void>.delayed(remaining < tick ? remaining : tick);
      slept += tick;
    }
  }

  /// Visible for tests: future that completes after `run()` exits.
  Future<void> get stopped =>
      _stoppedCompleter?.future ?? Future<void>.value();
}

// ─── Entry point ────────────────────────────────────────────────────

typedef WorkerPoolFactory = PostgresPool Function(String connectionString);

/// Default pool factory mirrors the audit_anchor pattern.
PostgresPool _defaultPoolFactory(String connectionString) =>
    PackagePostgresPool.fromUrl(connectionString);

/// Bundle returned by [buildWorkerRuntime]. Tests may inject a
/// pre-built [BackfillJobStore] / [CanonicalSink] / [WorkerScopeReader]
/// to avoid touching Postgres.
class WorkerRuntime {
  const WorkerRuntime({
    required this.scopeReader,
    required this.jobStore,
    required this.canonicalSink,
    required this.config,
  });

  final WorkerScopeReader scopeReader;
  final BackfillJobStore jobStore;
  final CanonicalSink canonicalSink;
  final WorkerRuntimeConfig config;
}

WorkerRuntime buildWorkerRuntime({
  required WorkerRuntimeConfig config,
  WorkerPoolFactory poolFactory = _defaultPoolFactory,
}) {
  final pool = poolFactory(config.postgresUrl);
  final wrapper = TenantTransactionWrapper(pool);
  final repository = ConnectorBackfillJobRepository(wrapper);
  final delegate = ConnectorBackfillJobStore(repository);
  final cappingStore = RetryCappingBackfillJobStore(
    delegate: delegate,
    maxAttempts: config.maxAttempts,
    tenantWrapper: wrapper,
  );
  final canonicalSink = WorkerCanonicalSink(tenantWrapper: wrapper);
  final scopeReader = PostgresWorkerScopeReader(wrapper: wrapper);
  return WorkerRuntime(
    scopeReader: scopeReader,
    jobStore: cappingStore,
    canonicalSink: canonicalSink,
    config: config,
  );
}

/// Adapter factory builder. Production wires this from the existing
/// per-category registries — there is no production callsite outside
/// of `proxy_bootstrap.dart` today, so we pass through to a guarded
/// scaffold that fails loud if the worker is deployed without a
/// proper factory wired in. The deploy script comments out a
/// follow-up where the factory wiring lands.
Object _scaffoldRejectingAdapterFactory(FirstConnectionBackfillJob job) {
  throw StateError(
    'WorkerBackfillAdapterFactory not wired: deploy must inject the '
    'production factory composed from the POS / labor / reservation '
    'adapter registries before running. See README.md.',
  );
}

const WorkerBackfillAdapterFactory kScaffoldRejectingAdapterFactory =
    _scaffoldRejectingAdapterFactory;

/// CLI runner. Tests pass overrides; production calls with no
/// overrides.
Future<int> runCli(
  List<String> rawArgs, {
  Map<String, String>? environment,
  WorkerPoolFactory? poolFactory,
  WorkerScopeReader? scopeReaderOverride,
  BackfillJobStore? jobStoreOverride,
  CanonicalSink? canonicalSinkOverride,
  WorkerBackfillAdapterFactory? adapterFactoryOverride,
  IntegrationSyncWorkerBackfillDispatch? dispatcherOverride,
  IOSink? out,
  IOSink? err,
  Future<void> Function(BackfillWorkerLoop loop)? installSignalHandlers,
}) async {
  // ignore: close_sinks - stdout/stderr owned by dart:io.
  final stdoutSink = out ?? stdout;
  // ignore: close_sinks - stdout/stderr owned by dart:io.
  final stderrSink = err ?? stderr;
  final env = environment ?? Platform.environment;

  WorkerCliArgs args;
  try {
    args = parseArgs(rawArgs);
  } on FormatException catch (error) {
    stderrSink.writeln('first_connect_backfill_worker: ${error.message}');
    return 2;
  }

  final hasOverrides =
      scopeReaderOverride != null &&
      jobStoreOverride != null &&
      canonicalSinkOverride != null;

  WorkerRuntimeConfig config;
  WorkerScopeReader scopeReader;
  BackfillJobStore jobStore;
  CanonicalSink canonicalSink;

  if (hasOverrides) {
    // Tests path: skip env config and pool wiring entirely.
    config = WorkerRuntimeConfig(
      postgresUrl: 'test://override',
      maxAttempts: args.maxAttempts ?? WorkerRuntimeConfig.defaultMaxAttempts,
      maxJobsPerTick:
          args.maxJobsPerTick ?? WorkerRuntimeConfig.defaultMaxJobsPerTick,
      pollInterval: Duration(
        seconds:
            args.pollIntervalSeconds ??
            WorkerRuntimeConfig.defaultPollInterval.inSeconds,
      ),
      claimStaleAfter: Duration(
        seconds:
            args.claimStaleSeconds ??
            WorkerRuntimeConfig.defaultClaimStaleAfter.inSeconds,
      ),
      workerIdPrefix: WorkerRuntimeConfig.defaultWorkerIdPrefix,
      loadedSecretNames: const <String>[],
    );
    scopeReader = scopeReaderOverride;
    jobStore = jobStoreOverride;
    canonicalSink = canonicalSinkOverride;
  } else {
    try {
      config = WorkerRuntimeConfig.fromEnvironment(env, cliOverrides: args);
    } on WorkerConfigError catch (error) {
      stderrSink.writeln(error.toString());
      return 2;
    }
    final runtime = buildWorkerRuntime(
      config: config,
      poolFactory: poolFactory ?? _defaultPoolFactory,
    );
    scopeReader = runtime.scopeReader;
    jobStore = runtime.jobStore;
    canonicalSink = runtime.canonicalSink;
    stdoutSink.writeln(
      'first_connect_backfill_worker starting (loaded secret names: '
      '${config.loadedSecretNames.join(', ')})',
    );
  }

  final adapterFactory =
      adapterFactoryOverride ?? kScaffoldRejectingAdapterFactory;
  final workerId =
      '${config.workerIdPrefix}-${pid.toRadixString(16)}-${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(16)}';

  switch (args.mode) {
    case WorkerMode.runOnce:
      try {
        final result = await runWorkerTick(
          scopeReader: scopeReader,
          jobStore: jobStore,
          canonicalSink: canonicalSink,
          adapterFactory: adapterFactory,
          workerId: workerId,
          maxJobsPerTick: config.maxJobsPerTick,
          claimStaleAfter: config.claimStaleAfter,
          dispatcher:
              dispatcherOverride ??
              const IntegrationSyncWorkerBackfillDispatch(),
        );
        stdoutSink.writeln(
          'first_connect_backfill_worker runOnce: '
          '${jsonEncode(result.toLogFields())}',
        );
        return 0;
      } catch (error) {
        stderrSink.writeln(
          'first_connect_backfill_worker runOnce error: $error',
        );
        return 3;
      }
    case WorkerMode.daemon:
      final loop = BackfillWorkerLoop(
        scopeReader: scopeReader,
        jobStore: jobStore,
        canonicalSink: canonicalSink,
        adapterFactory: adapterFactory,
        workerId: workerId,
        config: config,
        dispatcher:
            dispatcherOverride ??
            const IntegrationSyncWorkerBackfillDispatch(),
        out: stdoutSink,
        err: stderrSink,
      );
      if (installSignalHandlers != null) {
        await installSignalHandlers(loop);
      } else {
        _installDefaultSignalHandlers(loop);
      }
      try {
        await loop.run();
        return 0;
      } catch (error) {
        stderrSink.writeln(
          'first_connect_backfill_worker daemon error: $error',
        );
        return 3;
      }
  }
}

void _installDefaultSignalHandlers(BackfillWorkerLoop loop) {
  ProcessSignal.sigterm.watch().listen((_) {
    loop.requestStop();
  });
  ProcessSignal.sigint.watch().listen((_) {
    loop.requestStop();
  });
}

// Service principal id the dispatcher stamps as actor when claiming.
// Re-exported so the deploy script docs can reference the constant
// without pulling integration_sync_worker into the build context.
const String kFirstConnectBackfillWorkerServicePrincipalId =
    kSyncWorkerServicePrincipalId;

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
