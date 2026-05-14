// Wave 2 Q-2b — orchestrator that drives the in-app notification
// Patrol harness end-to-end and emits a Markdown report.
//
// Mirrors `tool/pressure/p4_soak_orchestrator.dart`'s shape on
// purpose: same CLI flag style, same Markdown report sections, same
// `--run-id=` derivation rule, same SIGINT-drain behavior. The
// orchestrator's job is to fan four per-path tests out (sequentially
// or in parallel), capture pass/fail + per-path latency, and bottom
// out at a single human-readable report the operator can paste into
// a triage doc.
//
// Origin: `docs/_indices/WAVE_2_LEDGER.md` Lane Q row Q-2 (split into
// a/b/c on 2026-05-14). Q-2a (email soak) merged as PR #696. This
// orchestrator is the Q-2b half. Q-2c (Firebase Test Lab) extends
// the same harness with cloud-device matrix runs.
//
// Difference from `p4_soak_orchestrator.dart`:
//
//   - Drives `flutter test integration_test/in_app_notifications/`
//     (or `patrol test` when `--patrol-native=true`) rather than an
//     HTTP soak.
//   - "Workload mix" becomes a path filter (`--paths=invite,audit`
//     to skip path 3 + path 4 etc).
//   - Heap-snapshot and FD-watcher wiring are dropped — the Patrol
//     harness owns its own per-path budget, and the orchestrator's
//     report just attributes outcomes per path.
//   - The Markdown report adds a "Per-path coverage" section so the
//     orchestrator audit can see, at a glance, which paths exercised
//     the seed + which paths fell back to the stock `WidgetTester`.
//
// Usage
// -----
//   dart run tool/in_app_notification_soak/in_app_notification_soak_orchestrator.dart \
//     --output-dir=test/in_app_notification_soak \
//     --run-id=local
//
// Hard rules
// ----------
// - Refuses to run when `--patrol-native=true` is requested but the
//   Patrol CLI is not on PATH. Falls back to a clear error rather
//   than silently degrading.
// - Captures per-path `flutter test` exit code + wall time.
// - SIGINT cleanly drains the current path + flushes the report.
// - Never edits trackers, ledgers, or audit docs. Output lives under
//   `--output-dir` only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Canonical per-path test file names under
/// `integration_test/in_app_notifications/`. The keys are the short
/// labels the CLI flag `--paths=` accepts.
const Map<String, String> _kPathFiles = <String, String>{
  'invite': 'integration_test/in_app_notifications/'
      'invite_claimed_transition_test.dart',
  'audit': 'integration_test/in_app_notifications/'
      'audit_anchor_failure_alert_test.dart',
  'backfill': 'integration_test/in_app_notifications/'
      'first_connect_backfill_complete_test.dart',
  'disconnect': 'integration_test/in_app_notifications/'
      'vendor_disconnect_warning_test.dart',
};

/// CLI options for [runInAppNotificationSoakOrchestrator]. Shape
/// mirrors `SoakOrchestratorOptions` so a reviewer comparing the two
/// harnesses can scan a single diff.
class InAppNotificationSoakOptions {
  InAppNotificationSoakOptions({
    required this.outputDir,
    required this.runId,
    required this.pathFilter,
    required this.patrolNative,
    required this.parallel,
    required this.dartDefines,
    required this.flavor,
    required this.testCommand,
  });

  /// Output directory for the report + raw JSONL.
  final String outputDir;

  /// Stable identifier for this run. Embeds into the report filename
  /// + per-path attribution. Default derived from UTC timestamp.
  final String runId;

  /// Subset of `_kPathFiles` keys to run. Empty means "all four".
  final Set<String> pathFilter;

  /// When true, invoke `patrol test` instead of `flutter test`.
  /// Requires the Patrol CLI on PATH; the orchestrator refuses to
  /// run otherwise.
  final bool patrolNative;

  /// When true, drive paths concurrently. When false (default), each
  /// path runs sequentially so the report's per-path latency is not
  /// contaminated by emulator contention.
  final bool parallel;

  /// Additional `--dart-define=K=V` pairs (the harness always adds
  /// `kDemoMode=true` per HP #2 + the harness compile-time guard).
  final List<String> dartDefines;

  /// Flutter flavor. Default `forgeflow`.
  final String flavor;

  /// Override the underlying test command (defaults to `flutter` or
  /// `patrol` based on [patrolNative]). Exposed for the unit test
  /// that asserts the CLI shape without invoking the real binary.
  final String? testCommand;
}

const String _kDefaultOutputDir = 'test/in_app_notification_soak';
const String _kDefaultFlavor = 'forgeflow';

InAppNotificationSoakOptions parseInAppNotificationSoakArgs(
  List<String> args,
) {
  String outputDir = _kDefaultOutputDir;
  String? runIdOverride;
  Set<String> pathFilter = <String>{};
  bool patrolNative = false;
  bool parallel = false;
  final List<String> dartDefines = <String>[];
  String flavor = _kDefaultFlavor;
  String? testCommand;

  for (final raw in args) {
    if (!raw.startsWith('--')) continue;
    final eq = raw.indexOf('=');
    if (eq <= 0) continue;
    final key = raw.substring(2, eq);
    final value = raw.substring(eq + 1);
    switch (key) {
      case 'output-dir':
        outputDir = value;
        break;
      case 'run-id':
        runIdOverride = value;
        break;
      case 'paths':
        pathFilter = value
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet();
        for (final p in pathFilter) {
          if (!_kPathFiles.containsKey(p)) {
            throw FormatException(
              'Unknown path "$p". Known: ${_kPathFiles.keys.join(', ')}',
            );
          }
        }
        break;
      case 'patrol-native':
        patrolNative = value == 'true' || value == '1';
        break;
      case 'parallel':
        parallel = value == 'true' || value == '1';
        break;
      case 'dart-define':
        dartDefines.add(value);
        break;
      case 'flavor':
        flavor = value;
        break;
      case 'test-command':
        testCommand = value;
        break;
      default:
        stderr.writeln('warning: unknown flag --$key');
    }
  }

  final runId = runIdOverride ??
      'inappnotif-${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^\w]'), '_')}';

  return InAppNotificationSoakOptions(
    outputDir: outputDir,
    runId: runId,
    pathFilter: pathFilter,
    patrolNative: patrolNative,
    parallel: parallel,
    dartDefines: dartDefines,
    flavor: flavor,
    testCommand: testCommand,
  );
}

/// Per-path outcome. Used by the report builder.
class PathOutcome {
  PathOutcome({
    required this.pathKey,
    required this.testFile,
    required this.exitCode,
    required this.wallMs,
    required this.stdoutHead,
    required this.stderrHead,
    required this.runner,
  });

  final String pathKey;
  final String testFile;
  final int exitCode;
  final int wallMs;
  final String stdoutHead;
  final String stderrHead;

  /// Which test runner drove this path ("flutter" or "patrol").
  final String runner;

  bool get isPass => exitCode == 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'path_key': pathKey,
        'test_file': testFile,
        'exit_code': exitCode,
        'wall_ms': wallMs,
        'runner': runner,
        'stdout_head': stdoutHead,
        'stderr_head': stderrHead,
      };
}

/// Returned by [runInAppNotificationSoakOrchestrator] for tests to
/// assert on without re-reading the report file.
class InAppNotificationSoakResult {
  InAppNotificationSoakResult({
    required this.exitCode,
    required this.reportPath,
    required this.rawJsonlPath,
    required this.outcomes,
  });

  final int exitCode;
  final String reportPath;
  final String rawJsonlPath;
  final List<PathOutcome> outcomes;

  int get passCount => outcomes.where((o) => o.isPass).length;
  int get failCount => outcomes.where((o) => !o.isPass).length;
}

/// Shutdown signal — fired on SIGINT. Workers check + drain.
class _ShutdownSignal {
  final Completer<void> _completer = Completer<void>();
  bool _fired = false;
  bool get isFired => _fired;
  void fire() {
    if (_fired) return;
    _fired = true;
    if (!_completer.isCompleted) _completer.complete();
  }

  Future<void> get future => _completer.future;
}

/// Process runner abstraction — the unit test injects a fake so the
/// orchestrator can be exercised without actually spawning `flutter
/// test`.
typedef ProcessRunner = Future<ProcessOutcome> Function(
  String command,
  List<String> arguments, {
  Map<String, String>? environment,
});

/// One process invocation outcome. Exposed (not private) so tests can
/// construct fakes against the [ProcessRunner] typedef.
class ProcessOutcome {
  ProcessOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
  final int exitCode;
  final String stdout;
  final String stderr;
}

Future<ProcessOutcome> _defaultProcessRunner(
  String command,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    command,
    arguments,
    environment: environment,
    runInShell: true,
  );
  return ProcessOutcome(
    exitCode: result.exitCode,
    stdout: result.stdout?.toString() ?? '',
    stderr: result.stderr?.toString() ?? '',
  );
}

/// Builds the argv for one path invocation. Exposed for the unit
/// test so the wire shape can be asserted without spawning a real
/// process.
List<String> buildPathArgv({
  required InAppNotificationSoakOptions opts,
  required String testFile,
}) {
  final argv = <String>[];
  if (opts.patrolNative) {
    argv
      ..add('test')
      ..add('--target')
      ..add(testFile);
  } else {
    argv
      ..add('test')
      ..add(testFile);
  }
  argv
    ..add('--flavor')
    ..add(opts.flavor)
    ..add('--dart-define=kDemoMode=true');
  for (final d in opts.dartDefines) {
    argv.add('--dart-define=$d');
  }
  return argv;
}

/// Drive the harness. Returns an [InAppNotificationSoakResult] so
/// tests can assert without re-reading the report from disk.
Future<InAppNotificationSoakResult> runInAppNotificationSoakOrchestrator(
  InAppNotificationSoakOptions opts, {
  IOSink? logSink,
  DateTime Function()? clock,
  bool installSigintHandler = true,
  ProcessRunner? processRunner,
}) async {
  // ignore: close_sinks — stdout is owned by dart:io, not by this fn.
  final log = logSink ?? stdout;
  final now = clock ?? () => DateTime.now().toUtc();
  final runProcess = processRunner ?? _defaultProcessRunner;

  // Resolve the runner binary up front.
  final runnerBinary =
      opts.testCommand ?? (opts.patrolNative ? 'patrol' : 'flutter');

  // Refuse early if Patrol native was requested but the CLI is not on
  // PATH (matches the URL guard in p4_soak_orchestrator).
  if (opts.patrolNative && opts.testCommand == null) {
    final probe = await runProcess(runnerBinary, <String>['--version']);
    if (probe.exitCode != 0) {
      stderr.writeln(
        'FATAL: --patrol-native=true requires the patrol CLI on PATH. '
        'Install with `dart pub global activate patrol_cli` and re-run.',
      );
      return InAppNotificationSoakResult(
        exitCode: 2,
        reportPath: '',
        rawJsonlPath: '',
        outcomes: const <PathOutcome>[],
      );
    }
  }

  final outputDir = Directory(opts.outputDir);
  outputDir.createSync(recursive: true);
  final reportPath =
      '${outputDir.path}/in_app_notification_soak_${opts.runId}.md';
  final rawJsonlPath =
      '${outputDir.path}/in_app_notification_soak_${opts.runId}_raw.jsonl';
  final rawSink = File(rawJsonlPath).openWrite(mode: FileMode.write);

  final selectedPaths = opts.pathFilter.isEmpty
      ? _kPathFiles.keys.toList()
      : _kPathFiles.keys.where(opts.pathFilter.contains).toList();

  log.writeln('=== in_app_notification_soak_orchestrator plan ===');
  log.writeln('  run_id: ${opts.runId}');
  log.writeln('  runner: $runnerBinary');
  log.writeln('  patrol_native: ${opts.patrolNative}');
  log.writeln('  parallel: ${opts.parallel}');
  log.writeln('  flavor: ${opts.flavor}');
  log.writeln('  paths: ${selectedPaths.join(', ')}');
  log.writeln('===');

  final shutdown = _ShutdownSignal();
  StreamSubscription<ProcessSignal>? sigintSub;
  if (installSigintHandler) {
    try {
      sigintSub = ProcessSignal.sigint.watch().listen((_) {
        stderr.writeln('SIGINT received — draining current path');
        shutdown.fire();
      });
    } catch (_) {
      // Some hosts (test isolates) don't support sigint subscriptions.
    }
  }

  final runStart = now();
  final outcomes = <PathOutcome>[];

  Future<PathOutcome> runPath(String pathKey) async {
    final testFile = _kPathFiles[pathKey]!;
    final argv = buildPathArgv(opts: opts, testFile: testFile);
    log.writeln('[path] $pathKey -> $runnerBinary ${argv.join(' ')}');
    final pathStart = now();
    final outcome = await runProcess(runnerBinary, argv);
    final wallMs = now().difference(pathStart).inMilliseconds;
    final stdoutHead = _truncate(outcome.stdout, 4096);
    final stderrHead = _truncate(outcome.stderr, 4096);
    final result = PathOutcome(
      pathKey: pathKey,
      testFile: testFile,
      exitCode: outcome.exitCode,
      wallMs: wallMs,
      stdoutHead: stdoutHead,
      stderrHead: stderrHead,
      runner: runnerBinary,
    );
    rawSink.writeln(jsonEncode(result.toJson()));
    return result;
  }

  if (opts.parallel) {
    final futures = selectedPaths.map(runPath).toList();
    outcomes.addAll(await Future.wait(futures, eagerError: false));
  } else {
    for (final p in selectedPaths) {
      if (shutdown.isFired) break;
      outcomes.add(await runPath(p));
    }
  }

  await sigintSub?.cancel();
  await rawSink.flush();
  await rawSink.close();

  final runEnd = now();
  final totalWallSec = math.max(1, runEnd.difference(runStart).inSeconds);
  final passCount = outcomes.where((o) => o.isPass).length;
  final failCount = outcomes.where((o) => !o.isPass).length;

  final report = StringBuffer()
    ..writeln('# in_app_notification_soak_orchestrator — ${opts.runId}')
    ..writeln()
    ..writeln('| Setting | Value |')
    ..writeln('|---|---|')
    ..writeln('| Runner | `$runnerBinary` |')
    ..writeln('| Patrol native | ${opts.patrolNative} |')
    ..writeln('| Parallel | ${opts.parallel} |')
    ..writeln('| Flavor | `${opts.flavor}` |')
    ..writeln('| Started | ${runStart.toIso8601String()} |')
    ..writeln('| Ended | ${runEnd.toIso8601String()} |')
    ..writeln('| Wall seconds | $totalWallSec |')
    ..writeln('| Paths invoked | ${selectedPaths.length} |')
    ..writeln()
    ..writeln('## Outcome summary')
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|')
    ..writeln('| Paths pass | $passCount |')
    ..writeln('| Paths fail | $failCount |')
    ..writeln()
    ..writeln('## Per-path coverage')
    ..writeln()
    ..writeln('| Path | Test file | Runner | Exit | Wall (ms) |')
    ..writeln('|---|---|---|---|---|');
  for (final o in outcomes) {
    final status = o.isPass ? 'pass' : 'fail';
    report.writeln(
      '| `${o.pathKey}` | `${o.testFile}` | `${o.runner}` | $status (${o.exitCode}) | ${o.wallMs} |',
    );
  }
  report
    ..writeln()
    ..writeln('## Failure tails')
    ..writeln();
  final failed = outcomes.where((o) => !o.isPass).toList();
  if (failed.isEmpty) {
    report.writeln('_No failed paths in this run._');
  } else {
    for (final o in failed) {
      report
        ..writeln('### `${o.pathKey}` (exit ${o.exitCode})')
        ..writeln()
        ..writeln('stdout (head):')
        ..writeln()
        ..writeln('```')
        ..writeln(o.stdoutHead.isEmpty ? '_(no stdout)_' : o.stdoutHead)
        ..writeln('```')
        ..writeln()
        ..writeln('stderr (head):')
        ..writeln()
        ..writeln('```')
        ..writeln(o.stderrHead.isEmpty ? '_(no stderr)_' : o.stderrHead)
        ..writeln('```')
        ..writeln();
    }
  }

  File(reportPath).writeAsStringSync(report.toString());
  log.writeln('\nReport: $reportPath');
  log.writeln('Raw JSONL: $rawJsonlPath');

  return InAppNotificationSoakResult(
    exitCode: failCount == 0 ? 0 : 1,
    reportPath: reportPath,
    rawJsonlPath: rawJsonlPath,
    outcomes: outcomes,
  );
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}\n…(truncated)';

Future<void> main(List<String> args) async {
  final opts = parseInAppNotificationSoakArgs(args);
  final result = await runInAppNotificationSoakOrchestrator(opts);
  exit(result.exitCode);
}
