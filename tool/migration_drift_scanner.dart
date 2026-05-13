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
const String defaultExpandContractGrandfatherCutoff =
    '202605131030_b11_1_auth_handoff_codes.sql';

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
final RegExp _createTablePattern = RegExp(
  r'\bcreate\s+table\s+(?:if\s+not\s+exists\s+)?((?:"[^"]+"|[a-zA-Z_][a-zA-Z0-9_$]*)(?:\s*\.\s*(?:"[^"]+"|[a-zA-Z_][a-zA-Z0-9_$]*))?)',
  caseSensitive: false,
);
final RegExp _addColumnPattern = RegExp(
  r'\balter\s+table\s+(?:if\s+exists\s+)?((?:"[^"]+"|[a-zA-Z_][a-zA-Z0-9_$]*)(?:\s*\.\s*(?:"[^"]+"|[a-zA-Z_][a-zA-Z0-9_$]*))?)\s+[\s\S]*?\badd\s+column\s+(?:if\s+not\s+exists\s+)?[\s\S]*?;',
  caseSensitive: false,
);
final RegExp _updateTablePattern = RegExp(
  r'\bupdate\s+(?:only\s+)?((?:"[^"]+"|[a-zA-Z_][a-zA-Z0-9_$]*)(?:\s*\.\s*(?:"[^"]+"|[a-zA-Z_][a-zA-Z0-9_$]*))?)(?:\s+(?:as\s+)?[a-zA-Z_][a-zA-Z0-9_$]*)?\s+set\b',
  caseSensitive: false,
);
final RegExp _setNotNullPattern = RegExp(
  r'\balter\s+table\s+(?:if\s+exists\s+)?((?:"[^"]+"|[a-zA-Z_][a-zA-Z0-9_$]*)(?:\s*\.\s*(?:"[^"]+"|[a-zA-Z_][a-zA-Z0-9_$]*))?)\s+[\s\S]*?\balter\s+column\s+[\s\S]*?\bset\s+not\s+null\b[\s\S]*?;',
  caseSensitive: false,
);

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

class MigrationExpandContractViolation {
  const MigrationExpandContractViolation({
    required this.fileName,
    required this.tableName,
    required this.line,
    required this.reason,
  });

  final String fileName;
  final String tableName;
  final int line;
  final String reason;

  @override
  String toString() =>
      '$fileName:$line combines schema expand + backfill + '
      'contract on $tableName ($reason). Split into an expand migration plus '
      'post_deploy backfill/contract SQL.';
}

class MigrationExpandContractLintResult {
  const MigrationExpandContractLintResult({
    required this.scannedFileCount,
    required this.grandfatheredFileCount,
    required this.violations,
  });

  final int scannedFileCount;
  final int grandfatheredFileCount;
  final List<MigrationExpandContractViolation> violations;

  bool get isClean => violations.isEmpty;
}

class MigrationExpandContractLintRunner {
  const MigrationExpandContractLintRunner({
    required this.files,
    this.grandfatherCutoff,
  });

  final Map<String, String> files;
  final String? grandfatherCutoff;

  MigrationExpandContractLintResult run() {
    final violations = <MigrationExpandContractViolation>[];
    var grandfatheredFileCount = 0;
    for (final entry in files.entries) {
      final fileName = entry.key;
      if (_isGrandfathered(fileName)) {
        grandfatheredFileCount++;
        continue;
      }
      violations.addAll(_scanFile(fileName, entry.value));
    }
    return MigrationExpandContractLintResult(
      scannedFileCount: files.length,
      grandfatheredFileCount: grandfatheredFileCount,
      violations: List<MigrationExpandContractViolation>.unmodifiable(
        violations,
      ),
    );
  }

  bool _isGrandfathered(String fileName) {
    final cutoff = grandfatherCutoff;
    return cutoff != null && fileName.compareTo(cutoff) <= 0;
  }

  Iterable<MigrationExpandContractViolation> _scanFile(
    String fileName,
    String body,
  ) sync* {
    final scanBody = _stripSqlCommentsPreservingOffsets(body);
    final createdTables = _createdTables(scanBody);
    final tableStates = <String, _ExpandContractTableState>{};

    for (final match in _addColumnPattern.allMatches(scanBody)) {
      final tableName = _normalizeSqlTableName(match.group(1) ?? '');
      if (tableName.isEmpty || createdTables.contains(tableName)) continue;
      final state = tableStates.putIfAbsent(
        tableName,
        () => _ExpandContractTableState(tableName),
      );
      final statement = match.group(0) ?? '';
      state.addColumnLine ??= _lineForOffset(scanBody, match.start);
      if (RegExp(r'\bnot\s+null\b', caseSensitive: false).hasMatch(statement)) {
        state.hasAddNotNull = true;
      } else {
        state.hasAddNullable = true;
      }
    }

    for (final match in _updateTablePattern.allMatches(scanBody)) {
      final tableName = _normalizeSqlTableName(match.group(1) ?? '');
      if (tableName.isEmpty || createdTables.contains(tableName)) continue;
      final state = tableStates.putIfAbsent(
        tableName,
        () => _ExpandContractTableState(tableName),
      );
      state.hasUpdate = true;
      state.updateLine ??= _lineForOffset(scanBody, match.start);
    }

    for (final match in _setNotNullPattern.allMatches(scanBody)) {
      final tableName = _normalizeSqlTableName(match.group(1) ?? '');
      if (tableName.isEmpty || createdTables.contains(tableName)) continue;
      final state = tableStates.putIfAbsent(
        tableName,
        () => _ExpandContractTableState(tableName),
      );
      state.hasSetNotNull = true;
      state.setNotNullLine ??= _lineForOffset(scanBody, match.start);
    }

    for (final state in tableStates.values) {
      if (state.hasAddNotNull && state.hasUpdate) {
        yield MigrationExpandContractViolation(
          fileName: fileName,
          tableName: state.tableName,
          line: state.addColumnLine ?? state.updateLine ?? 1,
          reason: 'ADD COLUMN NOT NULL and UPDATE in one migration',
        );
        continue;
      }
      if (state.hasAddNullable && state.hasUpdate && state.hasSetNotNull) {
        yield MigrationExpandContractViolation(
          fileName: fileName,
          tableName: state.tableName,
          line: state.addColumnLine ?? state.updateLine ?? 1,
          reason: 'ADD COLUMN, UPDATE, and SET NOT NULL in one migration',
        );
      }
    }
  }

  Set<String> _createdTables(String body) {
    return _createTablePattern
        .allMatches(body)
        .map((match) => _normalizeSqlTableName(match.group(1) ?? ''))
        .where((tableName) => tableName.isNotEmpty)
        .toSet();
  }
}

class _ExpandContractTableState {
  _ExpandContractTableState(this.tableName);

  final String tableName;
  bool hasAddNullable = false;
  bool hasAddNotNull = false;
  bool hasUpdate = false;
  bool hasSetNotNull = false;
  int? addColumnLine;
  int? updateLine;
  int? setNotNullLine;
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
  final requireExpandContract = args.contains('--require-expand-contract');
  final expandContractGrandfatherCutoff = _argOrDefault(
    args,
    '--expand-contract-grandfather-cutoff=',
    defaultExpandContractGrandfatherCutoff,
  );
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

  final migrationFiles =
      migrationsDirectory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.sql'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final migrationFilenames = migrationFiles
      .map((file) => file.uri.pathSegments.last)
      .toList();
  final migrationBodies = <String, String>{};
  for (final file in migrationFiles) {
    migrationBodies[file.uri.pathSegments.last] = file.readAsStringSync();
  }

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

  var shouldFail =
      !result.cutoffClean || (strictDocs && result.hasLikelyDocDrift);

  if (requireExpandContract) {
    final expandContractResult = MigrationExpandContractLintRunner(
      files: migrationBodies,
      grandfatherCutoff: expandContractGrandfatherCutoff.isEmpty
          ? null
          : expandContractGrandfatherCutoff,
    ).run();
    stdout.writeln(
      'migration_drift_scanner: expand-contract scanned '
      '${expandContractResult.scannedFileCount} migration file(s); '
      '${expandContractResult.grandfatheredFileCount} grandfathered.',
    );
    if (expandContractResult.isClean) {
      stdout.writeln(
        'migration_drift_scanner: expand-contract clean for enforced '
        'migrations.',
      );
    } else {
      stderr.writeln(
        'migration_drift_scanner: expand-contract '
        '${expandContractResult.violations.length} violation(s):',
      );
      for (final violation in expandContractResult.violations) {
        stderr.writeln('  - $violation');
      }
      shouldFail = true;
    }
  }

  if (shouldFail) {
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

String _stripSqlCommentsPreservingOffsets(String input) {
  final buffer = StringBuffer();
  var index = 0;
  var inSingleQuote = false;
  var inDoubleQuote = false;

  while (index < input.length) {
    final char = input[index];
    final next = index + 1 < input.length ? input[index + 1] : '';

    if (!inSingleQuote && !inDoubleQuote && char == '-' && next == '-') {
      buffer.write('  ');
      index += 2;
      while (index < input.length && input[index] != '\n') {
        buffer.write(' ');
        index++;
      }
      continue;
    }

    if (!inSingleQuote && !inDoubleQuote && char == '/' && next == '*') {
      buffer.write('  ');
      index += 2;
      while (index < input.length) {
        final blockChar = input[index];
        final blockNext = index + 1 < input.length ? input[index + 1] : '';
        if (blockChar == '*' && blockNext == '/') {
          buffer.write('  ');
          index += 2;
          break;
        }
        buffer.write(blockChar == '\n' ? '\n' : ' ');
        index++;
      }
      continue;
    }

    if (!inDoubleQuote && char == "'") {
      buffer.write(char);
      if (inSingleQuote && next == "'") {
        buffer.write(next);
        index += 2;
        continue;
      }
      inSingleQuote = !inSingleQuote;
      index++;
      continue;
    }

    if (!inSingleQuote && char == '"') {
      buffer.write(char);
      if (inDoubleQuote && next == '"') {
        buffer.write(next);
        index += 2;
        continue;
      }
      inDoubleQuote = !inDoubleQuote;
      index++;
      continue;
    }

    buffer.write(char);
    index++;
  }

  return buffer.toString();
}

String _normalizeSqlTableName(String raw) {
  final parts = raw
      .split('.')
      .map((part) => part.trim().replaceAll('"', '').toLowerCase())
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '';
  if (parts.length == 1) return 'public.${parts.single}';
  return '${parts[parts.length - 2]}.${parts.last}';
}

int _lineForOffset(String body, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < body.length; i++) {
    if (body.codeUnitAt(i) == 10) line++;
  }
  return line;
}
