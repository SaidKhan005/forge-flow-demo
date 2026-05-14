// Wave 2 Q-2c — Firebase Test Lab gcloud runner wrapper.
//
// Wraps `gcloud firebase test android run` + `gcloud firebase test
// ios run` so the Q-2c soak orchestrator can fan a single matrix out
// over both lanes without re-implementing the gcloud argv shape.
//
// CLAUDE.md compliance:
//   * Hard Promise #2 — demo neutrality. The APK / IPA the runner
//     hands gcloud is built with `--dart-define=kDemoMode=true`. The
//     same code path serves prod once the demo flag is dropped.
//   * Hard Promise #7 — no client-side cloud creds. Production
//     wiring uses Workload Identity Federation through the env var
//     `GOOGLE_APPLICATION_CREDENTIALS_JSON` consumed by gcloud's own
//     auth plug; this file never reads the credential itself.
//   * Test-time only. No `lib/` import. The runner is invoked from
//     the soak orchestrator at `tool/firebase_test_lab/
//     firebase_test_lab_orchestrator.dart` (separate file — Q-2b's
//     orchestrator drives the per-path harness and is structurally
//     different from a matrix fan-out).
//
// Skip-when-unset contract:
//   The runner consults `FIREBASE_TEST_LAB_PROJECT_ID` env. When the
//   var is unset OR empty, [run] returns a [FirebaseTestLabRunResult]
//   with [FirebaseTestLabRunSkipReason.projectIdUnset]. The
//   orchestrator surfaces this as a clear "no cloud project
//   configured; structural matrix validation only" message rather
//   than hanging on a gcloud call that would fail with a confusing
//   auth error. No CI cost.
//
// Why a wrapper class (not a top-level function)
// ----------------------------------------------
// The unit test injects a fake process runner so the orchestrator
// can be exercised without invoking the real gcloud binary. A class
// holds the (env-loader, process-runner) seam in one place.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'firebase_test_lab_matrix.dart';

/// Env var the runner reads for the Test Lab project id. Production
/// deploys wire this through Cloud Run secret bindings; CI leaves it
/// unset on cost-discipline grounds.
const String kFirebaseTestLabProjectIdEnvVar = 'FIREBASE_TEST_LAB_PROJECT_ID';

/// Env var the runner consults for the gcloud binary path override.
/// Default is `gcloud` on `PATH`; some CI hosts pin a fully-qualified
/// path so the runner accepts an override.
const String kFirebaseTestLabGcloudPathEnvVar = 'FIREBASE_TEST_LAB_GCLOUD';

/// Env var the runner reads for the optional Test Lab results bucket.
/// When unset, gcloud writes results to the default
/// `gs://test-lab-…` bucket the project provisions automatically.
const String kFirebaseTestLabResultsBucketEnvVar =
    'FIREBASE_TEST_LAB_RESULTS_BUCKET';

/// Reason the runner refused to invoke gcloud. Captured as a discrete
/// value so the orchestrator can attribute skips in its report.
enum FirebaseTestLabRunSkipReason {
  /// `FIREBASE_TEST_LAB_PROJECT_ID` is unset / empty.
  projectIdUnset,

  /// The matrix has no entries for the requested lane (Android-only
  /// matrices skip the iOS lane and vice versa).
  emptyLane,

  /// `gcloud` binary not on PATH and no override supplied.
  gcloudUnavailable,
}

/// Outcome of one matrix run. Exposed so the orchestrator can build
/// its Markdown report and exit with a meaningful code.
class FirebaseTestLabRunResult {
  const FirebaseTestLabRunResult({
    required this.lane,
    required this.exitCode,
    required this.skipReason,
    required this.stdoutHead,
    required this.stderrHead,
    required this.invocationArgv,
  });

  /// Convenience for skip outcomes — no gcloud was invoked.
  factory FirebaseTestLabRunResult.skipped({
    required FirebaseTestLabLane lane,
    required FirebaseTestLabRunSkipReason reason,
    String? detail,
  }) {
    return FirebaseTestLabRunResult(
      lane: lane,
      exitCode: 0,
      skipReason: reason,
      stdoutHead: detail ?? '',
      stderrHead: '',
      invocationArgv: const <String>[],
    );
  }

  /// Which lane this result belongs to. Surfaces in the report.
  final FirebaseTestLabLane lane;

  /// Process exit code from gcloud, or 0 on a skip.
  final int exitCode;

  /// Reason this run was skipped, or null when gcloud was invoked.
  final FirebaseTestLabRunSkipReason? skipReason;

  /// Truncated stdout from the gcloud invocation.
  final String stdoutHead;

  /// Truncated stderr from the gcloud invocation.
  final String stderrHead;

  /// The argv that was passed to gcloud, or empty on a skip. Exposed
  /// so the orchestrator's report can show the exact invocation a
  /// reviewer would reproduce locally.
  final List<String> invocationArgv;

  /// True when the gcloud invocation completed with exit 0.
  bool get isPass => skipReason == null && exitCode == 0;

  /// True when the run was skipped (env / matrix gating).
  bool get wasSkipped => skipReason != null;

  Map<String, Object?> toJson() => <String, Object?>{
        'lane': lane.name,
        'exit_code': exitCode,
        'skip_reason': skipReason?.name,
        'stdout_head': stdoutHead,
        'stderr_head': stderrHead,
        'invocation_argv': invocationArgv,
      };
}

/// Process runner seam — the unit test injects a fake so the runner
/// can be exercised without actually invoking gcloud.
typedef FirebaseTestLabProcessRunner = Future<FirebaseTestLabProcessOutcome>
    Function(
  String command,
  List<String> arguments, {
  Map<String, String>? environment,
});

/// One process invocation outcome. Mirrors the soak orchestrator's
/// `ProcessOutcome` shape so the two harnesses use the same surface.
class FirebaseTestLabProcessOutcome {
  const FirebaseTestLabProcessOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

Future<FirebaseTestLabProcessOutcome> _defaultProcessRunner(
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
  return FirebaseTestLabProcessOutcome(
    exitCode: result.exitCode,
    stdout: result.stdout?.toString() ?? '',
    stderr: result.stderr?.toString() ?? '',
  );
}

/// Loader for the env vars the runner consults. Defaults to
/// `Platform.environment`; tests inject a deterministic map.
typedef FirebaseTestLabEnvLoader = String? Function(String name);

String? _defaultEnvLoader(String name) {
  final raw = Platform.environment[name];
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

/// The runner wrapper. Holds the env + process seams so tests can
/// drive the orchestrator without standing up gcloud.
class FirebaseTestLabRunner {
  FirebaseTestLabRunner({
    FirebaseTestLabEnvLoader? envLoader,
    FirebaseTestLabProcessRunner? processRunner,
  })  : _envLoader = envLoader ?? _defaultEnvLoader,
        _processRunner = processRunner ?? _defaultProcessRunner;

  final FirebaseTestLabEnvLoader _envLoader;
  final FirebaseTestLabProcessRunner _processRunner;

  /// Returns the resolved project id, or null when the env var is
  /// unset / empty. Exposed for the orchestrator's report banner.
  String? get projectId => _envLoader(kFirebaseTestLabProjectIdEnvVar);

  /// Returns the resolved gcloud binary path. Defaults to `gcloud`
  /// when no override is set.
  String get gcloudBinary =>
      _envLoader(kFirebaseTestLabGcloudPathEnvVar) ?? 'gcloud';

  /// Resolved results bucket, or null when unset. gcloud writes to a
  /// default bucket the project provisions automatically when unset.
  String? get resultsBucket => _envLoader(kFirebaseTestLabResultsBucketEnvVar);

  /// Build the gcloud argv for one lane of the matrix. Exposed so the
  /// unit test can assert the wire shape without actually invoking
  /// gcloud.
  List<String> buildArgvForLane({
    required FirebaseTestLabMatrix matrix,
    required FirebaseTestLabLane lane,
    required String appPath,
    required String? testPath,
  }) {
    final entries = lane == FirebaseTestLabLane.android
        ? matrix.androidEntries
        : matrix.iosEntries;
    if (entries.isEmpty) {
      throw StateError(
        'Cannot build argv for ${lane.name}: matrix has no entries '
        'for this lane',
      );
    }
    final laneSubcommand =
        lane == FirebaseTestLabLane.android ? 'android' : 'ios';
    final appFlag = lane == FirebaseTestLabLane.android ? '--app' : '--test';
    final argv = <String>[
      'firebase',
      'test',
      laneSubcommand,
      'run',
      '--type',
      'instrumentation',
      appFlag,
      appPath,
    ];
    if (testPath != null && testPath.isNotEmpty) {
      argv
        ..add('--test')
        ..add(testPath);
    }
    for (final entry in entries) {
      argv
        ..add('--device')
        ..add(entry.toGcloudDeviceFlag());
    }
    final bucket = resultsBucket;
    if (bucket != null) {
      argv
        ..add('--results-bucket')
        ..add(bucket);
    }
    argv
      ..add('--format')
      ..add('json');
    return argv;
  }

  /// Run one lane of the matrix. Returns a [FirebaseTestLabRunResult]
  /// the orchestrator can fold into its report. Refuses to invoke
  /// gcloud when [kFirebaseTestLabProjectIdEnvVar] is unset OR when
  /// the requested lane has no entries.
  Future<FirebaseTestLabRunResult> run({
    required FirebaseTestLabMatrix matrix,
    required FirebaseTestLabLane lane,
    required String appPath,
    String? testPath,
  }) async {
    final project = projectId;
    if (project == null) {
      return FirebaseTestLabRunResult.skipped(
        lane: lane,
        reason: FirebaseTestLabRunSkipReason.projectIdUnset,
        detail:
            '$kFirebaseTestLabProjectIdEnvVar is unset on this host; '
            'the matrix was structurally validated but no gcloud '
            'invocation was performed. Set the env var to your Test '
            'Lab project id (e.g. `forge-flow-test-lab-prod`) to run '
            'the real matrix.',
      );
    }
    final entries = lane == FirebaseTestLabLane.android
        ? matrix.androidEntries
        : matrix.iosEntries;
    if (entries.isEmpty) {
      return FirebaseTestLabRunResult.skipped(
        lane: lane,
        reason: FirebaseTestLabRunSkipReason.emptyLane,
        detail:
            'matrix has no entries for the ${lane.name} lane; nothing '
            'to invoke.',
      );
    }
    final argv = buildArgvForLane(
      matrix: matrix,
      lane: lane,
      appPath: appPath,
      testPath: testPath,
    );
    // Inject `--project` so the gcloud config does not need to be
    // pre-pinned on the invoking host. We append it at the end of the
    // argv because gcloud accepts global flags before or after the
    // subcommand.
    argv
      ..add('--project')
      ..add(project);
    final outcome =
        await _processRunner(gcloudBinary, argv, environment: null);
    return FirebaseTestLabRunResult(
      lane: lane,
      exitCode: outcome.exitCode,
      skipReason: null,
      stdoutHead: _truncate(outcome.stdout, 8192),
      stderrHead: _truncate(outcome.stderr, 8192),
      invocationArgv: List<String>.unmodifiable(argv),
    );
  }
}

/// Truncate a captured stream head to [max] bytes so a chatty gcloud
/// invocation does not bloat the report JSONL. Mirrors the soak
/// orchestrator's `_truncate` helper to keep the two reports'
/// truncation behaviour identical.
String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}\n…(truncated)';

/// Encode a list of [FirebaseTestLabRunResult]s as a JSON document
/// the orchestrator's Markdown report references. Exposed so the
/// unit test can pin the wire shape.
String encodeResultsJson(List<FirebaseTestLabRunResult> results) {
  return jsonEncode(<String, Object?>{
    'result_count': results.length,
    'results': results.map((r) => r.toJson()).toList(growable: false),
  });
}
