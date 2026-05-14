// Wave 2 Lane Q slice Q-1 — p4_soak_orchestrator unit tests.
//
// Covers:
//   * `parseSoakOrchestratorArgs` defaults + `--pod-ids` parsing + the
//     `K_REVISION` fallback.
//   * `runSoakOrchestrator` end-to-end against an in-process HTTP
//     server: it produces a Markdown report with the metric tables the
//     B-2B triage needs (request rate, p50/p95/p99, per-pod breakdown,
//     heap-snapshot section).
//   * Multi-pod capture path: when more than one pod id is supplied,
//     the report's per-pod breakdown enumerates each and the
//     "remote_capture_pending" note appears for pods beyond the first.
//   * URL guard: a non-preview / non-staging / non-localhost proxy URL
//     surfaces exit code 2 without touching the wire.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/pressure/p4_heap_snapshot_uploader.dart';
import '../../tool/pressure/p4_soak_orchestrator.dart';

/// Flutter's test binding installs an `HttpOverrides` that returns
/// HTTP 400 for every request. The orchestrator drives a real loopback
/// HTTP server, so we lift the override during the soak run.
Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

void main() {
  group('parseSoakOrchestratorArgs', () {
    test('defaults: localhost proxy, single pod from K_REVISION fallback',
        () {
      final opts = parseSoakOrchestratorArgs(const <String>[]);
      expect(opts.proxyUrl, 'http://localhost:8080');
      expect(opts.durationSeconds, 60);
      expect(opts.podIds, isNotEmpty);
      // On a local dev box without `K_REVISION` set, the fallback is
      // `local-dev`. CI hosts may set it; either is acceptable as long
      // as the list is non-empty.
    });

    test('parses --pod-ids as comma-separated list', () {
      final opts = parseSoakOrchestratorArgs(<String>[
        '--pod-ids=pod-a,pod-b,pod-c',
        '--proxy-url=http://localhost:8080',
      ]);
      expect(opts.podIds, <String>['pod-a', 'pod-b', 'pod-c']);
    });

    test('--workload-mix bounds-checked', () {
      expect(
        () => parseSoakOrchestratorArgs(<String>['--workload-mix=1.5']),
        throwsFormatException,
      );
    });

    test('--run-id pins the run identifier', () {
      final opts = parseSoakOrchestratorArgs(<String>[
        '--run-id=test-run-42',
      ]);
      expect(opts.runId, 'test-run-42');
    });
  });

  group('runSoakOrchestrator', () {
    late HttpServer server;
    late int requestCount;

    setUp(() async {
      requestCount = 0;
      server = await _withRealHttp(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );
      // Loopback echo: every request gets a 200 with a tiny body. The
      // orchestrator's request loop should drive several thousand of
      // these in a few seconds; the per-request latency is ~ms.
      server.listen((HttpRequest req) async {
        requestCount += 1;
        req.response.statusCode = 200;
        req.response.headers.set('content-type', 'application/json');
        req.response.write('{"ok": true}');
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test(
        'drives requests, computes percentiles, writes report; '
        'heap-snapshot section reports unconfigured target', () async {
      final tempDir =
          Directory.systemTemp.createTempSync('soak_orchestrator_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final opts = SoakOrchestratorOptions(
        proxyUrl: 'http://${server.address.host}:${server.port}',
        durationSeconds: 2,
        concurrency: 2,
        ops: 4,
        outputDir: tempDir.path,
        thinkTimeMs: 50,
        heapSnapshotIntervalSeconds: 300,
        metricsCheckpointSeconds: 30,
        runId: 'unit-test-1',
        podIds: const <String>['pod-alpha'],
        workloadMix: 0.0, // all session-only flow for faster turnover
      );

      // Unconfigured heap target: no env vars → uploader logs skipped.
      final heapTarget = AzureBlobHeapSnapshotUploadTarget(
        env: const <String, String>{},
      );
      final result = await _withRealHttp(
        () => runSoakOrchestrator(
          opts,
          heapUploadTarget: heapTarget,
          installSigintHandler: false,
          maxWallClock: const Duration(seconds: 4),
          logSink: _SilentSink(),
        ),
      );

      expect(result.exitCode, 0);
      expect(result.totalRequests, greaterThan(0));
      expect(result.successCount, equals(result.totalRequests));
      expect(result.requestsPerSecond, greaterThan(0));
      expect(result.heapSnapshotUploadCount, 0);
      expect(result.perPodCounts.keys, contains('pod-alpha'));

      // Report file exists and carries the required sections.
      final reportFile = File(result.reportPath);
      expect(reportFile.existsSync(), isTrue);
      final report = reportFile.readAsStringSync();
      expect(report, contains('# p4_soak_orchestrator — unit-test-1'));
      expect(report, contains('## Request volume + outcome'));
      expect(report, contains('## Latency percentiles (ms)'));
      expect(report, contains('## Per-pod breakdown'));
      expect(report, contains('| `pod-alpha` |'));
      expect(report, contains('## Heap snapshots'));
      expect(
        report,
        contains('Heap-snapshot upload skipped'),
        reason:
            'unconfigured Azure target → report records the skip reason',
      );
    });

    test('multi-pod: report enumerates every pod; non-first pods flagged '
        'as remote_capture_pending', () async {
      final tempDir =
          Directory.systemTemp.createTempSync('soak_orchestrator_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final opts = SoakOrchestratorOptions(
        proxyUrl: 'http://${server.address.host}:${server.port}',
        durationSeconds: 2,
        concurrency: 4,
        ops: 8,
        outputDir: tempDir.path,
        thinkTimeMs: 50,
        heapSnapshotIntervalSeconds: 300,
        metricsCheckpointSeconds: 30,
        runId: 'unit-test-multipod',
        podIds: const <String>['pod-a', 'pod-b', 'pod-c'],
        workloadMix: 0.0,
      );

      final logSink = _CapturingSink();
      addTearDown(() => logSink.close());
      final result = await _withRealHttp(
        () => runSoakOrchestrator(
          opts,
          heapUploadTarget: AzureBlobHeapSnapshotUploadTarget(
            env: const <String, String>{},
          ),
          installSigintHandler: false,
          maxWallClock: const Duration(seconds: 4),
          logSink: logSink,
        ),
      );

      expect(result.exitCode, 0);
      // All three pods should have at least one row in the breakdown,
      // and pod-b / pod-c get the "remote_capture_pending" note.
      final report = File(result.reportPath).readAsStringSync();
      expect(report, contains('| `pod-a` |'));
      expect(report, contains('| `pod-b` |'));
      expect(report, contains('| `pod-c` |'));
      expect(report, contains('remote_capture_pending'));

      // The orchestrator emits a "soak.heap_snapshot.deferred" line for
      // each non-first pod (TODO stub until the control-plane endpoint
      // lands). Assert at least two of those lines appeared in the log
      // stream for pod-b and pod-c.
      final deferredLines = logSink.lines
          .where((l) {
            try {
              final decoded = jsonDecode(l) as Map<String, Object?>;
              return decoded['metric'] == 'soak.heap_snapshot.deferred';
            } catch (_) {
              return false;
            }
          })
          .toList();
      expect(deferredLines.length, greaterThanOrEqualTo(2));
    });

    test('URL guard: a non-preview / non-staging / non-localhost URL '
        'exits with code 2 and never hits the wire', () async {
      final tempDir =
          Directory.systemTemp.createTempSync('soak_orchestrator_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final opts = SoakOrchestratorOptions(
        proxyUrl: 'https://prod-vendor.example.com',
        durationSeconds: 2,
        concurrency: 2,
        ops: 4,
        outputDir: tempDir.path,
        thinkTimeMs: 50,
        heapSnapshotIntervalSeconds: 300,
        metricsCheckpointSeconds: 30,
        runId: 'unit-test-url-guard',
        podIds: const <String>['pod-a'],
        workloadMix: 0.0,
      );
      final result = await runSoakOrchestrator(
        opts,
        heapUploadTarget: AzureBlobHeapSnapshotUploadTarget(
          env: const <String, String>{},
        ),
        installSigintHandler: false,
        maxWallClock: const Duration(seconds: 1),
        logSink: _SilentSink(),
      );
      expect(result.exitCode, 2);
      expect(requestCount, 0, reason: 'wire should never be touched');
    });
  });
}

/// Discards every line. Used to keep test output quiet without losing
/// the `IOSink` shape the orchestrator depends on.
class _SilentSink implements IOSink {
  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}

  @override
  Future<dynamic> close() async {}

  @override
  Future<dynamic> get done async {}

  @override
  Future<dynamic> flush() async {}

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {}
}

/// Captures every `writeln(...)` call into an in-memory buffer.
class _CapturingSink implements IOSink {
  final List<String> lines = <String>[];

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {
    lines.add(utf8.decode(data, allowMalformed: true).trimRight());
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}

  @override
  Future<dynamic> close() async {}

  @override
  Future<dynamic> get done async {}

  @override
  Future<dynamic> flush() async {}

  @override
  void write(Object? object) {
    final s = object?.toString();
    if (s != null && s.isNotEmpty) lines.add(s);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {
    lines.add(object?.toString() ?? '');
  }
}
