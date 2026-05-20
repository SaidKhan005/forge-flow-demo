// Phase 9.0Σ.k — rollups foundation tests (split).
//
// Bucket 5j of test-suite tightening audit 2026-05-20. The original
// phase_9_0sigma_k_rollups_test.dart (2,012 lines, 8 top-level groups)
// was split into two focused files. Filename prefix
// `phase_9_0sigma_k_` is LOAD-BEARING per Authority Order — both
// files keep that prefix so the migration / phase trace stays
// grep-discoverable.
//
// This file: groups 7–8 (RLS lint + rebuild runbook).
//
//   7. RLS lint against the two new operator-scoped migrations
//      (aggregation_state has no RLS; rollup_tables has seven
//      policies that must all pass the wrapper-only lint).
//   8. Rebuild runbook contract — documents bounded rebuild scope,
//      staging→validate→promote sequence, failure / freshness
//      behaviour per Q3.7/Q3.8/Q3.9.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/rls_policy_lint.dart';

void main() {
  // ─── 6. RLS lint against the rollup migrations ────────────────────

  group('Phase 9.0Σ.k RLS lint', () {
    test('rollup_tables migration passes the policy-aware lint '
        '(every per_tenant policy reads through the wrapper)', () {
      final body = _readSqlNormalized(
        'db/migrations/'
        '202604280010_b_phase_9_0sigma_k_rollup_tables.sql',
      );
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280010_b_phase_9_0sigma_k_rollup_tables.sql': body,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'every rollup_<grain>_per_tenant policy MUST read GUCs '
            'through the 9.0Σ.b wrappers; violations: '
            '${result.violations}',
      );
    });

    test('aggregation_state migration has no CREATE POLICY (internal '
        'infra, not operator-scoped) so the lint passes trivially', () {
      final body = _readSqlNormalized(
        'db/migrations/'
        '202604280010_a_phase_9_0sigma_k_aggregation_state.sql',
      );
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280010_a_phase_9_0sigma_k_aggregation_state.sql': body,
        },
        allowlist: const <String>{},
      ).run();
      expect(result.isClean, isTrue);
      expect(body, isNot(contains('create policy')));
      expect(body, isNot(contains('enable row level security')));
    });
  });

  // ─── 7. Rebuild runbook contract ─────────────────────────────────

  group('Phase 9.0Σ.k rebuild runbook', () {
    final runbook = File(
      'docs/phases/phase_9/phase_9_rollups_rebuild_runbook.md',
    );

    setUpAll(() {
      expect(
        runbook.existsSync(),
        isTrue,
        reason: 'rebuild runbook must accompany the worker + migrations',
      );
    });

    test('documents the bounded rebuild scope axes (Q3.8)', () {
      final body = runbook.readAsStringSync();
      // Q3.8: bounded scope = operator + org_unit/location + metric
      // family + date range + grain + rule_version.
      for (final axis in const <String>[
        'operator',
        'org unit',
        'location',
        'metric family',
        'date range',
        'grain',
        'rule_version',
      ]) {
        expect(
          body.toLowerCase(),
          contains(axis.toLowerCase()),
          reason: 'runbook must list rebuild scope axis: $axis',
        );
      }
    });

    test('documents staging → validate → promote sequence (Q3.8) and '
        'failure / freshness behaviour (Q3.9)', () {
      final body = runbook.readAsStringSync().toLowerCase();
      expect(body, contains('staging'));
      expect(body, contains('validate'));
      expect(body, contains('promote'));
      // Q3.9 failure / Q3.7 freshness behaviour.
      expect(body, contains('last known good'));
      expect(body, contains('stale'));
    });
  });
}

/// Read the SQL file and collapse CRLF → LF so multi-line
/// `contains(...)` assertions work on Windows checkouts.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
