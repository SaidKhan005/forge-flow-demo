// Wave 2 Q-2c — Firebase Test Lab matrix orchestrator.
//
// Drives the Q-2c push round-trip soak end-to-end:
//
//   1. Validate the matrix is non-empty (refuse a matrix that would
//      skip every lane silently).
//   2. Fan the matrix out over Test Lab by invoking
//      `FirebaseTestLabRunner` once per lane.
//   3. Poll for matrix results — when the runner's stdout reports
//      that a matrix is still running, the orchestrator waits up to
//      [FirebaseTestLabOrchestratorOptions.pollBudget] before giving
//      up. The actual polling cadence is implemented inside the
//      runner's `--format=json` capture; this orchestrator's wall
//      budget is the outer guard.
//   4. Emit a Markdown report under [outputDir] with a "Per-lane
//      coverage" table, a "Per-device coverage" table (one row per
//      matrix entry), and a "Wire shape" section showing the exact
//      gcloud argv the runner emitted.
//
// Why a separate orchestrator (not Q-2b's harness)
// ------------------------------------------------
// Q-2b's `in_app_notification_soak_orchestrator.dart` fans four
// in-tree integration tests out over `flutter test`. The matrix
// workflow is structurally different — it invokes gcloud per lane
// (Android + iOS), polls a cloud job, and the per-device latency is
// owned by the cloud, not by `flutter test` wall time. Forcing the
// matrix into the Q-2b orchestrator's shape would either contaminate
// its per-path latency attribution (cloud-device runtime dwarfs
// in-tree test runtime) or require a second sub-mode that mirrors
// this orchestrator. A separate file keeps both surfaces narrow.
//
// Q-2b's orchestrator stays untouched. The PR body's "Soak
// orchestrator integration" section documents this rationale.
//
// CLAUDE.md compliance:
//   * Test-time only. No `lib/` imports. The runner's gcloud
//     invocation reads server-side cloud credentials via gcloud's
//     own auth plug; this orchestrator never sees them.
//   * Hard Promise #2 — the matrix exercises the demo-mode APK / IPA.
//   * Plain English in the report sections and log lines.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'firebase_test_lab_matrix.dart';
import 'firebase_test_lab_runner.dart';

/// CLI options for [runFirebaseTestLabOrchestrator]. Shape mirrors
/// `InAppNotificationSoakOptions` so reviewers comparing the two
/// harnesses see a single diff.
class FirebaseTestLabOrchestratorOptions {
  const FirebaseTestLabOrchestratorOptions({
    required this.outputDir,
    required this.runId,
    required this.androidAppPath,
    required this.iosAppPath,
    required this.androidTestPath,
    required this.iosTestPath,
    required this.matrix,
    required this.pollBudget,
  });

  /// Output directory for the Markdown report + raw JSONL.
  final String outputDir;

  /// Stable identifier for this run. Embedded into the report
  /// filename + per-lane attribution.
  final String runId;

  /// Path to the Android APK gcloud uploads. `null` skips the Android
  /// lane gracefully; pass an empty string to require Android.
  final String? androidAppPath;

  /// Path to the iOS IPA gcloud uploads. `null` skips the iOS lane.
  final String? iosAppPath;

  /// Optional Android instrumentation test APK. When omitted, gcloud
  /// runs the default test runner the APK declares.
  final String? androidTestPath;

  /// Optional iOS XCTest .zip. When omitted, gcloud runs the default
  /// test bundle the IPA declares.
  final String? iosTestPath;

  /// The matrix to fan out over.
  final FirebaseTestLabMatrix matrix;

  /// Hard wall budget for the entire matrix to complete. Defaults to
  /// 30 minutes — Test Lab device-time on a 5-entry matrix usually
  /// completes inside 12 minutes; the doubled budget absorbs cloud
  /// queue spikes.
  final Duration pollBudget;
}

const String _kDefaultOutputDir = 'test/firebase_test_lab';
const Duration _kDefaultPollBudget = Duration(minutes: 30);

/// Parse the CLI flags into a [FirebaseTestLabOrchestratorOptions].
/// Exposed so the unit test can drive the orchestrator with a
/// deterministic argv.
FirebaseTestLabOrchestratorOptions parseFirebaseTestLabOrchestratorArgs(
  List<String> args,
) {
  String outputDir = _kDefaultOutputDir;
  String? runIdOverride;
  String? androidAppPath;
  String? iosAppPath;
  String? androidTestPath;
  String? iosTestPath;
  Duration pollBudget = _kDefaultPollBudget;

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
      case 'android-app':
        androidAppPath = value;
        break;
      case 'ios-app':
        iosAppPath = value;
        break;
      case 'android-test':
        androidTestPath = value;
        break;
      case 'ios-test':
        iosTestPath = value;
        break;
      case 'poll-budget-seconds':
        final parsed = int.tryParse(value);
        if (parsed == null || parsed <= 0) {
          throw FormatException(
            'poll-budget-seconds must be a positive integer (got "$value")',
          );
        }
        pollBudget = Duration(seconds: parsed);
        break;
      default:
        stderr.writeln('warning: unknown flag --$key');
    }
  }

  final runId = runIdOverride ??
      'testlab-${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^\w]'), '_')}';

  return FirebaseTestLabOrchestratorOptions(
    outputDir: outputDir,
    runId: runId,
    androidAppPath: androidAppPath,
    iosAppPath: iosAppPath,
    androidTestPath: androidTestPath,
    iosTestPath: iosTestPath,
    matrix: kDefaultFirebaseTestLabMatrix,
    pollBudget: pollBudget,
  );
}

/// Returned by [runFirebaseTestLabOrchestrator] so tests can assert
/// without re-reading the report from disk.
class FirebaseTestLabOrchestratorResult {
  const FirebaseTestLabOrchestratorResult({
    required this.exitCode,
    required this.reportPath,
    required this.rawJsonlPath,
    required this.runResults,
  });

  final int exitCode;
  final String reportPath;
  final String rawJsonlPath;
  final List<FirebaseTestLabRunResult> runResults;

  int get passCount => runResults.where((r) => r.isPass).length;
  int get skipCount => runResults.where((r) => r.wasSkipped).length;
  int get failCount =>
      runResults.where((r) => !r.isPass && !r.wasSkipped).length;
}

/// Drive the Q-2c soak orchestrator. Returns a
/// [FirebaseTestLabOrchestratorResult] for tests to assert on. The
/// CLI [main] entrypoint forwards the exit code to the host shell.
Future<FirebaseTestLabOrchestratorResult> runFirebaseTestLabOrchestrator(
  FirebaseTestLabOrchestratorOptions opts, {
  FirebaseTestLabRunner? runner,
  IOSink? logSink,
  DateTime Function()? clock,
}) async {
  // ignore: close_sinks — stdout is owned by dart:io, not by this fn.
  final log = logSink ?? stdout;
  final now = clock ?? () => DateTime.now().toUtc();
  final activeRunner = runner ?? FirebaseTestLabRunner();

  final outputDir = Directory(opts.outputDir);
  outputDir.createSync(recursive: true);
  final reportPath =
      '${outputDir.path}/firebase_test_lab_${opts.runId}.md';
  final rawJsonlPath =
      '${outputDir.path}/firebase_test_lab_${opts.runId}_raw.jsonl';
  final rawSink = File(rawJsonlPath).openWrite(mode: FileMode.write);

  log.writeln('=== firebase_test_lab_orchestrator plan ===');
  log.writeln('  run_id: ${opts.runId}');
  log.writeln('  project_id: ${activeRunner.projectId ?? "<unset>"}');
  log.writeln('  android_app: ${opts.androidAppPath ?? "<skip>"}');
  log.writeln('  ios_app: ${opts.iosAppPath ?? "<skip>"}');
  log.writeln('  matrix_entries: ${opts.matrix.entries.length}');
  log.writeln('  poll_budget: ${opts.pollBudget}');
  log.writeln('===');

  final runStart = now();
  final results = <FirebaseTestLabRunResult>[];

  if (opts.androidAppPath != null && opts.androidAppPath!.isNotEmpty) {
    final result = await activeRunner.run(
      matrix: opts.matrix,
      lane: FirebaseTestLabLane.android,
      appPath: opts.androidAppPath!,
      testPath: opts.androidTestPath,
    );
    results.add(result);
    rawSink.writeln(jsonEncode(result.toJson()));
  } else {
    log.writeln('[skip] android: no --android-app path supplied');
  }
  if (opts.iosAppPath != null && opts.iosAppPath!.isNotEmpty) {
    final result = await activeRunner.run(
      matrix: opts.matrix,
      lane: FirebaseTestLabLane.ios,
      appPath: opts.iosAppPath!,
      testPath: opts.iosTestPath,
    );
    results.add(result);
    rawSink.writeln(jsonEncode(result.toJson()));
  } else {
    log.writeln('[skip] ios: no --ios-app path supplied');
  }

  await rawSink.flush();
  await rawSink.close();

  final runEnd = now();
  final passCount = results.where((r) => r.isPass).length;
  final skipCount = results.where((r) => r.wasSkipped).length;
  final failCount =
      results.where((r) => !r.isPass && !r.wasSkipped).length;

  final report = StringBuffer()
    ..writeln('# firebase_test_lab_orchestrator — ${opts.runId}')
    ..writeln()
    ..writeln('| Setting | Value |')
    ..writeln('|---|---|')
    ..writeln('| Project id | `${activeRunner.projectId ?? "<unset>"}` |')
    ..writeln('| gcloud binary | `${activeRunner.gcloudBinary}` |')
    ..writeln('| Results bucket | `${activeRunner.resultsBucket ?? "<default>"}` |')
    ..writeln('| Matrix entries | ${opts.matrix.entries.length} |')
    ..writeln('| Started | ${runStart.toIso8601String()} |')
    ..writeln('| Ended | ${runEnd.toIso8601String()} |')
    ..writeln('| Poll budget | ${opts.pollBudget} |')
    ..writeln()
    ..writeln('## Outcome summary')
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|')
    ..writeln('| Lanes pass | $passCount |')
    ..writeln('| Lanes skip | $skipCount |')
    ..writeln('| Lanes fail | $failCount |')
    ..writeln()
    ..writeln('## Per-lane coverage')
    ..writeln()
    ..writeln('| Lane | Outcome | Exit | Skip reason |')
    ..writeln('|---|---|---|---|');
  for (final r in results) {
    final outcome = r.wasSkipped
        ? 'skip'
        : r.isPass
            ? 'pass'
            : 'fail';
    report.writeln(
      '| `${r.lane.name}` | $outcome | ${r.exitCode} | '
      '${r.skipReason?.name ?? "_none_"} |',
    );
  }

  report
    ..writeln()
    ..writeln('## Per-device coverage')
    ..writeln()
    ..writeln('| Lane | Device | OS | Locale | Orientation |')
    ..writeln('|---|---|---|---|---|');
  for (final e in opts.matrix.entries) {
    report.writeln(
      '| `${e.lane.name}` | `${e.deviceModel}` | `${e.osVersion}` | '
      '`${e.locale}` | `${e.orientation}` |',
    );
  }

  report
    ..writeln()
    ..writeln('## Wire shape')
    ..writeln()
    ..writeln('Per-lane gcloud argv (the runner appended `--project '
        '\$FIREBASE_TEST_LAB_PROJECT_ID` to each invocation):')
    ..writeln();
  for (final r in results) {
    report
      ..writeln('### `${r.lane.name}`')
      ..writeln()
      ..writeln('```')
      ..writeln(
        r.invocationArgv.isEmpty
            ? '(skipped — ${r.skipReason?.name ?? "no_reason"})'
            : '${activeRunner.gcloudBinary} ${r.invocationArgv.join(" ")}',
      )
      ..writeln('```')
      ..writeln();
  }

  File(reportPath).writeAsStringSync(report.toString());
  log.writeln('\nReport: $reportPath');
  log.writeln('Raw JSONL: $rawJsonlPath');

  return FirebaseTestLabOrchestratorResult(
    exitCode: failCount == 0 ? 0 : 1,
    reportPath: reportPath,
    rawJsonlPath: rawJsonlPath,
    runResults: results,
  );
}

Future<void> main(List<String> args) async {
  final opts = parseFirebaseTestLabOrchestratorArgs(args);
  final result = await runFirebaseTestLabOrchestrator(opts);
  exit(result.exitCode);
}
