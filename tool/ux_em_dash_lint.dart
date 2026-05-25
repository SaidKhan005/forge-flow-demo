// UX no-em-dash law lint.
//
// Operator-facing copy never uses an em dash (U+2014 `—`) as punctuation
// or a separator. The em dash reads as engineering shorthand, renders
// inconsistently across the mobile/web/email surfaces, and is banned by
// the UX Writing Standard ("plain English, reads as training"). The
// canonical replacement is a colon for label/value separators
// (`'Barrio Legado: North Loop'`) or a full stop / comma when it joins
// clauses in prose.
//
// Scope: this lint is the automated backstop for the operator-facing
// rendering and content layers (screens, widgets, operator/admin web,
// the coaching-copy constants, email templates, and the demo display
// data that renders in those surfaces). The doctrine itself is broader
// (CLAUDE.md "House rules" + the UX Writing Standard memory): NO
// operator-facing string anywhere may carry an em dash. New UX surfaces
// must be added to [kUxCopyRoots] so the law keeps covering them.
//
// Deliberate carve-out: the standalone `'—'` glyph is the codebase's
// honest empty/missing-value sentinel (Metric Honesty Doctrine —
// `metric_pill.dart`, `daypart_table.dart`, `data_alignment_audit_panel
// .dart`). A literal whose content is only em dashes and whitespace is
// NOT prose; it is exempt.
//
// Rule: a Dart string literal in a scoped file is a violation when it
// contains U+2014 AND, after removing every U+2014 and whitespace, it
// still has content. Comments are skipped (the tokenizer parses code).
//
// Exposed surface:
//   * `UxEmDashLintRunner` — testable facade over a path→source map.
//   * `findUxEmDashViolations` — pure tokenizer over one source string.
//   * `main(List<String>)` — CLI entrypoint; exits 1 on any violation.

import 'dart:io';

/// Operator-facing rendering / content roots the law is enforced on.
/// A root may be a directory (recurse all `.dart`) or a single file.
const List<String> kUxCopyRoots = <String>[
  'lib/screens',
  'lib/widgets',
  'lib/operator_web/widgets',
  'lib/operator_web/screens',
  'lib/operator_web/router',
  'lib/operator_web/auth',
  'lib/admin/screens',
  'lib/admin/widgets',
  'lib/admin/admin_human_labels.dart',
  'lib/admin/admin_routes.dart',
  'lib/domain/constants/app_defaults.dart',
  'lib/services/email',
  'lib/infrastructure/persistence/sqlite/sqlite_database.dart',
  'lib/dev/demo_vendor_integration_state_fixture.dart',
];

/// The banned code point: EM DASH (U+2014).
const int _emDash = 0x2014;

class UxEmDashViolation {
  const UxEmDashViolation({
    required this.filePath,
    required this.lineNumber,
    required this.columnNumber,
    required this.literal,
  });

  final String filePath;
  final int lineNumber;
  final int columnNumber;

  /// The offending string literal text (quotes stripped, interpolation
  /// placeholders kept verbatim), truncated for the report.
  final String literal;

  String get _shownLiteral {
    final oneLine = literal.replaceAll('\n', r'\n');
    if (oneLine.length <= 80) return oneLine;
    return '${oneLine.substring(0, 77)}...';
  }

  @override
  String toString() {
    return '$filePath:$lineNumber:$columnNumber: operator-facing string '
        'contains an em dash (—) — UX no-em-dash law\n'
        '    "$_shownLiteral"';
  }
}

class UxEmDashLintResult {
  const UxEmDashLintResult({
    required this.violations,
    required this.scannedFileCount,
  });

  final List<UxEmDashViolation> violations;
  final int scannedFileCount;

  bool get isClean => violations.isEmpty;
}

class UxEmDashLintRunner {
  UxEmDashLintRunner({required this.files});

  /// Map of relative-path → Dart source.
  final Map<String, String> files;

  UxEmDashLintResult run() {
    final violations = <UxEmDashViolation>[];
    for (final entry in files.entries) {
      final path = entry.key.replaceAll(r'\', '/');
      violations.addAll(findUxEmDashViolations(path, entry.value));
    }
    return UxEmDashLintResult(
      violations: violations,
      scannedFileCount: files.length,
    );
  }
}

/// A string literal is prose when, after stripping every em dash and all
/// whitespace, it still has characters. A literal that is only em dashes
/// and whitespace is the honest empty-state sentinel and is exempt.
bool _isProse(String literal) {
  final stripped = String.fromCharCodes(
    literal.runes.where(
      (r) => r != _emDash && !_isWhitespace(r),
    ),
  );
  return stripped.isNotEmpty;
}

bool _isWhitespace(int rune) =>
    rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D;

/// Tokenizes [source] enough to extract string literals (skipping line
/// and nested block comments) and returns one violation per literal that
/// contains an em dash used as prose. String interpolation `${...}` and
/// `$ident` are kept verbatim inside the literal text; quotes that occur
/// inside a `${...}` expression do not terminate the string.
List<UxEmDashViolation> findUxEmDashViolations(
  String filePath,
  String source,
) {
  final violations = <UxEmDashViolation>[];
  final runes = source.runes.toList();
  var i = 0;
  var line = 1;
  var col = 1;

  void advanceTo(int next) {
    while (i < next) {
      if (runes[i] == 0x0A) {
        line++;
        col = 1;
      } else {
        col++;
      }
      i++;
    }
  }

  int peek(int offset) =>
      (i + offset) < runes.length ? runes[i + offset] : -1;

  while (i < runes.length) {
    final c = runes[i];

    // Line comment.
    if (c == 0x2F && peek(1) == 0x2F) {
      var j = i;
      while (j < runes.length && runes[j] != 0x0A) {
        j++;
      }
      advanceTo(j);
      continue;
    }

    // Block comment (Dart allows nesting).
    if (c == 0x2F && peek(1) == 0x2A) {
      var depth = 1;
      var j = i + 2;
      while (j < runes.length && depth > 0) {
        if (runes[j] == 0x2F && j + 1 < runes.length && runes[j + 1] == 0x2A) {
          depth++;
          j += 2;
          continue;
        }
        if (runes[j] == 0x2A && j + 1 < runes.length && runes[j + 1] == 0x2F) {
          depth--;
          j += 2;
          continue;
        }
        j++;
      }
      advanceTo(j);
      continue;
    }

    // String literal. Optional raw prefix `r`.
    final isRawPrefixed = c == 0x72 &&
        (peek(1) == 0x27 || peek(1) == 0x22);
    final quoteAt = isRawPrefixed ? i + 1 : i;
    final q = quoteAt < runes.length ? runes[quoteAt] : -1;
    if (q == 0x27 || q == 0x22) {
      final startLine = line;
      final startCol = col;
      final isRaw = isRawPrefixed;
      final triple = peek(quoteAt - i + 1) == q && peek(quoteAt - i + 2) == q;
      final delimLen = triple ? 3 : 1;
      final bodyStart = quoteAt + delimLen;

      final buf = StringBuffer();
      var j = bodyStart;
      var closed = false;
      while (j < runes.length) {
        final ch = runes[j];

        // Escape (non-raw only).
        if (!isRaw && ch == 0x5C && j + 1 < runes.length) {
          buf.writeCharCode(ch);
          buf.writeCharCode(runes[j + 1]);
          j += 2;
          continue;
        }

        // Interpolation: `${ ... }` (skip balanced braces verbatim) or
        // `$identifier`. Not active in raw strings.
        if (!isRaw && ch == 0x24 && j + 1 < runes.length) {
          if (runes[j + 1] == 0x7B) {
            var depth = 1;
            buf.writeCharCode(ch);
            buf.writeCharCode(runes[j + 1]);
            j += 2;
            while (j < runes.length && depth > 0) {
              final e = runes[j];
              if (e == 0x7B) depth++;
              if (e == 0x7D) depth--;
              buf.writeCharCode(e);
              j++;
            }
            continue;
          }
        }

        // Closing delimiter.
        if (ch == q) {
          if (!triple) {
            closed = true;
            j += 1;
            break;
          }
          if (j + 2 < runes.length && runes[j + 1] == q && runes[j + 2] == q) {
            closed = true;
            j += 3;
            break;
          }
        }

        buf.writeCharCode(ch);
        j++;
      }

      final literal = buf.toString();
      if (closed &&
          literal.runes.contains(_emDash) &&
          _isProse(literal)) {
        violations.add(UxEmDashViolation(
          filePath: filePath,
          lineNumber: startLine,
          columnNumber: startCol,
          literal: literal,
        ));
      }
      advanceTo(j);
      continue;
    }

    advanceTo(i + 1);
  }

  return violations;
}

// ─── CLI entrypoint ──────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final files = <String, String>{};
  for (final root in kUxCopyRoots) {
    final dir = Directory(root);
    final file = File(root);
    if (dir.existsSync()) {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.dart')) continue;
        final rel = entity.path.replaceAll(r'\', '/');
        files[rel] = entity.readAsStringSync();
      }
    } else if (file.existsSync()) {
      files[root] = file.readAsStringSync();
    } else {
      stderr.writeln(
        'ux_em_dash_lint: scoped root not found: $root '
        '(run from repository root).',
      );
      exitCode = 2;
      return;
    }
  }

  final result = UxEmDashLintRunner(files: files).run();

  stdout.writeln(
    'ux_em_dash_lint: scanned ${result.scannedFileCount} operator-facing '
    'file(s) across ${kUxCopyRoots.length} scoped root(s).',
  );

  if (result.isClean) {
    stdout.writeln(
      'ux_em_dash_lint: clean — no operator-facing string uses an em dash. '
      "(The standalone '—' empty-state sentinel is exempt.)",
    );
    return;
  }

  stderr.writeln(
    'ux_em_dash_lint: ${result.violations.length} violation(s):',
  );
  for (final v in result.violations) {
    stderr.writeln('  - $v');
  }
  stderr.writeln(
    'Fix: remove the em dash. Use a colon for label/value separators '
    "('Brand: Branch'), or a full stop / comma when it joins clauses in "
    "prose. The bare '—' missing-value glyph is allowed. UX no-em-dash "
    'law: CLAUDE.md "House rules" + UX Writing Standard.',
  );
  exitCode = 1;
}
