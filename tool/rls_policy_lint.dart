// Phase 9.0Σ.b — RLS policy bare-GUC lint.
//
// Item 4 from `phase_9_scalability_decisions_2026-04-27.md` locks the
// rule that every operator-scoped RLS policy body MUST read tenant
// context through the wrapper functions defined in
// `db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql`
// (`app_current_operator()`, `app_current_location()`,
// `app_current_actor_user()`, `app_acting_as_operator()`) instead of
// inline `current_setting('app.<name>', ...)` calls. Bare
// `current_setting()` is not LEAKPROOF, which forces the planner to
// evaluate the policy at the row level rather than folding it into
// the tenant-leading index — two orders of magnitude slower at scale
// per the CLAUDE.md "RLS performance discipline" guardrail.
//
// This lint walks `db/migrations/*.sql`, isolates every CREATE POLICY
// statement, and fails if the body contains a bare
// `current_setting('app.` reference. Migrations whose policies are
// definitively superseded by a later wrapper-using rewrite are listed
// in `tool/rls_policy_lint_allowlist.txt`; the lint skips files in
// the allowlist.
//
// The lint is policy-aware on purpose. Plain prose (e.g. the comment
// header in `202604250008_auth_schema_foundation.sql` that reads
// "Phase 9.2 flips these to per-tenant policies using
// `current_setting('app.operator_id', true)::uuid`") is documentation,
// not policy DDL, and a naive grep would force the lint to be turned
// off entirely. Anchoring on `CREATE POLICY ... ;` keeps the
// signal/noise ratio honest.
//
// Exposed surface:
//
//   * `RlsPolicyLintRunner` — testable façade. Construct with a list
//     of (filename, file body) pairs and an allowlist; call `run()`
//     to receive a `LintResult` with violations grouped by file.
//   * `main(List<String>)` — CLI entrypoint that reads the
//     filesystem under `db/migrations/` and the allowlist file at
//     `tool/rls_policy_lint_allowlist.txt`, prints violations, and
//     exits non-zero on any.
//
// Run locally:
//
//   dart run tool/rls_policy_lint.dart
//
// CI wires the same command into `.github/workflows/ci.yml` so a PR
// introducing a bare-GUC policy body fails before merge.

import 'dart:io';

/// One bare-`current_setting('app.*')` violation inside a policy body.
class RlsPolicyLintViolation {
  const RlsPolicyLintViolation({
    required this.fileName,
    required this.policyName,
    required this.snippet,
  });

  /// File the violation lives in (basename, e.g.
  /// `202604280002_new_policy.sql`).
  final String fileName;

  /// Policy name as it appears in `CREATE POLICY "<name>" ON ...`.
  /// Empty string when the lint cannot resolve the name (malformed
  /// CREATE POLICY DDL).
  final String policyName;

  /// The offending substring from the policy body, trimmed for
  /// diagnostic output.
  final String snippet;

  @override
  String toString() {
    return '$fileName: policy "$policyName" reads bare app.* GUC: '
        '$snippet';
  }
}

/// Aggregate result of a lint run.
class RlsPolicyLintResult {
  const RlsPolicyLintResult({
    required this.violations,
    required this.scannedFileCount,
    required this.allowlistedFileCount,
  });

  final List<RlsPolicyLintViolation> violations;
  final int scannedFileCount;
  final int allowlistedFileCount;

  bool get isClean => violations.isEmpty;
}

/// In-memory façade so tests can drive the lint without touching the
/// filesystem. Production CLI uses [main] which reads the real tree.
class RlsPolicyLintRunner {
  RlsPolicyLintRunner({
    required this.files,
    required this.allowlist,
  });

  /// Map of filename → SQL body. Production CLI populates this from
  /// `db/migrations/*.sql`; tests pass synthetic strings.
  final Map<String, String> files;

  /// Filenames whose policy bodies are explicitly superseded by a
  /// later wrapper-using rewrite. The lint skips these without
  /// reading their bodies.
  final Set<String> allowlist;

  RlsPolicyLintResult run() {
    final violations = <RlsPolicyLintViolation>[];
    var allowlistedCount = 0;
    for (final entry in files.entries) {
      if (allowlist.contains(entry.key)) {
        allowlistedCount++;
        continue;
      }
      violations.addAll(_scan(entry.key, entry.value));
    }
    return RlsPolicyLintResult(
      violations: violations,
      scannedFileCount: files.length,
      allowlistedFileCount: allowlistedCount,
    );
  }

  Iterable<RlsPolicyLintViolation> _scan(
    String fileName,
    String body,
  ) sync* {
    for (final policy in _extractPolicies(body)) {
      final match = _bareGucPattern.firstMatch(policy.body);
      if (match != null) {
        yield RlsPolicyLintViolation(
          fileName: fileName,
          policyName: policy.name,
          snippet: _trimSnippet(match.group(0) ?? ''),
        );
      }
    }
  }

  static String _trimSnippet(String raw) {
    final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length > 80
        ? '${collapsed.substring(0, 77)}...'
        : collapsed;
  }
}

/// One CREATE POLICY statement, isolated from its surrounding migration.
class _PolicyStatement {
  const _PolicyStatement({required this.name, required this.body});

  final String name;
  final String body;
}

/// `CREATE POLICY name ON table ... ;` — captures the name and the
/// DDL between CREATE POLICY and the terminating semicolon. Both
/// quoted (`"my_policy"`) and bare (`tenant_guard`) PostgreSQL
/// identifier forms are accepted; PG allows either, and a lint that
/// only handled the quoted form would silently miss a future
/// migration that omitted the quotes.
///
/// `[\s\S]*?` so `.` effectively crosses newlines (policy bodies are
/// usually multi-line). The terminator is `;` outside of any string
/// literal — policies do not contain semicolons inside their
/// predicates today, so the simple "first semicolon" rule is
/// sufficient.
final RegExp _createPolicyPattern = RegExp(
  r'''create\s+policy\s+(?:"([^"]+)"|([a-zA-Z_][a-zA-Z0-9_$]*))([\s\S]*?);''',
  caseSensitive: false,
);

/// `current_setting('app.<anything>'...)` inside a policy body. The
/// policy-aware extraction above already restricts scope, so we don't
/// need to anchor on USING/WITH CHECK separately.
final RegExp _bareGucPattern = RegExp(
  r'''current_setting\s*\(\s*'app\.[^']+'\s*''',
  caseSensitive: false,
);

Iterable<_PolicyStatement> _extractPolicies(String body) sync* {
  for (final match in _createPolicyPattern.allMatches(body)) {
    // group 1 = quoted name, group 2 = bare identifier; exactly one
    // is non-null per match.
    final name = match.group(1) ?? match.group(2) ?? '';
    yield _PolicyStatement(
      name: name,
      body: match.group(0) ?? '',
    );
  }
}

/// Production CLI entrypoint. Reads `db/migrations/*.sql` plus the
/// allowlist file, runs the lint, prints diagnostics, and exits 1 on
/// any violation.
Future<void> main(List<String> args) async {
  final migrationsDir = Directory('db/migrations');
  if (!migrationsDir.existsSync()) {
    stderr.writeln('rls_policy_lint: db/migrations not found '
        '(run from repository root).');
    exitCode = 2;
    return;
  }

  final files = <String, String>{};
  final entries = migrationsDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in entries) {
    final name = file.uri.pathSegments.last;
    files[name] = file.readAsStringSync();
  }

  final allowlistFile = File('tool/rls_policy_lint_allowlist.txt');
  final allowlist = <String>{};
  if (allowlistFile.existsSync()) {
    for (final raw in allowlistFile.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      allowlist.add(line);
    }
  }

  final runner = RlsPolicyLintRunner(files: files, allowlist: allowlist);
  final result = runner.run();

  stdout.writeln('rls_policy_lint: scanned ${result.scannedFileCount} '
      'migration file(s); ${result.allowlistedFileCount} allowlisted.');
  if (result.isClean) {
    stdout.writeln('rls_policy_lint: clean — every operator-scoped '
        'policy reads tenant context through wrapper functions.');
    return;
  }
  stderr.writeln('rls_policy_lint: '
      '${result.violations.length} violation(s):');
  for (final v in result.violations) {
    stderr.writeln('  - $v');
  }
  stderr.writeln(
    'Fix: replace bare current_setting(\'app.<name>\', ...) with the '
    'matching wrapper function (app_current_operator / '
    'app_current_location / app_current_actor_user / '
    'app_acting_as_operator).',
  );
  exitCode = 1;
}
