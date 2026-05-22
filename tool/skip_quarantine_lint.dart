// Skip-quarantine lint.
//
// Phase A (refactor-phase) test-integrity guardrail. A refactor must not
// silently disable test coverage: every skipped test in `test/**` is
// either self-documenting (its reason string explains WHY it is gated off)
// or quarantined (carries a matching row in
// `docs/KNOWN_FAILING_TESTS.md`). A skip that is neither — a bare
// `skip: true`, an empty/trivial reason, or an opaque "TODO"/"fixme" with
// no substance — is exactly the kind of coverage hole this lint exists to
// stop. Modeled on `tool/ignore_justification_lint.dart`: the bar is
// rationale that explains WHY, not a skip that merely turns the test off.
//
// What counts as a skip
// ---------------------
//   1. `skip:` named argument on `test(...)`, `group(...)`,
//      `testWidgets(...)` (and friends). The value may be a string literal,
//      an adjacent multi-line concatenated string, a `bool`, or an
//      identifier (e.g. `skip: skipReason`).
//   2. `@Skip(...)` annotations (file- or test-level).
//   3. `.skip(...)` invocations are NOT test skips in this codebase — they
//      are `Iterable.skip(n)` calls (e.g. `rows.skip(3).toList()`). The
//      lint deliberately ignores `.skip(` to avoid false positives; only
//      the two forms above gate a test.
//
// THE RULE (binding)
// ------------------
// A skip is ALLOWED without a `docs/KNOWN_FAILING_TESTS.md` row when its
// reason string is SELF-DOCUMENTING: it states WHY the test is gated off
// in plain terms. The canonical self-documenting case is an environment
// gate — a reason that mentions one of: requires / POSTGRES / live /
// staging / container / env var / `_env...` (and similar). Such tests run
// only when an operator supplies live infrastructure; they are healthy,
// not red. By the same standard a reason that clearly states a NON-env
// justification (an N/A condition such as "system-only table; not
// applicable", or a deliberate manual gate such as "timing-sensitive,
// enable manually if investigating a regression") is ALSO self-documenting
// — it explains WHY, which is the load-bearing property.
//
// A skip WITHOUT such a self-documenting reason — a boolean `skip: true`,
// an empty/whitespace reason, or a reason too short / too trivial to
// explain anything (`'TODO'`, `'fixme'`, `'broken'`, `'flaky'` with no
// further detail) — MUST have a matching row in
// `docs/KNOWN_FAILING_TESTS.md`, matched by the test file path or a clear
// identifier substring appearing in that doc's table. Otherwise it is a
// silent, undocumented coverage hole and the lint FAILS.
//
// Resolution by an `identifier` skip value (e.g. `skip: skipReason`): the
// identifier's nearest preceding assignment in the same file is resolved
// when it is initialised from a string literal or a known
// self-documenting helper (`postgresSkipReasonOrNull(...)`). When the
// initialiser cannot be resolved to a self-documenting string, the skip
// must be quarantined.
//
// Exposed surface:
//   * `SkipQuarantineLintRunner` — testable façade over a
//     path → source map plus the quarantine-doc text.
//   * `findSkipSites` — pure scanner over one source string.
//   * `classifySkip` — pure rule applied to one skip site.
//   * `main(List<String>)` — CLI entrypoint; exits 1 on any unjustified
//     skip, 0 otherwise.
//
// Run locally:
//
//   dart run tool/skip_quarantine_lint.dart
//
// Modeled on `tool/ignore_justification_lint.dart`.

import 'dart:io';

/// Directory root the lint scans (recursively) for `.dart` test files.
const String kSkipQuarantineTestRoot = 'test';

/// Path to the quarantine doc, relative to the repository root.
const String kKnownFailingTestsDoc = 'docs/KNOWN_FAILING_TESTS.md';

/// Substrings (case-insensitive) that mark a reason string as a
/// self-documenting environment / live-infrastructure gate.
const List<String> kEnvGateKeywords = <String>[
  'requires',
  'postgres',
  ' live', // " live" so we do not match e.g. "alive"; reasons say "real/live Postgres".
  'live ',
  'staging',
  'container',
  'env var',
  'environment',
  '_env', // helper convention: `$_envFlag`, `$_envLiveUrl`, etc.
  'dart-define',
  'set \$', // "set \$_envFlag=true" interpolations.
];

/// Trivial / opaque reason tokens that do NOT explain WHY a test is
/// disabled. A reason composed only of these (or shorter than
/// [kSelfDocReasonMinChars]) is NOT self-documenting.
const List<String> kTrivialReasonTokens = <String>[
  'todo',
  'fixme',
  'fix me',
  'broken',
  'flaky',
  'wip',
  'skip',
  'skipped',
  'disable',
  'disabled',
  'temp',
  'temporary',
  'xxx',
];

/// A reason string must carry at least this many non-whitespace
/// characters to be considered substantive enough to self-document.
const int kSelfDocReasonMinChars = 24;

/// Helper functions known to return a self-documenting (env-gated) skip
/// reason. A `skip: <identifier>` initialised from one of these resolves
/// as self-documenting.
const List<String> kSelfDocumentingHelpers = <String>[
  'postgresSkipReasonOrNull',
];

// ─── Models ──────────────────────────────────────────────────────────────────

/// One skip occurrence discovered in a source file.
class SkipSite {
  const SkipSite({
    required this.filePath,
    required this.lineNumber,
    required this.kind,
    required this.reason,
    required this.rawValueExpression,
  });

  final String filePath;
  final int lineNumber;

  /// `'skip-arg'` for a `skip:` named argument, `'annotation'` for `@Skip(`.
  final String kind;

  /// The resolved reason string when one could be extracted (literal value,
  /// concatenated literals, or a resolved identifier initialiser). `null`
  /// when the value is a boolean, an unresolvable identifier, or empty.
  final String? reason;

  /// The raw value expression as written in source (for the report), e.g.
  /// `true`, `skipReason`, or the first line of a string literal.
  final String rawValueExpression;

  String get locator => '$filePath:$lineNumber';
}

/// Why a skip is or is not acceptable.
enum SkipVerdict {
  /// Self-documenting reason (env gate or substantive WHY). Allowed.
  selfDocumenting,

  /// Not self-documenting, but a matching quarantine-doc row exists. Allowed.
  quarantined,

  /// Neither self-documenting nor quarantined. Violation.
  unjustified,
}

class SkipClassification {
  const SkipClassification({required this.site, required this.verdict});
  final SkipSite site;
  final SkipVerdict verdict;
  bool get isViolation => verdict == SkipVerdict.unjustified;
}

class SkipQuarantineLintResult {
  const SkipQuarantineLintResult({
    required this.classifications,
    required this.scannedFileCount,
  });

  final List<SkipClassification> classifications;
  final int scannedFileCount;

  List<SkipClassification> get violations =>
      classifications.where((c) => c.isViolation).toList();

  int get skipCount => classifications.length;
  bool get isClean => violations.isEmpty;
}

// ─── Runner ────────────────────────────────────────────────────────────────

class SkipQuarantineLintRunner {
  SkipQuarantineLintRunner({
    required this.files,
    required this.quarantineDoc,
  });

  /// Map of relative-path → Dart source for every scanned test file.
  final Map<String, String> files;

  /// Full text of `docs/KNOWN_FAILING_TESTS.md` (for substring matching).
  final String quarantineDoc;

  SkipQuarantineLintResult run() {
    final classifications = <SkipClassification>[];
    for (final entry in files.entries) {
      final path = entry.key.replaceAll(r'\', '/');
      final sites = findSkipSites(path, entry.value);
      for (final site in sites) {
        classifications.add(
          SkipClassification(
            site: site,
            verdict: classifySkip(site, quarantineDoc),
          ),
        );
      }
    }
    return SkipQuarantineLintResult(
      classifications: classifications,
      scannedFileCount: files.length,
    );
  }
}

// ─── Pure scanner ────────────────────────────────────────────────────────────

/// Scans [source] for skip sites: `skip:` named args and `@Skip(`
/// annotations. `.skip(` Iterable calls are deliberately ignored.
///
/// Line / `//` comment context is respected: a `skip:` or `@Skip(` that
/// appears inside a `//` line comment or a `///` doc comment is prose, not
/// a directive, and is skipped. (Block comments `/* */` are rare in this
/// suite and not specially handled; the keyword forms below do not appear
/// in block comments in `test/**`.)
List<SkipSite> findSkipSites(String filePath, String source) {
  final normalised = source.replaceAll('\r\n', '\n');
  final lines = normalised.split('\n');
  final sites = <SkipSite>[];

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    // `@Skip(` annotation.
    final annIdx = _indexOutsideComment(line, '@Skip(');
    if (annIdx >= 0) {
      final reason = _collectStringLiteral(lines, i, line.indexOf('@Skip(') + 6);
      sites.add(SkipSite(
        filePath: filePath,
        lineNumber: i + 1,
        kind: 'annotation',
        reason: reason,
        rawValueExpression: '@Skip(...)',
      ));
      continue;
    }

    // `skip:` named argument. Match the token at a word boundary so we do
    // not catch identifiers like `noSkip:` or doc references.
    final skipIdx = _findSkipArgIndex(line);
    if (skipIdx < 0) continue;

    final afterColon = line.substring(skipIdx + 'skip:'.length).trimLeft();
    final site = _buildSkipArgSite(
      filePath: filePath,
      lines: lines,
      lineIndex: i,
      afterColon: afterColon,
    );
    if (site != null) sites.add(site);
  }

  return sites;
}

/// Returns the index of a `skip:` named-arg token in [line] that is NOT in
/// a comment, NOT inside a string literal, and is at a word boundary
/// (the char before must not be an identifier char, so `noSkip:` /
/// `willSkip:` do not match, nor does `skip:` inside a test description
/// string such as `test('applicable-days skip: ...')`). Returns -1 if none.
int _findSkipArgIndex(String line) {
  final commentStart = _lineCommentStart(line);
  var idx = 0;
  while (true) {
    final found = line.indexOf('skip:', idx);
    if (found < 0) return -1;
    // Must be outside a `//` comment.
    if (commentStart >= 0 && found >= commentStart) return -1;
    // Must be outside a string literal (a `skip:` inside a quoted string is
    // prose — e.g. a test name — not a named argument).
    if (_isInsideStringLiteral(line, found)) {
      idx = found + 5;
      continue;
    }
    // Word boundary on the left: the char before must not be a letter,
    // digit, or `_` (else this is a tail of `noSkip:` / `willSkip:`).
    final ok = found == 0 || !_isIdentChar(line.codeUnitAt(found - 1));
    if (ok) return found;
    idx = found + 5;
  }
}

/// True when [col] in [line] is inside a single- or double-quoted string
/// literal. Walks the line tracking quote state, honouring backslash
/// escapes. Used to reject `skip:` matches that live inside a string.
bool _isInsideStringLiteral(String line, int col) {
  var inStr = false;
  String quote = '';
  for (var i = 0; i < col && i < line.length; i++) {
    final c = line[i];
    if (inStr) {
      if (c == r'\') {
        i++; // skip escaped char
        continue;
      }
      if (c == quote) inStr = false;
      continue;
    }
    if (c == "'" || c == '"') {
      inStr = true;
      quote = c;
    }
  }
  return inStr;
}

/// Builds a [SkipSite] for a `skip:` named argument given the text after
/// the colon. Resolves string literals (single or multi-line concatenated),
/// booleans, and identifiers (best-effort, via [_resolveIdentifierReason]).
/// Returns `null` when the text after the colon is not actually a value
/// (defensive; should not happen for a real named arg).
SkipSite? _buildSkipArgSite({
  required String filePath,
  required List<String> lines,
  required int lineIndex,
  required String afterColon,
}) {
  String? reason;
  String rawValue;

  if (afterColon.isEmpty || afterColon.startsWith("'") ||
      afterColon.startsWith('"')) {
    // String literal value, possibly empty on this line then continued.
    reason = _collectStringLiteralFromLines(lines, lineIndex);
    rawValue = afterColon.isEmpty ? '<string>' : _firstLiteralPreview(afterColon);
  } else if (afterColon.startsWith('true') || afterColon.startsWith('false')) {
    reason = null; // boolean skip carries no reason.
    rawValue = afterColon.startsWith('true') ? 'true' : 'false';
  } else {
    // Identifier or expression (e.g. `skipReason`, `kReason`,
    // `someHelper()`). Best-effort resolution within the same file.
    final ident = _leadingIdentifier(afterColon);
    rawValue = ident.isEmpty ? afterColon.trim() : ident;
    reason = _resolveIdentifierReason(lines, ident);
  }

  return SkipSite(
    filePath: filePath,
    lineNumber: lineIndex + 1,
    kind: 'skip-arg',
    reason: reason,
    rawValueExpression: rawValue,
  );
}

/// Resolves the reason string for a `skip: <identifier>` by finding the
/// identifier's nearest assignment in [lines]. Recognises:
///   * `final <ident> = '<literal>'...;` → the concatenated literal.
///   * `final <ident> = postgresSkipReasonOrNull(...);` (or another known
///     self-documenting helper) → a synthetic env-gate marker so the
///     classifier treats it as self-documenting.
/// Returns `null` when no resolvable initialiser is found.
String? _resolveIdentifierReason(List<String> lines, String ident) {
  if (ident.isEmpty) return null;
  final assignPattern =
      RegExp(r'\b' + RegExp.escape(ident) + r'\s*=\s*(.*)$');
  for (final line in lines) {
    final m = assignPattern.firstMatch(line);
    if (m == null) continue;
    final rhs = m.group(1)!.trimLeft();
    // Known self-documenting helper → synthesize an env-gate reason so the
    // classifier (keyword scan) treats this as self-documenting.
    for (final helper in kSelfDocumentingHelpers) {
      if (rhs.startsWith(helper)) {
        return 'resolved via $helper: requires live Postgres '
            '(POSTGRES_TEST_URL env var not set)';
      }
    }
    // String-literal initialiser.
    if (rhs.startsWith("'") || rhs.startsWith('"')) {
      return _joinAdjacentLiterals(rhs);
    }
  }
  return null;
}

// ─── Classification (the rule) ───────────────────────────────────────────────

/// Applies THE RULE (see file docstring) to one [site] given the full
/// [quarantineDoc] text.
SkipVerdict classifySkip(SkipSite site, String quarantineDoc) {
  if (_isSelfDocumenting(site.reason)) {
    return SkipVerdict.selfDocumenting;
  }
  if (_isQuarantined(site, quarantineDoc)) {
    return SkipVerdict.quarantined;
  }
  return SkipVerdict.unjustified;
}

/// A reason is self-documenting when it is a non-trivial string that EITHER
/// names an environment gate keyword OR is a substantive WHY (long enough
/// and not composed solely of trivial tokens).
bool _isSelfDocumenting(String? reason) {
  if (reason == null) return false;
  final trimmed = reason.trim();
  if (trimmed.isEmpty) return false;

  final lower = trimmed.toLowerCase();

  // Env-gate keyword → self-documenting regardless of length.
  for (final kw in kEnvGateKeywords) {
    if (lower.contains(kw)) return true;
  }

  // Otherwise require substance: long enough AND not just a trivial token.
  final nonWs = _nonWhitespaceCount(trimmed);
  if (nonWs < kSelfDocReasonMinChars) return false;
  if (_isTrivialOnly(lower)) return false;
  return true;
}

/// True when [lowerReason] is composed only of trivial tokens / punctuation
/// (e.g. `'TODO'`, `'fixme - flaky'`) with no explanatory content.
bool _isTrivialOnly(String lowerReason) {
  // Strip the trivial tokens; if nothing substantive remains, it is trivial.
  var residue = lowerReason;
  for (final tok in kTrivialReasonTokens) {
    residue = residue.replaceAll(tok, ' ');
  }
  residue = residue.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  // Residue of fewer than 8 letters/digits means the reason was essentially
  // all trivial tokens.
  return residue.replaceAll(' ', '').length < 8;
}

/// True when a quarantine-doc row matches this [site]: either the test file
/// path (or its basename / a path tail) appears in the doc, or — when no
/// path match — heuristically falls back to false (path is the reliable
/// match key; reason substrings are too noisy).
bool _isQuarantined(SkipSite site, String quarantineDoc) {
  final doc = quarantineDoc;
  final path = site.filePath; // already forward-slashed
  if (doc.contains(path)) return true;
  // Match on the basename without extension (e.g.
  // `operator_web_router_test`) and on a 2-segment path tail.
  final basename = path.split('/').last;
  if (basename.isNotEmpty && doc.contains(basename)) return true;
  final segs = path.split('/');
  if (segs.length >= 2) {
    final tail2 = segs.sublist(segs.length - 2).join('/');
    if (doc.contains(tail2)) return true;
  }
  return false;
}

// ─── String-literal collection helpers ──────────────────────────────────────

/// Collects a (possibly multi-line, adjacent-concatenated) string literal
/// starting at [startLine]'s value position. Used for `skip:` args whose
/// value begins on the same line OR on the following line(s).
String? _collectStringLiteralFromLines(List<String> lines, int startLine) {
  final buffer = StringBuffer();
  var foundAny = false;
  // Look at the value position on the start line and continue while the
  // following lines are adjacent string literals (Dart concatenation).
  for (var i = startLine; i < lines.length && i <= startLine + 12; i++) {
    final raw = lines[i];
    // On the start line, only consider text after `skip:`.
    final segment = i == startLine
        ? raw.substring(_findSkipArgIndex(raw) + 5)
        : raw;
    final literals = _extractLiterals(segment);
    if (literals.isEmpty) {
      // Stop once we've started collecting and hit a non-literal line, or
      // when the statement clearly terminates.
      if (foundAny) break;
      // If the start line had no literal (value on next line), keep going.
      if (i == startLine && _trimAfterSkip(raw).isEmpty) continue;
      // Start line has a non-string value (bool/identifier): no literal.
      if (i == startLine) return null;
      break;
    }
    for (final lit in literals) {
      buffer.write(lit);
    }
    foundAny = true;
    // A line ending in `,` or `);` terminates the value.
    final t = raw.trimRight();
    if (t.endsWith(',') || t.endsWith(');') || t.endsWith(')')) break;
  }
  return foundAny ? buffer.toString() : null;
}

/// Collects a string literal beginning at or after [col] on line
/// [startLine] (used for `@Skip(` annotations).
String? _collectStringLiteral(List<String> lines, int startLine, int col) {
  final buffer = StringBuffer();
  var foundAny = false;
  for (var i = startLine; i < lines.length && i <= startLine + 12; i++) {
    final segment = i == startLine ? lines[i].substring(col) : lines[i];
    final literals = _extractLiterals(segment);
    if (literals.isEmpty) {
      if (foundAny) break;
      continue;
    }
    for (final lit in literals) {
      buffer.write(lit);
    }
    foundAny = true;
    final t = lines[i].trimRight();
    if (t.endsWith(')') || t.endsWith('),')) break;
  }
  return foundAny ? buffer.toString() : null;
}

/// Joins adjacent string literals found in [rhs] (a single line's RHS) and
/// returns their concatenation, or `rhs` stripped of quotes when it is one
/// literal. Used for resolved identifier initialisers.
String _joinAdjacentLiterals(String rhs) {
  final lits = _extractLiterals(rhs);
  if (lits.isEmpty) return rhs;
  return lits.join();
}

/// Extracts the *contents* of every single- or double-quoted string
/// literal in [segment] (without the surrounding quotes), concatenated in
/// order. Handles escaped quotes minimally. Returns an empty list when no
/// literal is present.
List<String> _extractLiterals(String segment) {
  final out = <String>[];
  var i = 0;
  while (i < segment.length) {
    final c = segment[i];
    if (c == "'" || c == '"') {
      final quote = c;
      final sb = StringBuffer();
      i++;
      while (i < segment.length) {
        final ch = segment[i];
        if (ch == r'\' && i + 1 < segment.length) {
          // Keep the escaped char's literal value (good enough for keyword
          // scanning; we are not executing the string).
          sb.write(segment[i + 1]);
          i += 2;
          continue;
        }
        if (ch == quote) {
          i++;
          break;
        }
        sb.write(ch);
        i++;
      }
      out.add(sb.toString());
    } else {
      i++;
    }
  }
  return out;
}

String _firstLiteralPreview(String afterColon) {
  final lits = _extractLiterals(afterColon);
  if (lits.isEmpty) return afterColon.trim();
  final first = lits.first;
  return first.length <= 40 ? first : '${first.substring(0, 40)}...';
}

String _trimAfterSkip(String line) {
  final idx = _findSkipArgIndex(line);
  if (idx < 0) return line.trim();
  return line.substring(idx + 5).trim();
}

// ─── Comment / token helpers ─────────────────────────────────────────────────

/// Returns the column at which a `//` line comment begins in [line], or -1
/// if none. Quote-aware: a `//` inside a string literal is not a comment.
int _lineCommentStart(String line) {
  var inStr = false;
  String quote = '';
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (inStr) {
      if (c == r'\') {
        i++; // skip escaped char
        continue;
      }
      if (c == quote) inStr = false;
      continue;
    }
    if (c == "'" || c == '"') {
      inStr = true;
      quote = c;
      continue;
    }
    if (c == '/' && line[i + 1] == '/') return i;
  }
  return -1;
}

/// Returns the index of [token] in [line] when it appears OUTSIDE a `//`
/// line comment, else -1.
int _indexOutsideComment(String line, String token) {
  final idx = line.indexOf(token);
  if (idx < 0) return -1;
  final commentStart = _lineCommentStart(line);
  if (commentStart >= 0 && idx >= commentStart) return -1;
  return idx;
}

/// The leading identifier in [text] (`[A-Za-z_][A-Za-z0-9_]*`), or empty.
String _leadingIdentifier(String text) {
  final m = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)').firstMatch(text.trimLeft());
  return m == null ? '' : m.group(1)!;
}

bool _isIdentChar(int codeUnit) {
  // a-z A-Z 0-9 _
  return (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      codeUnit == 0x5F;
}

int _nonWhitespaceCount(String text) {
  var n = 0;
  for (final r in text.runes) {
    if (r != 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) n++;
  }
  return n;
}

// ─── CLI entrypoint ──────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final root = Directory(kSkipQuarantineTestRoot);
  if (!root.existsSync()) {
    stderr.writeln(
      'skip_quarantine_lint: test root not found: $kSkipQuarantineTestRoot '
      '(run from repository root).',
    );
    exitCode = 2;
    return;
  }

  final docFile = File(kKnownFailingTestsDoc);
  final quarantineDoc =
      docFile.existsSync() ? docFile.readAsStringSync().replaceAll(r'\', '/') : '';

  final files = <String, String>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.toLowerCase().endsWith('.dart')) continue;
    final rel = entity.path.replaceAll(r'\', '/');
    files[rel] = entity.readAsStringSync();
  }

  final result = SkipQuarantineLintRunner(
    files: files,
    quarantineDoc: quarantineDoc,
  ).run();

  if (result.isClean) {
    stdout.writeln(
      'skip_quarantine_lint: scanned ${result.scannedFileCount} test '
      'file(s); ${result.skipCount} skip(s); all self-documenting or '
      'quarantined; clean.',
    );
    return;
  }

  stderr.writeln(
    'skip_quarantine_lint: ${result.violations.length} unjustified skip(s) '
    'across ${result.scannedFileCount} scanned file(s) '
    '(${result.skipCount} skip(s) total):',
  );
  for (final v in result.violations) {
    final reasonPreview = v.site.reason == null
        ? '<no reason: ${v.site.rawValueExpression}>'
        : '"${v.site.reason}"';
    stderr.writeln('  ${v.site.locator}: ${v.site.kind} $reasonPreview');
  }
  stderr.writeln(
    'Fix: give the skip a SELF-DOCUMENTING reason that explains WHY it is '
    'gated off (an environment gate such as "requires live Postgres", an '
    'N/A justification, or a deliberate manual gate) OR add a matching row '
    'to $kKnownFailingTestsDoc keyed by the test file path. A bare '
    '`skip: true` or a trivial "TODO"/"flaky" reason is a silent coverage '
    'hole. Authority: refactor-phase test-integrity guardrail (Phase A A5).',
  );
  exitCode = 1;
}
