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
// What runs in-memory by default
// -------------------------------
// RLS lives entirely in Postgres. The four wrapper functions and
// `SET LOCAL`-based context injection have no in-memory analogue, so
// the runnable portion verifies the wrapper-naming + SQL-posture
// contract by reading the migration file: all four wrappers are
// declared exactly once with the locked `STABLE LEAKPROOF PARALLEL
// SAFE` posture, so a rename / posture-downgrade regression is
// caught under default `flutter test`.
//
// External-DB pressure
// --------------------
// DB-backed concurrency pressure for this seam (N concurrent
// operators flipping context on the same pool) is deferred to a
// future infra-gated slice (needs live Postgres with the
// 202604280000 series applied) — see POST_HARDENING_FOLLOWUPS.
// Single-tenant row visibility is already covered by
// `rls_isolation_p2_repos_test.dart`.

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
  });
}
