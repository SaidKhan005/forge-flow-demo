// Smoke test for `tool/agent_self_audit.dart`.
//
// Drives the public `AgentSelfAuditRunner` façade with synthetic inputs
// (changed-file lists, diff text, file-body lookup) and a fake
// subprocess runner that pretends every lint exited 0 unless the test
// overrides one. Asserts the produced markdown table + exit code.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/agent_self_audit.dart';

SubprocessRun _fakeRun({
  required String label,
  required String executable,
  required List<String> args,
}) {
  return SubprocessRun(
    label: label,
    command: '$executable ${args.join(' ')}',
    exitCode: 0,
    stdout: '$label stdout',
    stderr: '',
  );
}

SubprocessRunner _failingRunnerFor(String failingLabel) {
  return ({
    required String label,
    required String executable,
    required List<String> args,
  }) {
    return SubprocessRun(
      label: label,
      command: '$executable ${args.join(' ')}',
      exitCode: label == failingLabel ? 1 : 0,
      stdout: '$label stdout',
      stderr: label == failingLabel ? '$label boom' : '',
    );
  };
}

void main() {
  group('agent_self_audit', () {
    test('clean inputs → exit 0 and all four guards pass', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>[
          'tool/agent_self_audit.dart',
          'test/tool/agent_self_audit_test.dart',
        ],
        diffText:
            '''diff --git a/tool/agent_self_audit.dart b/tool/agent_self_audit.dart
+ added a benign line
+ another benign change
''',
        fileBodyLookup: (path) => '// fixture body for $path\n',
        subprocessRunner: _fakeRun,
        migrationsTouched: false,
      );

      final result = runner.run();
      expect(result.isClean, isTrue);
      expect(result.exitCode, 0);

      final report = renderAgentSelfAuditReport(
        result: result,
        diffBase: 'origin/master',
        changedFileCount: 2,
      );
      expect(report, contains('| Check | Result | Notes |'));
      expect(report, contains('no --no-verify in diff'));
      expect(report, contains('no edits under lib/data/**'));
      expect(
        report,
        contains('no out-of-scope package:postgres import'),
      );
      expect(
        report,
        contains('no edits to lib/auth/permission_keys.dart'),
      );
      expect(report, contains('advisor_proxy_size_lint'));
      // migrations skipped when no db/migrations/** touched.
      expect(
        report,
        contains('skipped — no db/migrations/** edits in diff'),
      );
    });

    test('--no-verify in an added diff line trips the guard', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>['scripts/foo.sh'],
        diffText:
            '''diff --git a/scripts/foo.sh b/scripts/foo.sh
+ git push --no-verify origin HEAD
''',
        fileBodyLookup: (_) => '',
        subprocessRunner: _fakeRun,
        migrationsTouched: false,
      );

      final result = runner.run();
      expect(result.exitCode, 1);
      final report = renderAgentSelfAuditReport(
        result: result,
        diffBase: 'origin/master',
        changedFileCount: 1,
      );
      expect(
        report,
        contains('| no --no-verify in diff | fail |'),
      );
    });

    test('--no-verify in a DELETED line does NOT trip the guard', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>['scripts/foo.sh'],
        diffText:
            '''diff --git a/scripts/foo.sh b/scripts/foo.sh
- git push --no-verify origin HEAD
+ git push origin HEAD
''',
        fileBodyLookup: (_) => '',
        subprocessRunner: _fakeRun,
        migrationsTouched: false,
      );
      final result = runner.run();
      expect(result.exitCode, 0);
    });

    test('edit under lib/data/** trips the frozen-path guard', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>['lib/data/legacy_repo.dart'],
        diffText: '',
        fileBodyLookup: (_) => '',
        subprocessRunner: _fakeRun,
        migrationsTouched: false,
      );
      final result = runner.run();
      expect(result.exitCode, 1);
      final report = renderAgentSelfAuditReport(
        result: result,
        diffBase: 'origin/master',
        changedFileCount: 1,
      );
      expect(
        report,
        contains('| no edits under lib/data/** | fail |'),
      );
    });

    test('package:postgres import outside allowed dirs trips the guard',
        () {
      const offending = "import 'package:postgres/postgres.dart';\n";
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>['lib/services/some_service.dart'],
        diffText: '',
        fileBodyLookup: (path) =>
            path == 'lib/services/some_service.dart' ? offending : null,
        subprocessRunner: _fakeRun,
        migrationsTouched: false,
      );
      final result = runner.run();
      expect(result.exitCode, 1);
    });

    test(
      'package:postgres import inside lib/infrastructure/persistence/'
      'postgres/ is allowed',
      () {
        const okImport = "import 'package:postgres/postgres.dart';\n";
        final runner = AgentSelfAuditRunner(
          diffBase: 'origin/master',
          changedFiles: const <String>[
            'lib/infrastructure/persistence/postgres/adapter.dart',
          ],
          diffText: '',
          fileBodyLookup: (_) => okImport,
          subprocessRunner: _fakeRun,
          migrationsTouched: false,
        );
        final result = runner.run();
        expect(result.exitCode, 0);
      },
    );

    test('editing lib/auth/permission_keys.dart trips the guard', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>['lib/auth/permission_keys.dart'],
        diffText: '',
        fileBodyLookup: (_) => '',
        subprocessRunner: _fakeRun,
        migrationsTouched: false,
      );
      final result = runner.run();
      expect(result.exitCode, 1);
    });

    test('migrations touched → drift+cutoff rows appear (and gate)', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>[
          'db/migrations/202605131111_test_migration.sql',
        ],
        diffText: '',
        fileBodyLookup: (_) => null,
        subprocessRunner: _fakeRun,
        migrationsTouched: true,
      );
      final result = runner.run();
      expect(result.exitCode, 0);
      final report = renderAgentSelfAuditReport(
        result: result,
        diffBase: 'origin/master',
        changedFileCount: 1,
      );
      expect(
        report,
        contains('migration_drift_scanner --strict-docs'),
      );
      expect(report, contains('migration_cutoff_lint'));
      expect(
        report,
        isNot(contains('skipped — no db/migrations/** edits in diff')),
      );
    });

    test('migration_drift_scanner failure → exit 1', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>[
          'db/migrations/202605131111_test_migration.sql',
        ],
        diffText: '',
        fileBodyLookup: (_) => null,
        subprocessRunner: _failingRunnerFor('migration_drift_scanner'),
        migrationsTouched: true,
      );
      final result = runner.run();
      expect(result.exitCode, 1);
    });

    test('advisor_proxy_size_lint failure → exit 1', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>['tool/agent_self_audit.dart'],
        diffText: '',
        fileBodyLookup: (_) => '',
        subprocessRunner: _failingRunnerFor('advisor_proxy_size_lint'),
        migrationsTouched: false,
      );
      final result = runner.run();
      expect(result.exitCode, 1);
    });

    test(
      'dart analyze --fatal-infos failure is advisory (does NOT gate)',
      () {
        final runner = AgentSelfAuditRunner(
          diffBase: 'origin/master',
          changedFiles: const <String>['tool/agent_self_audit.dart'],
          diffText: '',
          fileBodyLookup: (_) => '',
          subprocessRunner: _failingRunnerFor('dart analyze --fatal-infos'),
          migrationsTouched: false,
        );
        final result = runner.run();
        // baseline carries 5 errors per phase_0_smoke; that's not a
        // script-defined failure.
        expect(result.exitCode, 0);
        final report = renderAgentSelfAuditReport(
          result: result,
          diffBase: 'origin/master',
          changedFileCount: 1,
        );
        expect(
          report,
          contains('| dart analyze --fatal-infos | baseline |'),
        );
      },
    );

    test('rendered report includes the raw subprocess block', () {
      final runner = AgentSelfAuditRunner(
        diffBase: 'origin/master',
        changedFiles: const <String>['tool/agent_self_audit.dart'],
        diffText: '',
        fileBodyLookup: (_) => '',
        subprocessRunner: _fakeRun,
        migrationsTouched: false,
      );
      final result = runner.run();
      final report = renderAgentSelfAuditReport(
        result: result,
        diffBase: 'origin/master',
        changedFileCount: 1,
      );
      expect(report, contains('## Raw subprocess output'));
      expect(report, contains('### advisor_proxy_size_lint (exit 0)'));
    });
  });
}
