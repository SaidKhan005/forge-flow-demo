// ignore_for_file: file_names
//
// Filename intentionally mirrors the migration filename
// (`db/migrations/202605021500_phase_9_0sigma_l_rls_depth.sql`) so a
// reviewer can correlate test ↔ migration at a glance. The Dart
// `file_names` lint rejects digit-leading filenames; ignoring it here
// is the project convention for test/migrations/<timestamp>_test.dart.
//
// Phase 9.0Σ.l — RLS defense-in-depth migration shape coverage.
//
// Local-framework slice — same posture as
// `test/phase_9_0sigma_b_rls_wrappers_test.dart`. Asserts the on-disk
// migration declares the expected DDL: RLS enabled on both tables,
// the permissive 11a.11c.1 stub policies dropped, and the new
// wrapper-based per-tenant policies present with the predicate shape
// the slice prompt names.
//
// Live cross-tenant SELECT/INSERT/UPDATE/DELETE behavior on a real
// staging DB is exercised by the B36 RLS isolation sweep, which this
// slice extends to cover proxy_requests + feature_flags
// (`test/phase_9_0sigma_rls_isolation_sweep_test.dart`). Splitting
// the two suites keeps the migration-shape assertions deterministic
// and CI-cheap; the live sweep stays passive-by-default and runs
// only when staging credentials are sourced.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/rls_policy_lint.dart';

void main() {
  // CRLF → LF on read so multi-line `contains(...)` assertions are
  // platform-independent. Windows checkouts deliver CRLF by default
  // (`core.autocrlf=true`); the migration itself is LF-only on disk
  // per the slice prompt's CRLF-normalization requirement.
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202605021500_phase_9_0sigma_l_rls_depth.sql',
  );

  group('Phase 9.0Σ.l RLS depth migration', () {
    test('asserts RLS enabled on both tables (idempotent)', () {
      // Idempotent re-assert — `ALTER TABLE … ENABLE RLS` is a no-op
      // when RLS is already on. Both tables had RLS enabled in
      // 202604250005, but re-asserting is the spec'd posture so a
      // database that somehow lost RLS on either table comes back to
      // the locked state after applying this migration.
      expect(
        migrationSql,
        contains('alter table public.proxy_requests enable row level security'),
        reason:
            'proxy_requests RLS must be re-asserted (idempotent on '
            'top of 202604250005)',
      );
      expect(
        migrationSql,
        contains('alter table public.feature_flags enable row level security'),
        reason:
            'feature_flags RLS must be re-asserted (idempotent on '
            'top of 202604250005)',
      );
    });

    test('drops the permissive 11a.11c.1 service-role-only stubs', () {
      expect(
        migrationSql,
        contains(
          'drop policy if exists "proxy_requests_service_role_all"\n'
          '  on public.proxy_requests;',
        ),
        reason:
            'must drop the using=true stub from 202604250005 so the '
            'wrapper-based policy replaces it atomically',
      );
      expect(
        migrationSql,
        contains(
          'drop policy if exists "feature_flags_service_role_all"\n'
          '  on public.feature_flags;',
        ),
        reason:
            'must drop the using=true stub from 202604250005 so the '
            'wrapper-based policy replaces it atomically',
      );
    });

    test('proxy_requests policy filters on (operator_id, location_id) '
        'via wrappers — both USING and WITH CHECK', () {
      expect(
        migrationSql,
        contains('create policy "proxy_requests_tenant_isolation"\n'
            '  on public.proxy_requests for all to service_role'),
        reason:
            'tenant-isolation policy name + scope locked to match the '
            'slice prompt',
      );
      // USING half — visibility filter on (operator, location).
      expect(
        migrationSql,
        contains(
          'using (\n'
          '    operator_id = public.app_current_operator()\n'
          '    and location_id = public.app_current_location()\n'
          '  )',
        ),
        reason:
            'USING must filter on (operator_id, location_id) via the '
            'wrapper functions so the planner folds the predicate '
            'into the tenant-leading PK / idempotency-key UNIQUE '
            'index',
      );
      // WITH CHECK half — write-side parity with USING.
      expect(
        migrationSql,
        contains(
          'with check (\n'
          '    operator_id = public.app_current_operator()\n'
          '    and location_id = public.app_current_location()\n'
          '  )',
        ),
        reason:
            'WITH CHECK must mirror USING so a tenant cannot insert '
            'or update a row attributed to another (operator, '
            'location) pair',
      );
    });

    test('feature_flags policy: tenants read own + global, write own only', () {
      expect(
        migrationSql,
        contains('create policy "feature_flags_global_or_tenant"\n'
            '  on public.feature_flags for all to service_role'),
        reason:
            'tenant-or-global policy name + scope locked to match '
            'the slice prompt',
      );
      // USING half — global rows are visible to every tenant.
      expect(
        migrationSql,
        contains(
          'using (\n'
          '    operator_id is null\n'
          '    or operator_id = public.app_current_operator()\n'
          '  )',
        ),
        reason:
            'USING must allow operator_id IS NULL so launch-wide '
            'kill switches stay readable from every tenant context',
      );
      // WITH CHECK half — asymmetric: tenants cannot mutate global.
      expect(
        migrationSql,
        contains(
          'with check (\n'
          '    operator_id is not null\n'
          '    and operator_id = public.app_current_operator()\n'
          '  )',
        ),
        reason:
            'WITH CHECK must reject operator_id IS NULL so tenants '
            'cannot insert or update global-scope rows; super_admin '
            'mutations elevate to forge_admin BYPASSRLS',
      );
    });

    test('reads tenant context through wrappers only (no bare GUC)', () {
      // The whole point of item 4 — every operator-scoped policy
      // body in this migration must read GUCs through wrappers.
      // Reuse the policy-aware lint runner so any prose / comment
      // that mentions `current_setting` does not trip the
      // assertion.
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202605021500_phase_9_0sigma_l_rls_depth.sql': migrationSql,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'policy bodies must call app_current_operator() / '
            'app_current_location() — never bare current_setting; '
            'violations: ${result.violations}',
      );
    });

    test('does not add or rewrite indexes (RLS performance discipline '
        'compliance handled by 202604250007)', () {
      // CLAUDE.md "RLS performance discipline" + scalability-decisions
      // item 4: every B-tree index on operator-scoped tables MUST lead
      // with operator_id. proxy_requests already complies via
      // 202604250007_advisor_rls_index_hardening (PK + the
      // proxy_requests_operator_location_idempotency_key_key UNIQUE
      // both lead with (operator_id, location_id)). feature_flags
      // complies via the three partial unique indexes on
      // (flag_name, operator_id [, location_id]) from 202604250005,
      // which lead with the partition key for the global-scope
      // partial. This slice therefore intentionally ships zero index
      // DDL — the assertion guards against a future hand-edit that
      // accidentally adds a non-tenant-leading index here.
      expect(
        migrationSql.toLowerCase().contains('create index'),
        isFalse,
        reason:
            'this slice must not add indexes — RLS performance '
            'discipline is already satisfied by 202604250007 + '
            'the partial unique indexes from 202604250005',
      );
      expect(
        migrationSql.toLowerCase().contains('create unique index'),
        isFalse,
        reason: 'see above — no new unique indexes either',
      );
    });

    test('does not declare any policy as SECURITY DEFINER', () {
      // Wrapper functions are SECURITY INVOKER (the default); policies
      // do not have a DEFINER posture themselves, but a future
      // hand-edit might switch a referenced helper to DEFINER. The
      // direct check rejects accidental escalation.
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('security definer')),
        reason:
            'no SECURITY DEFINER — every wrapper call runs with the '
            'caller\'s privileges so a tenant cannot escalate',
      );
    });

    test('has carries-forward COMMENT ON POLICY for both new policies', () {
      // DROP POLICY removes the comment along with the object, so
      // the old `*_service_role_all` stubs (which had no comment in
      // 202604250005) lose nothing. The two new policies SHOULD
      // carry a COMMENT ON POLICY so `\dp+` on staging surfaces the
      // 9.0Σ.l attribution alongside the predicate body — matches
      // the pattern HARD-F restored on the auth tables.
      expect(
        migrationSql,
        contains(
          'comment on policy "proxy_requests_tenant_isolation" '
          'on public.proxy_requests is',
        ),
        reason:
            'the proxy_requests policy must carry a Phase 9.0Σ.l '
            'attribution comment so audit tooling can see why the '
            'permissive stub was replaced',
      );
      expect(
        migrationSql,
        contains(
          'comment on policy "feature_flags_global_or_tenant" '
          'on public.feature_flags is',
        ),
        reason:
            'the feature_flags policy must carry a Phase 9.0Σ.l '
            'attribution comment for the same reason',
      );
    });
  });
}

/// Reads [path] and collapses CRLF to LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
