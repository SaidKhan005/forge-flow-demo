// Phase 9 repo-lints — operator-scoped index leading-column.
//
// CLAUDE.md "RLS performance discipline" locks the rule:
//
//   Every fact-table B-tree index has `operator_id` (or
//   `(operator_id, location_id)`) as the leading column. Without this,
//   per-tenant RLS policy evaluation degrades from a single index probe
//   into a per-row filter — two orders of magnitude slower at scale.
//
// This lint walks `db/migrations/*.sql`, parses CREATE TABLE and
// ALTER TABLE ADD COLUMN statements to find tables that carry an
// `operator_id` column, then inspects every CREATE INDEX statement
// targeting one of those tables. If an index does not lead with
// `operator_id`, the lint fails. ALTER TABLE detection means a
// table that gains operator_id in a later migration (e.g.,
// `role_audit_log` in slice B.4) still flags non-leading indexes
// anywhere in the tree, including the original CREATE TABLE
// migration's own indexes.
//
// Cutoff: only files whose basenames sort lexicographically at or
// after `_indexLintCutoff` are scanned. Pre-cutoff migrations are
// out of scope (they captured the schema before the discipline was
// locked); they neither contribute to the operator-scoped table
// registry nor get scanned for index violations.
//
// Index-type scope: only B-tree indexes are linted. GIST/GIN/HASH/
// BRIN/SPGIST indexes do not benefit from a tenant-leading column the
// way a B-tree does (and PG cannot compose `(operator_id, ltree_path)`
// in a single GIST index, see 202604280002 `org_units_path_gist_idx`).
// Indexes whose CREATE INDEX statement carries `USING <method>` for a
// non-btree method are skipped.
//
// Partial-index NULL exemption: an index whose WHERE predicate
// constrains `operator_id IS NULL` covers system-wide rows that have
// no tenant. Leading with operator_id provides no value (the value is
// always NULL); these indexes are exempt.
//
// Targeted exemptions: a small hardcoded set of indexes is exempt
// because the index is for a cross-tenant infrastructure path that
// runs under `forge_admin BYPASSRLS` (e.g., the MFA factor-removal
// worker queue) or because the table is global config with nullable
// operator_id and uniqueness reads filter by another column first
// (e.g., feature_flags). The justification for each is recorded inline
// at the declaration. Adding a new exemption is an explicit code
// change reviewers see.
//
// Exposed surface:
//   * `IndexLeadingColumnLintRunner` — testable façade. Construct with
//     a map of filename → SQL body and an optional cutoff / exempt set.
//     Call `run()` for an `IndexLintResult`.
//   * `main(List<String>)` — CLI entrypoint that walks `db/migrations/`
//     and exits 1 on any error (warnings exit 0).
//
// Run locally:
//
//   dart run tool/index_leading_column_lint.dart
//
// CI wires this into the `repo-lints` job alongside
// `postgres_import_lint.dart` and `permission_key_lint.dart`.

import 'dart:io';

/// Cutoff prefix for migrations scanned by this lint. Files whose
/// basenames sort lexicographically before this string are skipped.
const String _indexLintCutoff = '202604250000';

/// Hardcoded exemptions. Each entry is `<filename>:<index_name>`.
///
/// Adding to this list is an explicit code change. Justifications
/// MUST be recorded inline so a future reviewer can answer "why is
/// this exempt?" without spelunking commits.
const Set<String> _defaultExemptions = <String>{
  // 202604250005 — `feature_flags` is global config with nullable
  // `operator_id` (one table holds global / operator-wide / location-
  // scoped flags). The two unique partial indexes below lead with
  // `flag_name` because admin reads filter by flag name first; the
  // operator/location columns are part of the uniqueness key, not the
  // RLS predicate. The table is admin-only and not on a tenant RLS hot
  // path.
  '202604250005_advisor_cloud_foundation.sql:feature_flags_operator_scope_idx',
  '202604250005_advisor_cloud_foundation.sql:feature_flags_location_scope_idx',

  // 202604250008 — three legacy `role_audit_log` indexes that pre-date
  // the operator_id column. Slice B.4 (migration
  // `202605010001_phase_9_b4_role_audit_log_operator_id.sql`) adds
  // operator_id via ALTER TABLE, drops these indexes via DROP INDEX
  // CONCURRENTLY, and creates operator-leading replacements. The
  // legacy CREATE INDEX statements remain in the shipped foundation
  // migration (we never edit shipped migrations); the indexes are
  // gone at runtime. Without this exemption the lint would error on
  // the foundation migration's text — ALTER-TABLE detection now
  // recognizes role_audit_log as operator-scoped — even though no
  // offending index exists in the live schema.
  '202604250008_auth_schema_foundation.sql:role_audit_log_role_changed_idx',
  '202604250008_auth_schema_foundation.sql:role_audit_log_user_role_changed_idx',
  '202604250008_auth_schema_foundation.sql:role_audit_log_changed_at_idx',

  // 202604300000 — Phase 9.UX.1 MFA factor-removal worker queue.
  // The "due" and "processing" indexes back the cross-tenant worker
  // poll that runs as `forge_admin` BYPASSRLS; tenant-scoped reads use
  // `mfa_factor_removal_active_idx` (operator-leading). Worker indexes
  // legitimately need the time column as the leading key for the
  // `execute_after`/`processing_started_at` ORDER BY scan.
  '202604300000_phase_9_mfa_factor_removal_requests.sql:mfa_factor_removal_due_idx',
  '202604300000_phase_9_mfa_factor_removal_requests.sql:mfa_factor_removal_processing_idx',
};

/// Severity of a lint finding.
enum IndexLintSeverity { error, warning }

/// One leading-column finding from the lint.
class IndexLintViolation {
  const IndexLintViolation({
    required this.fileName,
    required this.lineNumber,
    required this.tableName,
    required this.indexName,
    required this.leadingColumn,
    required this.severity,
    this.note = '',
  });

  /// File the violation lives in (basename, e.g.
  /// `202604300000_phase_9_mfa_factor_removal_requests.sql`).
  final String fileName;

  /// 1-based line number of the CREATE INDEX statement.
  final int lineNumber;

  /// Lowercase table name (no schema prefix).
  final String tableName;

  /// Lowercase index name.
  final String indexName;

  /// Leading column found in the index column list. Empty string if
  /// the column list could not be parsed.
  final String leadingColumn;

  final IndexLintSeverity severity;

  /// Free-form remediation hint or context (e.g. "see slice B.4").
  final String note;

  bool get isError => severity == IndexLintSeverity.error;
  bool get isWarning => severity == IndexLintSeverity.warning;

  @override
  String toString() {
    final tag = isError ? 'ERROR' : 'WARN';
    final extra = note.isEmpty ? '' : ' — $note';
    return '$tag $fileName:$lineNumber table=$tableName '
        'index=$indexName leading=$leadingColumn '
        'expected=operator_id$extra';
  }
}

/// Aggregate result of a lint run.
class IndexLintResult {
  const IndexLintResult({
    required this.violations,
    required this.scannedFileCount,
    required this.skippedPreCutoffCount,
    required this.operatorScopedTableCount,
  });

  final List<IndexLintViolation> violations;
  final int scannedFileCount;
  final int skippedPreCutoffCount;
  final int operatorScopedTableCount;

  Iterable<IndexLintViolation> get errors =>
      violations.where((v) => v.isError);

  Iterable<IndexLintViolation> get warnings =>
      violations.where((v) => v.isWarning);

  bool get hasErrors => errors.isNotEmpty;
  bool get hasWarnings => warnings.isNotEmpty;

  /// "Clean" means no errors. Warnings still allow the lint to pass.
  bool get isClean => !hasErrors;
}

/// In-memory façade so tests can drive the lint without touching the
/// filesystem.
class IndexLeadingColumnLintRunner {
  IndexLeadingColumnLintRunner({
    required this.files,
    this.cutoff = _indexLintCutoff,
    Set<String>? exemptions,
  }) : exemptions = exemptions ?? _defaultExemptions;

  /// Map of filename (basename) → SQL body. Production CLI populates
  /// this from `db/migrations/*.sql`; tests pass synthetic strings.
  final Map<String, String> files;

  /// Cutoff prefix. Files whose basenames sort lexicographically
  /// before this string are skipped entirely.
  final String cutoff;

  /// `<filename>:<index_name>` pairs exempt from the lint. See file
  /// header for justification policy.
  final Set<String> exemptions;

  IndexLintResult run() {
    var skipped = 0;
    final scanned = <String, String>{};
    for (final entry in files.entries) {
      if (entry.key.compareTo(cutoff) < 0) {
        skipped++;
        continue;
      }
      scanned[entry.key] = entry.value;
    }

    // Phase 1 — build the operator-scoped table registry from
    // CREATE TABLE statements across all in-scope files. Cross-file
    // because a CREATE INDEX in one migration may target a table
    // defined in an earlier migration.
    final operatorScopedTables = <String>{};
    for (final body in scanned.values) {
      operatorScopedTables.addAll(_extractOperatorScopedTables(body));
    }

    // Phase 2 — scan CREATE INDEX statements.
    final violations = <IndexLintViolation>[];
    for (final entry in scanned.entries) {
      _scanIndexes(
        fileName: entry.key,
        sqlBody: entry.value,
        operatorScopedTables: operatorScopedTables,
        out: violations,
      );
    }

    return IndexLintResult(
      violations: violations,
      scannedFileCount: scanned.length,
      skippedPreCutoffCount: skipped,
      operatorScopedTableCount: operatorScopedTables.length,
    );
  }

  // ─── CREATE TABLE / ALTER TABLE extraction ──────────────────────

  /// Extracts table names that declare an `operator_id` column,
  /// either via CREATE TABLE in the file or via a later ALTER TABLE
  /// ADD COLUMN. The lint runs across every in-scope migration, so
  /// an operator_id added by a later slice (e.g.,
  /// `202605010001_phase_9_b4_role_audit_log_operator_id.sql` for
  /// `role_audit_log`) still flags non-leading indexes anywhere in
  /// the tree.
  Iterable<String> _extractOperatorScopedTables(String body) sync* {
    final stripped = _stripCommentsAndStrings(body);

    // CREATE TABLE … ( … operator_id … )
    for (final m in _createTablePattern.allMatches(stripped)) {
      final name = m.group(1)!.toLowerCase();
      // The pattern's last char is `(`; m.end is just past it.
      final inner = _readBalancedParens(stripped, m.end);
      if (inner == null) continue;
      if (_operatorIdColumnPattern.hasMatch(inner)) {
        yield name;
      }
    }

    // ALTER TABLE [IF EXISTS] [schema.]name … ADD COLUMN [IF NOT
    // EXISTS] operator_id <type> …
    //
    // The pattern is a single regex with a non-greedy run up to the
    // statement terminator (`[^;]*?`). It handles multi-clause ALTER
    // TABLE statements (e.g., several ADD COLUMNs in one statement)
    // and ignores incidental `operator_id` references inside FOREIGN
    // KEY / CHECK clauses by requiring `add column [if not exists]
    // operator_id <type-identifier>`.
    for (final m in _alterTableAddOperatorIdPattern.allMatches(stripped)) {
      yield m.group(1)!.toLowerCase();
    }
  }

  // ─── CREATE INDEX scanning ──────────────────────────────────────

  void _scanIndexes({
    required String fileName,
    required String sqlBody,
    required Set<String> operatorScopedTables,
    required List<IndexLintViolation> out,
  }) {
    final stripped = _stripCommentsAndStrings(sqlBody);
    for (final m in _createIndexPattern.allMatches(stripped)) {
      final indexName = (m.group(1) ?? '').toLowerCase();
      final tableName = (m.group(2) ?? '').toLowerCase();
      final usingMethod = (m.group(3) ?? '').toLowerCase();

      if (!operatorScopedTables.contains(tableName)) continue;

      // Skip non-btree indexes. Default (no USING clause) is btree;
      // any explicit method other than btree is exempt.
      if (usingMethod.isNotEmpty && usingMethod != 'btree') continue;

      // Skip exempt indexes.
      if (exemptions.contains('$fileName:$indexName')) continue;

      // m.end points just past the `(` of the column list.
      final colsInner = _readBalancedParens(stripped, m.end);
      if (colsInner == null) continue;
      final leadingCol = _firstColumnIdentifier(colsInner);
      // Where clause comes after the column list's closing `)`. Read
      // up to the next `;` outside parens.
      final afterCols = m.end + colsInner.length + 1; // skip past ')'
      final tail = _readUntilSemicolon(stripped, afterCols);

      // Partial-index NULL exemption: the index's row set must be
      // strictly restricted to `operator_id IS NULL`. A predicate that
      // merely mentions the phrase (e.g. `operator_id IS NULL OR
      // archived_at IS NULL`, or `NOT (operator_id IS NULL)`) does NOT
      // qualify — those leave tenant rows in the index.
      if (_predicateRestrictsToNullOperator(tail)) continue;

      // Acceptable leading columns:
      //   * `operator_id`
      //   * `(operator_id, location_id, …)` — already covered: the
      //     leading column is `operator_id`.
      if (leadingCol == 'operator_id') continue;

      out.add(IndexLintViolation(
        fileName: fileName,
        lineNumber: _lineNumberAt(sqlBody, m.start),
        tableName: tableName,
        indexName: indexName,
        leadingColumn: leadingCol,
        severity: IndexLintSeverity.error,
        note: 'B-tree index on operator-scoped table must lead with '
            'operator_id (RLS performance discipline)',
      ));
    }
  }
}

// ─── Regex patterns ───────────────────────────────────────────────

/// `CREATE TABLE [IF NOT EXISTS] [schema.]name (` — captures the
/// (lowercased) bare table name. Match end points just past the `(`.
final RegExp _createTablePattern = RegExp(
  r'''create\s+table\s+(?:if\s+not\s+exists\s+)?(?:[a-zA-Z_][\w$]*\.)?([a-zA-Z_][\w$]*)\s*\(''',
  caseSensitive: false,
);

/// `operator_id <type>` inside a CREATE TABLE body. Anchors on a line/
/// statement start (after `(` or `,`) so a FOREIGN KEY or CHECK clause
/// referencing `operator_id` is not mistaken for a column declaration.
/// Currently every `operator_id` column in the tree is `uuid`, but the
/// pattern accepts any identifier-shaped type so a future bigint /
/// custom-domain typed column is not silently missed.
final RegExp _operatorIdColumnPattern = RegExp(
  r'''(^|[,(])\s*operator_id\s+[a-zA-Z_][\w]*''',
  multiLine: true,
);

/// `ALTER TABLE [IF EXISTS] [schema.]name … ADD COLUMN [IF NOT
/// EXISTS] operator_id TYPE …` — captures the bare table name (g1).
/// Non-greedy `[^;]*?` between the table reference and the ADD
/// COLUMN clause keeps the match within a single statement (semi-
/// colons aren't allowed inside the run). The trailing identifier
/// shape after `operator_id` ensures we match a column declaration,
/// not a FOREIGN KEY / CHECK reference.
final RegExp _alterTableAddOperatorIdPattern = RegExp(
  r'''alter\s+table\s+(?:if\s+exists\s+)?(?:[a-zA-Z_][\w$]*\.)?([a-zA-Z_][\w$]*)[^;]*?\badd\s+column\s+(?:if\s+not\s+exists\s+)?operator_id\s+[a-zA-Z_]''',
  caseSensitive: false,
);

/// `CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON [schema.]table
/// [USING method] (` — captures index name (g1), bare table name (g2),
/// and the optional USING method (g3, possibly empty). Match end
/// points just past the `(` opening the column list.
final RegExp _createIndexPattern = RegExp(
  r'''create\s+(?:unique\s+)?index\s+(?:if\s+not\s+exists\s+)?([a-zA-Z_][\w$]*)\s+on\s+(?:[a-zA-Z_][\w$]*\.)?([a-zA-Z_][\w$]*)\s*(?:using\s+([a-zA-Z_][\w]*)\s*)?\(''',
  caseSensitive: false,
);

/// `operator_id IS NULL` matched as a complete conjunct (not part of a
/// larger expression). Used by [_predicateRestrictsToNullOperator] to
/// decide whether a partial-index `WHERE` clause genuinely confines
/// the index's row set to NULL-operator rows.
final RegExp _nullOperatorConjunct = RegExp(
  r'''^operator_id\s+is\s+null$''',
  caseSensitive: false,
);

/// Returns true when [tail] (everything between the index column
/// list's closing `)` and the statement terminator `;`) carries a
/// `WHERE` clause whose semantics strictly restrict the index's row
/// set to `operator_id IS NULL` rows.
///
/// The check splits the WHERE predicate on top-level `AND` (not `AND`
/// nested inside parens) and accepts the predicate only when at least
/// one conjunct is the bare `operator_id IS NULL` expression. Any of
/// the following patterns therefore do NOT qualify:
///
///   * `WHERE operator_id IS NULL OR archived_at IS NULL`
///     — single conjunct that's an OR; leaves tenant rows in scope.
///   * `WHERE NOT (operator_id IS NULL)`
///     — explicit negation; covers tenant rows.
///   * `WHERE archived_at IS NULL`
///     — the phrase isn't even mentioned.
///
/// Patterns that DO qualify:
///
///   * `WHERE operator_id IS NULL`
///   * `WHERE operator_id IS NULL AND foo = 'bar'`
///   * `WHERE foo = 'bar' AND (operator_id IS NULL)`
bool _predicateRestrictsToNullOperator(String tail) {
  final whereClause = _extractWhereClause(tail);
  if (whereClause == null) return false;
  for (final raw in _splitTopLevelAnd(whereClause)) {
    final stripped = _stripOuterParens(raw).trim().toLowerCase();
    if (_nullOperatorConjunct.hasMatch(stripped)) return true;
  }
  return false;
}

/// Returns the predicate that follows a top-level `WHERE` keyword in
/// [tail], or null if the tail has no top-level WHERE. "Top-level"
/// means outside any parenthesized sub-expression (e.g. `WITH (` or
/// `INCLUDE (` lists). Matches a whole-word `WHERE`.
String? _extractWhereClause(String tail) {
  var depth = 0;
  for (var i = 0; i < tail.length; i++) {
    final c = tail[i];
    if (c == '(') {
      depth++;
      continue;
    }
    if (c == ')') {
      if (depth > 0) depth--;
      continue;
    }
    if (depth != 0) continue;
    if (i + 5 > tail.length) continue;
    final slice = tail.substring(i, i + 5).toLowerCase();
    if (slice != 'where') continue;
    final beforeOk = i == 0 || !RegExp(r'\w').hasMatch(tail[i - 1]);
    final after = i + 5 < tail.length ? tail[i + 5] : ' ';
    final afterOk = !RegExp(r'\w').hasMatch(after);
    if (beforeOk && afterOk) {
      return tail.substring(i + 5);
    }
  }
  return null;
}

/// Splits [predicate] on the SQL `AND` keyword at parenthesis depth
/// zero. Whitespace boundaries on either side ensure the literal
/// substring "and" inside an identifier (e.g. `landed_at`) is not
/// treated as a split point. Returns the predicate verbatim as a
/// single-element list when no top-level AND is found.
List<String> _splitTopLevelAnd(String predicate) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  final lower = predicate.toLowerCase();
  for (var i = 0; i < predicate.length; i++) {
    final c = predicate[i];
    if (c == '(') {
      depth++;
      continue;
    }
    if (c == ')') {
      if (depth > 0) depth--;
      continue;
    }
    if (depth != 0) continue;
    // Match `\sand\s` (case-insensitive). The leading whitespace
    // anchor protects against matching the `and` suffix inside an
    // identifier; the trailing one against a prefix.
    if (i + 5 > predicate.length) continue;
    final slice = lower.substring(i, i + 5);
    if (slice == ' and ' ||
        slice == '\nand ' ||
        slice == '\tand ') {
      parts.add(predicate.substring(start, i));
      start = i + 5;
    }
  }
  parts.add(predicate.substring(start));
  return parts;
}

/// Recursively strips a balanced pair of outer parentheses from
/// [s].trim(). `((operator_id IS NULL))` → `operator_id IS NULL`.
/// Returns the input unchanged if the outer parens do not encompass
/// the entire string (e.g. `(a) AND (b)`).
String _stripOuterParens(String s) {
  var current = s.trim();
  while (current.startsWith('(') && current.endsWith(')')) {
    var depth = 0;
    var matched = true;
    for (var i = 0; i < current.length; i++) {
      if (current[i] == '(') {
        depth++;
      } else if (current[i] == ')') {
        depth--;
        if (depth == 0 && i != current.length - 1) {
          matched = false;
          break;
        }
      }
    }
    if (!matched || depth != 0) break;
    current = current.substring(1, current.length - 1).trim();
  }
  return current;
}

// ─── Parsing helpers ──────────────────────────────────────────────

/// Returns the substring inside the parentheses opened at [openEnd].
/// [openEnd] must be the index just past the `(` character. Returns
/// null if the parens are unbalanced (e.g. malformed input).
String? _readBalancedParens(String body, int openEnd) {
  var depth = 1;
  for (var i = openEnd; i < body.length; i++) {
    final c = body[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) {
        return body.substring(openEnd, i);
      }
    }
  }
  return null;
}

/// Returns the substring from [start] up to (but not including) the
/// next `;` outside any parens. Used to read the trailing portion of
/// a CREATE INDEX statement (column list already consumed) so the
/// WHERE predicate can be inspected without consuming the next
/// statement.
String _readUntilSemicolon(String body, int start) {
  var depth = 0;
  for (var i = start; i < body.length; i++) {
    final c = body[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      if (depth > 0) depth--;
    } else if (c == ';' && depth == 0) {
      return body.substring(start, i);
    }
  }
  return body.substring(start);
}

/// Extracts the leading column identifier from an index column list.
/// Skips a leading `(` if the inner string itself is wrapped (e.g.
/// `(col1 desc, col2)`). Returns the lowercased identifier or empty
/// string when nothing identifier-shaped is found at the head.
String _firstColumnIdentifier(String colsInner) {
  final trimmed = colsInner.trimLeft();
  // Strip a leading `(` if the parser passed in a wrapped fragment.
  final body = trimmed.startsWith('(') ? trimmed.substring(1) : trimmed;
  final m = RegExp(r'''[a-zA-Z_][\w$]*''').firstMatch(body);
  if (m == null) return '';
  return m.group(0)!.toLowerCase();
}

/// 1-based line number for [offset] in [body], using `\n` as the line
/// terminator. CRLF inputs are handled by the caller (see [main]).
int _lineNumberAt(String body, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < body.length; i++) {
    if (body[i] == '\n') line++;
  }
  return line;
}

/// Strips SQL comments and string/dollar-quoted literals while
/// preserving newlines so line numbers reported against the original
/// file are accurate. Output length matches input length character-
/// for-character; replaced regions become spaces (or kept newlines).
String _stripCommentsAndStrings(String sql) {
  final buf = StringBuffer();
  var i = 0;
  final n = sql.length;
  while (i < n) {
    final c = sql[i];
    if (c == '-' && i + 1 < n && sql[i + 1] == '-') {
      // line comment
      while (i < n && sql[i] != '\n') {
        buf.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < n && sql[i + 1] == '*') {
      // block comment
      buf.write('  ');
      i += 2;
      while (i + 1 < n && !(sql[i] == '*' && sql[i + 1] == '/')) {
        buf.write(sql[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i + 1 < n) {
        buf.write('  ');
        i += 2;
      } else if (i < n) {
        buf.write(' ');
        i++;
      }
      continue;
    }
    if (c == "'") {
      buf.write(' ');
      i++;
      while (i < n) {
        if (sql[i] == "'" && i + 1 < n && sql[i + 1] == "'") {
          buf.write('  ');
          i += 2;
          continue;
        }
        if (sql[i] == "'") {
          buf.write(' ');
          i++;
          break;
        }
        buf.write(sql[i] == '\n' ? '\n' : ' ');
        i++;
      }
      continue;
    }
    if (c == r'$') {
      // Detect `$tag$ ... $tag$` (PG dollar-quoted string). The tag is
      // an identifier (or empty for `$$`).
      final tagMatch = RegExp(r'^\$([a-zA-Z_]\w*)?\$').matchAsPrefix(sql, i);
      if (tagMatch != null) {
        final tag = tagMatch.group(0)!;
        final closeIdx = sql.indexOf(tag, i + tag.length);
        if (closeIdx >= 0) {
          final endExclusive = closeIdx + tag.length;
          for (var j = i; j < endExclusive; j++) {
            buf.write(sql[j] == '\n' ? '\n' : ' ');
          }
          i = endExclusive;
          continue;
        }
      }
      buf.write(c);
      i++;
      continue;
    }
    buf.write(c);
    i++;
  }
  return buf.toString();
}

/// Production CLI entrypoint.
Future<void> main(List<String> args) async {
  final dir = Directory('db/migrations');
  if (!dir.existsSync()) {
    stderr.writeln('index_leading_column_lint: db/migrations not found '
        '(run from repository root).');
    exitCode = 2;
    return;
  }

  final files = <String, String>{};
  final entries = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in entries) {
    final name = f.uri.pathSegments.last;
    files[name] = f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  final runner = IndexLeadingColumnLintRunner(files: files);
  final result = runner.run();

  stdout.writeln(
    'index_leading_column_lint: scanned ${result.scannedFileCount} '
    'in-scope migration(s); ${result.skippedPreCutoffCount} skipped '
    '(pre-cutoff $_indexLintCutoff); '
    '${result.operatorScopedTableCount} operator-scoped table(s) registered.',
  );

  if (result.violations.isEmpty) {
    stdout.writeln('index_leading_column_lint: clean — every B-tree '
        'index on an operator-scoped table leads with operator_id.');
    return;
  }

  if (result.warnings.isNotEmpty) {
    stdout.writeln('index_leading_column_lint: '
        '${result.warnings.length} warning(s):');
    for (final w in result.warnings) {
      stdout.writeln('  - $w');
    }
  }

  if (!result.hasErrors) {
    stdout.writeln('index_leading_column_lint: no errors. '
        'Warnings allowed; lint exits 0.');
    return;
  }

  stderr.writeln('index_leading_column_lint: '
      '${result.errors.length} error(s):');
  for (final e in result.errors) {
    stderr.writeln('  - $e');
  }
  stderr.writeln(
    'Fix: re-key the index so the leading column is operator_id (or '
    'add an explicit `WHERE operator_id IS NULL` predicate for system-'
    'wide rows). If the index is for a cross-tenant infrastructure '
    'path, add it to _defaultExemptions in this script with an inline '
    'justification.',
  );
  exitCode = 1;
}
