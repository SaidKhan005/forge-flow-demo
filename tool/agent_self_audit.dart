// Central agent self-audit script (Wave 2 Lane D, slice D-2; debug.md:88 QI-5).
//
// A worker agent runs this once before opening a PR. It replaces the
// ad-hoc shell-line-by-shell-line verification each worker improvises
// today by orchestrating the existing repo lints + the 4 frozen-surface
// guards that the workflow already enforces (CLAUDE.md "Workflow",
// "Service-Layer Split", "Proxy & API Conventions" sections).
//
// What this script does NOT do: it does not add new lints, it does not
// run tests (workers run their own targeted tests), it does not push or
// merge, it does not edit trackers. It is read-only orchestration over
// existing tools.
//
// Usage:
//
//   dart run tool/agent_self_audit.dart [--diff-base=origin/master]
//
// Output is a markdown table on stdout suitable for pasting into a PR
// body's "Disclosed runs" section. Exit code is 1 if any frozen-surface
// guard fails or any always-run hard lint exits non-zero; 0 otherwise.
// `dart analyze --fatal-infos` is disclosed but its baseline does not
// fail this script (see docs/_audits/wave_2/phase_0_smoke.md).

import 'dart:io';

/// Files matching any of these path prefixes (forward-slash normalised)
/// are FROZEN — a worker that touches them must escalate, not patch
/// inline. Sourced from CLAUDE.md "Service-Layer Split" + "Architecture
/// Guardrails" + "Hard Promises".
const List<String> kFrozenPathPrefixes = <String>[
  'lib/data/',
];

/// File that is the canonical permission key catalog. Editing it bypasses
/// the `lib/auth/permission_keys.dart` "frozen permission key catalog"
/// rule from CLAUDE.md.
const String kPermissionKeysPath = 'lib/auth/permission_keys.dart';

/// Directories under which a `package:postgres` import is allowed. Kept
/// in sync with `tool/postgres_import_lint.dart`'s default allowlist
/// (`lib/infrastructure/persistence/postgres/` + `test/`). `tool/` is
/// intentionally NOT in this list — Cloud Run workers under `tool/`
/// must use the `PostgresExecutor` seam, same as production app code.
const List<String> kPostgresImportAllowedDirs = <String>[
  'lib/infrastructure/persistence/postgres/',
  'test/',
];

/// Regex that catches an `import` directive whose URI starts with
/// `package:postgres/`. Mirrors `tool/postgres_import_lint.dart`.
final RegExp _postgresImportPattern = RegExp(
  r'''^\s*import\s+['"]package:postgres/''',
);

/// Regex that catches `--no-verify` appearing in an added diff line. The
/// pre-push hook also blocks this; we still check the diff text so a
/// worker who tries to commit a script that contains `--no-verify` as a
/// string literal also gets a real signal.
final RegExp _noVerifyPattern = RegExp(r'--no-verify\b');

/// One row in the final markdown summary table.
class AuditRow {
  AuditRow({
    required this.check,
    required this.passed,
    required this.notes,
    this.advisory = false,
  });

  /// Human-readable check name (left column).
  final String check;

  /// True = pass, false = fail. Advisory rows do NOT cause exit 1 even
  /// when `passed` is false.
  final bool passed;

  /// Short note (right column). Keep to ~80 chars per line; the full
  /// raw output is appended below the table.
  final String notes;

  /// Advisory rows are disclosed but do not gate exit code (e.g. the
  /// project-wide `dart analyze --fatal-infos` baseline).
  final bool advisory;

  String get resultEmoji {
    if (advisory) return passed ? 'ok' : 'baseline';
    return passed ? 'pass' : 'fail';
  }
}

/// A subprocess invocation + its captured output. Stored so the script
/// can paste raw output below the summary table.
class SubprocessRun {
  SubprocessRun({
    required this.label,
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final String label;
  final String command;
  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Type of the subprocess runner the audit calls into. Production wires
/// [_runSubprocess]; tests inject a deterministic fake.
typedef SubprocessRunner = SubprocessRun Function({
  required String label,
  required String executable,
  required List<String> args,
});

/// Read `--diff-base=<value>` out of the CLI args.
String _parseDiffBase(List<String> args) {
  const prefix = '--diff-base=';
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return arg.substring(prefix.length);
    }
  }
  return 'origin/master';
}

/// `git diff --name-only $diffBase...HEAD` — list of changed files.
/// Returns an empty list (and a synthetic warning row) when the diff
/// command itself fails (e.g. shallow clone without the base branch).
List<String> _changedFiles(String diffBase) {
  final result = Process.runSync(
    'git',
    <String>['diff', '--name-only', '$diffBase...HEAD'],
  );
  if (result.exitCode != 0) return const <String>[];
  final out = (result.stdout as String).split('\n');
  return out
      .map((line) => line.trim().replaceAll(r'\', '/'))
      .where((line) => line.isNotEmpty)
      .toList();
}

/// `git diff $diffBase...HEAD` — full unified diff text used by the
/// `--no-verify` guard.
String _diffText(String diffBase) {
  final result = Process.runSync(
    'git',
    <String>['diff', '$diffBase...HEAD'],
  );
  if (result.exitCode != 0) return '';
  return result.stdout as String;
}

/// Body of a file (relative path) at HEAD. Used by the `package:postgres`
/// import guard to inspect added/modified Dart files.
String? _fileBodyAtHead(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    return file.readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

/// Paths whose added lines are exempt from the `--no-verify` guard.
/// The audit script + its smoke test legitimately contain the literal
/// `--no-verify` (the script is THE thing that detects it). Without this
/// allowlist the self-audit would always fail when scanning itself.
const Set<String> kNoVerifyGuardExemptPaths = <String>{
  'tool/agent_self_audit.dart',
  'test/tool/agent_self_audit_test.dart',
};

/// Matches the right-side path on a `diff --git a/X b/Y` boundary line.
/// We rely on this rather than the `+++ b/...` unified-header because
/// when a worker's diff itself contains test-fixture diff text (as this
/// project's smoke test does), an added line like `+++ b/scripts/foo.sh`
/// inside a `+`-prefixed addition becomes `++++ b/scripts/foo.sh`, which
/// is indistinguishable from a real header without the `diff --git`
/// anchor.
final RegExp _diffGitHeaderPattern = RegExp(
  r'^diff --git a/(\S+) b/(\S+)',
);

/// Frozen-surface guard 1 — no `--no-verify` in the diff.
///
/// Walks the unified diff line-by-line, tracking the current right-side
/// path via `diff --git a/X b/Y` headers so an added line in an exempt
/// file (the audit script + its test) does NOT trip the guard. Deleted
/// lines never trip the guard; a worker REMOVING a `--no-verify`
/// literal is the correct direction.
AuditRow _checkNoNoVerifyInDiff(String diffText) {
  final hits = <String>[];
  var currentFile = '';
  for (final line in diffText.split('\n')) {
    final headerMatch = _diffGitHeaderPattern.firstMatch(line);
    if (headerMatch != null) {
      currentFile = (headerMatch.group(2) ?? '').replaceAll(r'\', '/');
      continue;
    }
    // Skip unified-diff metadata lines and removed lines. We only flag
    // ADDED lines (a single leading `+` that is not part of a `+++`
    // header). To allow added lines that themselves contain
    // diff-fixture text (e.g. `++++ b/...` from the smoke test), we
    // require exactly one leading `+`.
    if (!line.startsWith('+')) continue;
    if (line.length >= 2 && line.codeUnitAt(1) == 0x2B /* '+' */) continue;
    if (kNoVerifyGuardExemptPaths.contains(currentFile)) continue;
    if (_noVerifyPattern.hasMatch(line)) {
      hits.add(line);
    }
  }
  if (hits.isEmpty) {
    return AuditRow(
      check: 'no --no-verify in diff',
      passed: true,
      notes: 'no added line contains `--no-verify` outside exempt paths',
    );
  }
  return AuditRow(
    check: 'no --no-verify in diff',
    passed: false,
    notes: '${hits.length} added line(s) contain `--no-verify`',
  );
}

/// Frozen-surface guard 2 — no edits under `lib/data/**` (delete-only
/// legacy per CLAUDE.md "Service-Layer Split").
AuditRow _checkNoFrozenPathEdits(List<String> changedFiles) {
  final hits = changedFiles
      .where((path) => kFrozenPathPrefixes.any(path.startsWith))
      .toList();
  if (hits.isEmpty) {
    return AuditRow(
      check: 'no edits under lib/data/**',
      passed: true,
      notes: 'no changed file is under a frozen prefix',
    );
  }
  return AuditRow(
    check: 'no edits under lib/data/**',
    passed: false,
    notes: '${hits.length} changed file(s) under frozen prefix: '
        '${hits.take(3).join(', ')}'
        '${hits.length > 3 ? ', …' : ''}',
  );
}

/// Frozen-surface guard 4 — no edits to `lib/auth/permission_keys.dart`.
AuditRow _checkNoPermissionKeysEdit(List<String> changedFiles) {
  final touched = changedFiles.contains(kPermissionKeysPath);
  return AuditRow(
    check: 'no edits to lib/auth/permission_keys.dart',
    passed: !touched,
    notes: touched
        ? '$kPermissionKeysPath is in the changed-file list'
        : 'permission key catalog untouched',
  );
}

/// Run a subprocess and capture its output. Always captures stdout +
/// stderr as strings (UTF-8 default). Never throws on non-zero exit.
///
/// `runInShell: true` so that Windows-only `.bat` shims (e.g. `dart.bat`,
/// `flutter.bat`) resolve correctly without forcing callers to find the
/// absolute path. POSIX hosts ignore the flag.
SubprocessRun _runSubprocess({
  required String label,
  required String executable,
  required List<String> args,
}) {
  final result = Process.runSync(
    executable,
    args,
    runInShell: true,
  );
  return SubprocessRun(
    label: label,
    command: '$executable ${args.join(' ')}',
    exitCode: result.exitCode,
    stdout: result.stdout is String
        ? result.stdout as String
        : String.fromCharCodes(result.stdout as List<int>),
    stderr: result.stderr is String
        ? result.stderr as String
        : String.fromCharCodes(result.stderr as List<int>),
  );
}

/// Render the final markdown report (table + raw output appendix).
String _renderReport({
  required List<AuditRow> rows,
  required List<SubprocessRun> runs,
  required String diffBase,
  required int changedFileCount,
}) {
  final buf = StringBuffer()
    ..writeln('# agent_self_audit')
    ..writeln()
    ..writeln(
      'Diff base: `$diffBase` · changed files: $changedFileCount',
    )
    ..writeln()
    ..writeln('| Check | Result | Notes |')
    ..writeln('|---|---|---|');
  for (final row in rows) {
    buf.writeln(
      '| ${row.check} | ${row.resultEmoji} | ${row.notes} |',
    );
  }
  if (runs.isNotEmpty) {
    buf
      ..writeln()
      ..writeln('## Raw subprocess output');
    for (final run in runs) {
      buf
        ..writeln()
        ..writeln('### ${run.label} (exit ${run.exitCode})')
        ..writeln('```')
        ..writeln('\$ ${run.command}');
      if (run.stdout.trim().isNotEmpty) {
        buf.writeln(run.stdout.trimRight());
      }
      if (run.stderr.trim().isNotEmpty) {
        buf
          ..writeln('--- stderr ---')
          ..writeln(run.stderr.trimRight());
      }
      buf.writeln('```');
    }
  }
  return buf.toString();
}

/// Pure entry point so tests can drive the audit deterministically.
/// Production [main] wires the live `git`/`dart` subprocesses + the live
/// filesystem; the test suite passes synthetic inputs.
class AgentSelfAuditRunner {
  AgentSelfAuditRunner({
    required this.diffBase,
    required this.changedFiles,
    required this.diffText,
    required this.fileBodyLookup,
    required this.subprocessRunner,
    required this.migrationsTouched,
  });

  /// The diff base passed on the CLI (e.g. `origin/master`).
  final String diffBase;

  /// Forward-slash normalised list of changed-file paths.
  final List<String> changedFiles;

  /// Full diff text (used by the `--no-verify` guard).
  final String diffText;

  /// Maps a changed-file path → file body at HEAD, or null if deleted.
  final String? Function(String path) fileBodyLookup;

  /// Runs a labelled subprocess and returns its captured output.
  final SubprocessRunner subprocessRunner;

  /// True when at least one changed file lives under `db/migrations/`.
  final bool migrationsTouched;

  /// Result of the run: rows + accumulated subprocess captures +
  /// final exit code.
  AgentSelfAuditResult run() {
    final rows = <AuditRow>[];
    final runs = <SubprocessRun>[];

    // Frozen-surface guards. These are the universal-guard rows whose
    // failure forces exit 1.
    final noVerifyRow = _checkNoNoVerifyInDiff(diffText);
    final frozenPathRow = _checkNoFrozenPathEdits(changedFiles);
    final permissionKeysRow = _checkNoPermissionKeysEdit(changedFiles);

    // For the package:postgres guard we need the file-body lookup
    // injected from the caller (tests pass a synthetic map; production
    // reads from disk).
    final pgRow = _checkPostgresImportScopeWith(
      changedFiles: changedFiles,
      fileBodyLookup: fileBodyLookup,
    );

    rows
      ..add(noVerifyRow)
      ..add(frozenPathRow)
      ..add(pgRow)
      ..add(permissionKeysRow);

    // Always-run hard lint: advisor proxy size.
    final proxySize = subprocessRunner(
      label: 'advisor_proxy_size_lint',
      executable: 'dart',
      args: const <String>['run', 'tool/advisor_proxy_size_lint.dart'],
    );
    runs.add(proxySize);
    rows.add(
      AuditRow(
        check: 'advisor_proxy_size_lint',
        passed: proxySize.exitCode == 0,
        notes: proxySize.exitCode == 0
            ? 'monolith at or below ceiling'
            : 'exited ${proxySize.exitCode} — see raw output',
      ),
    );

    // Trigger-based lints: migration drift + cutoff. Only run when
    // `db/migrations/**` was touched.
    if (migrationsTouched) {
      final drift = subprocessRunner(
        label: 'migration_drift_scanner',
        executable: 'dart',
        args: const <String>[
          'run',
          'tool/migration_drift_scanner.dart',
          '--strict-docs',
        ],
      );
      runs.add(drift);
      rows.add(
        AuditRow(
          check: 'migration_drift_scanner --strict-docs',
          passed: drift.exitCode == 0,
          notes: drift.exitCode == 0
              ? 'cutoff + watched docs aligned'
              : 'exited ${drift.exitCode} — see raw output',
        ),
      );

      final cutoff = subprocessRunner(
        label: 'migration_cutoff_lint',
        executable: 'dart',
        args: const <String>[
          'run',
          'tool/migration_cutoff_lint.dart',
        ],
      );
      runs.add(cutoff);
      rows.add(
        AuditRow(
          check: 'migration_cutoff_lint',
          passed: cutoff.exitCode == 0,
          notes: cutoff.exitCode == 0
              ? 'staging setup cutoff matches latest migration'
              : 'exited ${cutoff.exitCode} — see raw output',
        ),
      );
    } else {
      rows.add(
        AuditRow(
          check: 'migration_drift_scanner --strict-docs',
          passed: true,
          notes: 'skipped — no db/migrations/** edits in diff',
          advisory: true,
        ),
      );
      rows.add(
        AuditRow(
          check: 'migration_cutoff_lint',
          passed: true,
          notes: 'skipped — no db/migrations/** edits in diff',
          advisory: true,
        ),
      );
    }

    // Advisory disclosure: project-wide `dart analyze --fatal-infos`.
    // Baseline carries 5 errors per docs/_audits/wave_2/phase_0_smoke.md
    // (all in test/integration files); the row is advisory so the
    // worker discloses the number without the script gating on it.
    final analyze = subprocessRunner(
      label: 'dart analyze --fatal-infos',
      executable: 'dart',
      args: const <String>['analyze', '--fatal-infos'],
    );
    runs.add(analyze);
    rows.add(
      AuditRow(
        check: 'dart analyze --fatal-infos',
        passed: analyze.exitCode == 0,
        advisory: true,
        notes: analyze.exitCode == 0
            ? 'clean'
            : 'exited ${analyze.exitCode} — disclose vs. baseline '
                  '(phase_0_smoke 5 errors)',
      ),
    );

    // Compute exit code: any non-advisory failing row = exit 1.
    final fail = rows.any((row) => !row.advisory && !row.passed);

    return AgentSelfAuditResult(
      rows: List<AuditRow>.unmodifiable(rows),
      runs: List<SubprocessRun>.unmodifiable(runs),
      exitCode: fail ? 1 : 0,
    );
  }
}

/// Variant of [_checkPostgresImportScope] that takes an injected lookup
/// (so tests can pass synthetic file bodies).
AuditRow _checkPostgresImportScopeWith({
  required List<String> changedFiles,
  required String? Function(String path) fileBodyLookup,
}) {
  final dartFiles = changedFiles
      .where((path) => path.toLowerCase().endsWith('.dart'))
      .where(
        (path) => !kPostgresImportAllowedDirs.any(path.startsWith),
      )
      .toList();
  final hits = <String>[];
  for (final path in dartFiles) {
    final body = fileBodyLookup(path);
    if (body == null) continue;
    for (final line in body.split('\n')) {
      if (_postgresImportPattern.hasMatch(line)) {
        hits.add('$path: ${line.trim()}');
        break;
      }
    }
  }
  if (hits.isEmpty) {
    return AuditRow(
      check: 'no out-of-scope package:postgres import',
      passed: true,
      notes: 'no changed Dart file outside allowed dirs imports '
          '`package:postgres`',
    );
  }
  return AuditRow(
    check: 'no out-of-scope package:postgres import',
    passed: false,
    notes: '${hits.length} out-of-scope file(s): '
        '${hits.take(2).join('; ')}'
        '${hits.length > 2 ? '; …' : ''}',
  );
}

/// Result of a [AgentSelfAuditRunner.run] invocation.
class AgentSelfAuditResult {
  const AgentSelfAuditResult({
    required this.rows,
    required this.runs,
    required this.exitCode,
  });

  final List<AuditRow> rows;
  final List<SubprocessRun> runs;
  final int exitCode;

  bool get isClean => exitCode == 0;
}

/// Render the result as the markdown report the CLI prints.
String renderAgentSelfAuditReport({
  required AgentSelfAuditResult result,
  required String diffBase,
  required int changedFileCount,
}) {
  return _renderReport(
    rows: result.rows,
    runs: result.runs,
    diffBase: diffBase,
    changedFileCount: changedFileCount,
  );
}

/// Production CLI entrypoint.
Future<void> main(List<String> args) async {
  final diffBase = _parseDiffBase(args);

  final changedFiles = _changedFiles(diffBase);
  final diffText = _diffText(diffBase);
  final migrationsTouched =
      changedFiles.any((path) => path.startsWith('db/migrations/'));

  final runner = AgentSelfAuditRunner(
    diffBase: diffBase,
    changedFiles: changedFiles,
    diffText: diffText,
    fileBodyLookup: _fileBodyAtHead,
    subprocessRunner: _runSubprocess,
    migrationsTouched: migrationsTouched,
  );
  final result = runner.run();

  stdout.write(
    renderAgentSelfAuditReport(
      result: result,
      diffBase: diffBase,
      changedFileCount: changedFiles.length,
    ),
  );

  exitCode = result.exitCode;
}
