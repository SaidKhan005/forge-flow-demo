// Tests for `tool/migration_cutoff_lint.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/migration_cutoff_lint.dart';

void main() {
  group('migration_cutoff_lint', () {
    test('clean against the real on-disk tree', () {
      final scriptBody = File('scripts/postgres_staging_setup.ps1')
          .readAsStringSync();
      final filenames = Directory('db/migrations')
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.sql'))
          .map((f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
      final runner = MigrationCutoffLintRunner(
        scriptBody: scriptBody,
        migrationFilenames: filenames,
      );
      final result = runner.run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'real tree should pass; newer migrations: ${result.newerMigrations}',
      );
    });

    test('parses cutoff filename from sentinel-bracketed line', () {
      const body = '''
Write-Host '   db/migrations/202604250000_advisor_roles.sql and continuing'
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202605020400_phase_11A_7_feature_flags_admin_columns.sql.'
# MIGRATION_CUTOFF_END
''';
      final runner = MigrationCutoffLintRunner(
        scriptBody: body,
        migrationFilenames: const <String>[],
      );
      expect(
        runner.parseCutoff(),
        '202605020400_phase_11A_7_feature_flags_admin_columns.sql',
      );
    });

    test('flags newer migrations than the cutoff', () {
      const body = '''
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202605020400_phase_11A_7_feature_flags_admin_columns.sql.'
# MIGRATION_CUTOFF_END
''';
      final result = MigrationCutoffLintRunner(
        scriptBody: body,
        migrationFilenames: const <String>[
          '202604250000_advisor_roles.sql',
          '202605020400_phase_11A_7_feature_flags_admin_columns.sql',
          '202606010000_phase_x_new_table.sql',
        ],
      ).run();
      expect(result.isClean, isFalse);
      expect(result.newerMigrations, ['202606010000_phase_x_new_table.sql']);
      expect(
        result.cutoff,
        '202605020400_phase_11A_7_feature_flags_admin_columns.sql',
      );
    });

    test('passes when cutoff matches the highest migration', () {
      const body = '''
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202606010000_phase_x_new_table.sql.'
# MIGRATION_CUTOFF_END
''';
      final result = MigrationCutoffLintRunner(
        scriptBody: body,
        migrationFilenames: const <String>[
          '202604250000_advisor_roles.sql',
          '202606010000_phase_x_new_table.sql',
        ],
      ).run();
      expect(result.isClean, isTrue);
    });

    test('throws when sentinel markers are missing', () {
      const body = '''
Write-Host 'no markers here'
''';
      final runner = MigrationCutoffLintRunner(
        scriptBody: body,
        migrationFilenames: const <String>[],
      );
      expect(runner.parseCutoff, throwsA(isA<MigrationCutoffParseError>()));
    });

    test('throws when only the begin marker is present', () {
      const body = '''
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202605020400_phase_11A_7_feature_flags_admin_columns.sql.'
''';
      final runner = MigrationCutoffLintRunner(
        scriptBody: body,
        migrationFilenames: const <String>[],
      );
      expect(runner.parseCutoff, throwsA(isA<MigrationCutoffParseError>()));
    });

    test('throws when no filename is captured between markers', () {
      const body = '''
# MIGRATION_CUTOFF_BEGIN
Write-Host '   no sql filename on this line'
# MIGRATION_CUTOFF_END
''';
      final runner = MigrationCutoffLintRunner(
        scriptBody: body,
        migrationFilenames: const <String>[],
      );
      expect(runner.parseCutoff, throwsA(isA<MigrationCutoffParseError>()));
    });

    test('throws when the block has more than one filename line', () {
      const body = '''
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202605020400_phase_11A_7_feature_flags_admin_columns.sql.'
Write-Host '   then 202606010000_phase_x_new_table.sql.'
# MIGRATION_CUTOFF_END
''';
      final runner = MigrationCutoffLintRunner(
        scriptBody: body,
        migrationFilenames: const <String>[],
      );
      expect(runner.parseCutoff, throwsA(isA<MigrationCutoffParseError>()));
    });
  });
}
