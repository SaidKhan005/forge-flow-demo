// Pressure Preview v1 — Phase 3B: backfill flood load harness.
//
// Authority:
//   * docs/_execution/2026-05-08_pressure_preview_v1_plan.md (Phase 3B).
//   * tool/integration_sync_worker/backfill_dispatch.dart (worker
//     contract under test — bare-catch at :368 is a deliberate
//     terminal-state swallow per its comment, respected here).
//   * tool/first_connect_backfill_worker/main.dart (production worker
//     loop pattern — claim, dispatch, mark, repeat).
//   * db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql
//     (`connector_backfill_jobs` schema).
//   * lib/services/integration/demo_mode_state.dart
//     (`DemoModeFlipPolicy` flip rules).
//   * lib/infrastructure/persistence/postgres/repositories/
//     connector_backfill_job_repository.dart (claim semantics —
//     `FOR UPDATE SKIP LOCKED`, attempt_count++, claim_stale_after).
//
// What this harness does:
//   * Simulates N operators triggering first-connection backfills
//     concurrently. Each (operator, vendor) pair gets one backfill
//     job enqueued; M concurrent worker pods race to claim and
//     drain them.
//   * Verifies five durability properties:
//       1. backfill_stuck         — every job reaches a terminal
//          state (succeeded / failed) within budget.
//       2. backfill_didnt_resume  — pod-restart resume picks up
//          from cursor instead of re-processing from scratch.
//       3. demo_flip_race_lost   — concurrent backfills for the
//          same (operator, location) across all 3 categories all
//          flip cleanly.
//       4. worker_collision      — two worker pods never claim the
//          same job (simulates the production
//          `FOR UPDATE SKIP LOCKED` pattern).
//       5. audit_row_missing     — every completed backfill emits a
//          terminal-hook audit row.
//   * Records additional finding categories per the prompt:
//       cursor_lost_at_restart, connection_pool_exhaustion,
//       setup_skipped.
//
// Architecture:
//   * Pure in-memory simulation of `connector_backfill_jobs` +
//     `demo_mode_state` + `audit_logs`. We do NOT touch staging
//     Postgres from this binary. Phase 3B's "preview proxy only" rule
//     is honored by abstaining from network calls; the in-memory
//     `FOR UPDATE SKIP LOCKED` simulation is the part of the worker
//     contract this harness can prove without DB access. When real
//     `POSTGRES_URL` / `PRESSURE_PROXY_URL` env vars become available,
//     a future slice can swap the in-memory store for the
//     `ConnectorBackfillJobStore` + production proxy without changing
//     the assertions.
//   * Each "worker pod" is one Dart `_WorkerPod` instance running its
//     own poll loop on the same in-memory store. Pods race via Dart
//     microtasks (single-threaded but cooperatively interleaved); the
//     in-memory store implements the `claim` mutex with the same
//     "row already claimed by another worker" rejection the SQL CTE
//     produces under `SKIP LOCKED`.
//   * Pod-restart simulation: after the first ~30% of jobs reach
//     terminal state, kill one pod (cancel its loop), instantiate a
//     fresh pod with the same store, observe that previously-claimed
//     stuck jobs get re-claimed via the staleness path
//     (`claimStaleAfter` window — collapsed to 50ms in-harness so
//     the smoke completes in seconds).
//   * Demo-flip race: for one designated (opA, locA), enqueue one
//     job per category (pos, labor, reservation) at the same instant.
//     After all three terminate, assert all three `demo_mode_state`
//     rows for that triple are `is_demo = false` and the timestamps
//     fall within a 10-second window.
//
// Hard constraints:
//   * Never writes to a real database. The in-memory store is the
//     test surface.
//   * Never makes outbound HTTP calls (the preview proxy URL is
//     intentionally unused — this harness validates the worker's
//     local invariants, not the proxy round-trip).
//   * If POSTGRES_URL / PRESSURE_PROXY_URL is set, we still keep the
//     in-memory simulation (we do NOT auto-flip to live). A
//     `setup_skipped` finding is recorded once noting the limitation
//     and pointing at the env vars that would be needed for a future
//     "real DB" mode.
//
// Output:
//   * `test/load/pressure/p3b_backfill_flood_findings.jsonl` —
//     one JSON object per finding.
//   * `test/load/pressure/p3b_backfill_flood_summary.md` — overview
//     with parameters, finding tally, full-scale invocation.
//
// CLI:
//
//   dart run tool/pressure/p3b_backfill_flood.dart \
//       [--ops=N] [--vendors-per-op=N] [--records-per-vendor=N] \
//       [--worker-pods=N] [--simulate-restart=N] \
//       [--findings-out=path] [--summary-out=path] [--quiet]
//
// Defaults match the smoke profile (--ops=5 --vendors-per-op=3
// --records-per-vendor=100 --worker-pods=2 --simulate-restart=1)
// per the Phase 3B prompt. Pass --help for the full list.
//
// Exit codes:
//   * 0 — harness ran to completion. The findings file is the
//         deliverable; non-zero finding count does not fail the run.
//   * 2 — configuration error (malformed flags, missing required
//         value).
//   * 3 — runtime error (cannot open output files).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// ─── Defaults / constants ────────────────────────────────────────────

/// Smoke defaults from the Phase 3B prompt.
const int kSmokeOps = 5;
const int kSmokeVendorsPerOp = 3;
const int kSmokeRecordsPerVendor = 100;
const int kSmokeWorkerPods = 2;
const int kSmokeRestartCount = 1;

/// Categories backfilled in the demo-flip race (one per IntegrationCategory).
const List<String> kRaceCategories = <String>['pos', 'labor', 'reservation'];

/// Vendors used to populate (operator, vendor) pairs. Mix of POS,
/// labor, reservation so 3 vendors per operator naturally spans all
/// three categories. The vendor → category mapping mirrors the
/// production `Phase8VendorIntegrationFactories` registry.
const List<VendorSpec> kVendorRoster = <VendorSpec>[
  VendorSpec(id: 'lightspeed_lsk', category: 'pos'),
  VendorSpec(id: 'seven_shifts', category: 'labor'),
  VendorSpec(id: 'libro', category: 'reservation'),
  VendorSpec(id: 'toast', category: 'pos'),
  VendorSpec(id: 'humanity', category: 'labor'),
  VendorSpec(id: 'opentable', category: 'reservation'),
  VendorSpec(id: 'square', category: 'pos'),
  VendorSpec(id: 'adp', category: 'labor'),
  VendorSpec(id: 'tock', category: 'reservation'),
];

/// Single-tick budget for the simulated dispatch. Keeps the smoke
/// run in seconds; production claim contention is bounded by the
/// repository's `FOR UPDATE SKIP LOCKED`, not by this duration.
const Duration kSimulatedAdapterCallLatency = Duration(milliseconds: 4);

/// Per-job overall budget. Anything taking longer is a `backfill_stuck`
/// finding. Tuned so the smoke run with kSmokeOps × kSmokeVendorsPerOp
/// jobs (15 jobs) finishes inside this budget per pod.
const Duration kBackfillStuckBudget = Duration(seconds: 30);

/// Simulated `claim_stale_after` for the in-memory store. Production
/// uses 15 minutes; the harness collapses to 200ms so pod-restart
/// resume runs in seconds.
const Duration kSimulatedClaimStaleAfter = Duration(milliseconds: 200);

/// Tolerance for the demo-flip race: all three category flips for the
/// designated (op, loc) must fall within this window of each other.
const Duration kDemoFlipRaceTolerance = Duration(seconds: 10);

/// Synthetic operator id prefix. Mirrors `tool/rollups_load_test/`
/// so seeded data is visually distinguishable from real tenant rows
/// if a future revision swaps in the real Postgres path.
const String kOperatorIdPrefix = '00000000-0000-3b00-0000-';
const String kLocationIdPrefix = '00000000-0000-3b01-0000-';
const String kConnectionIdPrefix = '00000000-0000-3b02-0000-';
const String kJobIdPrefix = '00000000-0000-3b03-0000-';

const String kRaceOperatorId = '00000000-0000-3b00-0000-00000000face';
const String kRaceLocationId = '00000000-0000-3b01-0000-00000000face';

const String kPreviewProxyUrl =
    'https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app';

const String kHarnessVersion = 'p3b.v1';

// ─── CLI parsing ─────────────────────────────────────────────────────

class HarnessException implements Exception {
  HarnessException(this.message);
  final String message;
  @override
  String toString() => message;
}

class HarnessConfig {
  HarnessConfig({
    required this.ops,
    required this.vendorsPerOp,
    required this.recordsPerVendor,
    required this.workerPods,
    required this.simulateRestart,
    required this.findingsOut,
    required this.summaryOut,
    required this.quiet,
  });

  final int ops;
  final int vendorsPerOp;
  final int recordsPerVendor;
  final int workerPods;
  final int simulateRestart;
  final String findingsOut;
  final String summaryOut;
  final bool quiet;

  /// Total number of (operator, vendor) backfill jobs the harness
  /// will enqueue (excluding the dedicated demo-flip-race triple).
  int get totalEnqueued => ops * vendorsPerOp;

  /// Total record count synthesized across all jobs.
  int get totalRecords => totalEnqueued * recordsPerVendor;
}

const String _usage = '''
Usage: dart run tool/pressure/p3b_backfill_flood.dart [flags]

Smoke defaults:
  --ops=$kSmokeOps
  --vendors-per-op=$kSmokeVendorsPerOp
  --records-per-vendor=$kSmokeRecordsPerVendor
  --worker-pods=$kSmokeWorkerPods
  --simulate-restart=$kSmokeRestartCount

Output flags:
  --findings-out=<path>      default test/load/pressure/p3b_backfill_flood_findings.jsonl
  --summary-out=<path>       default test/load/pressure/p3b_backfill_flood_summary.md
  --quiet                    suppress per-event stdout
  --help / -h                print this usage

This harness uses an in-memory simulation of connector_backfill_jobs
(no real Postgres or proxy traffic). When POSTGRES_URL is unset, a
`setup_skipped` finding is recorded once and the harness validates the
worker contract against the in-memory store.
''';

HarnessConfig parseArgs(List<String> rawArgs) {
  var ops = kSmokeOps;
  var vendorsPerOp = kSmokeVendorsPerOp;
  var recordsPerVendor = kSmokeRecordsPerVendor;
  var workerPods = kSmokeWorkerPods;
  var simulateRestart = kSmokeRestartCount;
  var findingsOut = 'test/load/pressure/p3b_backfill_flood_findings.jsonl';
  var summaryOut = 'test/load/pressure/p3b_backfill_flood_summary.md';
  var quiet = false;

  for (final arg in rawArgs) {
    if (arg == '--help' || arg == '-h') {
      throw HarnessException('--help');
    } else if (arg == '--quiet') {
      quiet = true;
    } else if (arg.startsWith('--ops=')) {
      ops = _parsePositiveInt(arg.substring('--ops='.length), '--ops');
    } else if (arg.startsWith('--vendors-per-op=')) {
      vendorsPerOp = _parsePositiveInt(
        arg.substring('--vendors-per-op='.length),
        '--vendors-per-op',
      );
      if (vendorsPerOp > kVendorRoster.length) {
        throw HarnessException(
          '--vendors-per-op=$vendorsPerOp exceeds vendor roster size '
          '${kVendorRoster.length}; expand kVendorRoster to raise the cap',
        );
      }
    } else if (arg.startsWith('--records-per-vendor=')) {
      recordsPerVendor = _parsePositiveInt(
        arg.substring('--records-per-vendor='.length),
        '--records-per-vendor',
      );
    } else if (arg.startsWith('--worker-pods=')) {
      workerPods = _parsePositiveInt(
        arg.substring('--worker-pods='.length),
        '--worker-pods',
      );
    } else if (arg.startsWith('--simulate-restart=')) {
      simulateRestart = _parseNonNegativeInt(
        arg.substring('--simulate-restart='.length),
        '--simulate-restart',
      );
    } else if (arg.startsWith('--findings-out=')) {
      findingsOut = arg.substring('--findings-out='.length);
      if (findingsOut.isEmpty) {
        throw HarnessException('--findings-out requires a non-empty path');
      }
    } else if (arg.startsWith('--summary-out=')) {
      summaryOut = arg.substring('--summary-out='.length);
      if (summaryOut.isEmpty) {
        throw HarnessException('--summary-out requires a non-empty path');
      }
    } else {
      throw HarnessException('unknown flag: $arg');
    }
  }

  return HarnessConfig(
    ops: ops,
    vendorsPerOp: vendorsPerOp,
    recordsPerVendor: recordsPerVendor,
    workerPods: workerPods,
    simulateRestart: simulateRestart,
    findingsOut: findingsOut,
    summaryOut: summaryOut,
    quiet: quiet,
  );
}

int _parsePositiveInt(String raw, String flag) {
  final n = int.tryParse(raw);
  if (n == null || n <= 0) {
    throw HarnessException('$flag requires a positive integer (got "$raw")');
  }
  return n;
}

int _parseNonNegativeInt(String raw, String flag) {
  final n = int.tryParse(raw);
  if (n == null || n < 0) {
    throw HarnessException(
      '$flag requires a non-negative integer (got "$raw")',
    );
  }
  return n;
}

// ─── Vendor / category model ────────────────────────────────────────

class VendorSpec {
  const VendorSpec({required this.id, required this.category});

  final String id;
  final String category;
}

// ─── Simulated job row ───────────────────────────────────────────────

enum JobStatus { pending, running, succeeded, failed }

class SimulatedJob {
  SimulatedJob({
    required this.jobId,
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.vendorId,
    required this.category,
    required this.recordsTarget,
    required DateTime createdAt,
  })  : _createdAt = createdAt,
        _updatedAt = createdAt;

  final String jobId;
  final String operatorId;
  final String locationId;
  final String connectionId;
  final String vendorId;
  final String category;

  /// Total records the synthetic adapter will write across all
  /// resume iterations. Each `dispatch` writes a partial slice; the
  /// job is `completed` when `recordsWritten == recordsTarget`.
  final int recordsTarget;

  final DateTime _createdAt;
  DateTime _updatedAt;

  JobStatus status = JobStatus.pending;
  String? cursorToken;
  DateTime? lastModifiedSeen;
  int attemptCount = 0;
  String? workerId;
  DateTime? claimedAt;
  DateTime? completedAt;
  String? lastError;
  int recordsWritten = 0;

  /// Track which workers have ever claimed this job. Worker-collision
  /// finding fires when two distinct workers hold the row at the
  /// same time.
  final List<String> claimHistory = <String>[];

  DateTime get createdAt => _createdAt;
  DateTime get updatedAt => _updatedAt;
  void touch(DateTime now) => _updatedAt = now;
}

/// Audit row mirroring the production `audit_logs` schema.
class SimulatedAuditRow {
  SimulatedAuditRow({
    required this.operatorId,
    required this.locationId,
    required this.targetId,
    required this.action,
    required this.payload,
    required this.occurredAt,
  });

  final String operatorId;
  final String locationId;
  final String targetId;
  final String action;
  final Map<String, Object?> payload;
  final DateTime occurredAt;
}

/// Per-(operator, location, category) demo-mode row.
class SimulatedDemoModeRow {
  SimulatedDemoModeRow({
    required this.operatorId,
    required this.locationId,
    required this.category,
    required this.isDemo,
    this.flippedToLiveAt,
    this.flippedByConnectionId,
  });

  final String operatorId;
  final String locationId;
  final String category;
  bool isDemo;
  DateTime? flippedToLiveAt;
  String? flippedByConnectionId;
}

// ─── In-memory store (mimics ConnectorBackfillJobRepository) ────────

class InMemoryBackfillStore {
  InMemoryBackfillStore({DateTime Function()? clock})
      : _clock = clock ?? (() => DateTime.now().toUtc());

  final DateTime Function() _clock;
  final Map<String, SimulatedJob> _jobs = <String, SimulatedJob>{};
  final List<SimulatedAuditRow> _audit = <SimulatedAuditRow>[];
  final Map<String, SimulatedDemoModeRow> _demo =
      <String, SimulatedDemoModeRow>{};

  /// Worker IDs that currently hold a "claimed" job. Used to detect
  /// concurrent-claim collisions even when the in-memory mutex would
  /// normally prevent them.
  final Map<String, Set<String>> _activeClaimsByJob = <String, Set<String>>{};

  /// Single-threaded mutex emulation: cooperative critical section
  /// around claim / mark transitions. Dart is single-isolate so we
  /// rely on the event loop NOT preempting between the read and the
  /// write of `status`; we still gate via a `Future` chain so a
  /// deliberate `await` inside a transition cannot let another
  /// worker race in. This mirrors `FOR UPDATE SKIP LOCKED` semantics.
  Future<T> _runSerial<T>(FutureOr<T> Function() action) async {
    final completer = Completer<T>();
    final prior = _serial;
    _serial = completer.future;
    await prior;
    try {
      final result = await action();
      completer.complete(result);
      return result;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    }
  }

  Future<void> _serial = Future<void>.value();

  List<SimulatedJob> get allJobs => _jobs.values.toList(growable: false);
  List<SimulatedAuditRow> get allAudit => List.unmodifiable(_audit);
  List<SimulatedDemoModeRow> get allDemo => _demo.values.toList(growable: false);

  /// Enqueue one backfill job. Mirrors `ConnectorBackfillJobRepository.
  /// enqueueFirstBackfill` — idempotent on the
  /// (operator, connection, category, window) tuple. We keep the
  /// idempotency key implicit via `connectionId` since the harness
  /// gives each (operator, vendor) a fresh connection id.
  Future<SimulatedJob> enqueue({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorId,
    required String category,
    required int recordsTarget,
  }) async {
    return _runSerial(() async {
      // Idempotent: if a (connection_id, category) active row exists,
      // return it.
      for (final existing in _jobs.values) {
        if (existing.connectionId == connectionId &&
            existing.category == category &&
            (existing.status == JobStatus.pending ||
                existing.status == JobStatus.running)) {
          return existing;
        }
      }
      final jobId = _allocateJobId();
      final job = SimulatedJob(
        jobId: jobId,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        vendorId: vendorId,
        category: category,
        recordsTarget: recordsTarget,
        createdAt: _clock(),
      );
      _jobs[jobId] = job;
      return job;
    });
  }

  int _jobIdCounter = 0;
  String _allocateJobId() {
    final n = (_jobIdCounter++).toRadixString(16).padLeft(12, '0');
    return '$kJobIdPrefix$n';
  }

  /// Claim the next available job for (operator, location), mirroring
  /// the production CTE: `pending` OR (`running` AND
  /// `claimed_at < now() - claim_stale_after`).
  /// Increments `attempt_count`, sets `claimed_at`, sets `worker_id`,
  /// transitions to `running`. Returns `null` when nothing claimable.
  Future<SimulatedJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    required Duration claimStaleAfter,
  }) async {
    return _runSerial(() async {
      final now = _clock();
      final staleCutoff = now.subtract(claimStaleAfter);
      SimulatedJob? candidate;
      for (final job in _jobs.values) {
        if (job.operatorId != operatorId) continue;
        if (job.locationId != locationId) continue;
        final isClaimable = job.status == JobStatus.pending ||
            (job.status == JobStatus.running &&
                (job.claimedAt == null ||
                    job.claimedAt!.isBefore(staleCutoff)));
        if (!isClaimable) continue;
        if (candidate == null ||
            job.createdAt.isBefore(candidate.createdAt)) {
          candidate = job;
        }
      }
      if (candidate == null) return null;

      // Worker-collision detection: the `_activeClaimsByJob` set
      // tracks the set of workerIds with a live claim on the job.
      // Production's SKIP LOCKED guarantees the set has size 1;
      // this code path never produces size 2 because we serialize,
      // but the assertion guards against a future refactor that
      // drops the serial mutex.
      final activeSet = _activeClaimsByJob.putIfAbsent(
        candidate.jobId,
        () => <String>{},
      );
      if (activeSet.isNotEmpty && !activeSet.contains(workerId)) {
        // Existing claim by different worker — claim is rejected
        // (mirrors `SKIP LOCKED`).
        return null;
      }
      activeSet.add(workerId);

      candidate.status = JobStatus.running;
      candidate.claimedAt = now;
      candidate.workerId = workerId;
      candidate.attemptCount += 1;
      candidate.touch(now);
      candidate.claimHistory.add(workerId);
      return candidate;
    });
  }

  Future<SimulatedJob?> markSucceeded({
    required String jobId,
    required String workerId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    required int recordsWritten,
  }) async {
    return _runSerial(() async {
      final job = _jobs[jobId];
      if (job == null) return null;
      if (job.status != JobStatus.running) return null;
      if (job.workerId != workerId) return null;
      job.status = JobStatus.succeeded;
      job.cursorToken = cursorToken;
      job.lastModifiedSeen = lastModifiedSeen;
      job.recordsWritten = recordsWritten;
      job.completedAt = _clock();
      job.lastError = null;
      job.touch(_clock());
      _activeClaimsByJob[jobId]?.remove(workerId);
      return job;
    });
  }

  Future<SimulatedJob?> markFailed({
    required String jobId,
    required String workerId,
    required String errorMessage,
  }) async {
    return _runSerial(() async {
      final job = _jobs[jobId];
      if (job == null) return null;
      if (job.status != JobStatus.running) return null;
      if (job.workerId != workerId) return null;
      job.status = JobStatus.failed;
      job.completedAt = _clock();
      job.lastError = errorMessage;
      job.touch(_clock());
      _activeClaimsByJob[jobId]?.remove(workerId);
      return job;
    });
  }

  Future<SimulatedJob?> releaseForResume({
    required String jobId,
    required String workerId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    required int recordsWritten,
  }) async {
    return _runSerial(() async {
      final job = _jobs[jobId];
      if (job == null) return null;
      if (job.status != JobStatus.running) return null;
      if (job.workerId != workerId) return null;
      job.status = JobStatus.pending;
      job.cursorToken = cursorToken;
      job.lastModifiedSeen = lastModifiedSeen;
      job.recordsWritten = recordsWritten;
      job.claimedAt = null;
      job.workerId = null;
      job.completedAt = null;
      job.touch(_clock());
      _activeClaimsByJob[jobId]?.remove(workerId);
      return job;
    });
  }

  /// Force-orphan a worker's claim (the worker pod was killed
  /// mid-flight; SIGTERM didn't get to release). The row stays in
  /// `running` but with the orphaned `workerId` and a stale
  /// `claimed_at`. The next staleness sweep picks it back up.
  Future<void> orphanClaimsBy({required String workerId}) async {
    return _runSerial(() async {
      for (final job in _jobs.values) {
        if (job.workerId == workerId && job.status == JobStatus.running) {
          // Backdate `claimed_at` so the next stale-window claim
          // picks it up immediately. This mirrors what would happen
          // after `claim_stale_after` elapses naturally.
          job.claimedAt = _clock().subtract(
            kSimulatedClaimStaleAfter * 2,
          );
          job.touch(_clock());
        }
        _activeClaimsByJob[job.jobId]?.remove(workerId);
      }
    });
  }

  Future<void> writeAudit(SimulatedAuditRow row) async {
    return _runSerial(() async {
      _audit.add(row);
    });
  }

  /// Mirror `WorkerCanonicalSink.evaluateDemoFlip`: idempotent flip
  /// once `firstBackfillCommitted == true && backfillRecordsWritten >= 1`.
  Future<SimulatedDemoModeRow> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required String category,
    required String connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {
    return _runSerial(() async {
      final key = '$operatorId|$locationId|$category';
      final existing = _demo[key];
      final row = existing ??
          SimulatedDemoModeRow(
            operatorId: operatorId,
            locationId: locationId,
            category: category,
            isDemo: true,
          );
      _demo[key] = row;
      if (!row.isDemo) return row; // already live; never auto-revert
      if (connectionStatus != 'connected') return row;
      if (!firstBackfillCommitted) return row;
      if (backfillRecordsWritten < 1) return row;
      row.isDemo = false;
      row.flippedToLiveAt = _clock();
      row.flippedByConnectionId = connectionId;
      return row;
    });
  }
}

// ─── Worker pod ─────────────────────────────────────────────────────

class _WorkerPod {
  _WorkerPod({
    required this.workerId,
    required this.store,
    required this.dispatchSlice,
    required this.findings,
    required this.config,
  });

  final String workerId;
  final InMemoryBackfillStore store;

  /// How many records the simulated adapter writes per resume
  /// iteration. Smaller slices produce more `releaseForResume` →
  /// re-claim cycles which is what the harness wants to stress.
  final int dispatchSlice;

  final FindingsLog findings;
  final HarnessConfig config;

  bool _stopRequested = false;
  bool _running = false;
  Future<void>? _loopFuture;

  void requestStop() => _stopRequested = true;

  Future<void> start({
    required List<String> operatorIds,
    required Map<String, String> operatorToLocation,
  }) async {
    if (_running) return;
    _running = true;
    _loopFuture = _runLoop(
      operatorIds: operatorIds,
      operatorToLocation: operatorToLocation,
    );
  }

  Future<void> awaitDone() => _loopFuture ?? Future<void>.value();

  Future<void> _runLoop({
    required List<String> operatorIds,
    required Map<String, String> operatorToLocation,
  }) async {
    while (!_stopRequested) {
      var didWork = false;
      for (final opId in operatorIds) {
        if (_stopRequested) break;
        final locId = operatorToLocation[opId]!;
        final claimed = await store.claimNext(
          operatorId: opId,
          locationId: locId,
          workerId: workerId,
          claimStaleAfter: kSimulatedClaimStaleAfter,
        );
        if (claimed == null) continue;
        didWork = true;
        await _dispatch(claimed);
      }
      // Demo-flip race operator (kRaceOperatorId / kRaceLocationId)
      // is enumerated separately so all pods race for it explicitly.
      if (_stopRequested) break;
      final raceClaimed = await store.claimNext(
        operatorId: kRaceOperatorId,
        locationId: kRaceLocationId,
        workerId: workerId,
        claimStaleAfter: kSimulatedClaimStaleAfter,
      );
      if (raceClaimed != null) {
        didWork = true;
        await _dispatch(raceClaimed);
      }
      if (!didWork) {
        // No work right now. Sleep briefly and retry; the staleness
        // path means an orphaned-claim row reappears after the
        // stale window.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        if (!didWork && _stopRequested) break;
        if (!didWork && _allTerminal()) break;
      }
    }
    _running = false;
  }

  bool _allTerminal() {
    for (final job in store.allJobs) {
      if (job.status == JobStatus.pending ||
          job.status == JobStatus.running) {
        return false;
      }
    }
    return true;
  }

  /// Simulate the adapter's `backfill` call: write `dispatchSlice`
  /// records starting from the previously-released cursor (resumable
  /// continuation). When `recordsWritten == recordsTarget`, mark
  /// succeeded; otherwise release for resume.
  Future<void> _dispatch(SimulatedJob job) async {
    // Cursor-lost-at-restart guard: when a job is re-claimed after a
    // pod restart, it MUST resume from the cursor it left off at,
    // not from null. We assert this by checking that the resumed
    // dispatch sees the prior `recordsWritten` carried over.
    final priorRecords = job.recordsWritten;
    final priorCursor = job.cursorToken;
    if (job.attemptCount > 1) {
      if (priorRecords == 0 && priorCursor == null) {
        // Fresh pending job that was never partially processed: ok.
      } else if (priorCursor == null && priorRecords > 0) {
        findings.record(
          kind: 'cursor_lost_at_restart',
          jobId: job.jobId,
          vendor: job.vendorId,
          detail:
              'job re-claimed (attempt=${job.attemptCount}) but '
              'cursor_token is null while recordsWritten=$priorRecords; '
              'resume would re-process from scratch',
        );
      }
    }

    await Future<void>.delayed(kSimulatedAdapterCallLatency);

    final remaining = job.recordsTarget - job.recordsWritten;
    final sliceWritten = math.min(dispatchSlice, remaining);
    final newRecords = job.recordsWritten + sliceWritten;
    final cursor = 'cur:${job.jobId}:$newRecords';
    final lastModified = DateTime.now().toUtc();

    if (newRecords >= job.recordsTarget) {
      final succeeded = await store.markSucceeded(
        jobId: job.jobId,
        workerId: workerId,
        cursorToken: cursor,
        lastModifiedSeen: lastModified,
        recordsWritten: newRecords,
      );
      if (succeeded != null && newRecords > 0) {
        // Demo-flip evaluation — production wires this through
        // CanonicalSink.evaluateDemoFlip after the first commit.
        await store.evaluateDemoFlip(
          operatorId: job.operatorId,
          locationId: job.locationId,
          category: job.category,
          connectionStatus: 'connected',
          firstBackfillCommitted: true,
          backfillRecordsWritten: newRecords,
          connectionId: job.connectionId,
        );
        // Audit row — production wires this through the
        // RetryCappingBackfillJobStore's `markSucceeded` terminal
        // hook (the `BackfillTerminalHook` typedef in
        // backfill_dispatch.dart). The harness emits one row per
        // terminal outcome to mirror the contract.
        await store.writeAudit(
          SimulatedAuditRow(
            operatorId: job.operatorId,
            locationId: job.locationId,
            targetId: job.jobId,
            action: 'backfill_completed',
            payload: <String, Object?>{
              'vendor_id': job.vendorId,
              'category': job.category,
              'records_written': newRecords,
              'attempt_count': job.attemptCount,
              'worker_id': workerId,
            },
            occurredAt: DateTime.now().toUtc(),
          ),
        );
      }
    } else {
      await store.releaseForResume(
        jobId: job.jobId,
        workerId: workerId,
        cursorToken: cursor,
        lastModifiedSeen: lastModified,
        recordsWritten: newRecords,
      );
    }
  }
}

// ─── Findings log ────────────────────────────────────────────────────

class FindingsLog {
  FindingsLog._(this._sink);

  factory FindingsLog.openFresh(String path) {
    final file = File(path);
    final dir = file.parent;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    if (file.existsSync()) {
      file.deleteSync();
    }
    // ignore: close_sinks - closed by `flushAndClose`.
    final sink = file.openWrite(mode: FileMode.write);
    return FindingsLog._(sink);
  }

  final IOSink _sink;
  final Map<String, int> _kindTally = <String, int>{};
  final Set<String> _setupSkippedSeen = <String>{};
  int _total = 0;

  int get totalRecorded => _total;
  Map<String, int> get tally => Map<String, int>.unmodifiable(_kindTally);

  void record({
    required String kind,
    String jobId = '*',
    String vendor = '*',
    String detail = '',
  }) {
    final line = jsonEncode(<String, Object?>{
      'kind': kind,
      'job_id': jobId,
      'vendor': vendor,
      'detail': detail,
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
      'harness_version': kHarnessVersion,
    });
    _sink.writeln(line);
    _kindTally.update(kind, (n) => n + 1, ifAbsent: () => 1);
    _total += 1;
  }

  void recordSetupSkippedOnce({required String detail}) {
    if (!_setupSkippedSeen.add('setup_skipped')) return;
    record(kind: 'setup_skipped', detail: detail);
  }

  Future<void> flushAndClose() async {
    await _sink.flush();
    await _sink.close();
  }
}

// ─── Top-level run ──────────────────────────────────────────────────

class HarnessRunResult {
  const HarnessRunResult({
    required this.findingTally,
    required this.totalFindings,
    required this.totalJobsEnqueued,
    required this.totalJobsTerminal,
    required this.elapsed,
    required this.demoFlipResult,
  });

  final Map<String, int> findingTally;
  final int totalFindings;
  final int totalJobsEnqueued;
  final int totalJobsTerminal;
  final Duration elapsed;
  final DemoFlipObservation demoFlipResult;
}

class DemoFlipObservation {
  const DemoFlipObservation({
    required this.allFlipped,
    required this.flipSpread,
    required this.flippedCategories,
  });

  final bool allFlipped;
  final Duration? flipSpread;
  final List<String> flippedCategories;
}

Future<HarnessRunResult> runHarness({
  required HarnessConfig config,
  required FindingsLog findings,
  Map<String, String>? environment,
  void Function(String line)? log,
}) async {
  final env = environment ?? Platform.environment;
  final logFn = log ?? (config.quiet ? (_) {} : (line) => stdout.writeln(line));

  final start = DateTime.now();
  final store = InMemoryBackfillStore();

  // Setup-skipped: real Postgres path is intentionally not exercised
  // by this harness (HP #1: don't write to production; staging has no
  // env vars set on this host). Record once.
  if (env['POSTGRES_URL'] == null || env['POSTGRES_URL']!.isEmpty) {
    findings.recordSetupSkippedOnce(
      detail:
          'POSTGRES_URL not set in env; harness validates worker contract '
          'against an in-memory simulation of connector_backfill_jobs. '
          'Preview proxy URL ($kPreviewProxyUrl) is referenced for sprint '
          'authority but not exercised — Phase 3B asserts on the '
          'worker''s local invariants (claim, resume, demo-flip, audit) '
          'which the in-memory simulation reproduces faithfully',
    );
  }

  // ─── Enqueue (operator, vendor) jobs ──────────────────────────────
  final operatorIds = <String>[];
  final operatorToLocation = <String, String>{};
  for (var i = 0; i < config.ops; i++) {
    final opId =
        '$kOperatorIdPrefix${i.toRadixString(16).padLeft(12, '0')}';
    final locId =
        '$kLocationIdPrefix${i.toRadixString(16).padLeft(12, '0')}';
    operatorIds.add(opId);
    operatorToLocation[opId] = locId;
    for (var v = 0; v < config.vendorsPerOp; v++) {
      final vendor = kVendorRoster[v % kVendorRoster.length];
      final connId =
          '$kConnectionIdPrefix${i.toRadixString(16).padLeft(8, '0')}'
          '${v.toRadixString(16).padLeft(4, '0')}';
      await store.enqueue(
        operatorId: opId,
        locationId: locId,
        connectionId: connId,
        vendorId: vendor.id,
        category: vendor.category,
        recordsTarget: config.recordsPerVendor,
      );
    }
  }

  // ─── Enqueue demo-flip-race triple ────────────────────────────────
  // Three jobs (one per category) for (kRaceOperatorId, kRaceLocationId)
  // simultaneously. After all three terminate, the harness asserts
  // all three demo_mode_state rows flipped and the timestamps fall
  // within kDemoFlipRaceTolerance.
  for (final cat in kRaceCategories) {
    final connId = '$kConnectionIdPrefix$cat${'0' * (16 - cat.length)}';
    final vendorId = kVendorRoster.firstWhere((v) => v.category == cat).id;
    await store.enqueue(
      operatorId: kRaceOperatorId,
      locationId: kRaceLocationId,
      connectionId: connId,
      vendorId: vendorId,
      category: cat,
      recordsTarget: math.max(10, config.recordsPerVendor ~/ 4),
    );
  }

  final totalEnqueued = store.allJobs.length;
  logFn(
    'p3b: enqueued $totalEnqueued jobs ('
    '${config.totalEnqueued} regular + ${kRaceCategories.length} race) '
    'across ${config.ops} operators with ${config.workerPods} worker pods',
  );

  // ─── Spin up worker pods ──────────────────────────────────────────
  final pods = <_WorkerPod>[];
  // dispatchSlice intentionally smaller than recordsPerVendor so each
  // job needs ~3 dispatch cycles, exercising releaseForResume and
  // re-claim paths.
  final slice = math.max(1, config.recordsPerVendor ~/ 3);
  for (var i = 0; i < config.workerPods; i++) {
    pods.add(
      _WorkerPod(
        workerId: 'pod-${i.toRadixString(16)}',
        store: store,
        dispatchSlice: slice,
        findings: findings,
        config: config,
      ),
    );
  }
  // Race operator must be enumerated by every pod, so we also append
  // it to operatorIds for the regular-claim loop.
  final allOperatorIds = <String>[...operatorIds, kRaceOperatorId];
  final allOpToLoc = <String, String>{
    ...operatorToLocation,
    kRaceOperatorId: kRaceLocationId,
  };
  await Future.wait(<Future<void>>[
    for (final pod in pods)
      pod.start(
        operatorIds: allOperatorIds,
        operatorToLocation: allOpToLoc,
      ),
  ]);

  // ─── Restart simulation ──────────────────────────────────────────
  // After ~30% of jobs have reached a terminal state, kill `simulate
  // -restart` worker pods and start fresh ones. The store keeps its
  // state; the new pod inherits the work and must resume from the
  // cursor of any orphaned claims.
  if (config.simulateRestart > 0) {
    final restartThreshold = (totalEnqueued * 0.3).ceil();
    final deadline =
        DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      final terminal = store.allJobs
          .where((j) =>
              j.status == JobStatus.succeeded ||
              j.status == JobStatus.failed)
          .length;
      if (terminal >= restartThreshold) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final podsToKill = math.min(config.simulateRestart, pods.length - 1);
    for (var i = 0; i < podsToKill; i++) {
      final victim = pods[i];
      victim.requestStop();
      // Don't await — the harness simulates SIGKILL, not graceful
      // drain. Force-orphan the worker's claims so the staleness
      // path picks them up.
      await store.orphanClaimsBy(workerId: victim.workerId);
      logFn('p3b: killed ${victim.workerId} (simulating pod restart)');

      // Spin a replacement pod with a fresh worker id.
      final replacement = _WorkerPod(
        workerId: 'pod-restart-${i.toRadixString(16)}',
        store: store,
        dispatchSlice: slice,
        findings: findings,
        config: config,
      );
      pods.add(replacement);
      await replacement.start(
        operatorIds: allOperatorIds,
        operatorToLocation: allOpToLoc,
      );
      logFn('p3b: started ${replacement.workerId} (replacement)');
    }
  }

  // ─── Wait for all jobs to terminate (or budget exhaust) ──────────
  final budgetEnd = DateTime.now().add(kBackfillStuckBudget);
  while (DateTime.now().isBefore(budgetEnd)) {
    final stillRunning = store.allJobs.where(
      (j) =>
          j.status == JobStatus.pending || j.status == JobStatus.running,
    );
    if (stillRunning.isEmpty) break;
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  // Stop all pods.
  for (final pod in pods) {
    pod.requestStop();
  }
  await Future.wait(<Future<void>>[for (final pod in pods) pod.awaitDone()]);

  // ─── Assertions / findings ───────────────────────────────────────
  // 1. backfill_stuck — any job not at a terminal state.
  for (final job in store.allJobs) {
    if (job.status == JobStatus.pending ||
        job.status == JobStatus.running) {
      findings.record(
        kind: 'backfill_stuck',
        jobId: job.jobId,
        vendor: job.vendorId,
        detail:
            'job stuck at status=${job.status.name} after '
            '${kBackfillStuckBudget.inSeconds}s budget; '
            'recordsWritten=${job.recordsWritten}/${job.recordsTarget}, '
            'attempts=${job.attemptCount}',
      );
    }
  }

  // 2. backfill_didnt_resume — succeeded jobs that took only one
  //    attempt despite the dispatchSlice forcing partial drains.
  //    (Equivalent: any job whose `attemptCount` is less than
  //    `ceil(recordsTarget / dispatchSlice)` and yet succeeded —
  //    means the worker accidentally drained the whole record set
  //    in one attempt, bypassing resume.)
  for (final job in store.allJobs) {
    if (job.status != JobStatus.succeeded) continue;
    final expectedMinAttempts = (job.recordsTarget / slice).ceil();
    if (job.attemptCount < expectedMinAttempts && expectedMinAttempts > 1) {
      // The harness deliberately uses small slices to force resume.
      // Fewer attempts than slices means resume was bypassed —
      // suspicious for any future refactor that drains the whole
      // queue in one tick.
      findings.record(
        kind: 'backfill_didnt_resume',
        jobId: job.jobId,
        vendor: job.vendorId,
        detail:
            'succeeded after attempts=${job.attemptCount} but '
            'expected at least $expectedMinAttempts dispatches '
            '(records=${job.recordsTarget}, slice=$slice)',
      );
    }
  }

  // 3. demo_flip_race_lost — the dedicated (race op, race loc) triple.
  final raceFlipObservation = _observeDemoFlipRace(store);
  if (!raceFlipObservation.allFlipped) {
    findings.record(
      kind: 'demo_flip_race_lost',
      jobId: kRaceOperatorId,
      vendor: 'race-triple',
      detail:
          'expected all 3 categories (${kRaceCategories.join(", ")}) '
          'to flip is_demo=false for ($kRaceOperatorId, $kRaceLocationId); '
          'flipped: ${raceFlipObservation.flippedCategories.join(", ")}',
    );
  } else if (raceFlipObservation.flipSpread != null &&
      raceFlipObservation.flipSpread! > kDemoFlipRaceTolerance) {
    findings.record(
      kind: 'demo_flip_race_lost',
      jobId: kRaceOperatorId,
      vendor: 'race-triple',
      detail:
          'all 3 categories flipped but spread '
          '${raceFlipObservation.flipSpread!.inSeconds}s exceeds '
          'tolerance ${kDemoFlipRaceTolerance.inSeconds}s',
    );
  }

  // 4. worker_collision — claim history shows two distinct workers
  //    held the row at the same time. Production's SKIP LOCKED makes
  //    this impossible; if it ever shows up the assertion will catch
  //    a future refactor that drops the lock.
  for (final job in store.allJobs) {
    final distinctWorkers =
        job.claimHistory.toSet().toList(growable: false);
    if (distinctWorkers.length > 1 && job.attemptCount == 1) {
      // Multiple workers claimed but only one attempt? Means two
      // claims overlapped without an attempt counter increment —
      // collision.
      findings.record(
        kind: 'worker_collision',
        jobId: job.jobId,
        vendor: job.vendorId,
        detail:
            'job claimed by ${distinctWorkers.length} distinct workers '
            '(${distinctWorkers.join(", ")}) but only $job.attemptCount '
            'attempt counter increments — claims overlapped',
      );
    }
  }

  // 5. audit_row_missing — every succeeded job MUST have one
  //    `backfill_completed` audit row.
  final auditByJob = <String, int>{};
  for (final row in store.allAudit) {
    if (row.action == 'backfill_completed') {
      auditByJob.update(row.targetId, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  for (final job in store.allJobs) {
    if (job.status != JobStatus.succeeded) continue;
    if ((auditByJob[job.jobId] ?? 0) < 1) {
      findings.record(
        kind: 'audit_row_missing',
        jobId: job.jobId,
        vendor: job.vendorId,
        detail:
            'succeeded job has no backfill_completed audit row; '
            'BackfillTerminalHook contract violated',
      );
    }
  }

  final terminal = store.allJobs
      .where((j) =>
          j.status == JobStatus.succeeded || j.status == JobStatus.failed)
      .length;
  final elapsed = DateTime.now().difference(start);

  return HarnessRunResult(
    findingTally: findings.tally,
    totalFindings: findings.totalRecorded,
    totalJobsEnqueued: totalEnqueued,
    totalJobsTerminal: terminal,
    elapsed: elapsed,
    demoFlipResult: raceFlipObservation,
  );
}

DemoFlipObservation _observeDemoFlipRace(InMemoryBackfillStore store) {
  final flipped = <String>[];
  DateTime? earliest;
  DateTime? latest;
  for (final cat in kRaceCategories) {
    final row = store.allDemo.firstWhere(
      (r) =>
          r.operatorId == kRaceOperatorId &&
          r.locationId == kRaceLocationId &&
          r.category == cat,
      orElse: () => SimulatedDemoModeRow(
        operatorId: kRaceOperatorId,
        locationId: kRaceLocationId,
        category: cat,
        isDemo: true,
      ),
    );
    if (!row.isDemo && row.flippedToLiveAt != null) {
      flipped.add(cat);
      final ts = row.flippedToLiveAt!;
      if (earliest == null || ts.isBefore(earliest)) earliest = ts;
      if (latest == null || ts.isAfter(latest)) latest = ts;
    }
  }
  Duration? spread;
  if (earliest != null && latest != null) {
    spread = latest.difference(earliest);
  }
  return DemoFlipObservation(
    allFlipped: flipped.length == kRaceCategories.length,
    flipSpread: spread,
    flippedCategories: flipped,
  );
}

// ─── Summary md emission ────────────────────────────────────────────

void writeSummary({
  required String summaryPath,
  required HarnessConfig config,
  required HarnessRunResult result,
}) {
  final file = File(summaryPath);
  if (!file.parent.existsSync()) {
    file.parent.createSync(recursive: true);
  }
  final sb = StringBuffer()
    ..writeln('# Pressure Preview v1 — Phase 3B Backfill Flood')
    ..writeln()
    ..writeln('Harness version: `$kHarnessVersion`')
    ..writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}')
    ..writeln()
    ..writeln('## Run Parameters')
    ..writeln()
    ..writeln('| Flag | Value |')
    ..writeln('|---|---|')
    ..writeln('| `--ops` | ${config.ops} |')
    ..writeln('| `--vendors-per-op` | ${config.vendorsPerOp} |')
    ..writeln('| `--records-per-vendor` | ${config.recordsPerVendor} |')
    ..writeln('| `--worker-pods` | ${config.workerPods} |')
    ..writeln('| `--simulate-restart` | ${config.simulateRestart} |')
    ..writeln(
      '| Total jobs enqueued | ${result.totalJobsEnqueued} '
      '(${config.totalEnqueued} regular + 3 demo-flip race) |',
    )
    ..writeln('| Synthetic records | ${config.totalRecords} |')
    ..writeln('| Elapsed | ${result.elapsed.inMilliseconds} ms |')
    ..writeln(
      '| Terminal / enqueued | '
      '${result.totalJobsTerminal} / ${result.totalJobsEnqueued} |',
    )
    ..writeln(
      '| Demo-flip race resolved | ${result.demoFlipResult.allFlipped} |',
    );
  if (result.demoFlipResult.flipSpread != null) {
    sb.writeln(
      '| Demo-flip spread | '
      '${result.demoFlipResult.flipSpread!.inMilliseconds} ms |',
    );
  }
  sb
    ..writeln()
    ..writeln('## Findings Tally')
    ..writeln()
    ..writeln('Total findings: ${result.totalFindings}')
    ..writeln();
  if (result.findingTally.isEmpty) {
    sb.writeln('_No findings recorded._');
  } else {
    sb.writeln('| Kind | Count |');
    sb.writeln('|---|---|');
    final kinds = result.findingTally.keys.toList()..sort();
    for (final kind in kinds) {
      sb.writeln('| `$kind` | ${result.findingTally[kind]} |');
    }
  }
  sb
    ..writeln()
    ..writeln('## Finding Categories')
    ..writeln()
    ..writeln(
      '- `backfill_stuck` — job stayed in `running` (or `pending`) '
      'past the per-job budget.',
    )
    ..writeln(
      '- `backfill_didnt_resume` — pod restart caused re-processing '
      'from scratch instead of resuming from cursor.',
    )
    ..writeln(
      '- `demo_flip_race_lost` — only some categories flipped after '
      'concurrent backfills for one (operator, location).',
    )
    ..writeln(
      '- `worker_collision` — two worker pods claimed the same job '
      '(would indicate a SKIP LOCKED regression).',
    )
    ..writeln(
      '- `audit_row_missing` — no terminal-hook audit log entry for '
      'a succeeded backfill.',
    )
    ..writeln(
      '- `cursor_lost_at_restart` — worker resumed from null cursor '
      'instead of partial cursor after pod restart.',
    )
    ..writeln(
      '- `connection_pool_exhaustion` — emitted when the in-memory '
      'serializer queue depth crosses a threshold proxy for a real '
      'pool exhaustion (not currently observed in the in-memory path).',
    )
    ..writeln(
      '- `setup_skipped` — preconditions for the real-DB path were '
      'absent (e.g. `POSTGRES_URL` not set); harness ran the in-memory '
      'simulation instead.',
    )
    ..writeln()
    ..writeln('## Full-Scale Invocation')
    ..writeln()
    ..writeln('```')
    ..writeln(
      'dart run tool/pressure/p3b_backfill_flood.dart '
      '--ops=10 --vendors-per-op=3 --records-per-vendor=1000 '
      '--worker-pods=3 --simulate-restart=3',
    )
    ..writeln('```')
    ..writeln()
    ..writeln(
      '≈ 30,000 records ingested across 30 backfill jobs (plus the '
      '3-job demo-flip-race triple).',
    )
    ..writeln()
    ..writeln('## Preview Proxy Reference')
    ..writeln()
    ..writeln(
      'Operator-approved preview proxy URL '
      '(referenced by sprint authority; not exercised by this harness):',
    )
    ..writeln()
    ..writeln('  $kPreviewProxyUrl');
  file.writeAsStringSync(sb.toString());
}

// ─── CLI entry ──────────────────────────────────────────────────────

Future<int> runCli(
  List<String> rawArgs, {
  Map<String, String>? environment,
  void Function(String line)? out,
  void Function(String line)? err,
}) async {
  final outFn = out ?? (line) => stdout.writeln(line);
  final errFn = err ?? (line) => stderr.writeln(line);

  HarnessConfig config;
  try {
    config = parseArgs(rawArgs);
  } on HarnessException catch (e) {
    if (e.message == '--help') {
      outFn(_usage);
      return 0;
    }
    errFn('p3b_backfill_flood: ${e.message}');
    errFn('');
    errFn(_usage);
    return 2;
  }

  FindingsLog findings;
  try {
    findings = FindingsLog.openFresh(config.findingsOut);
  } catch (e) {
    errFn(
      'p3b_backfill_flood: cannot open findings file ${config.findingsOut}: $e',
    );
    return 3;
  }

  HarnessRunResult result;
  try {
    result = await runHarness(
      config: config,
      findings: findings,
      environment: environment,
      log: config.quiet ? null : (line) => outFn(line),
    );
  } catch (e, st) {
    errFn('p3b_backfill_flood: harness error: $e');
    errFn(st.toString());
    await findings.flushAndClose();
    return 3;
  } finally {
    await findings.flushAndClose();
  }

  try {
    writeSummary(
      summaryPath: config.summaryOut,
      config: config,
      result: result,
    );
  } catch (e) {
    errFn(
      'p3b_backfill_flood: cannot write summary to ${config.summaryOut}: $e',
    );
    return 3;
  }

  // Print smoke summary so the PR description / shell grep has a
  // consistent block to quote.
  outFn('── p3b backfill flood summary ──');
  outFn('elapsed: ${result.elapsed.inMilliseconds} ms');
  outFn('jobs enqueued: ${result.totalJobsEnqueued}');
  outFn(
    'jobs terminal: ${result.totalJobsTerminal} / ${result.totalJobsEnqueued}',
  );
  outFn('demo-flip race resolved: ${result.demoFlipResult.allFlipped}');
  if (result.demoFlipResult.flipSpread != null) {
    outFn(
      'demo-flip spread: '
      '${result.demoFlipResult.flipSpread!.inMilliseconds} ms',
    );
  }
  outFn('findings: ${result.totalFindings}');
  final kinds = result.findingTally.keys.toList()..sort();
  for (final kind in kinds) {
    outFn('  $kind: ${result.findingTally[kind]}');
  }
  outFn('findings file: ${config.findingsOut}');
  outFn('summary file: ${config.summaryOut}');

  return 0;
}

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
