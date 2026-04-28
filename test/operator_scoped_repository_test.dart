// Phase 9.2 - OperatorScopedRepository / TenantTransactionWrapper /
// per-tenant RLS policy migration tests.
//
// These tests exercise the repository pattern + SET LOCAL injection
// in isolation, with a fake Postgres pool that records every executed
// SQL string + parameter map. The real `package:postgres` binding
// lands in a follow-up — this layer is fully testable today without
// it because the `PostgresExecutor` interface is the entire seam.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart' as pg;

import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';

void main() {
  group('TenantContext (9.2 value object)', () {
    test('accepts strict 8-4-4-4-12 lowercase UUID fields', () {
      final ctx = TenantContext(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
      );
      expect(ctx.operatorId, equals(_validOpId));
      expect(ctx.locationId, equals(_validLocId));
      expect(ctx.userId, equals(_validUserId));
    });

    test('rejects non-UUID operator_id with a field-named error', () {
      TenantContextValidationError? thrown;
      try {
        TenantContext(operatorId: 'not-a-uuid', locationId: _validLocId);
      } on TenantContextValidationError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.field, equals('operator_id'));
      // Error must NOT echo the bad value — defense against pathological
      // header-injection attempts that smuggle a payload into a UUID slot.
      expect(thrown.toString(), isNot(contains('not-a-uuid')));
    });

    test('rejects non-UUID location_id with a field-named error', () {
      TenantContextValidationError? thrown;
      try {
        TenantContext(operatorId: _validOpId, locationId: 'BAD-LOC');
      } on TenantContextValidationError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.field, equals('location_id'));
    });

    test('rejects non-UUID user_id when present', () {
      TenantContextValidationError? thrown;
      try {
        TenantContext(
          operatorId: _validOpId,
          locationId: _validLocId,
          userId: '0',
        );
      } on TenantContextValidationError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.field, equals('user_id'));
    });

    test('UPPERCASE UUID is rejected (policy: lowercase only)', () {
      // UUIDs from JWT custom claims are written by the issuer in
      // canonical lowercase form. Accepting uppercase would risk a
      // case-folding mismatch between Postgres `uuid` column equality
      // (which is case-insensitive on cast but not on text compare)
      // and `current_setting(..., true)::uuid` parsing semantics.
      const upperOpId = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';
      TenantContextValidationError? thrown;
      try {
        TenantContext(operatorId: upperOpId, locationId: _validLocId);
      } on TenantContextValidationError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
    });
  });

  group('TenantTransactionWrapper.runInTenantContext', () {
    test('issues SET LOCAL for operator_id, location_id, user_id and '
        'commits on body success', () async {
      final pool = _RecordingPool();
      final wrapper = TenantTransactionWrapper(pool);
      final ctx = TenantContext(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
      );

      final result = await wrapper.runInTenantContext<int>(ctx, (exec) async {
        return 42;
      });

      expect(result, equals(42));
      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      expect(tx.commitCount, equals(1));
      expect(tx.rollbackCount, equals(0));
      // Acceptance: every SET LOCAL uses set_config(..., true)
      // (transaction-scoped) — never plain `SET` (session-scoped).
      expect(tx.executedSql, hasLength(greaterThanOrEqualTo(4)));
      expect(tx.executedSql[0], contains("set_config('app.operator_id'"));
      expect(tx.executedSql[0], contains('true)'));
      expect(tx.executedSql[1], contains("set_config('app.location_id'"));
      expect(tx.executedSql[2], contains("set_config('app.user_id'"));
      expect(tx.executedSql[3], contains("set_config('app.bypass_rls_audit'"));
      expect(tx.executedSql[3], contains("'tenant'"));

      // Acceptance: no plain `set ... = ...` (session-scoped) was issued.
      expect(
        tx.executedSql.any((sql) => RegExp(r'^\s*set\s+app\.').hasMatch(sql)),
        isFalse,
        reason:
            'must use set_config(..., true) (transaction-scoped) — '
            'plain SET would survive past commit on a pooled connection',
      );

      // Acceptance: parameters are bound (not concatenated).
      expect(tx.parameters[0]['value'], equals(_validOpId));
      expect(tx.parameters[1]['value'], equals(_validLocId));
      expect(tx.parameters[2]['value'], equals(_validUserId));
    });

    test('skips SET LOCAL app.user_id when context.userId is null '
        '(background jobs path)', () async {
      final pool = _RecordingPool();
      final wrapper = TenantTransactionWrapper(pool);
      final ctx = TenantContext(
        operatorId: _validOpId,
        locationId: _validLocId,
        // userId omitted — represents a system / scheduled job
      );

      await wrapper.runInTenantContext<void>(ctx, (exec) async {});
      final tx = pool.transactions.single;
      expect(
        tx.executedSql.any((sql) => sql.contains("'app.user_id'")),
        isFalse,
      );
    });

    test('rolls back on body throw and rethrows the original error', () async {
      final pool = _RecordingPool();
      final wrapper = TenantTransactionWrapper(pool);
      final ctx = TenantContext(
        operatorId: _validOpId,
        locationId: _validLocId,
      );
      final boom = StateError('user-supplied boom');

      Object? thrown;
      try {
        await wrapper.runInTenantContext<void>(ctx, (exec) async {
          throw boom;
        });
      } catch (error) {
        thrown = error;
      }
      expect(identical(thrown, boom), isTrue);
      expect(pool.transactions.single.commitCount, equals(0));
      expect(pool.transactions.single.rollbackCount, equals(1));
    });

    test('rolls back when SET LOCAL itself throws', () async {
      final pool = _RecordingPool(failOnExecuteIndex: 0);
      final wrapper = TenantTransactionWrapper(pool);
      final ctx = TenantContext(
        operatorId: _validOpId,
        locationId: _validLocId,
      );

      Object? thrown;
      try {
        await wrapper.runInTenantContext<void>(ctx, (exec) async {
          fail('body must not run when SET LOCAL fails');
        });
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      final tx = pool.transactions.single;
      expect(tx.commitCount, equals(0));
      expect(tx.rollbackCount, equals(1));
    });

    test(
      'swallows secondary rollback failure so the original error wins',
      () async {
        final pool = _RecordingPool(rollbackThrows: true);
        final wrapper = TenantTransactionWrapper(pool);
        final ctx = TenantContext(
          operatorId: _validOpId,
          locationId: _validLocId,
        );
        final boom = StateError('primary boom');

        Object? thrown;
        try {
          await wrapper.runInTenantContext<void>(ctx, (exec) async {
            throw boom;
          });
        } catch (error) {
          thrown = error;
        }
        expect(
          identical(thrown, boom),
          isTrue,
          reason: 'rollback secondary failure must not mask the original',
        );
      },
    );

    test('subsequent transactions use independent SET LOCAL — pooled '
        'connection reuse cannot leak tenant context', () async {
      final pool = _RecordingPool();
      final wrapper = TenantTransactionWrapper(pool);
      final ctxA = TenantContext(
        operatorId: _validOpId,
        locationId: _validLocId,
      );
      final ctxB = TenantContext(
        operatorId: '44444444-4444-4444-4444-444444444444',
        locationId: '55555555-5555-5555-5555-555555555555',
      );

      await wrapper.runInTenantContext<void>(ctxA, (_) async {});
      await wrapper.runInTenantContext<void>(ctxB, (_) async {});

      expect(pool.transactions, hasLength(2));
      // Each transaction sets its own operator_id; nothing carries
      // over because we're using set_config(..., true).
      expect(
        pool.transactions[0].parameters[0]['value'],
        equals(ctxA.operatorId),
      );
      expect(
        pool.transactions[1].parameters[0]['value'],
        equals(ctxB.operatorId),
      );
    });
  });

  group('TenantTransactionWrapper.runAsSystem', () {
    test('elevates to forge_admin and audits with reason', () async {
      final pool = _RecordingPool();
      final wrapper = TenantTransactionWrapper(pool);

      final result = await wrapper.runAsSystem<String>(
        (exec) async => 'ok',
        reason: 'admin.users.soft_delete',
      );

      expect(result, equals('ok'));
      final tx = pool.transactions.single;
      expect(tx.commitCount, equals(1));
      expect(tx.executedSql[0], contains("set_config('app.bypass_rls_audit'"));
      expect(
        tx.parameters[0]['value'],
        equals('system:admin.users.soft_delete'),
      );
      // Acceptance: BYPASSRLS engages via `SET LOCAL ROLE forge_admin`,
      // not by connecting as a different user. The wrapper relies on
      // service_role having been GRANTed forge_admin (db migration
      // 202604260000).
      expect(tx.executedSql[1], equals('set local role forge_admin'));
    });

    test('rejects blank reason', () async {
      final pool = _RecordingPool();
      final wrapper = TenantTransactionWrapper(pool);

      ArgumentError? thrown;
      try {
        await wrapper.runAsSystem<void>((exec) async {}, reason: '   ');
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      // Acceptance: no transaction was even opened — the wrapper
      // refuses before touching the pool so audit never sees an
      // unattributed bypass.
      expect(pool.transactions, isEmpty);
    });

    test('rolls back on body throw', () async {
      final pool = _RecordingPool();
      final wrapper = TenantTransactionWrapper(pool);

      Object? thrown;
      try {
        await wrapper.runAsSystem<void>(
          (exec) async => throw StateError('boom'),
          reason: 'admin.test',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<StateError>());
      final tx = pool.transactions.single;
      expect(tx.commitCount, equals(0));
      expect(tx.rollbackCount, equals(1));
    });
  });

  group('OperatorScopedRepository (subclass-facing API)', () {
    test(
      'withTenant delegates to the wrapper and forwards body return',
      () async {
        final pool = _RecordingPool();
        final repo = _ExampleRepository(TenantTransactionWrapper(pool));
        final ctx = TenantContext(
          operatorId: _validOpId,
          locationId: _validLocId,
        );

        final result = await repo.exampleRead(ctx);
        expect(result, equals(<String>['row-a', 'row-b']));
        expect(pool.transactions, hasLength(1));
        // The repository's body issued `select * from users` AFTER the
        // SET LOCAL block; the tenant context is in place for that read.
        final tx = pool.transactions.single;
        expect(tx.executedSql.any((sql) => sql.contains('from users')), isTrue);
      },
    );

    test('withSystem requires a reason string', () async {
      final pool = _RecordingPool();
      final repo = _ExampleRepository(TenantTransactionWrapper(pool));

      ArgumentError? thrown;
      try {
        await repo.exampleSystemWriteWithBlankReason();
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
    });
  });

  group('PackagePostgresPool (live driver adapter)', () {
    test(
      'opens a transaction, maps rows by column name, commits, and closes',
      () async {
        final connection = _FakePackagePostgresConnection(
          selectResult: _pgResult(
            rows: <PostgresRow>[
              <String, Object?>{'name': 'row-a'},
            ],
          ),
        );
        final pool = PackagePostgresPool(
          openConnection: () async => connection,
        );
        final tx = await pool.beginTransaction();

        final rows = await tx.query(
          'select name from users where operator_id = @operator_id',
          parameters: const <String, Object?>{'operator_id': _validOpId},
        );
        final affected = await tx.execute(
          'update users set roles_version = roles_version + 1 '
          'where user_id = @user_id',
          parameters: const <String, Object?>{'user_id': _validUserId},
        );
        await tx.commit();
        await tx.commit();

        expect(
          rows,
          equals(<PostgresRow>[
            <String, Object?>{'name': 'row-a'},
          ]),
        );
        expect(affected, equals(3));
        expect(connection.queries, hasLength(4));
        expect(connection.queries.first.query, equals('begin'));
        expect(connection.queries[1].query, isA<pg.Sql>());
        expect(
          connection.queries[1].parameters,
          equals(<String, Object?>{'operator_id': _validOpId}),
        );
        expect(connection.queries[2].query, isA<pg.Sql>());
        expect(connection.queries[2].ignoreRows, isTrue);
        expect(connection.queries.last.query, equals('commit'));
        expect(connection.closeCalls, equals(1));
        expect(connection.forceCloseCalls, equals(0));
      },
    );

    test(
      'rollback is idempotent, force-closes, and prevents later queries',
      () async {
        final connection = _FakePackagePostgresConnection();
        final pool = PackagePostgresPool(
          openConnection: () async => connection,
        );
        final tx = await pool.beginTransaction();

        await tx.rollback();
        await tx.rollback();

        expect(connection.queries.map((call) => call.sqlText), <String>[
          'begin',
          'rollback',
        ]);
        expect(connection.closeCalls, equals(1));
        expect(connection.forceCloseCalls, equals(1));
        expect(() => tx.query('select 1'), throwsA(isA<StateError>()));
      },
    );

    test(
      'begin failure closes the connection with force and rethrows',
      () async {
        final connection = _FakePackagePostgresConnection(failOnBegin: true);
        final pool = PackagePostgresPool(
          openConnection: () async => connection,
        );

        await expectLater(pool.beginTransaction(), throwsA(isA<StateError>()));
        expect(connection.closeCalls, equals(1));
        expect(connection.forceCloseCalls, equals(1));
      },
    );
  });

  group('Phase 9.2 RLS per-tenant policy migration '
      '(202604260000_auth_rls_per_tenant_policies.sql)', () {
    final migrationFile = File(
      'db/migrations/202604260000_auth_rls_per_tenant_policies.sql',
    );

    setUpAll(() {
      expect(
        migrationFile.existsSync(),
        isTrue,
        reason:
            'Phase 9.2 migration file must exist alongside 9.0 schema foundation',
      );
    });

    String migration() => migrationFile.readAsStringSync();

    test('creates forge_admin role with BYPASSRLS and grants it to '
        'service_role', () {
      final sql = migration();
      expect(sql, contains('create role forge_admin nologin bypassrls'));
      expect(sql, contains('alter role forge_admin nologin bypassrls'));
      expect(sql, contains('grant forge_admin to service_role'));
      // Idempotency — re-runs must not error on existing role.
      expect(
        sql,
        contains("from pg_catalog.pg_roles where rolname = 'forge_admin'"),
      );
    });

    test(
      'drops every 9.0 service-role-only policy stub before re-creating',
      () {
        final sql = migration();
        const stubsToDrop = <String>[
          'permission_keys_service_role_all',
          'roles_service_role_all',
          'role_permissions_service_role_all',
          'user_roles_service_role_all',
          'auth_sessions_service_role_all',
          'mfa_factors_service_role_all',
          'tncs_acceptances_service_role_all',
          'password_history_service_role_all',
          'auth_invites_service_role_all',
          'auth_events_audit_service_role_append_only',
          'auth_events_audit_service_role_select',
          'role_audit_log_service_role_append_only',
          'role_audit_log_service_role_select',
          'external_identity_links_service_role_all',
        ];
        for (final stub in stubsToDrop) {
          expect(
            sql,
            contains('drop policy if exists "$stub"'),
            reason: '9.0 stub policy must be dropped: $stub',
          );
        }
      },
    );

    test('per-tenant policies on operator_id-bearing tables read from '
        "current_setting('app.operator_id', true)::uuid", () {
      final sql = migration();
      const operatorScopedTables = <String>[
        'roles',
        'user_roles',
        'tncs_acceptances',
        'auth_invites',
        'external_identity_links',
      ];
      for (final table in operatorScopedTables) {
        // Each operator-scoped table has at least one policy that
        // filters by app.operator_id.
        expect(
          sql,
          contains('on public.$table'),
          reason: '$table needs a per-tenant policy',
        );
      }
      expect(sql, contains("current_setting('app.operator_id', true)::uuid"));
    });

    test('per-user policies on auth_sessions / mfa_factors / '
        'password_history filter by app.user_id', () {
      final sql = migration();
      expect(sql, contains('"auth_sessions_per_user"'));
      expect(sql, contains('"mfa_factors_per_user"'));
      expect(sql, contains('"password_history_per_user"'));
      expect(
        sql,
        contains("user_id = current_setting('app.user_id', true)::uuid"),
      );
    });

    test('auth_events_audit per-tenant SELECT keeps INSERT open for '
        'login/logout regardless of tenant context', () {
      final sql = migration();
      expect(sql, contains('"auth_events_audit_per_tenant_select"'));
      expect(sql, contains('"auth_events_audit_append_insert"'));
      // SELECT is per-tenant; INSERT uses with check (true).
      expect(
        sql,
        contains(
          'auth_events_audit for insert to service_role\n  with check (true)',
        ),
      );
    });

    test('role_audit_log policy joins through roles + user_roles for '
        'tenant filtering (no operator_id column on this table)', () {
      final sql = migration();
      expect(sql, contains('"role_audit_log_per_tenant_select"'));
      // Join via roles for catalog mutations.
      expect(sql, contains('select role_id from public.roles'));
      // Join via user_roles for grant mutations.
      expect(sql, contains('select user_role_id from public.user_roles'));
    });

    test('permission_keys SELECT-only for service_role; writes are '
        'forge_admin only via BYPASSRLS', () {
      final sql = migration();
      expect(sql, contains('"permission_keys_authenticated_select"'));
      // No INSERT/UPDATE/DELETE policy for service_role — the lack
      // of those policies means RLS denies them; only forge_admin
      // (BYPASSRLS) writes the catalog.
      expect(sql, isNot(contains('permission_keys_service_role_modify')));
    });

    test('migration does not re-introduce session-scoped SET (would leak '
        'tenant context across pooled connection reuse)', () {
      final sql = migration();
      // The wrapper uses select set_config(..., true) (transaction
      // local). The migration must not regress to plain SET app.x.
      expect(sql, isNot(matches(RegExp(r'^\s*set\s+app\.', multiLine: true))));
    });

    test('migration covers ONLY auth tables — cloud foundation flip is '
        'queued for follow-up', () {
      final sql = migration();
      // Sanity guard: the migration intentionally does NOT touch
      // operators, locations, users, operator_admins. Those need a
      // separate slice because flipping them affects every existing
      // 11a query path.
      expect(sql, isNot(contains('on public.operators ')));
      expect(sql, isNot(contains('on public.operator_admins ')));
      expect(sql, isNot(contains('on public.locations ')));
      // Note: `users` is left untouched by THIS migration; the
      // public.users table itself has its own service-role-only stub
      // from 11a.11c.1 that the cloud-foundation follow-up flips.
      expect(sql, isNot(contains('on public.users ')));
    });

    test('comments document the BYPASSRLS audit requirement', () {
      final sql = migration();
      expect(sql, contains('comment on role forge_admin'));
      expect(sql.toLowerCase(), contains('bypassrls'));
    });
  });

  group('Phase 9.2 service_role grants migration '
      '(202604260001_auth_rls_service_role_grants.sql)', () {
    final migrationFile = File(
      'db/migrations/202604260001_auth_rls_service_role_grants.sql',
    );

    setUpAll(() {
      expect(
        migrationFile.existsSync(),
        isTrue,
        reason: 'Phase 9.2 live-closeout grant migration must exist',
      );
    });

    String migration() => migrationFile.readAsStringSync();

    test('permission_keys is granted SELECT only to service_role', () {
      final sql = migration().toLowerCase();
      expect(
        sql,
        contains('grant select on public.permission_keys to service_role'),
      );
      expect(
        sql,
        contains('grant select on public.permission_keys to forge_admin'),
      );
      expect(
        sql,
        isNot(
          contains(
            'grant select, insert, update, delete on public.permission_keys',
          ),
        ),
      );
    });

    test('mutable auth tables grant DML to service_role and forge_admin', () {
      final sql = migration().toLowerCase();
      const tables = <String>[
        'roles',
        'role_permissions',
        'user_roles',
        'auth_sessions',
        'mfa_factors',
        'tncs_acceptances',
        'password_history',
        'auth_invites',
        'external_identity_links',
      ];
      for (final table in tables) {
        for (final role in <String>['service_role', 'forge_admin']) {
          expect(
            sql,
            contains(
              'grant select, insert, update, delete on public.$table '
              'to $role',
            ),
            reason: '$table needs table privileges before RLS can allow rows',
          );
        }
      }
    });

    test('audit tables preserve append-only grant shape for both roles', () {
      final sql = migration().toLowerCase();
      for (final table in <String>['auth_events_audit', 'role_audit_log']) {
        for (final role in <String>['service_role', 'forge_admin']) {
          expect(
            sql,
            contains('grant select, insert on public.$table to $role'),
          );
          expect(
            sql,
            contains('revoke update, delete on public.$table from $role'),
          );
        }
      }
    });
  });
}

// ─── Test helpers ────────────────────────────────────────────────────────────

class _PackagePostgresCall {
  _PackagePostgresCall({
    required this.query,
    required this.parameters,
    required this.ignoreRows,
  });

  final Object query;
  final Object? parameters;
  final bool ignoreRows;

  String get sqlText {
    final query = this.query;
    if (query is pg.Sql) return '<named-sql>';
    return query.toString();
  }
}

class _FakePackagePostgresConnection implements PackagePostgresConnection {
  _FakePackagePostgresConnection({
    this.failOnBegin = false,
    pg.Result? selectResult,
  }) : selectResult = selectResult ?? _pgResult();

  final bool failOnBegin;
  final pg.Result selectResult;
  final List<_PackagePostgresCall> queries = <_PackagePostgresCall>[];
  var closeCalls = 0;
  var forceCloseCalls = 0;

  @override
  Future<pg.Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
  }) async {
    final call = _PackagePostgresCall(
      query: query,
      parameters: parameters,
      ignoreRows: ignoreRows,
    );
    queries.add(call);
    if (call.sqlText == 'begin' && failOnBegin) {
      throw StateError('synthetic begin failure');
    }
    if (ignoreRows) return _pgResult(affectedRows: 3);
    return selectResult;
  }

  @override
  Future<void> close({bool force = false}) async {
    closeCalls += 1;
    if (force) forceCloseCalls += 1;
  }
}

pg.Result _pgResult({
  List<PostgresRow> rows = const <PostgresRow>[],
  int affectedRows = 3,
}) {
  final columns = rows.isEmpty
      ? <pg.ResultSchemaColumn>[]
      : rows.first.keys
            .map(
              (key) => pg.ResultSchemaColumn(
                typeOid: 0,
                type: pg.Type.text,
                columnName: key,
              ),
            )
            .toList(growable: false);
  final schema = pg.ResultSchema(columns);
  return pg.Result(
    rows: rows
        .map(
          (row) => pg.ResultRow(
            values: columns.map((column) => row[column.columnName]).toList(),
            schema: schema,
          ),
        )
        .toList(growable: false),
    affectedRows: affectedRows,
    schema: schema,
  );
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({this.failOnExecuteIndex, this.rollbackThrows = false});

  final int? failOnExecuteIndex;
  final bool rollbackThrows;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from users')) {
      // Example query in _ExampleRepository.exampleRead returns two
      // synthetic rows so the repo's reshape can be asserted.
      return <PostgresRow>[
        <String, Object?>{'name': 'row-a'},
        <String, Object?>{'name': 'row-b'},
      ];
    }
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (failOnExecuteIndex != null &&
        executedSql.length - 1 == failOnExecuteIndex) {
      throw StateError('synthetic execute failure for test');
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
    if (rollbackThrows) {
      throw StateError('synthetic rollback failure for test');
    }
  }
}

class _RecordingPool implements PostgresPool {
  _RecordingPool({this.failOnExecuteIndex, this.rollbackThrows = false});

  final int? failOnExecuteIndex;
  final bool rollbackThrows;

  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      failOnExecuteIndex: failOnExecuteIndex,
      rollbackThrows: rollbackThrows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _ExampleRepository extends OperatorScopedRepository {
  _ExampleRepository(super.tenantWrapper);

  Future<List<String>> exampleRead(TenantContext ctx) {
    return withTenant(ctx, (exec) async {
      final rows = await exec.query(
        'select name from users where operator_id = '
        "current_setting('app.operator_id', true)::uuid",
      );
      return rows
          .map((row) => row['name'] as String? ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
    });
  }

  Future<void> exampleSystemWriteWithBlankReason() {
    // Intentionally passes a blank reason so the test can assert the
    // wrapper rejects it before opening a transaction.
    return withSystem((exec) async {}, reason: '');
  }
}
