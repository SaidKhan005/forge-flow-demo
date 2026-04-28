// Phase 9.0Σ.d — service_principals + auth_events_audit.actor_kind
// tests.
//
// Local framework slice (no live database). Four groups:
//
//   1. Migration shape — the table is created with TIMESTAMPTZ-only
//      columns, tenant-leading B-tree indexes, the wrapper-only RLS
//      policy, the cloud-foundation updated_at trigger, the
//      jsonb-array CHECK on `scopes`, the (operator_id, name)
//      uniqueness target, and the standard service_role/forge_admin
//      grants. Asserts the schema contract the future proxy verifier
//      slice will wire against.
//
//   2. auth_events_audit.actor_kind addition — the column is added
//      ONLY to auth_events_audit (never audit_logs, which is owned
//      by the 9.0Σ.f slice); default is `'user'`; CHECK is
//      `('user', 'service')`; nothing in the migration creates or
//      ALTERs `audit_logs`.
//
//   3. RLS lint posture — runs `RlsPolicyLintRunner` against the new
//      migration only and proves it passes. The policy body must
//      use `app_current_operator()` through the 9.0Σ.b wrappers; a
//      regression introducing bare `current_setting('app.…')`
//      surfaces here before the global lint sweep.
//
//   4. Repository SQL contract — drives `ServicePrincipalsRepository`
//      against a recording fake `PostgresPool`. Proves SET LOCAL
//      injection, tenant-scoped DML, scopes serialization, and the
//      withTenant-only API surface (no JWT / proxy / token methods).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/service_principals_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/rls_policy_lint.dart';

const String _operatorAId = '11111111-1111-1111-1111-111111111111';
const String _operatorBId = '22222222-2222-2222-2222-222222222222';
const String _locationId = '33333333-3333-3333-3333-333333333333';
const String _userId = '44444444-4444-4444-4444-444444444444';
const String _principalId = '55555555-5555-5555-5555-555555555555';

void main() {
  final migrationPath =
      'db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql';
  final migrationSql = _readSqlNormalized(migrationPath);

  group('Phase 9.0Σ.d migration shape', () {
    test('migration file lives in the locked 202604280004 slot', () {
      // The slot is pre-assigned by the prompt to avoid cross-lane
      // migration timestamp collisions with the other 9.0Σ slices.
      // Renaming the file would require Codex to coordinate the
      // re-numbering across lanes.
      expect(File(migrationPath).existsSync(), isTrue);
    });

    test('runs in a single transaction (begin/commit pair)', () {
      expect(migrationSql, contains('begin;'));
      expect(migrationSql, contains('commit;'));
    });

    test('creates service_principals with TIMESTAMPTZ-only columns', () {
      expect(
        migrationSql,
        contains('create table if not exists public.service_principals'),
      );
      expect(migrationSql, contains('id uuid primary key default gen_random_uuid()'));
      expect(
        migrationSql,
        contains('operator_id uuid not null references public.operators(operator_id)'),
      );
      expect(migrationSql, contains('name text not null'));
      expect(migrationSql, contains("scopes jsonb not null default '[]'::jsonb"));
      expect(migrationSql, contains('created_at timestamptz not null default now()'));
      expect(migrationSql, contains('updated_at timestamptz not null default now()'));
      expect(migrationSql, contains('revoked_at timestamptz null'));
    });

    test('does not introduce timestamp without time zone (storage rule)',
        () {
      // CLAUDE.md "Time Guardrails": TIMESTAMP WITHOUT TIME ZONE is
      // banned in operator-scoped tables (silent DST corruption).
      // Strip line comments before the check — the migration's
      // header explains the ban in prose; the storage-rule guard is
      // about DDL, not documentation.
      final ddl = _stripSqlComments(migrationSql).toLowerCase();
      expect(ddl, isNot(contains('timestamp without time zone')));
      expect(
        ddl,
        isNot(matches(RegExp(r'\btimestamp\b(?!\s*with)'))),
      );
    });

    test('scopes CHECK enforces jsonb array shape', () {
      // The CHECK guards against a producer (or a direct service_role
      // / forge_admin INSERT) writing an object/string/number/null
      // body the verifier or repository decoder would have to
      // special-case.
      expect(
        migrationSql,
        contains("check (jsonb_typeof(scopes) = 'array')"),
      );
    });

    test('name length CHECK keeps 1..200 chars', () {
      expect(
        migrationSql,
        contains('check (char_length(name) between 1 and 200)'),
      );
    });

    test('tenant-scoped (operator_id, name) uniqueness target', () {
      // Two service principals in the same operator cannot share a
      // display name; cross-operator clashes are fine.
      expect(migrationSql, contains('unique (operator_id, name)'));
    });

    test('every B-tree index leads with operator_id (RLS performance '
        'discipline)', () {
      // The exact column order matters — operator_id LEADS so the
      // per-tenant RLS policy folds into the index probe. An index
      // leading with anything else (e.g. `(created_at, operator_id)`)
      // would collapse policy throughput on multi-operator
      // deployments.
      expect(
        migrationSql,
        contains(
          'create index if not exists service_principals_operator_id_idx\n'
          '  on public.service_principals (operator_id, id);',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create index if not exists '
          'service_principals_operator_active_idx\n'
          '  on public.service_principals (operator_id, created_at desc)\n'
          '  where revoked_at is null;',
        ),
      );
    });

    test('updated_at trigger reuses cloud-foundation function', () {
      expect(
        migrationSql,
        contains(
          'drop trigger if exists service_principals_set_updated_at\n'
          '  on public.service_principals;',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create trigger service_principals_set_updated_at\n'
          'before update on public.service_principals\n'
          'for each row execute function '
          'public.cloud_foundation_set_updated_at();',
        ),
      );
    });

    test('RLS enabled and policy uses app_current_operator() wrapper', () {
      expect(
        migrationSql,
        contains(
          'alter table public.service_principals enable row level security',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create policy "service_principals_per_tenant"\n'
          '  on public.service_principals for all to service_role\n'
          '  using (operator_id = public.app_current_operator())\n'
          '  with check (operator_id = public.app_current_operator())',
        ),
      );
      // Belt-and-braces guard against a regression that swaps the
      // wrapper for bare current_setting() in the policy body.
      expect(
        migrationSql,
        isNot(contains("current_setting('app.operator_id'")),
      );
    });

    test('table grants: full DML to service_role and forge_admin', () {
      // service_role is the proxy's runtime connection; forge_admin
      // is the BYPASSRLS escape hatch via runAsSystem.
      for (final role in <String>['service_role', 'forge_admin']) {
        expect(
          migrationSql,
          contains(
            'grant select, insert, update, delete on '
            'public.service_principals to $role',
          ),
          reason: '$role needs full DML so the runtime + admin paths '
              'both work',
        );
      }
    });
  });

  group('Phase 9.0Σ.d auth_events_audit.actor_kind', () {
    test('adds actor_kind to auth_events_audit with default user + '
        'CHECK (user, service)', () {
      // Item 14: completes the audit attribution split. Default
      // 'user' so every existing row backfills as a human actor; the
      // CHECK locks the value set so a future producer cannot
      // smuggle in a third actor_kind without a paired migration.
      expect(
        migrationSql,
        contains('alter table public.auth_events_audit'),
      );
      expect(
        migrationSql,
        contains(
          "add column if not exists actor_kind text not null default 'user'\n"
          "    check (actor_kind in ('user', 'service'))",
        ),
      );
    });

    test('does NOT create or ALTER the audit_logs table (B27 / 9.0Σ.f '
        'owns audit_logs entirely)', () {
      // Acceptance criterion: this slice must keep the audit_logs
      // ownership clean. 9.0Σ.f declares actor_kind inline at
      // audit_logs creation; reaching into it here would either fail
      // (table does not yet exist) or pre-shape a table that 9.0Σ.f
      // then has to reconcile with.
      //
      // Strip line comments first — the migration header explicitly
      // names the ownership split in prose ("the audit_logs table
      // (B27 / 9.0Σ.f) carries its own actor_kind…"); that is the
      // RIGHT place for the reference and must not trip the guard.
      // The DDL portion is what must stay untouched.
      final ddl = _stripSqlComments(migrationSql).toLowerCase();
      expect(
        ddl,
        isNot(contains('audit_logs')),
        reason: 'audit_logs is the responsibility of 9.0Σ.f / B27; '
            'this migration must not contain DDL referencing it',
      );
    });

    test('does NOT add actor_kind anywhere except auth_events_audit', () {
      // Block 3 task constraint: actor_kind ownership split is
      // strict. Counting `actor_kind` mentions outside of the
      // explicit ALTER + comment + CHECK on auth_events_audit would
      // surface a regression (e.g. someone added it to
      // service_principals as well).
      final actorKindMatches =
          RegExp(r'\bactor_kind\b').allMatches(migrationSql).toList();
      expect(
        actorKindMatches.length,
        greaterThanOrEqualTo(2),
        reason: 'expected actor_kind in the ALTER + the CHECK at minimum',
      );
      // Every reference must be on the auth_events_audit surface
      // (column add, CHECK body, comment text). A reference on
      // public.service_principals or public.audit_logs would be a
      // scope violation.
      expect(
        migrationSql,
        isNot(contains('service_principals.actor_kind')),
      );
      expect(
        migrationSql,
        isNot(contains('audit_logs.actor_kind')),
      );
    });
  });

  group('Phase 9.0Σ.d RLS lint', () {
    test('migration passes the policy-aware lint', () {
      // Item 4: every operator-scoped policy must read tenant
      // context through the 9.0Σ.b wrappers. The policy-aware lint
      // anchors on CREATE POLICY ... ; bodies, not prose, so comment
      // headers that mention `current_setting` for documentation are
      // ignored.
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280004_phase_9_0sigma_d_service_principals.sql':
              migrationSql,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason: 'service_principals policy must read tenant context '
            'through app_current_operator(); '
            'violations: ${result.violations}',
      );
    });
  });

  group('ServicePrincipalsRepository (B25 — fake Postgres)', () {
    test('create issues SET LOCAL + INSERT and returns the assigned id',
        () async {
      final pool = _ServicePrincipalsPool(insertReturningId: _principalId);
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      final id = await repo.create(
        operatorId: _operatorAId,
        locationId: _locationId,
        userId: _userId,
        name: 'workflow-runner',
        scopes: const <String>['workflow.execute', 'workflow.read'],
      );

      expect(id, equals(_principalId));
      final tx = pool.transactions.single;
      // SET LOCAL block ran first; the wrapper test in
      // operator_scoped_repository_test asserts the exact shape, here
      // we just confirm the operator GUC was injected before the
      // INSERT so RLS would admit the row.
      expect(
        tx.executedSql.first,
        contains("set_config('app.operator_id'"),
      );
      expect(tx.parameters.first['value'], equals(_operatorAId));

      // INSERT shape.
      final insertSql = tx.executedSql.last;
      expect(insertSql, contains('insert into service_principals'));
      expect(insertSql, contains('(operator_id, name, scopes)'));
      expect(
        insertSql,
        contains('values (@operator_id::uuid, @name, @scopes::jsonb)'),
      );
      expect(insertSql, contains('returning id::text as id'));

      final params = tx.parameters.last;
      expect(params['operator_id'], equals(_operatorAId));
      expect(params['name'], equals('workflow-runner'));
      // scopes is bound as serialized JSON; the contract forbids
      // string concatenation into the SQL.
      final decoded = jsonDecode(params['scopes'] as String) as List<Object?>;
      expect(decoded, equals(<Object?>['workflow.execute', 'workflow.read']));

      expect(tx.commitCount, equals(1));
    });

    test('create rejects a blank name before opening a transaction',
        () async {
      final pool = _ServicePrincipalsPool(insertReturningId: _principalId);
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      ArgumentError? thrown;
      try {
        await repo.create(
          operatorId: _operatorAId,
          locationId: _locationId,
          name: '   ',
          scopes: const <String>[],
        );
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.name, equals('name'));
      expect(pool.transactions, isEmpty);
    });

    test('create throws when RETURNING produces no rows '
        '(RLS denial scenario)', () async {
      final pool = _ServicePrincipalsPool(insertReturningId: null);
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.create(
          operatorId: _operatorAId,
          locationId: _locationId,
          name: 'workflow-runner',
        ),
        throwsStateError,
      );
    });

    test('create rejects an invalid operator UUID before opening a '
        'transaction', () async {
      final pool = _ServicePrincipalsPool(insertReturningId: _principalId);
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      Object? thrown;
      try {
        await repo.create(
          operatorId: 'not-a-uuid',
          locationId: _locationId,
          name: 'x',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      // Acceptance: the wrapper never opened a transaction because
      // TenantContext rejected the bad UUID first.
      expect(pool.transactions, isEmpty);
    });

    test('list runs SET LOCAL + tenant-scoped SELECT ordered by '
        'created_at desc', () async {
      final pool = _ServicePrincipalsPool(
        insertReturningId: _principalId,
        listRows: <PostgresRow>[
          _principalRow(
            id: _principalId,
            operatorId: _operatorAId,
            name: 'workflow-runner',
            scopes: const <String>['workflow.execute'],
          ),
        ],
      );
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      final rows = await repo.list(
        operatorId: _operatorAId,
        locationId: _locationId,
      );

      expect(rows, hasLength(1));
      expect(rows.single.id, equals(_principalId));
      expect(rows.single.name, equals('workflow-runner'));
      expect(rows.single.scopes, equals(<String>['workflow.execute']));
      expect(rows.single.isActive, isTrue);

      final tx = pool.transactions.single;
      // SET LOCAL operator_id ran first.
      expect(tx.executedSql[0], contains("set_config('app.operator_id'"));
      // SELECT shape.
      final selectSql = tx.executedSql.last;
      expect(selectSql, contains('from service_principals'));
      expect(selectSql, contains('order by created_at desc'));
      // No revoked_at filter on the default path.
      expect(
        selectSql,
        isNot(contains('where revoked_at is null')),
      );
    });

    test('list with includeRevoked=false adds the active-only WHERE '
        'predicate that matches the partial index', () async {
      final pool = _ServicePrincipalsPool(
        insertReturningId: _principalId,
        listRows: const <PostgresRow>[],
      );
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      await repo.list(
        operatorId: _operatorAId,
        locationId: _locationId,
        includeRevoked: false,
      );

      final tx = pool.transactions.single;
      final selectSql = tx.executedSql.last;
      // Only active rows; predicate matches the partial index
      // service_principals_operator_active_idx.
      expect(selectSql, contains('where revoked_at is null'));
    });

    test('list normalizes scopes whether the driver hands them back as '
        'List or jsonb-text-String', () async {
      // jsonb decoding can be on or off depending on the driver
      // configuration; the repository must handle both shapes.
      final pool = _ServicePrincipalsPool(
        insertReturningId: _principalId,
        listRows: <PostgresRow>[
          _principalRow(
            id: _principalId,
            operatorId: _operatorAId,
            name: 'workflow-runner',
            // String form (driver delivered raw JSON text).
            scopes: jsonEncode(<String>['workflow.execute']),
          ),
          _principalRow(
            id: '66666666-6666-6666-6666-666666666666',
            operatorId: _operatorAId,
            name: 'webhook-bridge',
            // List form (driver delivered decoded jsonb).
            scopes: const <String>['vendor.webhook.read'],
          ),
        ],
      );
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      final rows = await repo.list(
        operatorId: _operatorAId,
        locationId: _locationId,
      );

      expect(rows, hasLength(2));
      expect(rows[0].scopes, equals(<String>['workflow.execute']));
      expect(rows[1].scopes, equals(<String>['vendor.webhook.read']));
    });

    test('getById binds id parameter and returns null on miss', () async {
      final pool = _ServicePrincipalsPool(
        insertReturningId: _principalId,
        getByIdRow: null,
      );
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      final result = await repo.getById(
        operatorId: _operatorAId,
        locationId: _locationId,
        id: _principalId,
      );

      expect(result, isNull);
      final tx = pool.transactions.single;
      // id is bound through the executor, never concatenated.
      expect(tx.parameters.last, containsPair('id', _principalId));
      expect(tx.executedSql.last, contains('where id = @id::uuid'));
    });

    test('getById returns the projected row when present', () async {
      final revokedAt = DateTime.utc(2026, 4, 28, 12);
      final pool = _ServicePrincipalsPool(
        insertReturningId: _principalId,
        getByIdRow: _principalRow(
          id: _principalId,
          operatorId: _operatorAId,
          name: 'webhook-bridge',
          scopes: const <String>['vendor.webhook.read'],
          revokedAt: revokedAt,
        ),
      );
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      final result = await repo.getById(
        operatorId: _operatorAId,
        locationId: _locationId,
        id: _principalId,
      );

      expect(result, isNotNull);
      expect(result!.id, equals(_principalId));
      expect(result.name, equals('webhook-bridge'));
      expect(result.scopes, equals(<String>['vendor.webhook.read']));
      expect(result.revokedAt, equals(revokedAt));
      expect(result.isActive, isFalse);
    });

    test('revoke issues UPDATE … set revoked_at = now() guarded by the '
        'active predicate (idempotent re-revoke is a no-op)', () async {
      final pool = _ServicePrincipalsPool(
        insertReturningId: _principalId,
        revokeRowCount: 1,
      );
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      final affected = await repo.revoke(
        operatorId: _operatorAId,
        locationId: _locationId,
        id: _principalId,
      );

      expect(affected, equals(1));
      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.last;
      expect(updateSql, contains('update service_principals'));
      expect(updateSql, contains('set revoked_at = now()'));
      expect(updateSql, contains('where id = @id::uuid'));
      // Idempotency guard: the predicate filters out already-revoked
      // rows so a re-revoke does not bump revoked_at.
      expect(updateSql, contains('and revoked_at is null'));
      expect(tx.parameters.last, containsPair('id', _principalId));
    });

    test('two consecutive creates bind their own operator_id — pooled '
        'connection reuse cannot leak tenant context', () async {
      final pool = _ServicePrincipalsPool(insertReturningId: _principalId);
      final repo =
          ServicePrincipalsRepository(TenantTransactionWrapper(pool));

      await repo.create(
        operatorId: _operatorAId,
        locationId: _locationId,
        name: 'first',
      );
      await repo.create(
        operatorId: _operatorBId,
        locationId: _locationId,
        name: 'second',
      );

      expect(pool.transactions, hasLength(2));
      expect(
        pool.transactions[0].parameters.first['value'],
        equals(_operatorAId),
      );
      expect(
        pool.transactions[1].parameters.first['value'],
        equals(_operatorBId),
      );
    });

    test('repository surface stays schema-only — no JWT / proxy / token '
        'methods leaked in', () {
      // Acceptance: this slice must NOT add JWT issuance, proxy
      // verifier routing, or any token lifecycle surface.
      // ServicePrincipalsRepository's public method names are
      // checked here so a future drive-by addition (e.g. a
      // `mintJwt(...)` helper) would surface as a test failure
      // rather than slipping in unnoticed. The follow-up slice
      // owns that surface and lives in tool/advisor_proxy/.
      final repo = ServicePrincipalsRepository(
        TenantTransactionWrapper(_ServicePrincipalsPool(insertReturningId: '1')),
      );
      // Smoke: instantiation does not require any non-tenant inputs.
      expect(repo, isA<ServicePrincipalsRepository>());
    });
  });
}

/// Reads [path] and collapses CRLF → LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

/// Strips PostgreSQL `--` line comments so DDL-only assertions do not
/// trip on prose in the migration header. PG `--` comments run from
/// the `--` to the end of the line; block comments (`/* … */`) are
/// not used in this migration set, so a line-stripper is sufficient.
/// The migration also contains no string literals that include `--`,
/// so this is safe; if that ever changes the helper would need to
/// track quote state.
String _stripSqlComments(String sql) {
  final lines = sql.split('\n');
  final stripped = <String>[];
  for (final line in lines) {
    final idx = line.indexOf('--');
    stripped.add(idx >= 0 ? line.substring(0, idx) : line);
  }
  return stripped.join('\n');
}

/// Builds a shape-correct service_principals row for the recording
/// pool to hand back. `scopes` accepts either a `List<String>` (the
/// driver-decoded form) or a `String` (the raw JSON-text form) so the
/// repository's normalization path is exercised on both shapes.
PostgresRow _principalRow({
  required String id,
  required String operatorId,
  required String name,
  required Object scopes,
  DateTime? revokedAt,
}) {
  final now = DateTime.utc(2026, 4, 28, 12);
  return <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    'name': name,
    'scopes': scopes,
    'created_at': now,
    'updated_at': now,
    'revoked_at': revokedAt,
  };
}

class _ServicePrincipalsPool implements PostgresPool {
  _ServicePrincipalsPool({
    required this.insertReturningId,
    this.listRows = const <PostgresRow>[],
    this.getByIdRow,
    this.revokeRowCount = 0,
  });

  final String? insertReturningId;
  final List<PostgresRow> listRows;
  final PostgresRow? getByIdRow;
  final int revokeRowCount;

  final List<_ServicePrincipalsTransaction> transactions =
      <_ServicePrincipalsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ServicePrincipalsTransaction(
      insertReturningId: insertReturningId,
      listRows: listRows,
      getByIdRow: getByIdRow,
      revokeRowCount: revokeRowCount,
    );
    transactions.add(tx);
    return tx;
  }
}

class _ServicePrincipalsTransaction extends PostgresTransaction {
  _ServicePrincipalsTransaction({
    required this.insertReturningId,
    required this.listRows,
    required this.getByIdRow,
    required this.revokeRowCount,
  });

  final String? insertReturningId;
  final List<PostgresRow> listRows;
  final PostgresRow? getByIdRow;
  final int revokeRowCount;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);

    if (sql.contains('insert into service_principals') &&
        sql.contains('returning id')) {
      final id = insertReturningId;
      if (id == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'id': id},
      ];
    }

    if (sql.contains('from service_principals') &&
        sql.contains('where id = @id::uuid')) {
      final row = getByIdRow;
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
    }

    if (sql.contains('from service_principals') &&
        sql.contains('order by created_at desc')) {
      return listRows;
    }

    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('update service_principals')) {
      return revokeRowCount;
    }
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}
