// Migration drift scanner.
//
// This is the higher-level companion to `migration_cutoff_lint.dart`.
// The lint is the hard gate: it fails when the staging setup script's
// cutoff is behind `db/migrations`. This scanner is the operational helper:
// it can update the staging setup cutoff with `--fix` and always emits a
// markdown report that shows the migration drift and watched docs that still
// need tracker/runbook wording updates.

import 'dart:io';

import 'migration_cutoff_lint.dart';

const String defaultReportPath = 'build/reports/migration_drift_report.md';

const List<String> defaultWatchedDocs = <String>[
  'PROJECT_TRACKER.md',
  'docs/POST_HARDENING_FOLLOWUPS.md',
  'runbooks/phase_9_production1_migration_apply_runbook.md',
  'scripts/postgres_staging_setup.ps1',
  'docs/phases/phase_9/phase_9_execution_backlog.md',
  'docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md',
];

const String _cutoffBeginMarker = '# MIGRATION_CUTOFF_BEGIN';
const String _cutoffEndMarker = '# MIGRATION_CUTOFF_END';

final RegExp _filenamePattern = RegExp(r'(\d{8,}[A-Za-z0-9_.-]*\.sql)');
final RegExp _timestampPattern = RegExp(r'\b20\d{6,}\b');

class MigrationDriftScanResult {
  const MigrationDriftScanResult({
    required this.scannedMigrationCount,
    required this.latestMigration,
    required this.cutoffBefore,
    required this.cutoffAfter,
    required this.driftMigrations,
    required this.fixed,
    required this.docResults,
    required this.generatedAtUtc,
  });

  final int scannedMigrationCount;
  final String latestMigration;
  final String cutoffBefore;
  final String cutoffAfter;
  final List<String> driftMigrations;
  final bool fixed;
  final List<MigrationDocScanResult> docResults;
  final DateTime generatedAtUtc;

  bool get cutoffClean => cutoffAfter == latestMigration;
  bool get hadCutoffDrift => driftMigrations.isNotEmpty;

  bool get hasLikelyDocDrift =>
      docResults.any((result) => result.status == MigrationDocStatus.stale);

  String get latestTimestamp => latestMigration.split('_').first;
}

enum MigrationDocStatus {
  ok,
  stale,
  futureReference,
  noMigrationReferences,
  missing,
}

class MigrationDocScanResult {
  const MigrationDocScanResult({
    required this.path,
    required this.status,
    required this.containsLatest,
    this.highestReference,
  });

  final String path;
  final MigrationDocStatus status;
  final bool containsLatest;
  final String? highestReference;
}

class MigrationDriftScanner {
  const MigrationDriftScanner({
    required this.scriptBody,
    required this.migrationFilenames,
    required this.docBodies,
    required this.generatedAtUtc,
  });

  final String scriptBody;
  final List<String> migrationFilenames;
  final Map<String, String?> docBodies;
  final DateTime generatedAtUtc;

  MigrationDriftScanResult scan({required bool fix}) {
    final migrations =
        migrationFilenames
            .where((name) => name.toLowerCase().endsWith('.sql'))
            .toList()
          ..sort();
    if (migrations.isEmpty) {
      throw MigrationCutoffParseError('no migration files found');
    }

    final latestMigration = migrations.last;
    final lintResult = MigrationCutoffLintRunner(
      scriptBody: scriptBody,
      migrationFilenames: migrations,
    ).run();
    final cutoffAfter = fix && lintResult.cutoff != latestMigration
        ? latestMigration
        : lintResult.cutoff;

    final effectiveDocBodies = Map<String, String?>.from(docBodies);
    final scriptDocBody = fix && lintResult.cutoff != latestMigration
        ? updateScriptCutoff(scriptBody, latestMigration)
        : scriptBody;
    effectiveDocBodies[defaultScriptPath] = scriptDocBody;

    final latestTimestamp = latestMigration.split('_').first;
    final docResults = effectiveDocBodies.entries
        .map(
          (entry) => scanDoc(
            path: entry.key,
            body: entry.value,
            latestMigration: latestMigration,
            latestTimestamp: latestTimestamp,
          ),
        )
        .toList();

    return MigrationDriftScanResult(
      scannedMigrationCount: migrations.length,
      latestMigration: latestMigration,
      cutoffBefore: lintResult.cutoff,
      cutoffAfter: cutoffAfter,
      driftMigrations: List<String>.unmodifiable(lintResult.newerMigrations),
      fixed: fix && lintResult.cutoff != latestMigration,
      docResults: List<MigrationDocScanResult>.unmodifiable(docResults),
      generatedAtUtc: generatedAtUtc,
    );
  }

  static MigrationDocScanResult scanDoc({
    required String path,
    required String? body,
    required String latestMigration,
    required String latestTimestamp,
  }) {
    if (body == null) {
      return MigrationDocScanResult(
        path: path,
        status: MigrationDocStatus.missing,
        containsLatest: false,
      );
    }

    final filenames = _filenamePattern
        .allMatches(body)
        .map((match) => match.group(1)!)
        .toList();
    final timestamps = _timestampPattern
        .allMatches(body)
        .map((match) => match.group(0)!)
        .toList();
    final references = <String>[...filenames, ...timestamps]..sort();
    if (references.isEmpty) {
      return MigrationDocScanResult(
        path: path,
        status: MigrationDocStatus.noMigrationReferences,
        containsLatest: false,
      );
    }

    final containsLatest =
        body.contains(latestMigration) || body.contains(latestTimestamp);
    final highest = references.last;
    if (containsLatest) {
      return MigrationDocScanResult(
        path: path,
        status: MigrationDocStatus.ok,
        containsLatest: true,
        highestReference: highest,
      );
    }

    final highestTimestamp = highest.split('_').first;
    final status = highestTimestamp.compareTo(latestTimestamp) > 0
        ? MigrationDocStatus.futureReference
        : MigrationDocStatus.stale;
    return MigrationDocScanResult(
      path: path,
      status: status,
      containsLatest: false,
      highestReference: highest,
    );
  }
}

String updateScriptCutoff(String scriptBody, String latestMigration) {
  final blockPattern = RegExp(
    '(${RegExp.escape(_cutoffBeginMarker)}\\r?\\n)(.*?)'
    '(\\r?\\n${RegExp.escape(_cutoffEndMarker)})',
    dotAll: true,
  );
  final match = blockPattern.firstMatch(scriptBody);
  if (match == null) {
    throw MigrationCutoffParseError(
      'sentinel markers $_cutoffBeginMarker / $_cutoffEndMarker '
      'not found in script',
    );
  }

  final blockBody = match.group(2)!;
  final filenameMatches = _filenamePattern.allMatches(blockBody).toList();
  if (filenameMatches.isEmpty) {
    throw MigrationCutoffParseError(
      'no migration filename captured between markers',
    );
  }
  if (filenameMatches.length > 1) {
    throw MigrationCutoffParseError(
      'multiple cutoff lines between markers; expected exactly one',
    );
  }

  final updatedBlock = blockBody.replaceFirst(
    _filenamePattern,
    latestMigration,
  );
  return scriptBody.replaceRange(
    match.start,
    match.end,
    [match.group(1)!, updatedBlock, match.group(3)!].join(),
  );
}

String renderMigrationDriftReport(MigrationDriftScanResult result) {
  final buffer = StringBuffer()
    ..writeln('# Migration Drift Report')
    ..writeln()
    ..writeln('Generated: ${result.generatedAtUtc.toIso8601String()}')
    ..writeln()
    ..writeln('## Summary')
    ..writeln()
    ..writeln('- Scanned migrations: ${result.scannedMigrationCount}')
    ..writeln('- Latest migration: `${result.latestMigration}`')
    ..writeln('- Staging setup cutoff before: `${result.cutoffBefore}`')
    ..writeln('- Staging setup cutoff after: `${result.cutoffAfter}`')
    ..writeln('- Cutoff drift: ${result.hadCutoffDrift ? 'yes' : 'no'}')
    ..writeln('- Staging setup updated: ${result.fixed ? 'yes' : 'no'}')
    ..writeln();

  buffer
    ..writeln('## Drift Migrations')
    ..writeln();
  if (result.driftMigrations.isEmpty) {
    buffer.writeln('None.');
  } else {
    for (final migration in result.driftMigrations) {
      buffer.writeln('- `$migration`');
    }
  }
  buffer.writeln();

  buffer
    ..writeln('## Watched Authority Files')
    ..writeln()
    ..writeln('| File | Status | Highest reference | Contains latest |')
    ..writeln('| --- | --- | --- | --- |');
  for (final doc in result.docResults) {
    buffer.writeln(
      '| `${doc.path}` | ${_statusLabel(doc.status)} | '
      '${doc.highestReference == null ? '-' : '`${doc.highestReference}`'} | '
      '${doc.containsLatest ? 'yes' : 'no'} |',
    );
  }
  buffer.writeln();

  buffer
    ..writeln('## Recommended Follow-Up')
    ..writeln();
  if (result.hadCutoffDrift && !result.fixed) {
    buffer.writeln(
      '- Run `dart run tool/migration_drift_scanner.dart --fix` to update '
      'the staging setup cutoff.',
    );
  }
  final staleDocs = result.docResults
      .where((doc) => doc.status == MigrationDocStatus.stale)
      .toList();
  if (staleDocs.isNotEmpty) {
    buffer.writeln(
      '- Review stale authority docs and update their queue/count wording '
      'to include `${result.latestMigration}`.',
    );
  }
  if (!result.hadCutoffDrift && staleDocs.isEmpty) {
    buffer.writeln('- No migration drift detected.');
  }

  return buffer.toString();
}

Future<void> main(List<String> args) async {
  final fix = args.contains('--fix');
  final strictDocs = args.contains('--strict-docs');
  final scriptPath = _argOrDefault(args, '--script=', defaultScriptPath);
  final migrationsDir = _argOrDefault(
    args,
    '--migrations=',
    defaultMigrationsDir,
  );
  final reportPath = _argOrDefault(args, '--report=', defaultReportPath);
  final watchedDocs = _argListOrDefault(args, '--docs=', defaultWatchedDocs);

  final scriptFile = File(scriptPath);
  final migrationsDirectory = Directory(migrationsDir);
  if (!scriptFile.existsSync()) {
    stderr.writeln('migration_drift_scanner: script not found at $scriptPath');
    exitCode = 2;
    return;
  }
  if (!migrationsDirectory.existsSync()) {
    stderr.writeln(
      'migration_drift_scanner: migrations dir not found at $migrationsDir',
    );
    exitCode = 2;
    return;
  }

  final migrationFilenames =
      migrationsDirectory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.sql'))
          .map((file) => file.uri.pathSegments.last)
          .toList()
        ..sort();

  final scriptBody = scriptFile.readAsStringSync();
  final docBodies = <String, String?>{};
  for (final path in watchedDocs) {
    final file = File(path);
    docBodies[path] = file.existsSync() ? file.readAsStringSync() : null;
  }

  final MigrationDriftScanResult result;
  try {
    result = MigrationDriftScanner(
      scriptBody: scriptBody,
      migrationFilenames: migrationFilenames,
      docBodies: docBodies,
      generatedAtUtc: DateTime.now().toUtc(),
    ).scan(fix: fix);
  } on MigrationCutoffParseError catch (e) {
    stderr.writeln('migration_drift_scanner: parse error: ${e.message}');
    exitCode = 2;
    return;
  }

  if (fix && result.fixed) {
    scriptFile.writeAsStringSync(
      updateScriptCutoff(scriptBody, result.latestMigration),
    );
  }

  final report = renderMigrationDriftReport(result);
  final reportFile = File(reportPath);
  reportFile.parent.createSync(recursive: true);
  reportFile.writeAsStringSync(report);

  stdout.writeln(
    'migration_drift_scanner: latest=${result.latestMigration}; '
    'cutoff=${result.cutoffAfter}; report=$reportPath',
  );
  if (result.fixed) {
    stdout.writeln('migration_drift_scanner: updated $scriptPath');
  }
  if (result.hasLikelyDocDrift) {
    stdout.writeln(
      'migration_drift_scanner: report contains stale authority docs',
    );
  }

  if (!result.cutoffClean || (strictDocs && result.hasLikelyDocDrift)) {
    exitCode = 1;
  }
}

String _argOrDefault(List<String> args, String prefix, String fallback) {
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return arg.substring(prefix.length);
    }
  }
  return fallback;
}

List<String> _argListOrDefault(
  List<String> args,
  String prefix,
  List<String> fallback,
) {
  final raw = _argOrDefault(args, prefix, '');
  if (raw.isEmpty) return fallback;
  return raw
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
}

String _statusLabel(MigrationDocStatus status) {
  switch (status) {
    case MigrationDocStatus.ok:
      return 'ok';
    case MigrationDocStatus.stale:
      return 'stale';
    case MigrationDocStatus.futureReference:
      return 'future-reference';
    case MigrationDocStatus.noMigrationReferences:
      return 'no-migration-references';
    case MigrationDocStatus.missing:
      return 'missing';
  }
}
