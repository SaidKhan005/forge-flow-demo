// Slice B.4 audit — role_audit_log gains operator_id; legacy indexes
// are dropped and replaced with operator-leading variants.
//
// The `202605010001_phase_9_b4_role_audit_log_operator_id.sql`
// migration:
//
//   * Adds `operator_id uuid null` to `role_audit_log`.
//   * Backfills it from `roles.operator_id` (role_id-keyed rows) or
//     `user_roles.operator_id` (user_role_id-keyed rows). Global role
//     mutations stay NULL.
//   * Drops the three legacy non-operator-leading indexes via
//     `drop index concurrently if exists` and creates five
//     operator-leading replacements via
//     `create index concurrently if not exists` (split into tenant +
//     global partials, mirroring auth_events_audit).
//   * Replaces the 9.0Σ.b subquery-based per-tenant SELECT policy
//     with a direct operator_id check using
//     `public.app_current_operator()`.
//
// Two layers, mirroring `user_roles_scope_check_test.dart`:
//
//   1. STRUCTURAL (offline, every run): grep the migration file for
//      the expected DDL clauses so a refactor that drops or renames
//      one of them surfaces in the standard test pass.
//   2. INTEGRATION (passive-by-default, gated on
//      `FORGE_FLOW_RUN_STAGING_ROLE_AUDIT_LOG_TEST=true` +
//      POSTGRES_URL + POSTGRES_ADMIN_URL): assume the migration has
//      been applied to staging out-of-band (CONCURRENTLY index ops
//      cannot run inside `BEGIN; … COMMIT;`, so the standard
//      pool-driven test transaction cannot apply it). Two checks:
//
//        (a) Schema state via `adminPool` (forge_admin BYPASSRLS):
//            queries `information_schema` / `pg_indexes` /
//            `pg_proc` / `pg_constraint` to assert the column,
//            indexes, BEFORE INSERT trigger function, and
//            source-not-null CHECK exist (and the legacy indexes
//            don't). Admin pool is the correct surface for pg-
//            catalog introspection; no `SET ROLE` games.
//
//        (b) RLS dynamics via `tenantPool` + `TenantTransactionWrapper.
//            runInTenantContext`: a sentinel operator UUID that
//            does not match any real staging tenant must see no
//            rows where `operator_id IS NOT NULL`. This is the
//            same path repositories use at runtime (set_config of
//            `app.operator_id`, service_role role inherited from
//            the tenant DSN). The check is vacuous on a staging
//            DB with zero tenant-scoped role_audit_log rows; that
//            is acknowledged — full RLS isolation for
//            role_audit_log is covered by the B36 sweep
//            (`phase_9_0sigma_rls_isolation_sweep_test.dart`)
//            once role_audit_log is added to its table list.
//
//      Live target is staging only — never Production1.
//
// CLAUDE.md bindings:
//   * `package:postgres` is not imported here; all SQL flows through
//     `PackagePostgresPool` + `TenantTransactionWrapper`, so SET
//     LOCAL discipline holds and the rule against direct
//     `package:postgres` imports outside
//     `lib/infrastructure/persistence/postgres/` is preserved.
//   * Admin pool is reserved for pg-catalog introspection; tenant
//     reads run through `runInTenantContext`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _migrationPath =
    'db/migrations/202605010001_phase_9_b4_role_audit_log_operator_id.sql';

const String _envFlag =
    'FORGE_FLOW_RUN_STAGING_ROLE_AUDIT_LOG_TEST';
const String _envPostgresUrl = 'POSTGRES_URL';
const String _envPostgresAdminUrl = 'POSTGRES_ADMIN_URL';

const List<String> _legacyIndexNames = <String>[
  'role_audit_log_role_changed_idx',
  'role_audit_log_user_role_changed_idx',
  'role_audit_log_changed_at_idx',
];

const List<String> _newIndexNames = <String>[
  'role_audit_log_operator_role_changed_idx',
  'role_audit_log_operator_user_role_changed_idx',
  'role_audit_log_global_role_changed_idx',
  'role_audit_log_operator_changed_idx',
  'role_audit_log_global_changed_idx',
];

void main() {
  // ─── STRUCTURAL layer (offline, every run) ───────────────────────

  group('role_audit_log slice B.4 migration shape', () {
    final migrationFile = File(_migrationPath);

    test('migration file exists', () {
      expect(
        migrationFile.existsSync(),
        isTrue,
        reason: 'expected migration at $_migrationPath',
      );
    });

    // Normalize CRLF → LF on read so multi-line `contains(...)`
    // assertions are platform-independent. Windows checkouts via the
    // default `core.autocrlf=true` setting deliver CRLF line endings,
    // which would otherwise break literal-string assertions that span
    // multiple lines (matches the convention used by
    // `phase_9_0sigma_b_rls_wrappers_test.dart`).
    final migration = migrationFile.existsSync()
        ? migrationFile.readAsStringSync().replaceAll('\r\n', '\n')
        : '';

    test('adds operator_id column to role_audit_log', () {
      expect(
        migration,
        contains('add column if not exists operator_id uuid null'),
      );
    });

    test('backfill authoritatively rewrites every source-keyed row '
        'from the resolved source (no operator_id IS NULL filter)',
        () {
      // The backfill MUST NOT filter on `ral.operator_id is null`.
      // The ADD COLUMN → CREATE TRIGGER window is small but non-zero;
      // a writer in that window can land a row with a non-null but
      // misattributed operator_id (e.g., guessed from a different
      // request). Since operator_id is purely denormalized from
      // roles / user_roles, the backfill rewrites every source-keyed
      // row from its resolved source. Misattributed rows get
      // corrected; unresolved rows collapse to NULL and are caught
      // by the verify in step 5. Idempotent in result: re-runs
      // recompute the same value.
      expect(migration, contains('update public.role_audit_log'));
      expect(migration, contains('coalesce'));
      expect(migration, contains('public.roles'));
      expect(migration, contains('public.user_roles'));

      // Pin the exact backfill OUTER WHERE clause so a regression
      // that re-introduces the operator_id IS NULL filter surfaces
      // here. Subquery WHEREs inside the COALESCE legitimately use
      // `where ur.…` / `where r.…`; the outer WHERE uses the `ral`
      // alias. Anchor on `where ral.` to skip the subquery WHEREs.
      final updateStart = migration.indexOf(
        'update public.role_audit_log as ral',
      );
      expect(
        updateStart,
        isNonNegative,
        reason: 'backfill UPDATE statement must be present',
      );
      final outerWhereStart = migration.indexOf(
        '\n where ral.',
        updateStart,
      );
      expect(
        outerWhereStart,
        isNonNegative,
        reason:
            'backfill UPDATE must terminate with an outer WHERE on '
            'the `ral` alias',
      );
      final stmtEnd = migration.indexOf(';', outerWhereStart);
      final outerWhere = migration
          .substring(outerWhereStart, stmtEnd)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      expect(
        outerWhere,
        equals(
          'where ral.role_id is not null or ral.user_role_id is '
          'not null',
        ),
        reason:
            'backfill outer WHERE must be exactly `ral.role_id is '
            'not null or ral.user_role_id is not null`. Adding a '
            'guard on `ral.operator_id is null` re-opens the '
            'misattributed-row regression: a row inserted with a '
            'wrong non-null operator_id in the ADD COLUMN → CREATE '
            'TRIGGER window would be skipped by backfill AND verify '
            'and survive into the policy swap.',
      );

      // Order matters: user_roles is preferred (its operator_id is
      // NOT NULL) so a row carrying both source ids resolves to the
      // grant-mutation tenant. The trigger uses the same precedence;
      // backfill and trigger must agree or COALESCE could short-
      // circuit on a global-role NULL when a user_role_id-side
      // resolution would have given a tenant.
      final userRolesIdx = migration.indexOf(
        'from public.user_roles ur',
      );
      final rolesIdx = migration.indexOf('from public.roles r');
      expect(
        userRolesIdx,
        isNonNegative,
        reason: 'backfill must reference public.user_roles',
      );
      expect(
        rolesIdx,
        greaterThan(userRolesIdx),
        reason:
            'backfill COALESCE must lookup user_roles before roles so '
            'global-role NULLs do not short-circuit a valid tenant '
            'resolution',
      );
    });

    test('verifies no regression-bearing pre-existing rows: both-NULL '
        'AND unresolved-source classes each raise', () {
      // Two distinct pre-existing-row classes would silently flip
      // from "hidden" (legacy subquery policy) to "globally visible"
      // (new direct-operator_id policy):
      //
      //   (a) both-NULL    role_id AND user_role_id both NULL
      //   (b) unresolved   non-null source id w/ no matching row
      //
      // The DO block must count + raise on each so an operator can't
      // ship the policy swap until both classes are cleaned up.
      expect(
        migration,
        contains(r'do $$'),
        reason:
            'verification must run as a DO block so RAISE EXCEPTION '
            'aborts the migration step',
      );

      // ─── (a) both-NULL ─────────────────────────────────────────
      expect(migration, contains('v_both_null bigint'));
      expect(migration, contains('count(*) into v_both_null'));
      expect(
        migration,
        contains(
          'where role_id is null\n'
          '     and user_role_id is null',
        ),
        reason:
            'both-NULL count must filter exactly on role_id IS NULL '
            'AND user_role_id IS NULL',
      );
      expect(
        migration,
        contains('% pre-existing row(s) with both '),
        reason:
            'both-NULL raise must call out "pre-existing" so the '
            'operator knows it is not a writer bug',
      );

      // ─── (b) unresolved-source ─────────────────────────────────
      expect(migration, contains('v_unresolved bigint'));
      expect(migration, contains('count(*) into v_unresolved'));
      // The unresolvedness predicate must check both source columns
      // independently so a row with one resolved + one dangling id is
      // not falsely flagged (the trigger / backfill resolves either
      // side; only a row with NEITHER side resolvable is unresolved).
      expect(
        migration,
        contains(
          'ral.role_id is null\n'
          '       or not exists (\n'
          '         select 1 from public.roles r '
          'where r.role_id = ral.role_id\n'
          '       )',
        ),
      );
      expect(
        migration,
        contains(
          'ral.user_role_id is null\n'
          '       or not exists (\n'
          '         select 1 from public.user_roles ur',
        ),
      );

      // ─── shared raise posture ──────────────────────────────────
      // Both raises use errcode 23514 (check_violation).
      final raiseCount =
          'raise exception'.allMatches(migration).length;
      expect(
        raiseCount,
        greaterThanOrEqualTo(3),
        reason:
            'expected at least three RAISE EXCEPTION (both-NULL, '
            'unresolved, trigger NOT FOUND); found $raiseCount',
      );
      final errcodeCount =
          "using errcode = '23514'".allMatches(migration).length;
      expect(
        errcodeCount,
        greaterThanOrEqualTo(3),
        reason:
            'every RAISE EXCEPTION should carry errcode 23514 so '
            'callers can recognize the class of failure',
      );
    });

    test('CHECK constraint is added NOT VALID then immediately '
        'VALIDATEd so pre-existing both-NULL rows cannot survive', () {
      // ADD CONSTRAINT … NOT VALID without VALIDATE only blocks
      // FUTURE writes; VALIDATE re-checks every existing row. Without
      // this step, a both-NULL row that somehow slipped past the DO
      // block above would still survive into the policy swap and
      // become globally visible.
      expect(
        migration,
        contains(
          'add constraint role_audit_log_source_not_null\n'
          '  check (role_id is not null or user_role_id is not null) '
          'not valid;',
        ),
      );
      expect(
        migration,
        contains(
          'alter table public.role_audit_log\n'
          '  validate constraint role_audit_log_source_not_null;',
        ),
        reason:
            'VALIDATE CONSTRAINT is required so the CHECK applies to '
            'pre-existing rows, not just future inserts',
      );
      // Idempotent: the migration must drop any prior version of the
      // constraint before re-adding so a re-apply doesn't error.
      expect(
        migration,
        contains(
          'drop constraint if exists role_audit_log_source_not_null',
        ),
      );

      // Order matters: DROP < ADD < VALIDATE.
      final dropIdx = migration.indexOf(
        'drop constraint if exists role_audit_log_source_not_null',
      );
      final addIdx = migration.indexOf(
        'add constraint role_audit_log_source_not_null',
      );
      final validateIdx = migration.indexOf(
        'validate constraint role_audit_log_source_not_null',
      );
      expect(dropIdx, isNonNegative);
      expect(addIdx, greaterThan(dropIdx));
      expect(
        validateIdx,
        greaterThan(addIdx),
        reason:
            'VALIDATE CONSTRAINT must come after ADD CONSTRAINT, '
            'never before',
      );
    });

    test('drops every legacy index CONCURRENTLY', () {
      for (final name in _legacyIndexNames) {
        expect(
          migration,
          contains('drop index concurrently if exists public.$name'),
          reason: 'legacy index $name must be dropped CONCURRENTLY',
        );
      }
    });

    test('creates every replacement index CONCURRENTLY with '
        'operator_id leading', () {
      for (final name in _newIndexNames) {
        expect(
          migration,
          contains('create index concurrently if not exists $name'),
          reason: 'replacement index $name must be created CONCURRENTLY',
        );
      }
    });

    test('replacement indexes use the operator-id-leading discipline',
        () {
      // Tenant partials lead with operator_id directly; global
      // partials are exempt via WHERE operator_id IS NULL.
      expect(
        migration,
        contains(
          'on public.role_audit_log (operator_id, role_id, '
          'changed_at desc)',
        ),
      );
      expect(
        migration,
        contains(
          'on public.role_audit_log (operator_id, user_role_id, '
          'changed_at desc)',
        ),
      );
      expect(
        migration,
        contains(
          'on public.role_audit_log (operator_id, changed_at desc)',
        ),
      );
      // Global partials are gated on operator_id IS NULL.
      expect(migration, contains('where operator_id is null'));
    });

    test('BEFORE INSERT trigger denormalizes operator_id and uses '
        'IF FOUND to distinguish global-role NULL from missing-source '
        'NULL (raises on NOT FOUND)', () {
      // Function declaration with the locked posture.
      expect(
        migration,
        contains(
          'create or replace function '
          'public.role_audit_log_resolve_operator_id()',
        ),
      );
      expect(migration, contains('returns trigger'));
      expect(migration, contains('language plpgsql'));
      // Both source-of-truth lookups must be present so the trigger
      // resolves user_role_id-keyed and role_id-keyed rows alike.
      expect(
        migration,
        contains(
          'select ur.operator_id into v_op\n'
          '      from public.user_roles ur\n'
          '     where ur.user_role_id = new.user_role_id;',
        ),
      );
      expect(
        migration,
        contains(
          'select r.operator_id into v_op\n'
          '      from public.roles r\n'
          '     where r.role_id = new.role_id;',
        ),
      );
      // Each lookup is followed by `IF FOUND THEN … RETURN NEW` so a
      // global role (FOUND TRUE, operator_id NULL) propagates NULL
      // intentionally — distinct from the missing-source case.
      expect(
        migration,
        contains(
          'if found then\n'
          '      new.operator_id := v_op;\n'
          '      return new;\n'
          '    end if;',
        ),
      );
      // If neither lookup found a source row, the trigger MUST raise.
      // Without the raise, an unresolved INSERT would silently land
      // operator_id NULL and become globally visible.
      expect(
        migration,
        contains(
          'raise exception\n'
          "    'role_audit_log: source mutation does not reference an "
          "existing '\n"
          "    'roles or user_roles row",
        ),
      );
      expect(
        migration,
        contains("using errcode = '23514'"),
      );
      // Trigger is BEFORE INSERT FOR EACH ROW.
      expect(
        migration,
        contains(
          'create trigger role_audit_log_resolve_operator_id_trg\n'
          '  before insert on public.role_audit_log\n'
          '  for each row\n'
          '  execute function '
          'public.role_audit_log_resolve_operator_id();',
        ),
      );
    });

    test('replaces RLS SELECT policy with direct operator_id check '
        'using app_current_operator()', () {
      expect(
        migration,
        contains(
          'drop policy if exists "role_audit_log_per_tenant_select"\n'
          '  on public.role_audit_log;',
        ),
      );
      expect(
        migration,
        contains(
          'create policy "role_audit_log_per_tenant_select"\n'
          '  on public.role_audit_log for select to service_role',
        ),
      );
      expect(
        migration,
        contains('operator_id = public.app_current_operator()'),
      );
      // The new policy must NOT re-introduce the legacy
      // roles/user_roles subquery pattern.
      expect(
        migration,
        isNot(contains('select role_id from public.roles')),
      );
      expect(
        migration,
        isNot(contains('select user_role_id from public.user_roles')),
      );
    });

    test('write gate is installed BEFORE backfill / verify so the '
        'live-writer window cannot land bad rows behind the verify',
        () {
      // The migration is applied statement-by-statement; live writers
      // are not blocked between statements. If CREATE TRIGGER ran
      // AFTER the backfill or verify, a legacy writer (one that
      // doesn't set operator_id) could land a row with a dangling
      // source id between the verify and the trigger install — the
      // row would survive every defense and become globally visible
      // after the policy swap. This test pins the trigger-first
      // ordering so that regression cannot return.
      final triggerIdx = migration.indexOf(
        'create trigger role_audit_log_resolve_operator_id_trg',
      );
      final functionIdx = migration.indexOf(
        'create or replace function '
        'public.role_audit_log_resolve_operator_id()',
      );
      final backfillIdx = migration.indexOf(
        'update public.role_audit_log as ral',
      );
      final verifyIdx = migration.indexOf(r'do $$');
      final policyDropIdx = migration.indexOf(
        'drop policy if exists "role_audit_log_per_tenant_select"',
      );

      expect(triggerIdx, isNonNegative);
      expect(functionIdx, isNonNegative);
      expect(backfillIdx, isNonNegative);
      expect(verifyIdx, isNonNegative);
      expect(policyDropIdx, isNonNegative);

      // Function must be created before the trigger references it.
      expect(
        triggerIdx,
        greaterThan(functionIdx),
        reason:
            'CREATE TRIGGER must reference an already-created '
            'trigger function',
      );
      // The write gate must precede the data-shape work.
      expect(
        backfillIdx,
        greaterThan(triggerIdx),
        reason:
            'backfill UPDATE must run AFTER CREATE TRIGGER — '
            'otherwise legacy writers can insert dangling-source '
            'rows during the backfill / verify window and survive '
            'every defense',
      );
      expect(
        verifyIdx,
        greaterThan(triggerIdx),
        reason:
            'DO block verification must run AFTER CREATE TRIGGER '
            'so the set of rows being checked is frozen',
      );
      // And the policy swap is the last visibility-affecting change.
      expect(
        policyDropIdx,
        greaterThan(verifyIdx),
        reason:
            'RLS policy swap must come AFTER the verification '
            'block — otherwise the simplified policy could expose '
            'unverified rows globally',
      );
    });
  });

  // ─── INTEGRATION layer (passive-by-default, staging only) ────────

  final flagRaw = Platform.environment[_envFlag] ?? '';
  final liveEnabled =
      flagRaw.toLowerCase() == 'true' || flagRaw == '1';

  if (!liveEnabled) {
    test(
      'role_audit_log slice B.4 integration (passive default)',
      () {
        // The skip below is the contract — body intentionally empty.
      },
      skip:
          'role_audit_log index-reorder integration is passive by '
          'default. To run against staging Postgres, set $_envFlag=true '
          'and provide $_envPostgresUrl + $_envPostgresAdminUrl. Live '
          'target is staging only — never Production1.',
    );
    return;
  }

  final pgAdminUrl = Platform.environment[_envPostgresAdminUrl];
  final pgUrl = Platform.environment[_envPostgresUrl];
  final missingEnv = <String>[
    if (pgUrl == null || pgUrl.isEmpty) _envPostgresUrl,
    if (pgAdminUrl == null || pgAdminUrl.isEmpty) _envPostgresAdminUrl,
  ];
  if (missingEnv.isNotEmpty) {
    test('role_audit_log slice B.4 — env preflight', () {
      fail(
        'BLOCKED: $_envFlag is true but required env names are '
        'missing: ${missingEnv.join(', ')}. Source the staging env '
        'loader (scripts/use_postgres_staging_env.ps1) and re-run. '
        'No env values are echoed by this test.',
      );
    });
    return;
  }

  late PackagePostgresPool adminPool;
  late PackagePostgresPool tenantPool;
  late TenantTransactionWrapper tenantWrapper;

  setUpAll(() {
    adminPool = PackagePostgresPool.fromUrl(pgAdminUrl!);
    tenantPool = PackagePostgresPool.fromUrl(pgUrl!);
    tenantWrapper = TenantTransactionWrapper(tenantPool);
  });

  test(
    'staging schema reflects slice B.4: column, indexes, trigger, '
    'and CHECK present (admin pg-catalog introspection)',
    () async {
      final tx = await adminPool.beginTransaction();
      try {
        // operator_id column exists.
        final colRows = await tx.query(
          "select column_name from information_schema.columns "
          "where table_schema = 'public' "
          "and table_name = 'role_audit_log' "
          "and column_name = 'operator_id'",
        );
        expect(
          colRows,
          hasLength(1),
          reason:
              'role_audit_log.operator_id should exist after slice B.4. '
              'If staging has not received the migration yet, run '
              'db/migrations/202605010001_phase_9_b4_role_audit_log_'
              'operator_id.sql against staging.',
        );

        // Legacy indexes are gone; new indexes are present.
        final idxRows = await tx.query(
          "select indexname from pg_indexes "
          "where schemaname = 'public' "
          "and tablename = 'role_audit_log'",
        );
        final names = idxRows
            .map((r) => (r['indexname']! as String).toLowerCase())
            .toSet();

        for (final legacy in _legacyIndexNames) {
          expect(
            names,
            isNot(contains(legacy)),
            reason: 'legacy index $legacy should have been dropped',
          );
        }
        for (final fresh in _newIndexNames) {
          expect(
            names,
            contains(fresh),
            reason: 'replacement index $fresh should exist',
          );
        }

        // BEFORE INSERT trigger function exists with the right
        // attachment.
        final trigRows = await tx.query(
          "select t.tgname, p.proname "
          "from pg_trigger t "
          "join pg_class c on c.oid = t.tgrelid "
          "join pg_namespace n on n.oid = c.relnamespace "
          "join pg_proc p on p.oid = t.tgfoid "
          "where n.nspname = 'public' "
          "and c.relname = 'role_audit_log' "
          "and t.tgname = 'role_audit_log_resolve_operator_id_trg' "
          "and not t.tgisinternal",
        );
        expect(
          trigRows,
          hasLength(1),
          reason:
              'BEFORE INSERT trigger '
              'role_audit_log_resolve_operator_id_trg should be '
              'attached to public.role_audit_log',
        );
        expect(
          trigRows.first['proname'],
          'role_audit_log_resolve_operator_id',
        );

        // Source-not-null CHECK constraint exists.
        final ckRows = await tx.query(
          "select conname from pg_constraint c "
          "join pg_class t on t.oid = c.conrelid "
          "join pg_namespace n on n.oid = t.relnamespace "
          "where n.nspname = 'public' "
          "and t.relname = 'role_audit_log' "
          "and c.contype = 'c' "
          "and c.conname = 'role_audit_log_source_not_null'",
        );
        expect(
          ckRows,
          hasLength(1),
          reason:
              'CHECK constraint role_audit_log_source_not_null should '
              'exist so a both-NULL row cannot become globally visible',
        );
      } finally {
        await tx.rollback();
      }
    },
  );

  test(
    'tenant context with a sentinel operator sees no rows where '
    'operator_id is non-null (RLS dynamics via TenantTransactionWrapper)',
    () async {
      // Sentinel operator UUID — does not match any real staging
      // tenant by construction. Under the simplified policy
      // (`operator_id IS NULL OR operator_id = app_current_operator()`),
      // a session bound to this sentinel must see only rows whose
      // operator_id is NULL — never another tenant's rows.
      //
      // The check is non-vacuous as long as staging has at least one
      // tenant-scoped role_audit_log row (very likely after any auth
      // exercise). On an empty staging DB the test trivially passes;
      // full positive coverage belongs in the B36 RLS sweep
      // (`phase_9_0sigma_rls_isolation_sweep_test.dart`).
      const sentinelOp = '00000000-0000-0000-0000-0000deadbeef';
      const sentinelLoc = '00000000-0000-0000-0000-0000baadf00d';

      final visible = await tenantWrapper.runInTenantContext(
        TenantContext(
          operatorId: sentinelOp,
          locationId: sentinelLoc,
        ),
        (exec) async {
          return exec.query(
            'select count(*)::bigint as c '
            'from public.role_audit_log '
            'where operator_id is not null',
          );
        },
      );

      expect(
        visible,
        hasLength(1),
        reason: 'count query should always return exactly one row',
      );
      expect(
        visible.first['c'],
        0,
        reason:
            'service_role bound to a sentinel operator_id must not see '
            "any tenant-scoped role_audit_log rows. A non-zero count "
            'indicates the simplified RLS policy is leaking another '
            "tenant's audit rows.",
      );
    },
  );
}
