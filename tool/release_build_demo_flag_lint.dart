// B1.A5 — Release-build demo-flag lint.
//
// Scans GitHub Actions workflow files for `flutter build` commands that
// pass any of the demo-auth elevation flags —
//   `ADMIN_DEMO_AUTH=true`, `OPERATOR_WEB_DEMO_AUTH=true`,
//   `kDemoMode=true`, or `FORGE_FLOW_DEMO_MODE=true`
// — as dart-define arguments without also passing `--debug` or `--profile`.
//
// A release artifact shipping with any of these true bypasses Firebase and
// exposes a privilege escalation surface on any publicly-routed Cloud Run
// service. The web/admin flags (`ADMIN_DEMO_AUTH`, `OPERATOR_WEB_DEMO_AUTH`)
// elevate the demo user in `lib/main_admin.dart` /
// `lib/main_operator_web.dart`; the mobile Forge&Flow flavor
// (`lib/main_forgeflow.dart`) elevates `demo.operator@forgeflow.test` to an
// F&F admin gated by `kDemoMode=true` / `FORGE_FLOW_DEMO_MODE=true`, so the
// parity flags are forbidden on release artifacts too. This lint is a
// belt-and-suspenders check on top of the `assert()` startup guards and the
// deploy scripts (which require an explicit `-DemoMode` switch with a
// warning).
//
// Rule: a `flutter build` command is a violation when:
//   (a) it is not a debug or profile build, AND
//   (b) it contains `ADMIN_DEMO_AUTH=true`, `OPERATOR_WEB_DEMO_AUTH=true`,
//       `kDemoMode=true`, or `FORGE_FLOW_DEMO_MODE=true`.
//
// Exposed surface:
//   * `ReleaseBuildDemoFlagLintRunner` — testable facade.
//   * `main(List<String>)` — CLI entrypoint; exits 1 on any violation.

import 'dart:io';

const List<String> _forbiddenFlags = <String>[
  'ADMIN_DEMO_AUTH=true',
  'OPERATOR_WEB_DEMO_AUTH=true',
  'kDemoMode=true',
  'FORGE_FLOW_DEMO_MODE=true',
];

class ReleaseBuildDemoFlagViolation {
  const ReleaseBuildDemoFlagViolation({
    required this.filePath,
    required this.lineNumber,
    required this.command,
    required this.flag,
  });

  final String filePath;
  final int lineNumber;
  final String command;

  /// Which of the forbidden flags was found.
  final String flag;

  @override
  String toString() {
    return '$filePath:$lineNumber: release `flutter build` passes '
        '--dart-define=$flag — this ships demo auth on a release artifact\n'
        '    command: $command';
  }
}

class ReleaseBuildDemoFlagLintResult {
  const ReleaseBuildDemoFlagLintResult({
    required this.violations,
    required this.scannedFileCount,
    required this.releaseBuildCount,
  });

  final List<ReleaseBuildDemoFlagViolation> violations;
  final int scannedFileCount;
  final int releaseBuildCount;

  bool get isClean => violations.isEmpty;
}

class ReleaseBuildDemoFlagLintRunner {
  ReleaseBuildDemoFlagLintRunner({required this.files});

  /// Map of relative-path → workflow YAML body.
  final Map<String, String> files;

  ReleaseBuildDemoFlagLintResult run() {
    final violations = <ReleaseBuildDemoFlagViolation>[];
    var releaseBuildCount = 0;

    for (final entry in files.entries) {
      final path = entry.key.replaceAll(r'\', '/');
      final lines = entry.value.split('\n');
      var i = 0;
      while (i < lines.length) {
        final line = lines[i];
        if (!_flutterBuildPattern.hasMatch(line)) {
          i++;
          continue;
        }
        final start = i;
        final command = _joinCommand(lines, i);
        i = command.endLineExclusive;
        if (!_isReleaseBuild(command.text)) continue;
        releaseBuildCount++;
        for (final flag in _forbiddenFlags) {
          if (command.text.contains(flag)) {
            violations.add(ReleaseBuildDemoFlagViolation(
              filePath: path,
              lineNumber: start + 1,
              command: command.text.trim(),
              flag: flag,
            ));
          }
        }
      }
    }

    return ReleaseBuildDemoFlagLintResult(
      violations: violations,
      scannedFileCount: files.length,
      releaseBuildCount: releaseBuildCount,
    );
  }
}

// ─── Internal helpers ────────────────────────────────────────────────────────

class _Joined {
  const _Joined(this.text, this.endLineExclusive);
  final String text;
  final int endLineExclusive;
}

final RegExp _flutterBuildPattern = RegExp(r'\bflutter\s+build\b');

bool _isReleaseBuild(String command) {
  if (command.contains('--debug')) return false;
  if (command.contains('--profile')) return false;
  if (command.contains('--simulator')) return false;
  return true;
}

/// Joins shell line-continuation (`\`) sequences into one logical command.
_Joined _joinCommand(List<String> lines, int start) {
  final buffer = StringBuffer(lines[start].trimRight());
  var i = start;
  while (i + 1 < lines.length) {
    final current = lines[i];
    if (!current.trimRight().endsWith(r'\')) break;
    final body = buffer.toString();
    buffer.clear();
    buffer.write(body.substring(0, body.length - 1));
    buffer.write(' ');
    buffer.write(lines[i + 1].trim());
    i++;
  }
  return _Joined(buffer.toString(), i + 1);
}

// ─── CLI entrypoint ──────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  const root = '.github/workflows';
  final dir = Directory(root);
  if (!dir.existsSync()) {
    stderr.writeln(
      'release_build_demo_flag_lint: $root not found '
      '(run from repository root).',
    );
    exitCode = 2;
    return;
  }

  final files = <String, String>{};
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final lower = entity.path.toLowerCase();
    if (!lower.endsWith('.yml') && !lower.endsWith('.yaml')) continue;
    final rel = entity.path.replaceAll(r'\', '/');
    files[rel] = entity.readAsStringSync();
  }

  final runner = ReleaseBuildDemoFlagLintRunner(files: files);
  final result = runner.run();

  stdout.writeln(
    'release_build_demo_flag_lint: scanned ${result.scannedFileCount} '
    'workflow file(s); ${result.releaseBuildCount} release-eligible '
    '`flutter build` step(s).',
  );

  if (result.isClean) {
    stdout.writeln(
      'release_build_demo_flag_lint: clean — no release build ships '
      'ADMIN_DEMO_AUTH=true, OPERATOR_WEB_DEMO_AUTH=true, '
      'kDemoMode=true, or FORGE_FLOW_DEMO_MODE=true.',
    );
    return;
  }

  stderr.writeln(
    'release_build_demo_flag_lint: '
    '${result.violations.length} violation(s):',
  );
  for (final v in result.violations) {
    stderr.writeln('  - $v');
  }
  stderr.writeln(
    'Fix: remove --dart-define=ADMIN_DEMO_AUTH=true / '
    '--dart-define=OPERATOR_WEB_DEMO_AUTH=true / '
    '--dart-define=kDemoMode=true / '
    '--dart-define=FORGE_FLOW_DEMO_MODE=true from release build steps. '
    'Demo auth must only be passed in debug/profile builds or behind an '
    'explicit deploy-script -DemoMode switch with a visible warning.',
  );
  exitCode = 1;
}
