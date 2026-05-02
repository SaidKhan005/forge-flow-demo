// HARD-E — `scripts/postgres_staging_setup.ps1` migration-cutoff lint.
//
// The staging setup script prints a runbook with a literal cutoff
// migration filename. Operators following the runbook stop at that
// file. If a new migration lands in `db/migrations/` and nobody
// bumps the cutoff, fresh staging instances silently miss the new
// migration and drift from production1.
//
// The lint extracts the cutoff filename from sentinel markers in
// the script and walks `db/migrations/` for *.sql files. If any
// file's basename sorts strictly higher than the cutoff, the lint
// fails with a clear remediation message.
//
// Sentinel markers (host script edits both lines together):
//
//   # MIGRATION_CUTOFF_BEGIN
//   Write-Host '   through <FILENAME>.'
//   # MIGRATION_CUTOFF_END
//
// Filenames in `db/migrations/` are timestamp-prefixed, so
// lexicographic sort is the chronological order:
//
//   202604250000_advisor_roles.sql
//   202605020400_phase_11A_7_feature_flags_admin_columns.sql
//
// Exposed surface:
//   * `MigrationCutoffLintRunner` — testable façade that takes the
//     script body and a list of migration filenames and returns a
//     `MigrationCutoffLintResult`.
//   * `main(List<String>)` — CLI entrypoint. Reads the script and
//     migrations directory from disk; exits 1 on any drift.

import 'dart:io';

const String defaultScriptPath = 'scripts/postgres_staging_setup.ps1';
const String defaultMigrationsDir = 'db/migrations';

const String _cutoffBeginMarker = '# MIGRATION_CUTOFF_BEGIN';
const String _cutoffEndMarker = '# MIGRATION_CUTOFF_END';

/// Extracts the cutoff filename from the script body. Throws
/// [MigrationCutoffParseError] if the markers are missing or the
/// captured line does not contain a `*.sql` filename.
class MigrationCutoffParseError implements Exception {
  MigrationCutoffParseError(this.message);
  final String message;
  @override
  String toString() => 'MigrationCutoffParseError: $message';
}

/// One drift violation: a migration file whose basename sorts strictly
/// higher than the script's cutoff line.
class MigrationCutoffViolation {
  const MigrationCutoffViolation({
    required this.cutoff,
    required this.newer,
  });

  final String cutoff;
  final List<String> newer;

  bool get isClean => newer.isEmpty;

  @override
  String toString() {
    return 'cutoff=$cutoff; newer=${newer.join(', ')}';
  }
}

/// Aggregate result of a lint run.
class MigrationCutoffLintResult {
  const MigrationCutoffLintResult({
    required this.cutoff,
    required this.scannedMigrationCount,
    required this.newerMigrations,
  });

  final String cutoff;
  final int scannedMigrationCount;
  final List<String> newerMigrations;

  bool get isClean => newerMigrations.isEmpty;
}

/// Pure, in-memory façade. Tests drive this directly without
/// touching the filesystem.
class MigrationCutoffLintRunner {
  MigrationCutoffLintRunner({
    required this.scriptBody,
    required this.migrationFilenames,
  });

  /// Full text of `scripts/postgres_staging_setup.ps1`.
  final String scriptBody;

  /// Basenames of all `*.sql` files under `db/migrations/`.
  final List<String> migrationFilenames;

  /// Returns the cutoff filename declared in the script. Throws
  /// [MigrationCutoffParseError] when the markers cannot be found.
  String parseCutoff() {
    final lines = scriptBody.split('\n');
    var insideBlock = false;
    String? captured;
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.contains(_cutoffBeginMarker)) {
        insideBlock = true;
        continue;
      }
      if (line.contains(_cutoffEndMarker)) {
        if (!insideBlock) {
          throw MigrationCutoffParseError(
            'found $_cutoffEndMarker before $_cutoffBeginMarker',
          );
        }
        if (captured == null) {
          throw MigrationCutoffParseError(
            'no migration filename captured between markers',
          );
        }
        return captured;
      }
      if (!insideBlock) continue;
      final match = _filenamePattern.firstMatch(line);
      if (match == null) continue;
      if (captured != null) {
        throw MigrationCutoffParseError(
          'multiple cutoff lines between markers; expected exactly one',
        );
      }
      captured = match.group(1)!;
    }
    if (insideBlock) {
      throw MigrationCutoffParseError(
        '$_cutoffBeginMarker without matching $_cutoffEndMarker',
      );
    }
    throw MigrationCutoffParseError(
      'sentinel markers $_cutoffBeginMarker / $_cutoffEndMarker '
      'not found in script',
    );
  }

  MigrationCutoffLintResult run() {
    final cutoff = parseCutoff();
    final newer = <String>[];
    for (final basename in migrationFilenames) {
      if (basename.compareTo(cutoff) > 0) {
        newer.add(basename);
      }
    }
    newer.sort();
    return MigrationCutoffLintResult(
      cutoff: cutoff,
      scannedMigrationCount: migrationFilenames.length,
      newerMigrations: newer,
    );
  }
}

/// Captures `<digits>_<anything>.sql` anywhere on the line.
final RegExp _filenamePattern = RegExp(r'(\d{8,}[A-Za-z0-9_.-]*\.sql)');

Future<void> main(List<String> args) async {
  final scriptPath = _argOrDefault(args, '--script=', defaultScriptPath);
  final migrationsDir =
      _argOrDefault(args, '--migrations=', defaultMigrationsDir);

  final scriptFile = File(scriptPath);
  if (!scriptFile.existsSync()) {
    stderr.writeln(
      'migration_cutoff_lint: script not found at $scriptPath '
      '(run from repository root).',
    );
    exitCode = 2;
    return;
  }

  final dir = Directory(migrationsDir);
  if (!dir.existsSync()) {
    stderr.writeln(
      'migration_cutoff_lint: migrations dir not found at $migrationsDir '
      '(run from repository root).',
    );
    exitCode = 2;
    return;
  }

  final filenames = <String>[];
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.toLowerCase().endsWith('.sql')) continue;
    filenames.add(entity.uri.pathSegments.last);
  }
  filenames.sort();

  final runner = MigrationCutoffLintRunner(
    scriptBody: scriptFile.readAsStringSync(),
    migrationFilenames: filenames,
  );

  final MigrationCutoffLintResult result;
  try {
    result = runner.run();
  } on MigrationCutoffParseError catch (e) {
    stderr.writeln('migration_cutoff_lint: parse error: ${e.message}');
    stderr.writeln(
      'Fix: ensure $scriptPath has a single line between '
      '$_cutoffBeginMarker and $_cutoffEndMarker that contains the latest '
      'migration filename.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'migration_cutoff_lint: scanned ${result.scannedMigrationCount} '
    'migration(s); cutoff=${result.cutoff}.',
  );
  if (result.isClean) {
    stdout.writeln(
      'migration_cutoff_lint: clean — runbook cutoff is current.',
    );
    return;
  }
  stderr.writeln(
    'migration_cutoff_lint: '
    '${result.newerMigrations.length} migration(s) newer than cutoff:',
  );
  for (final name in result.newerMigrations) {
    stderr.writeln('  - $name');
  }
  stderr.writeln(
    'Fix: bump the cutoff line in $scriptPath (between '
    '$_cutoffBeginMarker and $_cutoffEndMarker) to the latest '
    'migration filename above, then re-run this lint.',
  );
  exitCode = 1;
}

String _argOrDefault(List<String> args, String prefix, String fallback) {
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return arg.substring(prefix.length);
    }
  }
  return fallback;
}
