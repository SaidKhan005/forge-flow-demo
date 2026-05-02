// HARD-E — release dart-defines lint.
//
// Enforces that every release-eligible `flutter build` invocation in
// the GitHub Actions workflows passes
// `--dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true`. The flag opts
// the runtime auth client into the Firebase-backed path; release
// artifacts shipped without it would silently fall back to the
// in-memory dev path and fail the moment a user signs in.
//
// Rule: a `flutter build` step is "release-eligible" if the same
// command does not include `--debug` and does not include
// `--simulator`. `flutter build ipa` is implicitly release.
//
// The lint joins YAML continuation lines (anything starting with
// whitespace under a `run:` block, plus shell `\` line-continuations)
// so it does not get fooled by multi-line build commands.
//
// Exposed surface:
//   * `ReleaseDartDefinesLintRunner` — testable façade. Construct
//     with `{filePath: yamlBody}` and call `run()` for a result.
//   * `main(List<String>)` — CLI entrypoint. Walks
//     `.github/workflows/*.yml` and exits 1 on any violation.

import 'dart:io';

const String requiredDartDefine = 'FORGE_FLOW_USE_FIREBASE_AUTH=true';

/// One release-build step missing the required dart-define.
class ReleaseDartDefinesViolation {
  const ReleaseDartDefinesViolation({
    required this.filePath,
    required this.lineNumber,
    required this.command,
  });

  /// Workflow file the violation lives in (forward-slash relative
  /// path).
  final String filePath;

  /// 1-based line number where the `flutter build` command starts.
  final int lineNumber;

  /// The reconstructed (multi-line-joined) build command.
  final String command;

  @override
  String toString() {
    return '$filePath:$lineNumber: release `flutter build` is missing '
        '--dart-define=$requiredDartDefine\n'
        '    command: $command';
  }
}

/// Aggregate result of a lint run.
class ReleaseDartDefinesLintResult {
  const ReleaseDartDefinesLintResult({
    required this.violations,
    required this.scannedFileCount,
    required this.releaseBuildCount,
  });

  final List<ReleaseDartDefinesViolation> violations;
  final int scannedFileCount;
  final int releaseBuildCount;

  bool get isClean => violations.isEmpty;
}

class ReleaseDartDefinesLintRunner {
  ReleaseDartDefinesLintRunner({required this.files});

  /// Map of relative-path → workflow YAML body.
  final Map<String, String> files;

  ReleaseDartDefinesLintResult run() {
    final violations = <ReleaseDartDefinesViolation>[];
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
        final scalarStyle = _scalarStyleFor(lines, i);
        final command = _joinContinuation(lines, i, scalarStyle);
        i = command.endLineExclusive;
        if (!_isReleaseBuild(command.text)) {
          continue;
        }
        releaseBuildCount++;
        if (!command.text.contains(requiredDartDefine)) {
          violations.add(ReleaseDartDefinesViolation(
            filePath: path,
            lineNumber: start + 1,
            command: command.text.trim(),
          ));
        }
      }
    }
    return ReleaseDartDefinesLintResult(
      violations: violations,
      scannedFileCount: files.length,
      releaseBuildCount: releaseBuildCount,
    );
  }
}

class _Joined {
  const _Joined(this.text, this.endLineExclusive);
  final String text;
  final int endLineExclusive;
}

enum _ScalarStyle {
  /// `run: >` — folded; all content lines collapse into one logical
  /// command. Join greedily up to a less-indented line or a new list
  /// item.
  folded,

  /// `run: |` — literal; each line is its own command. Join only on
  /// explicit shell `\` continuations.
  literal,

  /// Unknown context (e.g., `flutter build` not under a `run:` key
  /// the lint can identify). Default to literal — it never
  /// over-joins.
  unknown,
}

/// Walks backward from [index] to the first line containing `run:`
/// and inspects the trailing block-scalar marker.
_ScalarStyle _scalarStyleFor(List<String> lines, int index) {
  for (var j = index - 1; j >= 0; j--) {
    final trimmed = lines[j].trim();
    if (trimmed.isEmpty) continue;
    if (!trimmed.contains('run:')) {
      // Crossed into a different key/list item without finding `run:`
      // — treat as unknown.
      if (_looksLikeYamlBoundary(trimmed)) return _ScalarStyle.unknown;
      continue;
    }
    final marker = trimmed.split('run:').last.trim();
    if (marker.startsWith('>')) return _ScalarStyle.folded;
    if (marker.startsWith('|')) return _ScalarStyle.literal;
    return _ScalarStyle.unknown;
  }
  return _ScalarStyle.unknown;
}

bool _looksLikeYamlBoundary(String trimmed) {
  // List item: `- ` (dash + whitespace) or a bare `-`. Crucially
  // NOT `--flag`, which is a CLI argument.
  if (trimmed == '-' || trimmed.startsWith('- ')) return true;
  // A bare key like `env:` or `with:` ends a `run:` scalar block.
  if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_-]*\s*:\s*$').hasMatch(trimmed)) {
    return true;
  }
  return false;
}

/// Joins the line at [start] with subsequent continuation lines.
///
/// Behavior depends on [style]:
///   * folded (`>`): join all subsequent lines at indent >=
///     firstIndent, stopping at a new list item or YAML boundary.
///   * literal (`|`) and unknown: join only on explicit shell `\`
///     line continuations.
_Joined _joinContinuation(List<String> lines, int start, _ScalarStyle style) {
  final firstIndent = _leadingSpaces(lines[start]);
  final buffer = StringBuffer(lines[start].trimRight());
  var i = start;
  while (i + 1 < lines.length) {
    final current = lines[i];
    final next = lines[i + 1];
    final trimmedCurrent = current.trimRight();
    final shellContinuation = trimmedCurrent.endsWith(r'\');
    var foldedContinuation = false;
    if (style == _ScalarStyle.folded && next.trim().isNotEmpty) {
      final nextIndent = _leadingSpaces(next);
      final trimmedNext = next.trim();
      foldedContinuation = nextIndent >= firstIndent &&
          !_looksLikeYamlBoundary(trimmedNext);
    }
    if (!shellContinuation && !foldedContinuation) break;
    if (shellContinuation) {
      final body = buffer.toString();
      buffer.clear();
      buffer.write(body.substring(0, body.length - 1));
    }
    buffer.write(' ');
    buffer.write(next.trim());
    i++;
  }
  return _Joined(buffer.toString(), i + 1);
}

int _leadingSpaces(String line) {
  var n = 0;
  for (final ch in line.codeUnits) {
    if (ch == 0x20) {
      n++;
    } else if (ch == 0x09) {
      n += 8;
    } else {
      break;
    }
  }
  return n;
}

/// Matches a `flutter build` invocation. The leading characters can
/// be anything (YAML run-block marker `>`, indentation, etc.).
final RegExp _flutterBuildPattern = RegExp(r'\bflutter\s+build\b');

bool _isReleaseBuild(String command) {
  // `flutter build ipa` is always release.
  if (RegExp(r'\bflutter\s+build\s+ipa\b').hasMatch(command)) {
    return true;
  }
  // `--debug` or `--simulator` opts the build out of release.
  if (command.contains('--debug')) return false;
  if (command.contains('--simulator')) return false;
  // Profile builds are not release artifacts.
  if (command.contains('--profile')) return false;
  // Any other `flutter build` is release-eligible (the default mode
  // for `flutter build apk`, `flutter build ios`, etc. is release).
  return true;
}

Future<void> main(List<String> args) async {
  const root = '.github/workflows';
  final dir = Directory(root);
  if (!dir.existsSync()) {
    stderr.writeln(
      'release_dart_defines_lint: $root not found '
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

  final runner = ReleaseDartDefinesLintRunner(files: files);
  final result = runner.run();

  stdout.writeln(
    'release_dart_defines_lint: scanned ${result.scannedFileCount} '
    'workflow file(s); ${result.releaseBuildCount} release-eligible '
    '`flutter build` step(s).',
  );
  if (result.isClean) {
    stdout.writeln(
      'release_dart_defines_lint: clean — every release `flutter build` '
      'passes --dart-define=$requiredDartDefine.',
    );
    return;
  }
  stderr.writeln(
    'release_dart_defines_lint: '
    '${result.violations.length} violation(s):',
  );
  for (final v in result.violations) {
    stderr.writeln('  - $v');
  }
  stderr.writeln(
    'Fix: add `--dart-define=$requiredDartDefine` to each release '
    '`flutter build` invocation listed above. Without the flag, the '
    'release artifact silently falls back to the in-memory auth path.',
  );
  exitCode = 1;
}
