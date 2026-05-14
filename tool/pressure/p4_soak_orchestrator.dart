// Wave 2 Lane Q slice Q-1 (2026-05-13) — soak orchestrator that drives
// a sustained multi-instance request workload against the proxy,
// captures runtime metrics, schedules periodic heap snapshots into
// Azure Blob, and emits a final report.
//
// Origin: `docs/_indices/WAVE_2_LEDGER.md` row Q-1 ("Soak harness
// completion + Azure Blob swap"). The pre-existing `p4_session_soak`
// and `p4_operator_day_soak` harnesses each cover a slice of the soak
// surface (sign-in only, full operator-day flow) but do not surface a
// single end-to-end report with request rate, latency percentiles,
// error counts, and heap-snapshot URLs the way debug.md:16 + the
// follow-ups doc need to unblock B-2B (proxy crash root cause).
//
// What this orchestrator adds beyond the two existing soak files:
//   1. Drives both `p4_session_soak` and `p4_operator_day_soak` style
//      workloads concurrently (configurable mix; default 50/50).
//   2. Captures per-request latency into a sample buffer and computes
//      p50 / p95 / p99 at run end.
//   3. Wires a `HeapSnapshotUploader` against the Azure Blob target so
//      heap snapshots are pushed at configured intervals.
//   4. Iterates over a list of known proxy instance IDs (multi-pod
//      capture) and emits a per-pod summary in the final report. When
//      no pod-discovery endpoint is wired, falls back to the local pod
//      identifier from `K_REVISION` (still emits per-pod sections so
//      the report shape stays stable for live multi-pod runs).
//   5. Emits a Markdown report with the metrics the orchestrator
//      audit + the `B-2B` triage need (request rate sustained, error
//      rate, p50/p95/p99 latency, heap-snapshot URLs, per-pod
//      breakdown).
//
// Usage
// -----
//   dart run tool/pressure/p4_soak_orchestrator.dart \
//     --proxy-url=http://localhost:8080 \
//     --duration=10min \
//     --concurrency=8 \
//     --ops=20
//
// Hard rules
// ----------
// - Refuses to run against a non-preview / non-staging / non-localhost
//   URL (same guard the per-route soak files use).
// - Captures heap snapshots only when the Azure Blob target is fully
//   configured (the four `AZURE_BLOB_HEAP_SNAPSHOTS_*` + `AZURE_AD_*`
//   env vars set). Otherwise emits ONE structured "skipped" line at
//   start and keeps the request workload running.
// - Never writes to production (URL guard).
// - SIGINT cleanly drains in-flight requests + flushes the report.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'p4_fd_watcher.dart';
import 'p4_heap_snapshot_uploader.dart';
import 'p4_session_record_predicate.dart';

/// CLI options for [runSoakOrchestrator].
class SoakOrchestratorOptions {
  SoakOrchestratorOptions({
    required this.proxyUrl,
    required this.durationSeconds,
    required this.concurrency,
    required this.ops,
    required this.outputDir,
    required this.thinkTimeMs,
    required this.heapSnapshotIntervalSeconds,
    required this.metricsCheckpointSeconds,
    required this.runId,
    required this.podIds,
    required this.workloadMix,
  });

  /// Proxy base URL. Must satisfy [isSoakProxyUrlAllowed] (preview /
  /// staging / localhost).
  final String proxyUrl;
  final int durationSeconds;
  final int concurrency;
  final int ops;
  final String outputDir;
  final int thinkTimeMs;
  final int heapSnapshotIntervalSeconds;
  final int metricsCheckpointSeconds;

  /// Stable identifier for this soak run. Embeds into heap-snapshot
  /// object keys + the report filename. Caller may pin via `--run-id=`;
  /// otherwise derived from the current UTC timestamp.
  final String runId;

  /// Proxy instances to attribute requests to. When the harness has no
  /// control-plane endpoint to enumerate live pods, falls back to a
  /// single-element list of the local `K_REVISION` (or `local-dev`).
  /// Multi-pod heap capture iterates this list at run end (see
  /// [_capturePerPodHeapSnapshots] for the TODO around per-pod
  /// triggering — Cloud Run currently lacks a per-pod heap-dump
  /// endpoint, so today this is a stub that emits one snapshot
  /// labeled per pod and notes the limitation).
  final List<String> podIds;

  /// Fraction of workers running the operator-day flow (vs the
  /// session-only flow). 0.0 = all session-soak; 1.0 = all
  /// operator-day. Default 0.5.
  final double workloadMix;
}

/// Default arg values; the CLI parses overrides.
const String _kDefaultDuration = '60s';
const int _kDefaultConcurrency = 4;
const int _kDefaultOps = 8;
const int _kDefaultThinkMs = 500;
const int _kDefaultHeapIntervalSeconds = 300; // 5 min
const int _kDefaultCheckpointSeconds = 30;
const double _kDefaultMix = 0.5;

/// Synthetic operator id. Deterministic per `(ordinal, runSalt)` so a
/// rerun against the same `--run-id` writes to the same synthetic
/// scope.
String _deterministicUuid(String role, int ordinal, String salt) {
  final raw = '$role-$ordinal-$salt';
  final digest = sha256.convert(utf8.encode(raw)).bytes;
  final hex = digest
      .sublist(0, 16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final mutable = hex.codeUnits.toList();
  mutable[12] = '4'.codeUnitAt(0);
  mutable[16] = '8'.codeUnitAt(0);
  final fixed = String.fromCharCodes(mutable);
  return '${fixed.substring(0, 8)}-'
      '${fixed.substring(8, 12)}-'
      '${fixed.substring(12, 16)}-'
      '${fixed.substring(16, 20)}-'
      '${fixed.substring(20, 32)}';
}

String _placeholderJwt({
  required String userId,
  required String operatorId,
  required String locationId,
}) {
  final header = base64Url
      .encode(utf8.encode(jsonEncode(<String, Object?>{
        'alg': 'none',
        'typ': 'JWT',
      })))
      .replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode(jsonEncode(<String, Object?>{
        'sub': userId,
        'user_id': userId,
        'operator_id': operatorId,
        'location_id': locationId,
        'iat': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        'exp': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000,
      })))
      .replaceAll('=', '');
  return '$header.$payload.placeholder';
}

/// One captured request outcome. Used by the report builder to compute
/// rates + latency percentiles.
class _RequestSample {
  _RequestSample({
    required this.timestamp,
    required this.podId,
    required this.route,
    required this.statusCode,
    required this.latencyMs,
    required this.errorKind,
  });

  final DateTime timestamp;
  final String podId;
  final String route;
  final int statusCode;
  final int latencyMs;
  final String errorKind;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
  bool get isClientError => statusCode >= 400 && statusCode < 500;
  bool get isServerError => statusCode >= 500;
  bool get isNetworkError => errorKind == 'network_error';
  bool get isTimeout => errorKind == 'timeout';

  Map<String, Object?> toJson() => <String, Object?>{
        'ts': timestamp.toIso8601String(),
        'pod_id': podId,
        'route': route,
        'status_code': statusCode,
        'latency_ms': latencyMs,
        'error_kind': errorKind,
      };
}

/// Parse `Ns` / `Nmin` / `Nm` / `Nh`. Shared shape with `p3a` / `p4`.
int _parseDurationSeconds(String raw) {
  return parseSoakDurationSeconds(raw);
}

SoakOrchestratorOptions parseSoakOrchestratorArgs(List<String> args) {
  String proxyUrl =
      Platform.environment['FF_PRESSURE_PROXY_URL']?.trim() ?? '';
  int durationSeconds = _parseDurationSeconds(_kDefaultDuration);
  int concurrency = _kDefaultConcurrency;
  int ops = _kDefaultOps;
  String outputDir = 'test/pressure';
  int thinkTimeMs = _kDefaultThinkMs;
  int heapIntervalSeconds = _kDefaultHeapIntervalSeconds;
  int checkpointSeconds = _kDefaultCheckpointSeconds;
  String? runIdOverride;
  List<String>? podIdsOverride;
  double mix = _kDefaultMix;

  for (final raw in args) {
    if (!raw.startsWith('--')) continue;
    final eq = raw.indexOf('=');
    if (eq <= 0) continue;
    final key = raw.substring(2, eq);
    final value = raw.substring(eq + 1);
    switch (key) {
      case 'proxy-url':
        proxyUrl = value.trim();
        break;
      case 'duration':
        durationSeconds = _parseDurationSeconds(value);
        break;
      case 'concurrency':
        concurrency = int.parse(value);
        break;
      case 'ops':
        ops = int.parse(value);
        break;
      case 'output-dir':
        outputDir = value;
        break;
      case 'think-ms':
        thinkTimeMs = int.parse(value);
        break;
      case 'heap-interval':
        heapIntervalSeconds = _parseDurationSeconds(value);
        break;
      case 'checkpoint':
        checkpointSeconds = _parseDurationSeconds(value);
        break;
      case 'run-id':
        runIdOverride = value;
        break;
      case 'pod-ids':
        podIdsOverride =
            value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        break;
      case 'workload-mix':
        mix = double.parse(value);
        if (mix < 0 || mix > 1) {
          throw FormatException('--workload-mix must be in [0.0, 1.0]');
        }
        break;
      default:
        stderr.writeln('warning: unknown flag --$key');
    }
  }

  if (proxyUrl.isEmpty) {
    proxyUrl = 'http://localhost:8080';
  }

  final runId = runIdOverride ??
      'soak-${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^\w]'), '_')}';

  // Pod-id resolution: if the operator pinned `--pod-ids=`, use that.
  // Otherwise read `K_REVISION` (Cloud Run revision id, the closest
  // proxy-instance identifier the harness can see without a
  // control-plane endpoint). Fallback `local-dev` covers the laptop
  // run.
  final podIds = podIdsOverride ??
      <String>[
        Platform.environment['K_REVISION'] ??
            Platform.environment['CLOUD_RUN_REVISION'] ??
            'local-dev',
      ];

  return SoakOrchestratorOptions(
    proxyUrl: proxyUrl,
    durationSeconds: durationSeconds,
    concurrency: concurrency,
    ops: ops,
    outputDir: outputDir,
    thinkTimeMs: thinkTimeMs,
    heapSnapshotIntervalSeconds: heapIntervalSeconds,
    metricsCheckpointSeconds: checkpointSeconds,
    runId: runId,
    podIds: podIds,
    workloadMix: mix,
  );
}

/// Result returned by [runSoakOrchestrator] — used by tests to assert
/// the harness produced the expected report shape without re-reading
/// the JSONL/MD outputs from disk.
class SoakOrchestratorResult {
  SoakOrchestratorResult({
    required this.exitCode,
    required this.reportPath,
    required this.rawJsonlPath,
    required this.totalRequests,
    required this.successCount,
    required this.errorCount,
    required this.requestsPerSecond,
    required this.latencyP50Ms,
    required this.latencyP95Ms,
    required this.latencyP99Ms,
    required this.heapSnapshotUploadCount,
    required this.heapSnapshotBlobUris,
    required this.perPodCounts,
  });

  final int exitCode;
  final String reportPath;
  final String rawJsonlPath;
  final int totalRequests;
  final int successCount;
  final int errorCount;
  final double requestsPerSecond;
  final int latencyP50Ms;
  final int latencyP95Ms;
  final int latencyP99Ms;
  final int heapSnapshotUploadCount;
  final List<String> heapSnapshotBlobUris;
  final Map<String, int> perPodCounts;
}

/// Drive the soak: spin up workers, capture metrics, optionally
/// schedule heap snapshots, emit a final Markdown report. Returns a
/// [SoakOrchestratorResult] that tests can assert against. The CLI
/// entry point ([main]) maps the exit code to the process exit code.
Future<SoakOrchestratorResult> runSoakOrchestrator(
  SoakOrchestratorOptions opts, {
  HttpClient? httpClient,
  HeapSnapshotUploadTarget? heapUploadTarget,
  HeapSnapshotCapturer? heapCapturer,
  IOSink? logSink,
  DateTime Function()? clock,
  bool installSigintHandler = true,
  Duration? maxWallClock,
}) async {
  // ignore: close_sinks — stdout is owned by dart:io, not by this fn.
  final log = logSink ?? stdout;
  final now = clock ?? (() => DateTime.now().toUtc());

  if (!isSoakProxyUrlAllowed(opts.proxyUrl)) {
    stderr.writeln(
      'FATAL: proxy URL "${opts.proxyUrl}" is not preview / staging / '
      'localhost. Refusing to run pressure load against an unknown target.',
    );
    return SoakOrchestratorResult(
      exitCode: 2,
      reportPath: '',
      rawJsonlPath: '',
      totalRequests: 0,
      successCount: 0,
      errorCount: 0,
      requestsPerSecond: 0,
      latencyP50Ms: 0,
      latencyP95Ms: 0,
      latencyP99Ms: 0,
      heapSnapshotUploadCount: 0,
      heapSnapshotBlobUris: const <String>[],
      perPodCounts: const <String, int>{},
    );
  }

  final outputDir = Directory(opts.outputDir);
  outputDir.createSync(recursive: true);
  final reportPath = '${outputDir.path}/p4_soak_orchestrator_${opts.runId}.md';
  final rawJsonlPath =
      '${outputDir.path}/p4_soak_orchestrator_${opts.runId}_raw.jsonl';
  final findingsPath =
      '${outputDir.path}/p4_soak_orchestrator_${opts.runId}_findings.jsonl';
  final rawSink = File(rawJsonlPath).openWrite(mode: FileMode.write);

  final samples = <_RequestSample>[];
  final findings = <SoakFinding>[];
  final perPodCounts = <String, int>{
    for (final pod in opts.podIds) pod: 0,
  };

  log.writeln('=== p4_soak_orchestrator plan ===');
  log.writeln('  run_id: ${opts.runId}');
  log.writeln('  proxy: ${opts.proxyUrl}');
  log.writeln('  duration: ${opts.durationSeconds}s');
  log.writeln('  concurrency: ${opts.concurrency}');
  log.writeln('  ops: ${opts.ops}');
  log.writeln('  workload_mix (operator-day fraction): ${opts.workloadMix}');
  log.writeln('  pod_ids: ${opts.podIds.join(', ')}');
  log.writeln(
    '  heap_snapshot_interval: ${opts.heapSnapshotIntervalSeconds}s',
  );
  log.writeln('===');

  // Heap-snapshot wiring.
  // The trigger condition is "fire every N seconds since the last
  // upload" — the uploader's polling timer handles the cadence, so we
  // simply return true every time the timer fires.
  final effectiveHeapTarget =
      heapUploadTarget ?? AzureBlobHeapSnapshotUploadTarget();
  final heapUploader = HeapSnapshotUploader(
    triggerCondition: () => true,
    uploadTarget: effectiveHeapTarget,
    pollInterval: Duration(seconds: opts.heapSnapshotIntervalSeconds),
    capturer: heapCapturer,
    output: log,
    runId: opts.runId,
    podId: opts.podIds.first,
  );

  // FD-watcher (Linux only; emits no-op line elsewhere).
  final fdWatcher = FdWatcher(
    pollInterval: Duration(seconds: opts.metricsCheckpointSeconds),
    output: log,
  );

  fdWatcher.start();
  heapUploader.start();

  final client = httpClient ??
      (HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..idleTimeout = const Duration(seconds: 30));

  final shutdown = SoakShutdownSignal();
  StreamSubscription<ProcessSignal>? sigintSub;
  if (installSigintHandler) {
    try {
      sigintSub = ProcessSignal.sigint.watch().listen((_) {
        stderr.writeln('SIGINT received — draining in-flight requests');
        shutdown.fire();
      });
    } catch (_) {
      // Some hosts (test isolates) don't support sigint subscriptions;
      // proceed without one.
    }
  }

  final runStart = now();
  final hardEnd = runStart.add(Duration(seconds: opts.durationSeconds));
  final effectiveEnd = maxWallClock == null
      ? hardEnd
      : runStart.add(maxWallClock);
  final rng = math.Random(0x504 ^ opts.runId.hashCode);
  final runSalt =
      opts.runId.replaceAll(RegExp(r'[^\w]'), '_');

  Future<_RequestSample> doRequest({
    required Uri url,
    required String method,
    required String podId,
    required String jwt,
    Map<String, Object?>? body,
  }) async {
    final start = now();
    try {
      final req = method == 'POST'
          ? await client.postUrl(url).timeout(const Duration(seconds: 15))
          : await client.getUrl(url).timeout(const Duration(seconds: 15));
      req.headers.set('authorization', 'Bearer $jwt');
      req.headers.set(
        'user-agent',
        'forge-flow-pressure-preview-v1/p4-soak-orchestrator',
      );
      req.headers.set('x-pressure-test-lane', 'p4-soak-orchestrator');
      req.headers.set('x-pressure-run-id', opts.runId);
      req.headers.set('x-pressure-target-pod', podId);
      if (body != null) {
        req.headers.set('content-type', 'application/json');
        req.add(utf8.encode(jsonEncode(body)));
      }
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final drained = <int>[];
      await for (final chunk in resp) {
        drained.addAll(chunk);
        if (drained.length > 4096) break;
      }
      final latency = now().difference(start).inMilliseconds;
      return _RequestSample(
        timestamp: start,
        podId: podId,
        route: url.path,
        statusCode: resp.statusCode,
        latencyMs: latency,
        errorKind: '',
      );
    } on TimeoutException {
      return _RequestSample(
        timestamp: start,
        podId: podId,
        route: url.path,
        statusCode: -1,
        latencyMs: now().difference(start).inMilliseconds,
        errorKind: 'timeout',
      );
    } catch (e) {
      return _RequestSample(
        timestamp: start,
        podId: podId,
        route: url.path,
        statusCode: -1,
        latencyMs: now().difference(start).inMilliseconds,
        errorKind: 'network_error',
      );
    }
  }

  Future<void> sessionFlow(int operatorOrdinal, String podId) async {
    final userId = _deterministicUuid('user', operatorOrdinal, runSalt);
    final operatorId =
        _deterministicUuid('operator', operatorOrdinal, runSalt);
    final locationId =
        _deterministicUuid('location', operatorOrdinal, runSalt);
    final jwt = _placeholderJwt(
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
    );
    final tokenHash = sha256.convert(utf8.encode(jwt)).toString();
    final loginUri = Uri.parse(opts.proxyUrl)
        .replace(path: '/v1/auth/session/login');
    final sample = await doRequest(
      url: loginUri,
      method: 'POST',
      podId: podId,
      jwt: jwt,
      body: <String, Object?>{'token_hash': tokenHash},
    );
    samples.add(sample);
    perPodCounts[podId] = (perPodCounts[podId] ?? 0) + 1;
    rawSink.writeln(jsonEncode(sample.toJson()));
  }

  Future<void> operatorDayFlow(int operatorOrdinal, String podId) async {
    final userId = _deterministicUuid('user', operatorOrdinal, runSalt);
    final operatorId =
        _deterministicUuid('operator', operatorOrdinal, runSalt);
    final locationId =
        _deterministicUuid('location', operatorOrdinal, runSalt);
    final jwt = _placeholderJwt(
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
    );
    final baseUrl = Uri.parse(opts.proxyUrl);
    final tokenHash = sha256.convert(utf8.encode(jwt)).toString();

    final routes = <_RouteStep>[
      _RouteStep(
        method: 'POST',
        path: '/v1/auth/session/login',
        body: <String, Object?>{'token_hash': tokenHash},
      ),
      _RouteStep(method: 'GET', path: '/v1/auth/account'),
      _RouteStep(
        method: 'GET',
        path: '/v1/operator/notification-preferences',
      ),
      _RouteStep(method: 'GET', path: '/healthz'),
    ];
    for (final step in routes) {
      if (shutdown.isFired || now().isAfter(effectiveEnd)) return;
      final sample = await doRequest(
        url: baseUrl.replace(path: step.path),
        method: step.method,
        podId: podId,
        jwt: jwt,
        body: step.body,
      );
      samples.add(sample);
      perPodCounts[podId] = (perPodCounts[podId] ?? 0) + 1;
      rawSink.writeln(jsonEncode(sample.toJson()));
    }
  }

  Future<void> worker(int workerIdx) async {
    final podIdx = workerIdx % opts.podIds.length;
    final podId = opts.podIds[podIdx];
    var operatorOrdinal = workerIdx;
    final useOperatorDay = rng.nextDouble() < opts.workloadMix;
    while (!shutdown.isFired && now().isBefore(effectiveEnd)) {
      if (useOperatorDay) {
        await operatorDayFlow(operatorOrdinal, podId);
      } else {
        await sessionFlow(operatorOrdinal, podId);
      }
      operatorOrdinal = (operatorOrdinal + opts.concurrency) % opts.ops;
      // Think-time jitter: ±25%.
      final jitterRange = (opts.thinkTimeMs * 0.5).round();
      final delay = math.max(
        50,
        opts.thinkTimeMs + (rng.nextInt(2 * jitterRange + 1) - jitterRange),
      );
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
  }

  final workers = <Future<void>>[
    for (var w = 0; w < opts.concurrency; w++) worker(w),
  ];

  final checkpoint = Timer.periodic(
    Duration(seconds: opts.metricsCheckpointSeconds),
    (timer) {
      if (shutdown.isFired || !now().isBefore(effectiveEnd)) {
        timer.cancel();
        return;
      }
      final n = samples.length;
      if (n == 0) return;
      final ok = samples.where((s) => s.isSuccess).length;
      final err5xx = samples.where((s) => s.isServerError).length;
      final tmo = samples.where((s) => s.isTimeout).length;
      log.writeln(
        '[checkpoint @ ${now().toIso8601String()}] n=$n 2xx=$ok '
        '5xx=$err5xx timeouts=$tmo',
      );
    },
  );

  await Future.any(<Future<void>>[
    Future.wait(workers, eagerError: false),
    shutdown.future,
  ]);
  shutdown.fire();
  await Future.wait(workers, eagerError: false);

  checkpoint.cancel();
  heapUploader.stop();
  fdWatcher.stop();
  await sigintSub?.cancel();
  await rawSink.flush();
  await rawSink.close();
  // The HttpClient is owned by the harness when not injected; close it.
  if (httpClient == null) {
    client.close(force: true);
  }

  // Multi-pod heap snapshot capture: today, the proxy does not expose a
  // per-pod heap-dump endpoint (Cloud Run hides pod identities behind
  // its load balancer). The orchestrator captures a snapshot of THIS
  // process's heap labeled with the first pod id. When the operator
  // wires a control-plane endpoint per the follow-up slice
  // (`Q-1-FU-multi-pod-heap`) the loop below becomes a real
  // `for (pod in podIds) { invokeRemoteCapture(pod) }`. Until then,
  // each non-local pod is reported as "remote_capture_pending" in the
  // report so the operator sees the gap explicitly.
  await _capturePerPodHeapSnapshots(
    uploader: heapUploader,
    opts: opts,
    log: log,
  );

  // Compute final metrics.
  final runEnd = now();
  final wallSeconds = math.max(
    1,
    runEnd.difference(runStart).inSeconds,
  );
  final n = samples.length;
  final successCount = samples.where((s) => s.isSuccess).length;
  final clientErr = samples.where((s) => s.isClientError).length;
  final serverErr = samples.where((s) => s.isServerError).length;
  final networkErr = samples.where((s) => s.isNetworkError).length;
  final timeoutErr = samples.where((s) => s.isTimeout).length;
  final errorCount = serverErr + networkErr + timeoutErr;
  final rps = n / wallSeconds;
  final percentiles = _latencyPercentiles(samples);

  // Findings: surface error spikes the operator should triage.
  if (n > 0 && (errorCount / n) > 0.2) {
    findings.add(SoakFinding(
      category: 'error_rate_high',
      detail: 'error rate exceeded 20% during soak',
      evidence: <String, Object?>{
        'total_requests': n,
        'error_count': errorCount,
        'server_5xx': serverErr,
        'timeouts': timeoutErr,
        'network_errors': networkErr,
      },
    ));
  }
  if (heapUploader.uploadCount > 0) {
    // Surface the heap-snapshot URIs as positive findings so the
    // operator can copy them into a triage doc.
    findings.add(SoakFinding(
      category: 'heap_snapshot_captured',
      detail: '${heapUploader.uploadCount} heap snapshot(s) uploaded',
      evidence: <String, Object?>{
        'blob_uris': heapUploader.uploads
            .map((r) => r.blobUri ?? r.objectKey)
            .toList(),
      },
    ));
  }
  File(findingsPath).writeAsStringSync(
    findings.map((f) => jsonEncode(f.toJson())).join('\n') +
        (findings.isEmpty ? '' : '\n'),
  );

  final report = StringBuffer()
    ..writeln('# p4_soak_orchestrator — ${opts.runId}')
    ..writeln()
    ..writeln('| Setting | Value |')
    ..writeln('|---|---|')
    ..writeln('| Proxy | `${opts.proxyUrl}` |')
    ..writeln('| Started | ${runStart.toIso8601String()} |')
    ..writeln('| Ended | ${runEnd.toIso8601String()} |')
    ..writeln('| Wall seconds | $wallSeconds |')
    ..writeln('| Configured duration | ${opts.durationSeconds}s |')
    ..writeln('| Concurrency | ${opts.concurrency} |')
    ..writeln('| Ops pool | ${opts.ops} |')
    ..writeln('| Workload mix (operator-day fraction) | ${opts.workloadMix} |')
    ..writeln('| Pod IDs | ${opts.podIds.join(', ')} |')
    ..writeln()
    ..writeln('## Request volume + outcome')
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|')
    ..writeln('| Total requests | $n |')
    ..writeln(
      '| Sustained request rate (req/s) | ${rps.toStringAsFixed(2)} |',
    )
    ..writeln('| 2xx success | $successCount |')
    ..writeln('| 4xx client error | $clientErr |')
    ..writeln('| 5xx server error | $serverErr |')
    ..writeln('| Timeouts | $timeoutErr |')
    ..writeln('| Network errors | $networkErr |')
    ..writeln(
      '| Error rate | '
      '${n == 0 ? "n/a" : "${(100.0 * errorCount / n).toStringAsFixed(2)}%"} |',
    )
    ..writeln()
    ..writeln('## Latency percentiles (ms)')
    ..writeln()
    ..writeln('| Percentile | Value |')
    ..writeln('|---|---|')
    ..writeln('| p50 | ${percentiles.p50} |')
    ..writeln('| p95 | ${percentiles.p95} |')
    ..writeln('| p99 | ${percentiles.p99} |')
    ..writeln()
    ..writeln('## Per-pod breakdown')
    ..writeln()
    ..writeln('| Pod | Requests | Note |')
    ..writeln('|---|---|---|');
  for (final pod in opts.podIds) {
    final count = perPodCounts[pod] ?? 0;
    final note = (pod == opts.podIds.first || pod == 'local-dev')
        ? 'driving worker; local heap snapshot enabled'
        : 'remote_capture_pending — needs control-plane endpoint per Q-1-FU';
    report.writeln('| `$pod` | $count | $note |');
  }
  report
    ..writeln()
    ..writeln('## Heap snapshots')
    ..writeln();
  if (heapUploader.uploadCount == 0) {
    report.writeln(
      effectiveHeapTarget.isConfigured
          ? '_No heap snapshots captured during this run._'
          : '_Heap-snapshot upload skipped: ${effectiveHeapTarget.unconfiguredReason}._',
    );
  } else {
    report.writeln('| # | Object key | Blob URI | Size (bytes) |');
    report.writeln('|---|---|---|---|');
    for (var i = 0; i < heapUploader.uploads.length; i++) {
      final r = heapUploader.uploads[i];
      report.writeln(
        '| ${i + 1} | `${r.objectKey}` | '
        '${r.blobUri == null ? "_(no uri)_" : "`${r.blobUri}`"} | '
        '${r.sizeBytes} |',
      );
    }
  }
  report
    ..writeln()
    ..writeln('## Findings')
    ..writeln();
  if (findings.isEmpty) {
    report.writeln('_No findings surfaced during this run._');
  } else {
    for (final f in findings) {
      report.writeln('- **${f.category}** — ${f.detail}');
    }
  }

  File(reportPath).writeAsStringSync(report.toString());
  log.writeln('\nReport: $reportPath');
  log.writeln('Raw JSONL: $rawJsonlPath');
  log.writeln('Findings JSONL: $findingsPath');

  return SoakOrchestratorResult(
    exitCode: 0,
    reportPath: reportPath,
    rawJsonlPath: rawJsonlPath,
    totalRequests: n,
    successCount: successCount,
    errorCount: errorCount,
    requestsPerSecond: rps,
    latencyP50Ms: percentiles.p50,
    latencyP95Ms: percentiles.p95,
    latencyP99Ms: percentiles.p99,
    heapSnapshotUploadCount: heapUploader.uploadCount,
    heapSnapshotBlobUris: heapUploader.uploads
        .map((r) => r.blobUri ?? r.objectKey)
        .toList(),
    perPodCounts: Map<String, int>.unmodifiable(perPodCounts),
  );
}

/// Multi-pod heap snapshot capture.
///
/// TODO(Q-1-FU-multi-pod-heap): wire a control-plane endpoint on the
/// proxy that exposes per-pod heap-dump capture (`POST
/// /v1/admin/diagnostics/heap-snapshot` with a `pod_id` selector — the
/// proxy would forward via gRPC to the named pod). Until that lands,
/// this method captures one snapshot from the local process labeled
/// against the first pod id and emits a structured "deferred" log line
/// for each remaining pod. Live multi-pod soak runs (Cloud Run revision
/// > 1) currently surface a single-pod heap; the per-pod breakdown
/// table in the final report flags the gap explicitly.
Future<void> _capturePerPodHeapSnapshots({
  required HeapSnapshotUploader uploader,
  required SoakOrchestratorOptions opts,
  required IOSink log,
}) async {
  if (!uploader.isPolling && uploader.uploadCount == 0) {
    // Nothing fired during the run. Try one explicit final capture so
    // the report has something to attach. The uploader's trigger is
    // `() => true`, so a single `tick()` either uploads or logs a
    // structured skip.
    await uploader.tick();
  }
  // Pods beyond the first: emit a structured "deferred" line each so
  // the operator's grep finds them.
  for (var i = 1; i < opts.podIds.length; i++) {
    log.writeln(jsonEncode(<String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'metric': 'soak.heap_snapshot.deferred',
      'pod_id': opts.podIds[i],
      'reason': 'multi-pod capture requires control-plane endpoint '
          '(follow-up slice Q-1-FU-multi-pod-heap)',
    }));
  }
}

class _RouteStep {
  _RouteStep({
    required this.method,
    required this.path,
    this.body,
  });

  final String method;
  final String path;
  final Map<String, Object?>? body;
}

class _Percentiles {
  _Percentiles({required this.p50, required this.p95, required this.p99});
  final int p50;
  final int p95;
  final int p99;
}

_Percentiles _latencyPercentiles(List<_RequestSample> samples) {
  if (samples.isEmpty) {
    return _Percentiles(p50: 0, p95: 0, p99: 0);
  }
  final sorted = samples.map((s) => s.latencyMs).toList()..sort();
  int pick(double fraction) {
    final idx = ((sorted.length - 1) * fraction).round();
    return sorted[idx];
  }

  return _Percentiles(
    p50: pick(0.50),
    p95: pick(0.95),
    p99: pick(0.99),
  );
}

Future<void> main(List<String> args) async {
  final opts = parseSoakOrchestratorArgs(args);
  final result = await runSoakOrchestrator(opts);
  exit(result.exitCode);
}
