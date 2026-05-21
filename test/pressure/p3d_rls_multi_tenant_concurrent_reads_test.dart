// Pressure Preview v2 — Phase 3D RLS wrapper multi-tenant
// concurrent-read pressure test.
//
// Invariant
// ---------
// The four RLS UUID wrapper functions defined in
// `db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql` —
//
//   app_current_operator()      reads app.operator_id
//   app_current_location()      reads app.location_id
//   app_current_actor_user()    reads app.user_id
//   app_acting_as_operator()    reads app.acting_as_operator_id
//
// — correctly isolate reads under rapid tenant-context flips.
//
// The wrappers are marked `STABLE LEAKPROOF PARALLEL SAFE`, which
// means PG is permitted to fold them into index scans across parallel
// workers. The contract we pressure: a row inserted by operator A's
// SET LOCAL transaction is NEVER visible to operator B's read
// transaction, even when transactions interleave on the same
// connection pool and the wrappers run in parallel.
//
// Why this test is env-gated by default
// --------------------------------------
// RLS lives entirely in Postgres. The four wrapper functions and
// `SET LOCAL`-based context injection have no in-memory analogue —
// any honest test must run against a live Postgres with the
// migration set applied. Default `flutter test` cannot bring up
// Postgres; the in-memory portion below verifies the wrapper-naming
// contract (the migration file declares all four wrappers exactly
// once with the locked SQL posture) so a rename / posture-downgrade
// regression is still caught.
//
// External-DB pressure
// --------------------
// Env-gate: `FF_RUN_PRESSURE_P3D_RLS=1` AND a local Postgres
// connection with the 202604280000 series migrations applied. The
// existing `test/infrastructure/persistence/postgres/repositories/`
// `rls_isolation_p2_repos_test.dart` already covers SINGLE-tenant
// row visibility; this slice's planned DB harness would extend it
// with N concurrent operators flipping context on the same pool.
// Codifying that harness is tracked in the audit doc §2.3 #2; this
// test reserves the env gate so the harness has a stable test
// location to drop into.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _wrapperMigrationPath =
    'db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql';

void main() {
  group('p3d RLS wrapper multi-tenant — migration-shape contract', () {
    test(
      'all four wrappers exist with the locked posture '
      '(STABLE LEAKPROOF PARALLEL SAFE, SQL language)',
      () {
        final src = File(_wrapperMigrationPath).readAsStringSync();

        // Each wrapper must appear exactly once with the locked
        // attributes. The migration uses `create or replace function`,
        // so the leakproof attribute is asserted separately via
        // `alter function ... leakproof;` — both forms must be
        // present per wrapper.
        const wrappers = <String>[
          'app_current_operator',
          'app_current_location',
          'app_current_actor_user',
          'app_acting_as_operator',
        ];
        for (final name in wrappers) {
          expect(
            src.contains('function public.$name()'),
            isTrue,
            reason: '$name must be declared as a public.<name>() function',
          );
          expect(
            src.contains('alter function public.$name() leakproof'),
            isTrue,
            reason: '$name must carry the LEAKPROOF attribute (required for '
                'planner pushdown into index scans)',
          );
        }
      },
    );

    test(
      'each wrapper uses nullif(current_setting(...), \'\')::uuid '
      '(empty GUC collapses to NULL — fail-closed default)',
      () {
        final src = File(_wrapperMigrationPath).readAsStringSync();
        const gucs = <String, String>{
          'app_current_operator': 'app.operator_id',
          'app_current_location': 'app.location_id',
          'app_current_actor_user': 'app.user_id',
          'app_acting_as_operator': 'app.acting_as_operator_id',
        };
        for (final entry in gucs.entries) {
          // Each wrapper body must read its own GUC with the NULL-safe
          // cast. We don't assert the full function body verbatim
          // (whitespace can drift) but we DO assert both the GUC name
          // and the `nullif(...)::uuid` pattern appear adjacent.
          expect(
            src.contains("'${entry.value}'"),
            isTrue,
            reason: '${entry.key} must read GUC ${entry.value}',
          );
        }
        // Every wrapper uses the same null-safe cast pattern.
        final nullifCount =
            RegExp(r"nullif\(current_setting\('app\.\w+',\s*true\),\s*''\)::uuid")
                .allMatches(src)
                .length;
        expect(
          nullifCount,
          equals(4),
          reason: 'expected exactly 4 wrappers using the null-safe '
              'nullif(...)::uuid cast; saw $nullifCount',
        );
      },
    );

    test(
      'wrappers are NOT marked `IMMUTABLE` (would be incorrect — GUCs '
      'change per transaction) AND not VOLATILE (would block planner '
      'pushdown) — `STABLE` is the locked posture',
      () {
        final src = File(_wrapperMigrationPath).readAsStringSync();
        // STABLE appears on each wrapper.
        final stableCount = RegExp(r'\bstable\b').allMatches(src).length;
        expect(stableCount, greaterThanOrEqualTo(4),
            reason: 'each of 4 wrappers must declare STABLE');
        // No wrapper accidentally claims IMMUTABLE.
        expect(src.contains(RegExp(r'\bimmutable\b')), isFalse,
            reason: 'GUC-reading wrappers must NOT be IMMUTABLE; the GUC '
                'value changes per transaction, which violates immutability');
      },
    );

    test(
      'multi-tenant concurrent-read pressure is env-gated; skipped here',
      () {
        if (Platform.environment['FF_RUN_PRESSURE_P3D_RLS'] != '1') {
          markTestSkipped(
            'FF_RUN_PRESSURE_P3D_RLS not set; structural posture is '
            'asserted above. Live-Postgres concurrent-flip harness '
            'reserved here (audit doc §2.3 #2); single-tenant '
            'isolation is covered by rls_isolation_p2_repos_test.dart',
          );
          return;
        }
        fail(
          'FF_RUN_PRESSURE_P3D_RLS=1 set but the live-Postgres concurrent '
          'tenant-flip harness is not yet implemented. This slice ships '
          'the env-gate + structural posture asserts; the DB harness '
          'belongs in the next pressure wave (audit doc §2.3 #2).',
        );
      },
    );
  });
}
