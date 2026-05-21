// Ignore-justification lint.
//
// Codifies an engineering bar from
// `docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §5.2 bar #7:
// every `// ignore:` directive in production / tooling sources must carry
// rationale that explains WHY the diagnostic is suppressed, not just
// restate it. A bare `// ignore: unused_element` is opaque to a future
// reader; the convention requires inline rationale on the same line OR
// an adjacent comment line within 2 lines above or below that names the
// reason (e.g. "kept for Phase 10.5 lever teaching surface").
//
// Scope: `lib/**` and `tool/**` Dart sources. Localization codegen
// (`lib/l10n/**`) and any `.g.dart` / `.freezed.dart` codegen files are
// exempt (those carry their own conventions). `// ignore_for_file:`
// top-of-file directives are out of scope.
//
// Convention enforced:
//   1. Inline rationale on the same line — `// ignore: foo - <reason>`
//      where the separator is ` - `, ` — ` (em dash, the only allowed
//      use inside a code comment), or `: `, and the trailing text has
//      at least 6 non-whitespace characters.
//   2. Adjacent rationale comment within 2 lines above OR below the
//      `// ignore:` directive, beginning with `//` (but NOT itself an
//      `// ignore:`) with at least 8 non-whitespace characters after
//      the `//`.
//
// Exposed surface:
//   * `IgnoreJustificationLintRunner` — testable façade over a
//     path → source map.
//   * `findIgnoreJustificationViolations` — pure scanner over one source
//     string.
//   * `main(List<String>)` — CLI entrypoint; exits 1 on any violation.
//
// Run locally:
//
//   dart run tool/ignore_justification_lint.dart
//
// Modeled on `tool/advisor_proxy_size_lint.dart` and
// `tool/ux_em_dash_lint.dart`.

import 'dart:io';

/// Directory roots the lint scans (recursively). Each root contributes
/// every `.dart` file underneath, except the exempt patterns below.
const List<String> kIgnoreJustificationRoots = <String>[
  'lib',
  'tool',
];

/// Path-substring exemptions. A file is skipped if its forward-slashed
/// path contains any of these substrings.
const List<String> kIgnoreJustificationExemptSubstrings = <String>[
  'lib/l10n/', // generated localization
  '.g.dart', // codegen
  '.freezed.dart', // codegen
];

/// Minimum non-whitespace character count for an inline rationale tail.
const int kInlineRationaleMinChars = 6;

/// Minimum non-whitespace character count for an adjacent rationale
/// comment body (the text after `//`).
const int kAdjacentRationaleMinChars = 8;

/// How many lines above and below an `// ignore:` directive may carry
/// an adjacent rationale comment.
const int kAdjacentRationaleWindow = 2;

class IgnoreJustificationViolation {
  const IgnoreJustificationViolation({
    required this.filePath,
    required this.lineNumber,
    required this.directive,
  });

  final String filePath;
  final int lineNumber;

  /// The full `// ignore: ...` directive text (trimmed), for the report.
  final String directive;

  @override
  String toString() =>
      '$filePath:$lineNumber: $directive - no rationale found within '
      '$kAdjacentRationaleWindow lines';
}

class IgnoreJustificationLintResult {
  const IgnoreJustificationLintResult({
    required this.violations,
    required this.scannedFileCount,
    required this.ignoreDirectiveCount,
  });

  final List<IgnoreJustificationViolation> violations;
  final int scannedFileCount;
  final int ignoreDirectiveCount;

  bool get isClean => violations.isEmpty;
}

class IgnoreJustificationLintRunner {
  IgnoreJustificationLintRunner({required this.files});

  /// Map of relative-path → Dart source.
  final Map<String, String> files;

  IgnoreJustificationLintResult run() {
    final violations = <IgnoreJustificationViolation>[];
    var directiveCount = 0;
    for (final entry in files.entries) {
      final path = entry.key.replaceAll(r'\', '/');
      final perFile = findIgnoreJustificationViolations(path, entry.value);
      violations.addAll(perFile.violations);
      directiveCount += perFile.directiveCount;
    }
    return IgnoreJustificationLintResult(
      violations: violations,
      scannedFileCount: files.length,
      ignoreDirectiveCount: directiveCount,
    );
  }
}

/// Per-file scan result.
class IgnoreJustificationFileScan {
  const IgnoreJustificationFileScan({
    required this.violations,
    required this.directiveCount,
  });
  final List<IgnoreJustificationViolation> violations;
  final int directiveCount;
}

/// Scans [source] line-by-line for `// ignore:` directives and returns
/// one violation per directive without rationale (inline OR adjacent).
/// `// ignore_for_file:` directives are skipped (out of scope).
IgnoreJustificationFileScan findIgnoreJustificationViolations(
  String filePath,
  String source,
) {
  final normalised = source.replaceAll('\r\n', '\n');
  final lines = normalised.split('\n');

  final violations = <IgnoreJustificationViolation>[];
  var directiveCount = 0;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final ignoreIdx = _findIgnoreDirectiveIndex(line);
    if (ignoreIdx < 0) continue;

    directiveCount++;

    final directiveText = line.substring(ignoreIdx).trim();
    final afterIgnore = _afterIgnorePrefix(directiveText);
    // `afterIgnore` is whatever follows `// ignore:` on this line, e.g.
    // ` unused_element — Phase 10.5 teaching` (lints + optional tail).

    if (_hasInlineRationale(afterIgnore)) continue;
    if (_hasAdjacentRationale(lines, i)) continue;

    violations.add(IgnoreJustificationViolation(
      filePath: filePath,
      lineNumber: i + 1,
      directive: directiveText,
    ));
  }

  return IgnoreJustificationFileScan(
    violations: violations,
    directiveCount: directiveCount,
  );
}

/// Returns the column index of `// ignore:` in [line] (NOT
/// `// ignore_for_file:`), or -1 if none.
///
/// Matches case-sensitively and requires the directive to live in a
/// `//` line comment (`//` followed by optional whitespace + `ignore:`).
/// Doc comments (`///` lines) are skipped entirely — they are
/// documentation prose, not directives, even if they mention the
/// literal text `// ignore:` inside a code span.
int _findIgnoreDirectiveIndex(String line) {
  final trimmed = line.trimLeft();
  // `///` doc comment: treat the whole line as prose, never a directive.
  // (Triple-slash is dartdoc. Quadruple-or-more (`////`) is also dartdoc
  // by convention.)
  if (trimmed.startsWith('///')) return -1;

  // Walk to a `//`, then check it's an `// ignore:` and not an
  // `// ignore_for_file:`. Skip any `//` that is actually the tail of a
  // `///` triple-slash (preceded by `/`).
  var idx = 0;
  while (true) {
    final found = line.indexOf('//', idx);
    if (found < 0) return -1;
    // Reject `///` (the `//` we found is actually positions 1..2 of a
    // `///` token, not the start of a `//` directive).
    if (found > 0 && line[found - 1] == '/') {
      idx = found + 2;
      continue;
    }
    // Reject `///` when the `//` we found IS at the start: check the
    // char after.
    if (found + 2 < line.length && line[found + 2] == '/') {
      idx = found + 2;
      continue;
    }
    final rest = line.substring(found + 2).trimLeft();
    if (rest.startsWith('ignore:')) {
      return found;
    }
    if (rest.startsWith('ignore_for_file:')) {
      return -1; // out of scope; treat as no match for this line.
    }
    idx = found + 2;
  }
}

/// Returns the part of [directiveText] after the `// ignore:` prefix.
/// `directiveText` is the trimmed slice starting at `//`.
String _afterIgnorePrefix(String directiveText) {
  // Strip `//`, leading whitespace, then `ignore:`.
  var rest = directiveText;
  if (rest.startsWith('//')) rest = rest.substring(2);
  rest = rest.trimLeft();
  if (rest.startsWith('ignore:')) rest = rest.substring('ignore:'.length);
  return rest;
}

/// True when [afterIgnore] (text after `// ignore:`) carries rationale on
/// the same line. Recognised separators: ` - `, ` — ` (em dash), ` : `,
/// and `: ` only when the colon is NOT part of the lints list (i.e. the
/// colon appears AFTER a separator-like context). We use a simple rule:
/// the first occurrence of any of ` - `, ` — `, ` : `, `: ` AFTER the
/// lints list. To avoid false-positive `: ` inside the lints list, we
/// require at least one of:
///   * ` - ` (space-dash-space)
///   * ` — ` (space-emdash-space)
///   * ` : ` (space-colon-space)
/// any of which is unambiguous as a rationale separator after the lints.
/// In all cases the tail must carry at least
/// [kInlineRationaleMinChars] non-whitespace characters.
bool _hasInlineRationale(String afterIgnore) {
  const separators = <String>[' - ', ' — ', ' : '];
  var earliest = -1;
  var earliestSepLen = 0;
  for (final sep in separators) {
    final idx = afterIgnore.indexOf(sep);
    if (idx >= 0 && (earliest < 0 || idx < earliest)) {
      earliest = idx;
      earliestSepLen = sep.length;
    }
  }
  if (earliest < 0) return false;
  final tail = afterIgnore.substring(earliest + earliestSepLen);
  return _nonWhitespaceCount(tail) >= kInlineRationaleMinChars;
}

/// True when at least one line within [lineIndex] +/- [kAdjacentRationaleWindow]
/// (excluding the directive line itself) is a `//` comment that is NOT
/// itself an `// ignore:` directive AND has at least
/// [kAdjacentRationaleMinChars] non-whitespace characters after `//`.
bool _hasAdjacentRationale(List<String> lines, int lineIndex) {
  for (var offset = -kAdjacentRationaleWindow;
      offset <= kAdjacentRationaleWindow;
      offset++) {
    if (offset == 0) continue;
    final neighbour = lineIndex + offset;
    if (neighbour < 0 || neighbour >= lines.length) continue;
    final raw = lines[neighbour];
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('//')) continue;

    // Skip block-comment markers like `///` only when paired with no body;
    // `///` and `////` are still line comments and CAN carry rationale.
    final afterSlash = trimmed.replaceFirst(RegExp(r'^/+\s*'), '');

    // Skip neighbours that are themselves `// ignore:` or
    // `// ignore_for_file:`.
    if (afterSlash.startsWith('ignore:') ||
        afterSlash.startsWith('ignore_for_file:')) {
      continue;
    }

    if (_nonWhitespaceCount(afterSlash) >= kAdjacentRationaleMinChars) {
      return true;
    }
  }
  return false;
}

int _nonWhitespaceCount(String text) {
  var n = 0;
  for (final r in text.runes) {
    if (r != 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) n++;
  }
  return n;
}

/// True when [path] (forward-slashed) is exempt from the lint.
bool _isExempt(String path) {
  for (final pattern in kIgnoreJustificationExemptSubstrings) {
    if (path.contains(pattern)) return true;
  }
  return false;
}

// ─── CLI entrypoint ──────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final files = <String, String>{};
  for (final root in kIgnoreJustificationRoots) {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      stderr.writeln(
        'ignore_justification_lint: scoped root not found: $root '
        '(run from repository root).',
      );
      exitCode = 2;
      return;
    }
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      if (_isExempt(rel)) continue;
      files[rel] = entity.readAsStringSync();
    }
  }

  final result = IgnoreJustificationLintRunner(files: files).run();

  if (result.isClean) {
    stdout.writeln(
      'ignore_justification_lint: scanned ${result.scannedFileCount} '
      'Dart file(s); ${result.ignoreDirectiveCount} ignores; clean.',
    );
    return;
  }

  stderr.writeln(
    'ignore_justification_lint: ${result.violations.length} violation(s) '
    'across ${result.scannedFileCount} scanned file(s) '
    '(${result.ignoreDirectiveCount} ignore directive(s) total):',
  );
  for (final v in result.violations) {
    stderr.writeln('  $v');
  }
  stderr.writeln(
    'Fix: add inline rationale on the same line '
    '("// ignore: foo - <why>" with at least '
    '$kInlineRationaleMinChars non-whitespace chars in the tail) OR an '
    'adjacent "//" comment line within '
    '$kAdjacentRationaleWindow lines that explains WHY the diagnostic '
    'is suppressed (not just restating it). Authority: '
    'docs/_audits/code_health/code_hardening_plan_2026_05_21.md §5.2 '
    'bar #7.',
  );
  exitCode = 1;
}
