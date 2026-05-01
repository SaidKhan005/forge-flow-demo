// Phase 9 repo-lints — `package:postgres` import containment.
//
// CLAUDE.md ("Service-Layer Split" + "Proxy & API Conventions") locks
// raw `package:postgres` imports to a single adapter directory:
//
//   lib/infrastructure/persistence/postgres/
//
// Anything else under `lib/` that imports `package:postgres` bypasses
// the `PostgresExecutor` / `OperatorScopedRepository` seam and lets a
// future caller leak tenant context into a raw query. The lint walks
// the source tree and fails on any net-new violation.
//
// Out-of-scope by design (test tree stays walkable but exempt):
//   * `test/*.dart`  — tests against the binding (e.g.
//     `operator_scoped_repository_test.dart`) need real
//     `pg.Pool`/`pg.Endpoint` types. The repository pattern itself is
//     what guarantees app code never touches `pg`; tests verifying
//     that pattern legitimately need the import.
//
// `tool/` is NOT exempt. The Cloud Run workers under `tool/`
// (`advisor_proxy/`, `audit_anchor/`, …) talk to Postgres through the
// `PostgresExecutor` seam by design — their headers reference that
// pattern explicitly. A future tool that imports `package:postgres`
// directly bypasses that seam and would mask the same tenant-context
// risks the lib/-side rule prevents, so the lint enforces the same
// containment under `tool/`.
//
// The walker still scans `lib/`, `tool/`, and `test/` so future
// violations under any of them cannot hide by being routed through a
// relative import path that dips through another root.
//
// Exposed surface:
//   * `PostgresImportLintRunner` — testable façade. Construct with a
//     map of relative-path → file body and an optional set of allowed
//     directory prefixes. Call `run()` to receive a `PostgresImportLintResult`.
//   * `main(List<String>)` — CLI entrypoint. Walks the on-disk tree,
//     prints diagnostics, and exits 1 on any violation.
//
// Run locally:
//
//   dart run tool/postgres_import_lint.dart
//
// CI wires this into the `repo-lints` job alongside
// `index_leading_column_lint.dart` and `permission_key_lint.dart`.

import 'dart:io';

/// One forbidden `package:postgres` import.
class PostgresImportLintViolation {
  const PostgresImportLintViolation({
    required this.filePath,
    required this.lineNumber,
    required this.importLine,
  });

  /// File the violation lives in (relative path from repo root, with
  /// forward slashes).
  final String filePath;

  /// 1-based line number in the file.
  final int lineNumber;

  /// The exact import line that triggered the lint, trimmed of leading
  /// and trailing whitespace.
  final String importLine;

  @override
  String toString() {
    return '$filePath:$lineNumber: $importLine '
        '(allowed only under lib/infrastructure/persistence/postgres/)';
  }
}

/// Aggregate result of a lint run.
class PostgresImportLintResult {
  const PostgresImportLintResult({
    required this.violations,
    required this.scannedFileCount,
    required this.exemptFileCount,
  });

  final List<PostgresImportLintViolation> violations;
  final int scannedFileCount;
  final int exemptFileCount;

  bool get isClean => violations.isEmpty;
}

/// In-memory façade so tests can drive the lint without touching the
/// filesystem. Production CLI uses [main].
class PostgresImportLintRunner {
  PostgresImportLintRunner({
    required this.files,
    Set<String>? allowedDirs,
  }) : allowedDirs = allowedDirs ?? _defaultAllowedDirs;

  /// Map of relative-path → file body. Production CLI walks the tree;
  /// tests pass synthetic strings.
  final Map<String, String> files;

  /// Directory prefixes (with trailing `/`) under which a
  /// `package:postgres` import does not fail the lint. Paths are
  /// compared with forward-slash normalization.
  final Set<String> allowedDirs;

  PostgresImportLintResult run() {
    final violations = <PostgresImportLintViolation>[];
    var exempt = 0;
    for (final entry in files.entries) {
      final norm = entry.key.replaceAll(r'\', '/');
      if (allowedDirs.any((dir) => norm.startsWith(dir))) {
        exempt++;
        continue;
      }
      final lines = entry.value.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (_postgresImportPattern.hasMatch(line)) {
          violations.add(PostgresImportLintViolation(
            filePath: norm,
            lineNumber: i + 1,
            importLine: line.trim(),
          ));
        }
      }
    }
    return PostgresImportLintResult(
      violations: violations,
      scannedFileCount: files.length,
      exemptFileCount: exempt,
    );
  }
}

/// Default exempt directory prefixes. Paths use forward slashes.
///
/// `tool/` is intentionally absent — Cloud Run workers under `tool/`
/// must use the `PostgresExecutor` seam, same as production app code,
/// per the headers on `tool/advisor_proxy/advisor_proxy.dart` and
/// `tool/audit_anchor/audit_anchor.dart`. Tests are exempt because
/// `test/operator_scoped_repository_test.dart` (and any future
/// adapter-binding test) legitimately constructs `pg.Pool`/`pg.Endpoint`
/// instances to exercise the very seam the rule protects.
const Set<String> _defaultAllowedDirs = <String>{
  'lib/infrastructure/persistence/postgres/',
  'test/',
};

/// Matches an `import` directive whose package URI starts with
/// `package:postgres/`. Anchored on line start (the line is fed in
/// pre-split, so `^` is the start of one logical line) so a
/// docstring or block comment that mentions an `import` line does
/// not trip a false positive. Captures both the canonical entry-point
/// `package:postgres/postgres.dart` and any subpath (e.g.
/// `package:postgres/messages.dart`) so a transitive import cannot
/// sneak past the lint by referencing a non-default subpath.
final RegExp _postgresImportPattern = RegExp(
  r'''^\s*import\s+['"]package:postgres/''',
);

/// Production CLI entrypoint. Walks `lib/`, `tool/`, and `test/` for
/// `*.dart` files (per the spec) and runs the lint.
Future<void> main(List<String> args) async {
  const roots = <String>['lib', 'tool', 'test'];
  final files = <String, String>{};
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      files[rel] = entity.readAsStringSync();
    }
  }

  if (files.isEmpty) {
    stderr.writeln('postgres_import_lint: no Dart files found '
        '(run from repository root).');
    exitCode = 2;
    return;
  }

  final runner = PostgresImportLintRunner(files: files);
  final result = runner.run();

  stdout.writeln('postgres_import_lint: scanned ${result.scannedFileCount} '
      'Dart file(s); ${result.exemptFileCount} under exempt directories.');
  if (result.isClean) {
    stdout.writeln('postgres_import_lint: clean — no `package:postgres` '
        'imports outside lib/infrastructure/persistence/postgres/.');
    return;
  }
  stderr.writeln('postgres_import_lint: '
      '${result.violations.length} violation(s):');
  for (final v in result.violations) {
    stderr.writeln('  - $v');
  }
  stderr.writeln(
    'Fix: route the call through PostgresExecutor / '
    'OperatorScopedRepository under lib/infrastructure/persistence/postgres/, '
    'or move the file into that directory if it belongs there.',
  );
  exitCode = 1;
}
