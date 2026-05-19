// Canonical fact projection retry worker.
//
// Cloud Run Job entrypoint that closes the durable retry gap: projection
// failures are already recorded in `canonical_fact_projection_retry_jobs`, and
// this worker drains due rows in a bounded batch. It uses a system-scope read
// only to discover operator/location scopes with due jobs; every claim, replay,
// success, failure, and dead-letter update runs through
// CanonicalFactProjectionRetryRepository under tenant context.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/canonical_fact_projection_retry_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_projection_retry.dart';
import 'package:meta/meta.dart';

import '../advisor_proxy/phase_8_projector_wiring.dart';

DateTime _defaultUtcClock() => DateTime.now().toUtc();

abstract class ProjectionRetryWorkerEnvNames {
  static const String postgresUrl = 'POSTGRES_URL';
  static const String maxJobsPerTick =
      'PROJECTION_RETRY_WORKER_MAX_JOBS_PER_TICK';
  static const String pollIntervalSeconds =
      'PROJECTION_RETRY_WORKER_POLL_SECONDS';
  static const String workerIdPrefix = 'PROJECTION_RETRY_WORKER_ID_PREFIX';
}

enum WorkerMode { daemon, runOnce }

class WorkerCliArgs {
  WorkerCliArgs({
    required this.mode,
    this.maxJobsPerTick,
    this.pollIntervalSeconds,
  });

  final WorkerMode mode;
  final int? maxJobsPerTick;
  final int? pollIntervalSeconds;
}

class ProjectionRetryWorkerConfigError implements Exception {
  ProjectionRetryWorkerConfigError(this.message);

  final String message;

  @override
  String toString() => 'projection_retry_worker: $message';
}

WorkerCliArgs parseArgs(List<String> args) {
  if (args.isEmpty) {
    throw const FormatException(
      'usage: projection_retry_worker <daemon|runOnce> '
      '[--max-jobs-per-tick=N] [--poll-interval-seconds=N]',
    );
  }
  final mode = switch (args.first) {
    'daemon' => WorkerMode.daemon,
    'runOnce' => WorkerMode.runOnce,
    final unknown => throw FormatException(
      'unknown mode "$unknown" (expected daemon|runOnce)',
    ),
  };
  int? maxJobsPerTick;
  int? pollIntervalSeconds;
  for (final raw in args.skip(1)) {
    if (raw.startsWith('--max-jobs-per-tick=')) {
      maxJobsPerTick = _parsePositiveInt(
        raw.substring('--max-jobs-per-tick='.length),
        'max-jobs-per-tick',
      );
    } else if (raw.startsWith('--poll-interval-seconds=')) {
      pollIntervalSeconds = _parsePositiveInt(
        raw.substring('--poll-interval-seconds='.length),
        'poll-interval-seconds',
      );
    } else {
      throw FormatException('unknown flag "$raw"');
    }
  }
  return WorkerCliArgs(
    mode: mode,
    maxJobsPerTick: maxJobsPerTick,
    pollIntervalSeconds: pollIntervalSeconds,
  );
}

int _parsePositiveInt(String raw, String name) {
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0) {
    throw FormatException('$name must be a positive integer');
  }
  return parsed;
}

int resolveMaxJobsPerTick({int? cliValue, Map<String, String>? environment}) {
  if (cliValue != null) return cliValue;
  final env = environment ?? Platform.environment;
  return _positiveEnvInt(
    env[ProjectionRetryWorkerEnvNames.maxJobsPerTick],
    fallback: 50,
  );
}

Duration resolvePollInterval({
  int? cliValueSeconds,
  Map<String, String>? environment,
}) {
  if (cliValueSeconds != null) return Duration(seconds: cliValueSeconds);
  final env = environment ?? Platform.environment;
  return Duration(
    seconds: _positiveEnvInt(
      env[ProjectionRetryWorkerEnvNames.pollIntervalSeconds],
      fallback: 300,
    ),
  );
}

String resolveWorkerId({
  Map<String, String>? environment,
  DateTime Function()? clock,
}) {
  final env = environment ?? Platform.environment;
  final prefix =
      env[ProjectionRetryWorkerEnvNames.workerIdPrefix]?.trim().isNotEmpty ==
          true
      ? env[ProjectionRetryWorkerEnvNames.workerIdPrefix]!.trim()
      : 'projection-retry';
  final now = (clock ?? _defaultUtcClock)().toUtc().toIso8601String();
  return '$prefix-$pid-$now';
}

int _positiveEnvInt(String? raw, {required int fallback}) {
  final parsed = int.tryParse(raw?.trim() ?? '');
  return parsed != null && parsed > 0 ? parsed : fallback;
}

class ProjectionRetryScope {
  const ProjectionRetryScope({
    required this.operatorId,
    required this.locationId,
  });

  final String operatorId;
  final String locationId;
}

abstract interface class ProjectionRetryScopeSource {
  Stream<ProjectionRetryScope> dueScopes({
    required int limit,
    Duration claimStaleAfter = const Duration(minutes: 15),
  });
}

class PostgresProjectionRetryScopeSource implements ProjectionRetryScopeSource {
  PostgresProjectionRetryScopeSource(this._tenantWrapper);

  final TenantTransactionWrapper _tenantWrapper;

  @override
  Stream<ProjectionRetryScope> dueScopes({
    required int limit,
    Duration claimStaleAfter = const Duration(minutes: 15),
  }) async* {
    if (limit <= 0) return;
    final rows = await _tenantWrapper.runAsSystem<List<PostgresRow>>((exec) {
      return exec.query(
        'select operator_id::text as operator_id, '
        '       location_id::text as location_id '
        'from public.canonical_fact_projection_retry_jobs '
        'where (status = @pending '
        '   or (status = @running '
        '       and (claimed_at is null '
        "         or claimed_at < now() - (@claim_stale_seconds * interval '1 second'))"
        '      )'
        '  ) '
        '  and next_attempt_at <= now() '
        'group by operator_id, location_id '
        'order by min(next_attempt_at) asc, min(created_at) asc '
        'limit @limit',
        parameters: <String, Object?>{
          'pending': CanonicalFactProjectionRetryStatus.pending.wire,
          'running': CanonicalFactProjectionRetryStatus.running.wire,
          'claim_stale_seconds': claimStaleAfter.inSeconds,
          'limit': limit,
        },
      );
    }, reason: 'projection_retry_worker.due_scope_scan');
    for (final row in rows) {
      yield ProjectionRetryScope(
        operatorId: _requiredString(row, 'operator_id'),
        locationId: _requiredString(row, 'location_id'),
      );
    }
  }
}

class ProjectionRetryWorkerTickResult {
  const ProjectionRetryWorkerTickResult({
    required this.scopesScanned,
    required this.jobsAttempted,
    required this.succeeded,
    required this.failed,
    required this.deadLettered,
    required this.emptyScopes,
  });

  final int scopesScanned;
  final int jobsAttempted;
  final int succeeded;
  final int failed;
  final int deadLettered;
  final int emptyScopes;

  bool get hadFailures => failed > 0 || deadLettered > 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'scopes_scanned': scopesScanned,
    'jobs_attempted': jobsAttempted,
    'succeeded': succeeded,
    'failed': failed,
    'dead_lettered': deadLettered,
    'empty_scopes': emptyScopes,
  };
}

Future<ProjectionRetryWorkerTickResult> runProjectionRetryWorkerTick({
  required ProjectionRetryScopeSource scopeSource,
  required CanonicalFactProjectionRetryDispatcher dispatcher,
  required String workerId,
  required int maxJobsPerTick,
  bool Function()? shouldStop,
}) async {
  if (maxJobsPerTick <= 0) {
    throw ArgumentError.value(
      maxJobsPerTick,
      'maxJobsPerTick',
      'must be positive',
    );
  }
  var scopesScanned = 0;
  var jobsAttempted = 0;
  var succeeded = 0;
  var failed = 0;
  var deadLettered = 0;
  var emptyScopes = 0;

  while (jobsAttempted < maxJobsPerTick && !(shouldStop?.call() ?? false)) {
    var madeProgress = false;
    final remaining = maxJobsPerTick - jobsAttempted;
    await for (final scope in scopeSource.dueScopes(limit: remaining)) {
      if (shouldStop?.call() ?? false) break;
      scopesScanned += 1;
      final result = await dispatcher.dispatchNext(
        operatorId: scope.operatorId,
        locationId: scope.locationId,
        workerId: workerId,
      );
      switch (result.outcome) {
        case CanonicalFactProjectionRetryDispatchOutcome.noJob:
          emptyScopes += 1;
        case CanonicalFactProjectionRetryDispatchOutcome.succeeded:
          jobsAttempted += 1;
          succeeded += 1;
          madeProgress = true;
        case CanonicalFactProjectionRetryDispatchOutcome.failed:
          jobsAttempted += 1;
          failed += 1;
          madeProgress = true;
        case CanonicalFactProjectionRetryDispatchOutcome.deadLettered:
          jobsAttempted += 1;
          deadLettered += 1;
          madeProgress = true;
      }
      if (jobsAttempted >= maxJobsPerTick) break;
    }
    if (!madeProgress) break;
  }

  return ProjectionRetryWorkerTickResult(
    scopesScanned: scopesScanned,
    jobsAttempted: jobsAttempted,
    succeeded: succeeded,
    failed: failed,
    deadLettered: deadLettered,
    emptyScopes: emptyScopes,
  );
}

Future<void> main(List<String> args) async {
  WorkerCliArgs cli;
  try {
    cli = parseArgs(args);
  } on FormatException catch (error) {
    stderr.writeln('projection retry worker startup failed: ${error.message}');
    exitCode = 2;
    return;
  }

  final environment = Platform.environment;
  final postgresUrl = environment[ProjectionRetryWorkerEnvNames.postgresUrl];
  if (postgresUrl == null || postgresUrl.trim().isEmpty) {
    stderr.writeln(
      'projection retry worker startup failed: missing required env name: '
      '${ProjectionRetryWorkerEnvNames.postgresUrl}',
    );
    exitCode = 2;
    return;
  }

  final maxJobsPerTick = resolveMaxJobsPerTick(
    cliValue: cli.maxJobsPerTick,
    environment: environment,
  );
  final workerId = resolveWorkerId(environment: environment);
  final pool = PackagePostgresPool.fromUrl(
    postgresUrl,
    maxConnectionCount: resolvePostgresMaxConnectionsPerPool(
      environment: environment,
    ),
  );
  final tenantWrapper = TenantTransactionWrapper(pool);
  final wiring = buildDefaultPhase8ProjectorWiring(tenantWrapper);
  final projector = wiring.projector;
  if (projector == null) {
    stderr.writeln(
      'projection retry worker startup failed: projector inactive',
    );
    exitCode = 2;
    return;
  }
  final dispatcher = CanonicalFactProjectionRetryDispatcher(
    jobStore: CanonicalFactProjectionRetryRepository(tenantWrapper),
    projector: projector,
  );
  final scopeSource = PostgresProjectionRetryScopeSource(tenantWrapper);
  final shouldStop = _ShutdownFlag();
  final signalSubs = _registerShutdownListeners(shouldStop);

  try {
    if (cli.mode == WorkerMode.runOnce) {
      final result = await runProjectionRetryWorkerTick(
        scopeSource: scopeSource,
        dispatcher: dispatcher,
        workerId: workerId,
        maxJobsPerTick: maxJobsPerTick,
        shouldStop: () => shouldStop.isShuttingDown,
      );
      stdout.writeln(
        'projection retry worker completed: ${jsonEncode(result.toJson())}',
      );
      exitCode = result.deadLettered > 0 ? 1 : 0;
      return;
    }

    final pollInterval = resolvePollInterval(
      cliValueSeconds: cli.pollIntervalSeconds,
      environment: environment,
    );
    while (!shouldStop.isShuttingDown) {
      final result = await runProjectionRetryWorkerTick(
        scopeSource: scopeSource,
        dispatcher: dispatcher,
        workerId: workerId,
        maxJobsPerTick: maxJobsPerTick,
        shouldStop: () => shouldStop.isShuttingDown,
      );
      stdout.writeln(
        'projection retry worker tick: ${jsonEncode(result.toJson())}',
      );
      await Future.any(<Future<void>>[
        Future<void>.delayed(pollInterval),
        shouldStop.future,
      ]);
    }
  } catch (error, stack) {
    stderr.writeln(
      'projection retry worker runtime failed: $error '
      'stack_first_frame=${_firstStackFrame(stack)}',
    );
    exitCode = 3;
  } finally {
    for (final sub in signalSubs) {
      await sub.cancel();
    }
    await pool.closeIdleConnections();
  }
}

class _ShutdownFlag {
  final Completer<void> _completer = Completer<void>();
  bool _shuttingDown = false;

  bool get isShuttingDown => _shuttingDown;
  Future<void> get future => _completer.future;

  void signal() {
    if (_shuttingDown) return;
    _shuttingDown = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}

List<StreamSubscription<ProcessSignal>> _registerShutdownListeners(
  _ShutdownFlag shutdown,
) {
  final subs = <StreamSubscription<ProcessSignal>>[];
  try {
    subs.add(ProcessSignal.sigterm.watch().listen((_) => shutdown.signal()));
  } catch (_) {
    // Windows local runs do not deliver SIGTERM to the Dart isolate.
  }
  try {
    subs.add(ProcessSignal.sigint.watch().listen((_) => shutdown.signal()));
  } catch (_) {
    // Keep startup resilient on stripped hosts.
  }
  return subs;
}

String _requiredString(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw StateError('projection retry scope row missing non-blank $key');
}

@visibleForTesting
String firstStackFrameForProjectionRetryWorker(StackTrace stackTrace) {
  return _firstStackFrame(stackTrace);
}

String _firstStackFrame(StackTrace stackTrace) {
  final text = stackTrace.toString();
  if (text.isEmpty) return '';
  return text.split('\n').first;
}
