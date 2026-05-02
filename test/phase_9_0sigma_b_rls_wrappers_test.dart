// Phase 9.0Σ.b — RLS wrapper migration + lint coverage.
//
// Local framework slice (no live database). Three groups:
//
//   1. Wrapper migration shape — proves the four wrapper functions
//      exist with the LANGUAGE sql STABLE LEAKPROOF PARALLEL SAFE
//      posture item 4 locks, that they read the correct app.* GUCs,
//      and that they are granted EXECUTE to both runtime roles.
//
//   2. Rewrite migration coverage — proves the rewrite migration
//      drops every per-tenant auth policy from 202604260000 and
//      recreates each one through a wrapper. No bare-GUC reads remain
//      in the rewriter's output, and the policy count matches the
//      live-staging closeout.
//
//   3. Lint behavior — exercises the [RlsPolicyLintRunner] façade
//      against (a) the real on-disk migrations + allowlist (clean),
//      (b) a synthetic new file with a bare-GUC violation (fails),
//      (c) an allowlisted superseded file (skipped), and (d) a
//      wrapper-only file (clean).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/rls_policy_lint.dart';

void main() {
  group('Phase 9.0Σ.b wrapper migration', () {
    // Normalize CRLF → LF on read so multi-line `contains(...)`
    // assertions are platform-independent. Windows checkouts via the
    // default `core.autocrlf=true` setting deliver CRLF line endings,
    // which would otherwise break literal-string assertions that span
    // multiple lines.
    final wrapperSql = _readSqlNormalized(
      'db/migrations/'
      '202604280000_phase_9_0sigma_b_rls_wrappers.sql',
    );

    test('declares four wrappers with the locked posture', () {
      const expected = <String, String>{
        'app_current_operator': 'app.operator_id',
        'app_current_location': 'app.location_id',
        'app_current_actor_user': 'app.user_id',
        'app_acting_as_operator': 'app.acting_as_operator_id',
      };
      for (final entry in expected.entries) {
        final body = _extractFunctionBody(wrapperSql, entry.key);
        expect(body, isNotNull, reason: 'wrapper ${entry.key} not declared');
        expect(
          body,
          contains('returns uuid'),
          reason: '${entry.key} must return uuid',
        );
        expect(
          body,
          contains('language sql'),
          reason: '${entry.key} must be language sql',
        );
        expect(
          body,
          contains('stable parallel safe'),
          reason: '${entry.key} must be STABLE PARALLEL SAFE',
        );
        expect(
          wrapperSql,
          contains('alter function public.${entry.key}() leakproof;'),
          reason:
              '${entry.key} must be marked LEAKPROOF after creation '
              '(item 4 locked posture)',
        );
        expect(
          body,
          contains(
            "nullif(current_setting('${entry.value}', true), '')"
            '::uuid',
          ),
          reason:
              '${entry.key} must read ${entry.value} via NULL-safe '
              'cast so missing/empty GUCs collapse to NULL',
        );
      }
    });

    test('grants EXECUTE on every wrapper to service_role and forge_admin', () {
      const wrapperNames = <String>[
        'app_current_operator',
        'app_current_location',
        'app_current_actor_user',
        'app_acting_as_operator',
      ];
      for (final name in wrapperNames) {
        expect(
          wrapperSql,
          contains(
            'grant execute on function public.$name() '
            'to service_role',
          ),
          reason:
              '$name must be EXECUTE-able by service_role for '
              'tenant runtime',
        );
        expect(
          wrapperSql,
          contains(
            'grant execute on function public.$name() '
            'to forge_admin',
          ),
          reason:
              '$name must be EXECUTE-able by forge_admin so the '
              'BYPASSRLS escape hatch can still evaluate predicates',
        );
      }
    });

    test('does not declare wrappers as SECURITY DEFINER', () {
      // SECURITY INVOKER (the default) is required so a tenant
      // cannot use the wrapper to escalate. Item 4 does not call
      // for SECURITY DEFINER, and accidentally adding it would be
      // a privilege bug.
      expect(
        wrapperSql.toLowerCase(),
        isNot(contains('security definer')),
        reason:
            'wrappers must run with caller privileges (default '
            'SECURITY INVOKER)',
      );
    });
  });

  group('Phase 9.0Σ.b rewrite migration', () {
    final rewriteSql = _readSqlNormalized(
      'db/migrations/'
      '202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql',
    );

    test('drops every per-tenant policy created in 202604260000', () {
      const policiesFromOriginal = <String, String>{
        'permission_keys_authenticated_select': 'public.permission_keys',
        'roles_per_tenant_select': 'public.roles',
        'roles_per_tenant_modify': 'public.roles',
        'role_permissions_per_tenant_select': 'public.role_permissions',
        'role_permissions_per_tenant_modify': 'public.role_permissions',
        'user_roles_per_tenant': 'public.user_roles',
        'auth_sessions_per_user': 'public.auth_sessions',
        'mfa_factors_per_user': 'public.mfa_factors',
        'tncs_acceptances_per_tenant': 'public.tncs_acceptances',
        'password_history_per_user': 'public.password_history',
        'auth_invites_per_tenant': 'public.auth_invites',
        'auth_events_audit_per_tenant_select': 'public.auth_events_audit',
        'auth_events_audit_append_insert': 'public.auth_events_audit',
        'role_audit_log_per_tenant_select': 'public.role_audit_log',
        'role_audit_log_append_insert': 'public.role_audit_log',
        'external_identity_links_per_tenant': 'public.external_identity_links',
      };
      for (final entry in policiesFromOriginal.entries) {
        expect(
          rewriteSql,
          contains(
            'drop policy if exists "${entry.key}" '
            'on ${entry.value}',
          ),
          reason:
              'rewrite must drop ${entry.key} so the new wrapper '
              'version replaces the bare-GUC version atomically',
        );
        expect(
          rewriteSql,
          contains('create policy "${entry.key}"'),
          reason:
              'rewrite must recreate ${entry.key} through '
              'wrappers',
        );
      }
    });

    test('rewrite policy bodies contain no bare current_setting calls', () {
      // The whole point of the slice — every operator-scoped policy
      // body in the rewrite must read GUCs through wrappers only.
      // Use the policy-aware lint runner so comments / prose that
      // reference the old pattern do not trip the assertion.
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql':
              rewriteSql,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'rewrite policy bodies must not contain bare app.* '
            'current_setting calls; violations: ${result.violations}',
      );
    });

    test('rewrite calls each wrapper at least once', () {
      // app_current_location and app_acting_as_operator are not used
      // by the auth tables (no per-location auth surface today and
      // no impersonation policies yet), so this test only asserts
      // the two wrappers the auth tables need.
      expect(rewriteSql, contains('app_current_operator()'));
      expect(rewriteSql, contains('app_current_actor_user()'));
    });

    test('preserves auth-events-audit append-only WITH CHECK shape', () {
      // The 9.2 policy used `with check (true)` so failed-login
      // rows still write even when tenant resolution fails. The
      // wrapper rewrite must keep that exact shape — narrowing to
      // a tenant predicate would silently drop pre-tenant audit
      // rows.
      expect(
        rewriteSql,
        contains(
          'create policy "auth_events_audit_append_insert"\n'
          '  on public.auth_events_audit for insert to service_role\n'
          '  with check (true);',
        ),
      );
    });
  });

  // HARD-F — defense-in-depth re-assert of the same wrapper-based
  // policies. The hardening migration is intentionally a wire-for-wire
  // duplicate of 202604280001 so that a database that lost the rewrite
  // (hand-edit on staging, out-of-band restore that resurrected the
  // 9.2 shape) still ends up wrapper-clean after this slice applies.
  // Asserting it here keeps a future hand-edit from quietly diverging
  // the two migrations — name presence is not enough; the predicate
  // body, the role grant, and the WITH CHECK clause must all match.
  group('HARD-F hardening migration', () {
    final hardeningSql = _readSqlNormalized(
      'db/migrations/'
      '202605020500_hardening_auth_rls_to_wrappers.sql',
    );
    final rewriteParitySql = _readSqlNormalized(
      'db/migrations/'
      '202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql',
    );

    test('every CREATE POLICY block matches the 202604280001 rewrite '
        'byte-for-byte (after whitespace normalization) — the migration '
        'must be a wire-for-wire duplicate so a widened/narrowed '
        'predicate or an altered WITH CHECK cannot drift unnoticed', () {
      final hardeningPolicies = _extractCreatePolicyBlocks(hardeningSql);
      final rewritePolicies = _extractCreatePolicyBlocks(rewriteParitySql);

      // Sanity check: both files capture the same 16-policy set the
      // 9.2 migration originally created.
      expect(
        hardeningPolicies.keys.toSet(),
        equals(rewritePolicies.keys.toSet()),
        reason:
            'hardening migration must drop+recreate exactly the same '
            'set of policies as 202604280001 — different policy sets '
            'mean the migrations are no longer parity siblings',
      );
      expect(
        hardeningPolicies, hasLength(16),
        reason:
            '202604280001 recreates 16 policies (12 tables, 4 of which '
            'have two policies each); hardening must match',
      );

      // Each policy body is identical after whitespace normalization.
      // The normalized form preserves every keyword, identifier,
      // operator, and predicate — only collapses runs of whitespace.
      for (final name in hardeningPolicies.keys) {
        expect(
          hardeningPolicies[name],
          equals(rewritePolicies[name]),
          reason:
              'policy "$name" body diverges from 202604280001. The '
              'hardening migration MUST be wire-for-wire identical so '
              'a widened predicate, narrowed WITH CHECK, or changed '
              'role grant cannot land here without also landing in the '
              'rewrite. Diff:\n'
              '  hardening: ${hardeningPolicies[name]}\n'
              '  rewrite:   ${rewritePolicies[name]}',
        );
      }
    });

    test('every COMMENT ON POLICY restored matches the 202604280001 '
        'rewrite — DROP POLICY removes the comment along with the '
        'policy object, so the re-assert must lay every comment back '
        'down with identical wording or `\\dp+` diverges between the '
        'two parity sibling migrations', () {
      final hardeningComments = _extractCommentOnPolicy(hardeningSql);
      final rewriteComments = _extractCommentOnPolicy(rewriteParitySql);

      expect(
        hardeningComments.keys.toSet(),
        equals(rewriteComments.keys.toSet()),
        reason:
            'hardening migration must restore exactly the same set of '
            'COMMENT ON POLICY statements as 202604280001 — missing '
            'restorations leave the database without comments after '
            'the DROP POLICY pass; extra restorations mean a comment '
            'lives in HARD-F that has no rewrite-side counterpart. '
            'hardening: ${hardeningComments.keys.toList()..sort()}, '
            'rewrite: ${rewriteComments.keys.toList()..sort()}',
      );
      expect(
        hardeningComments, hasLength(5),
        reason:
            '202604280001 carries forward 5 COMMENT ON POLICY '
            'statements (permission_keys, roles_per_tenant_select, '
            'user_roles_per_tenant, auth_sessions_per_user, '
            'auth_events_audit_per_tenant_select); hardening must '
            'match',
      );

      for (final name in hardeningComments.keys) {
        expect(
          hardeningComments[name],
          equals(rewriteComments[name]),
          reason:
              'comment on policy "$name" diverges from 202604280001. '
              'Reword in lockstep across both files or the database '
              'state diverges by which one was applied last. Diff:\n'
              '  hardening: ${hardeningComments[name]}\n'
              '  rewrite:   ${rewriteComments[name]}',
        );
      }
    });

    test('drops + recreates every per-tenant policy from 202604260000', () {
      const policiesFromOriginal = <String, String>{
        'permission_keys_authenticated_select': 'public.permission_keys',
        'roles_per_tenant_select': 'public.roles',
        'roles_per_tenant_modify': 'public.roles',
        'role_permissions_per_tenant_select': 'public.role_permissions',
        'role_permissions_per_tenant_modify': 'public.role_permissions',
        'user_roles_per_tenant': 'public.user_roles',
        'auth_sessions_per_user': 'public.auth_sessions',
        'mfa_factors_per_user': 'public.mfa_factors',
        'tncs_acceptances_per_tenant': 'public.tncs_acceptances',
        'password_history_per_user': 'public.password_history',
        'auth_invites_per_tenant': 'public.auth_invites',
        'auth_events_audit_per_tenant_select': 'public.auth_events_audit',
        'auth_events_audit_append_insert': 'public.auth_events_audit',
        'role_audit_log_per_tenant_select': 'public.role_audit_log',
        'role_audit_log_append_insert': 'public.role_audit_log',
        'external_identity_links_per_tenant': 'public.external_identity_links',
      };
      for (final entry in policiesFromOriginal.entries) {
        expect(
          hardeningSql,
          contains(
            'drop policy if exists "${entry.key}" '
            'on ${entry.value}',
          ),
          reason:
              'hardening migration must drop ${entry.key} so the '
              're-assert is atomic on a database that lost the '
              '202604280001 rewrite',
        );
        expect(
          hardeningSql,
          contains('create policy "${entry.key}"'),
          reason:
              'hardening migration must recreate ${entry.key} '
              'through wrappers',
        );
      }
    });

    test('hardening policy bodies contain no bare current_setting calls', () {
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202605020500_hardening_auth_rls_to_wrappers.sql': hardeningSql,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'hardening migration must read GUCs through wrappers '
            'only; violations: ${result.violations}',
      );
    });

    test('hardening migration calls the same two wrappers as the rewrite', () {
      // app_current_location / app_acting_as_operator are not used
      // by the auth tables (matches the 202604280001 rewrite scope).
      expect(hardeningSql, contains('app_current_operator()'));
      expect(hardeningSql, contains('app_current_actor_user()'));
    });

    test('preserves auth-events-audit append-only WITH CHECK shape', () {
      expect(
        hardeningSql,
        contains(
          'create policy "auth_events_audit_append_insert"\n'
          '  on public.auth_events_audit for insert to service_role\n'
          '  with check (true);',
        ),
      );
    });
  });

  group('rls_policy_lint', () {
    test('clean against the real on-disk migrations + allowlist', () {
      final files = _readMigrationsDir();
      final allowlist = _readAllowlist();
      final result = RlsPolicyLintRunner(
        files: files,
        allowlist: allowlist,
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason: 'real tree should pass; violations: ${result.violations}',
      );
      expect(result.scannedFileCount, greaterThan(0));
      expect(result.allowlistedFileCount, greaterThan(0));
    });

    test('fails on a synthetic new bare-GUC policy', () {
      const violator = '''
create policy "new_table_per_tenant"
  on public.new_table for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid)
  with check (operator_id = current_setting('app.operator_id', true)::uuid);
''';
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604290000_new_table_policies.sql': violator,
        },
        allowlist: const <String>{},
      ).run();
      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(1));
      expect(result.violations.single.policyName, 'new_table_per_tenant');
      expect(
        result.violations.single.fileName,
        '202604290000_new_table_policies.sql',
      );
    });

    test('skips a file present in the allowlist', () {
      const violator = '''
create policy "old_per_tenant"
  on public.legacy for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid);
''';
      final result = RlsPolicyLintRunner(
        files: <String, String>{'202604010000_legacy_policies.sql': violator},
        allowlist: const <String>{'202604010000_legacy_policies.sql'},
      ).run();
      expect(result.isClean, isTrue);
      expect(result.allowlistedFileCount, 1);
      expect(result.scannedFileCount, 1);
    });

    test('passes on a wrapper-only policy body', () {
      const wrapperOnly = '''
create policy "new_table_per_tenant"
  on public.new_table for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());
''';
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604290000_new_table_policies.sql': wrapperOnly,
        },
        allowlist: const <String>{},
      ).run();
      expect(result.isClean, isTrue);
    });

    test('ignores prose `current_setting` references outside policy '
        'bodies', () {
      // The 202604250008 auth schema foundation has the literal
      // string `current_setting('app.operator_id', true)::uuid`
      // inside a SQL comment, NOT inside a CREATE POLICY body. A
      // naïve grep would flag this; the policy-aware scanner must
      // not.
      const docOnly = '''
-- Phase 9.2 flips these to per-tenant policies using
-- `current_setting('app.operator_id', true)::uuid`. Until then…

create policy "stub_service_role_all"
  on public.stub for all to service_role
  using (true) with check (true);
''';
      final result = RlsPolicyLintRunner(
        files: <String, String>{'202604010001_stub_policies.sql': docOnly},
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'lint must only inspect CREATE POLICY bodies, not '
            'free-form comments or prose',
      );
    });

    test('flags a bare-GUC policy declared with an unquoted name', () {
      // PG accepts both `create policy "name" ...` and
      // `create policy name ...`. Earlier versions of the lint only
      // matched the quoted form, which would have left an easy
      // accidental bypass if a future migration omitted the quotes.
      const unquotedViolator = '''
create policy tenant_guard
  on public.t1 for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid);
''';
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604290002_unquoted_policy.sql': unquotedViolator,
        },
        allowlist: const <String>{},
      ).run();
      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(1));
      expect(result.violations.single.policyName, 'tenant_guard');
    });

    test('flags every offending policy in a multi-policy file', () {
      const twoBadOneGood = '''
create policy "first_bad"
  on public.t1 for all to service_role
  using (operator_id = current_setting('app.operator_id', true)::uuid);

create policy "good"
  on public.t2 for all to service_role
  using (operator_id = public.app_current_operator());

create policy "second_bad"
  on public.t3 for all to service_role
  using (user_id = current_setting('app.user_id', true)::uuid);
''';
      final result = RlsPolicyLintRunner(
        files: <String, String>{'202604290001_mixed.sql': twoBadOneGood},
        allowlist: const <String>{},
      ).run();
      expect(result.violations, hasLength(2));
      expect(
        result.violations.map((v) => v.policyName).toSet(),
        equals(<String>{'first_bad', 'second_bad'}),
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

/// Returns the body between `create or replace function public.<name>()`
/// and the matching `$$;` terminator. Returns null if the function is
/// not found.
String? _extractFunctionBody(String sql, String functionName) {
  final pattern = RegExp(
    'create\\s+or\\s+replace\\s+function\\s+public\\.'
    '${RegExp.escape(functionName)}\\s*\\(\\s*\\)([\\s\\S]*?)\\\$\\\$;',
    caseSensitive: false,
  );
  final match = pattern.firstMatch(sql);
  return match?.group(0)?.toLowerCase();
}

Map<String, String> _readMigrationsDir() {
  final dir = Directory('db/migrations');
  expect(
    dir.existsSync(),
    isTrue,
    reason: 'tests must run from repository root',
  );
  final out = <String, String>{};
  for (final entity in dir.listSync()) {
    if (entity is File && entity.path.toLowerCase().endsWith('.sql')) {
      final name = entity.uri.pathSegments.last;
      out[name] = entity.readAsStringSync().replaceAll('\r\n', '\n');
    }
  }
  return out;
}

Set<String> _readAllowlist() {
  final file = File('tool/rls_policy_lint_allowlist.txt');
  if (!file.existsSync()) return <String>{};
  final out = <String>{};
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    out.add(line);
  }
  return out;
}

/// Extracts every `create policy "<name>" ... ;` block from [sql] and
/// returns a map of policy name → whitespace-normalized block body.
/// Used by the HARD-F parity test to compare the hardening migration
/// against `202604280001` byte-for-byte. Only matches the quoted-name
/// form because both files declare every policy with double quotes;
/// extending to bare identifiers would introduce ambiguity (a future
/// migration that mixed forms could mask drift).
Map<String, String> _extractCreatePolicyBlocks(String sql) {
  final pattern = RegExp(
    r'''create\s+policy\s+"([^"]+)"([\s\S]*?);''',
    caseSensitive: false,
  );
  final out = <String, String>{};
  for (final match in pattern.allMatches(sql)) {
    final name = match.group(1)!;
    final block = match.group(0)!;
    out[name] = _normalizeWhitespaceLowered(block);
  }
  return out;
}

/// Lowercases [s] and collapses every whitespace run (spaces, tabs,
/// newlines) to a single space, then trims. Two SQL blocks that
/// differ only in indentation, line wrapping, or keyword case
/// normalize to the same string; any token, identifier, predicate, or
/// grant difference survives the normalization and shows up as a
/// diff. Safe for CREATE POLICY bodies because Postgres parses SQL
/// case-insensitively and stores no string literal — every byte is
/// part of the policy definition, not user-visible text.
String _normalizeWhitespaceLowered(String s) {
  return s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Like [_normalizeWhitespaceLowered] but **preserves case**. Use for
/// `COMMENT ON POLICY '<text>'` because the SQL string literal IS the
/// stored comment text — Postgres keeps it byte-identical, and `\dp+`
/// renders it verbatim. Lowercasing here would silently equate two
/// comments whose stored text differs only in case (e.g. one says
/// `WITH CHECK` and the other says `with check`), which would still
/// diverge in production.
String _normalizeWhitespacePreserveCase(String s) {
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Extracts every `comment on policy "<name>" on <table> is '<text>';`
/// statement from [sql] and returns a map of policy name →
/// case-preserving, whitespace-normalized statement.
///
/// Whitespace collapse handles the SQL standard's adjacent-string-
/// literal concatenation rule (`'first ' 'second'` parses as
/// `first second`) — the two parity siblings can split their literal
/// across lines differently and still compare equal as long as the
/// case-preserving payload is the same.
///
/// Case is preserved precisely because Postgres stores the literal
/// verbatim. A future writer that swaps the case inside the literal
/// (deliberately or by accident) shows up as a real diff here even
/// though the surrounding SQL keywords are case-insensitive.
Map<String, String> _extractCommentOnPolicy(String sql) {
  final pattern = RegExp(
    r'''comment\s+on\s+policy\s+"([^"]+)"([\s\S]*?);''',
    caseSensitive: false,
  );
  final out = <String, String>{};
  for (final match in pattern.allMatches(sql)) {
    final name = match.group(1)!;
    final stmt = match.group(0)!;
    out[name] = _normalizeWhitespacePreserveCase(stmt);
  }
  return out;
}
