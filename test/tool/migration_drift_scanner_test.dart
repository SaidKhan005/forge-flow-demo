// Tests for `tool/migration_drift_scanner.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/migration_drift_scanner.dart';

void main() {
  group('migration_drift_scanner', () {
    test('updates the cutoff line inside sentinel markers', () {
      const body = '''
Write-Host 'before'
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202605021500_phase_9_0sigma_l_rls_depth.sql.'
# MIGRATION_CUTOFF_END
Write-Host 'after'
''';

      final updated = updateScriptCutoff(
        body,
        '202605021710_phase_11A_health_age_runtime_grants.sql',
      );

      expect(
        updated,
        contains(
          'through 202605021710_phase_11A_health_age_runtime_grants.sql.',
        ),
      );
      expect(updated, contains("Write-Host 'before'"));
      expect(updated, contains("Write-Host 'after'"));
    });

    test('scan reports drift and stale docs before fix', () {
      const body = '''
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202605021500_phase_9_0sigma_l_rls_depth.sql.'
# MIGRATION_CUTOFF_END
''';
      final result = MigrationDriftScanner(
        scriptBody: body,
        migrationFilenames: const <String>[
          '202605021500_phase_9_0sigma_l_rls_depth.sql',
          '202605021600_phase_11A_7_feature_flags_forge_admin_grants.sql',
          '202605021710_phase_11A_health_age_runtime_grants.sql',
        ],
        docBodies: const <String, String?>{
          'PROJECT_TRACKER.md': 'pending through 202605021500',
        },
        generatedAtUtc: DateTime.utc(2026, 5, 2),
      ).scan(fix: false);

      expect(result.hadCutoffDrift, isTrue);
      expect(
        result.cutoffBefore,
        '202605021500_phase_9_0sigma_l_rls_depth.sql',
      );
      expect(result.cutoffAfter, '202605021500_phase_9_0sigma_l_rls_depth.sql');
      expect(result.latestMigration, endsWith('health_age_runtime_grants.sql'));
      expect(result.driftMigrations, hasLength(2));
      expect(result.hasLikelyDocDrift, isTrue);
    });

    test('scan reports fixed cutoff when fix is requested', () {
      const body = '''
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202605021500_phase_9_0sigma_l_rls_depth.sql.'
# MIGRATION_CUTOFF_END
''';
      final result = MigrationDriftScanner(
        scriptBody: body,
        migrationFilenames: const <String>[
          '202605021500_phase_9_0sigma_l_rls_depth.sql',
          '202605021710_phase_11A_health_age_runtime_grants.sql',
        ],
        docBodies: const <String, String?>{
          'scripts/postgres_staging_setup.ps1': body,
        },
        generatedAtUtc: DateTime.utc(2026, 5, 2),
      ).scan(fix: true);

      expect(result.fixed, isTrue);
      expect(
        result.cutoffAfter,
        '202605021710_phase_11A_health_age_runtime_grants.sql',
      );
      expect(result.cutoffClean, isTrue);
    });

    test('doc scan accepts latest timestamp even without full filename', () {
      final result = MigrationDriftScanner.scanDoc(
        path: 'PROJECT_TRACKER.md',
        body: '25 migrations queued (`202604280014`-`202605021710`)',
        latestMigration: '202605021710_phase_11A_health_age_runtime_grants.sql',
        latestTimestamp: '202605021710',
      );

      expect(result.status, MigrationDocStatus.ok);
      expect(result.containsLatest, isTrue);
    });

    test('renders report with drift migrations and watched docs', () {
      final result = MigrationDriftScanResult(
        scannedMigrationCount: 2,
        latestMigration: '202605021710_phase_11A_health_age_runtime_grants.sql',
        cutoffBefore: '202605021500_phase_9_0sigma_l_rls_depth.sql',
        cutoffAfter: '202605021710_phase_11A_health_age_runtime_grants.sql',
        driftMigrations: const <String>[
          '202605021710_phase_11A_health_age_runtime_grants.sql',
        ],
        fixed: true,
        docResults: const <MigrationDocScanResult>[
          MigrationDocScanResult(
            path: 'PROJECT_TRACKER.md',
            status: MigrationDocStatus.ok,
            containsLatest: true,
            highestReference: '202605021710',
          ),
        ],
        generatedAtUtc: DateTime.utc(2026, 5, 2),
      );

      final report = renderMigrationDriftReport(result);

      expect(report, contains('# Migration Drift Report'));
      expect(
        report,
        contains('202605021710_phase_11A_health_age_runtime_grants.sql'),
      );
      expect(report, contains('PROJECT_TRACKER.md'));
    });

    test('expand-contract flag catches add, backfill, and contract shape', () {
      final result = MigrationExpandContractLintRunner(
        files: const <String, String>{
          '202606010000_bad_expand_contract.sql': '''
alter table public.audit_target
  add column if not exists business_date date null;

update public.audit_target
   set business_date = current_date
 where business_date is null;

alter table public.audit_target
  alter column business_date set not null;
''',
        },
      ).run();

      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(1));
      expect(result.violations.single.tableName, 'public.audit_target');
      expect(result.violations.single.line, 1);
    });

    test(
      'expand-contract flag catches ADD NOT NULL plus same-table update',
      () {
        final result = MigrationExpandContractLintRunner(
          files: const <String, String>{
            '202606010100_bad_add_not_null.sql': '''
alter table public.admin_request_idempotency
  add column if not exists expires_at timestamptz not null
    default now();

update public.admin_request_idempotency
   set expires_at = now()
 where expires_at is null;
''',
          },
        ).run();

        expect(result.isClean, isFalse);
        expect(
          result.violations.single.reason,
          contains('ADD COLUMN NOT NULL'),
        );
      },
    );

    test('expand-contract flag ignores tables created in the same file', () {
      final result = MigrationExpandContractLintRunner(
        files: const <String, String>{
          '202606010200_create_then_seed.sql': '''
create table public.new_table (
  id uuid primary key
);

alter table public.new_table
  add column if not exists label text not null default 'seed';

update public.new_table
   set label = 'seed';
''',
        },
      ).run();

      expect(result.isClean, isTrue);
    });

    test('expand-contract flag grandfathers files at or before cutoff', () {
      final result = MigrationExpandContractLintRunner(
        files: const <String, String>{
          '202605131030_b11_1_auth_handoff_codes.sql': '''
alter table public.legacy_table
  add column if not exists label text not null default 'legacy';

update public.legacy_table
   set label = 'legacy';
''',
          '202606010300_new_bad.sql': '''
alter table public.new_bad
  add column if not exists label text not null default 'bad';

update public.new_bad
   set label = 'bad';
''',
        },
        grandfatherCutoff: defaultExpandContractGrandfatherCutoff,
      ).run();

      expect(result.grandfatheredFileCount, 1);
      expect(result.violations, hasLength(1));
      expect(result.violations.single.fileName, '202606010300_new_bad.sql');
    });

    test('real tree is clean after the current tracker refresh', () {
      final scriptBody = File(
        'scripts/postgres_staging_setup.ps1',
      ).readAsStringSync();
      final filenames =
          Directory('db/migrations')
              .listSync(followLinks: false)
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.sql'))
              .map((file) => file.uri.pathSegments.last)
              .toList()
            ..sort();
      final docBodies = <String, String?>{};
      for (final path in defaultWatchedDocs) {
        final file = File(path);
        docBodies[path] = file.existsSync() ? file.readAsStringSync() : null;
      }

      final result = MigrationDriftScanner(
        scriptBody: scriptBody,
        migrationFilenames: filenames,
        docBodies: docBodies,
        generatedAtUtc: DateTime.utc(2026, 5, 2),
      ).scan(fix: false);

      expect(result.cutoffClean, isTrue);
      expect(result.hasLikelyDocDrift, isFalse);
    });
  });
}
