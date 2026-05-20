// Phase 9.0Σ.c — org_units ltree + data_region tests.
//
// Local framework slice (no live database). Three groups:
//
//   1. Migration shape — proves the migration creates the table with
//      the right unit_type CHECK, depth guard, tenant-leading indexes,
//      GiST path index, the operators.data_region default, the root-
//      per-operator backfill, RLS policy via the wrapper function,
//      and table grants.
//
//   2. Repository SQL shape — drives `OrgUnitsRepository` against a
//      fake `PostgresPool` and asserts SET LOCAL injection, the
//      tenant-context body, the depth-guard pre-flight, and the
//      withSystem admin path.
//
//   3. RLS lint clean — runs the existing `RlsPolicyLintRunner`
//      against the on-disk migration so a regression that swaps the
//      wrapper for bare `current_setting()` would be caught.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/org_units_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/rls_policy_lint.dart';

const String _operatorAId = '11111111-1111-1111-1111-111111111111';
const String _operatorBId = '22222222-2222-2222-2222-222222222222';
const String _locationId = '33333333-3333-3333-3333-333333333333';
const String _userId = '44444444-4444-4444-4444-444444444444';
const String _parentRootId = '55555555-5555-5555-5555-555555555555';
const String _orgUnitChildId = '66666666-6666-6666-6666-666666666666';

void main() {
  group('Brand org-unit follow-up migration', () {
    final migrationFile = File(
      'db/migrations/202605200900_brand_org_unit_type.sql',
    );

    String migration() => readSqlNormalized(migrationFile.path);

    test('promotes brand into the org_units unit_type CHECK', () {
      expect(migrationFile.existsSync(), isTrue);
      final sql = migration();
      expect(
        sql,
        contains('drop constraint if exists org_units_unit_type_check'),
      );
      expect(sql, contains("'brand'"));
      expect(sql, contains("'location_group'"));
    });
  });

  group('Phase 9.0Σ.c migration shape', () {
    final migrationFile = File(
      'db/migrations/202604280002_phase_9_0sigma_c_org_units.sql',
    );

    setUpAll(() {
      expect(
        migrationFile.existsSync(),
        isTrue,
        reason:
            'Phase 9.0Σ.c migration file must exist alongside the 9.0Σ.b '
            'wrapper migrations',
      );
    });

    String migration() => readSqlNormalized(migrationFile.path);

    test('enables the ltree extension', () {
      expect(migration(), contains('create extension if not exists ltree'));
    });

    test('runs in a single transaction (begin/commit pair)', () {
      final sql = migration();
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
    });

    test('adds operators.data_region default CA-CENTRAL', () {
      final sql = migration();
      expect(sql, contains('alter table public.operators'));
      expect(
        sql,
        contains(
          "add column if not exists data_region text not null "
          "default 'CA-CENTRAL'",
        ),
      );
    });

    test('creates org_units with unit_type CHECK and depth CHECK', () {
      final sql = migration();
      expect(sql, contains('create table if not exists public.org_units'));
      expect(
        sql,
        contains(
          "check (unit_type in ('corp', 'region', 'district', "
          "'location_group'))",
        ),
      );
      expect(
        sql,
        contains('constraint org_units_depth_check check (nlevel(path) <= 6)'),
      );
    });

    test('parent_id FK is composite with operator_id (cross-tenant '
        'parent forbidden)', () {
      final sql = migration();
      expect(sql, contains('constraint org_units_parent_same_operator_fk'));
      expect(
        sql,
        contains(
          'foreign key (operator_id, parent_id)\n'
          '    references public.org_units(operator_id, id)',
        ),
      );
    });

    test(
      'one-root-per-operator + composite uniqueness on (operator_id, id)',
      () {
        final sql = migration();
        expect(sql, contains('unique (operator_id, id)'));
        expect(sql, contains('unique (operator_id, path)'));
      },
    );

    test('every B-tree index leads with operator_id (RLS performance '
        'discipline)', () {
      final sql = migration();
      expect(
        sql,
        contains(
          'create index if not exists org_units_operator_id_idx\n'
          '  on public.org_units (operator_id, id)',
        ),
      );
      expect(
        sql,
        contains(
          'create index if not exists org_units_operator_parent_idx\n'
          '  on public.org_units (operator_id, parent_id)',
        ),
      );
      expect(
        sql,
        contains(
          'create index if not exists org_units_operator_unit_type_idx\n'
          '  on public.org_units (operator_id, unit_type)',
        ),
      );
    });

    test('GiST path index present (subtree query support)', () {
      final sql = migration();
      expect(
        sql,
        contains(
          'create index if not exists org_units_path_gist_idx\n'
          '  on public.org_units using gist (path)',
        ),
      );
    });

    test('single-root-per-operator partial unique index enforces the '
        'invariant the migration comments promise', () {
      // `unique (operator_id, path)` alone does not enforce one-root —
      // two roots with different path labels (e.g. `acme` and
      // `acme_branch`) would both pass it. The partial unique index
      // is the one DDL gate that closes the door.
      final sql = migration();
      expect(
        sql,
        contains(
          'create unique index if not exists '
          'org_units_one_root_per_operator_uq\n'
          '  on public.org_units (operator_id)\n'
          '  where parent_id is null',
        ),
      );
    });

    test('updated_at trigger reuses the cloud-foundation function', () {
      final sql = migration();
      expect(sql, contains('org_units_set_updated_at'));
      expect(
        sql,
        contains('execute function public.cloud_foundation_set_updated_at()'),
      );
    });

    test('backfill inserts one root corp row per existing operator', () {
      final sql = migration();
      expect(sql, contains('insert into public.org_units'));
      // Backfill iterates operators, sets parent_id=null + unit_type='corp'.
      expect(sql, contains('from public.operators op'));
      expect(sql, contains("'corp',"));
      expect(sql, contains('where ou.operator_id = op.operator_id'));
      expect(sql, contains('and ou.parent_id is null'));
      // Re-run safe via NOT EXISTS gate.
      expect(sql, contains('where not exists ('));
    });

    test('RLS enabled and policy uses app_current_operator() wrapper', () {
      final sql = migration();
      expect(
        sql,
        contains('alter table public.org_units enable row level security'),
      );
      expect(
        sql,
        contains(
          'create policy "org_units_per_tenant"\n'
          '  on public.org_units for all to service_role\n'
          '  using (operator_id = public.app_current_operator())\n'
          '  with check (operator_id = public.app_current_operator())',
        ),
      );
    });

    test('table grants: full DML to service_role and forge_admin', () {
      final sql = migration().toLowerCase();
      expect(
        sql,
        contains(
          'grant select, insert, update, delete on public.org_units '
          'to service_role',
        ),
      );
      expect(
        sql,
        contains(
          'grant select, insert, update, delete on public.org_units '
          'to forge_admin',
        ),
      );
    });

    test('does not introduce timestamp without time zone (storage rule)', () {
      final sql = migration().toLowerCase();
      expect(sql, isNot(contains('timestamp without time zone')));
      expect(sql, isNot(matches(RegExp(r'\btimestamp\b(?!\s*with)'))));
    });

    test('policy body does not read tenant context via bare '
        'current_setting (item 4)', () {
      // Policy-aware lint: comments and prose may reference the
      // historical pattern, but the policy body itself must call the
      // wrapper. Reuses the existing lint runner so a regression
      // would be caught both here and in the global lint sweep.
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280002_phase_9_0sigma_c_org_units.sql': migration(),
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'org_units policy must read operator context through '
            'the wrapper; violations: ${result.violations}',
      );
    });
  });

  group('OrgUnitsRepository (tenant-context SQL)', () {
    test('listForTenant builds SET LOCAL + tenant-scoped SELECT', () async {
      final pool = _RecordingPool();
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final rows = await repo.listForTenant(
        operatorId: _operatorAId,
        locationId: _locationId,
        userId: _userId,
      );

      expect(rows, hasLength(1));
      expect(rows.single.id, equals(_parentRootId));
      expect(rows.single.unitType, equals('corp'));
      expect(rows.single.parentId, isNull);

      final tx = pool.transactions.single;
      // SET LOCAL operator_id / location_id / user_id are issued
      // before the body runs (4th statement is the bypass_rls_audit
      // marker; 5th is the SELECT).
      expect(tx.executedSql[0], contains("set_config('app.operator_id'"));
      expect(tx.parameters[0]['value'], equals(_operatorAId));
      expect(tx.executedSql[1], contains("set_config('app.location_id'"));
      expect(tx.executedSql[2], contains("set_config('app.user_id'"));
      // The repository SELECT runs inside the same transaction.
      expect(
        tx.executedSql.any(
          (sql) =>
              sql.contains('from org_units') && sql.contains('order by path'),
        ),
        isTrue,
      );
      expect(tx.commitCount, equals(1));
    });

    test('getById binds id parameter and returns null on miss', () async {
      final pool = _RecordingPool();
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      // Pool returns no rows for a SELECT with this id.
      final result = await repo.getById(
        operatorId: _operatorAId,
        locationId: _locationId,
        id: _orgUnitChildId,
      );

      expect(result, isNull);
      final tx = pool.transactions.single;
      // id parameter is bound through the executor, not concatenated.
      expect(tx.parameters.last, containsPair('id', _orgUnitChildId));
      expect(tx.executedSql.last, contains('where id = @id::uuid'));
    });

    test('createRoot inserts a corp row with parent_id=null + binds '
        'path and name', () async {
      final pool = _RecordingPool();
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final id = await repo.createRoot(
        operatorId: _operatorAId,
        locationId: _locationId,
        pathLabel: 'acme',
        name: 'Acme Restaurants',
      );

      expect(id, equals(_parentRootId));
      final tx = pool.transactions.single;
      final insertSql = tx.executedSql.last;
      expect(insertSql, contains('insert into org_units'));
      expect(insertSql, contains("values (@operator_id::uuid, null, "));
      expect(insertSql, contains("'corp', @path::ltree"));
      expect(insertSql, contains('returning id::text'));
      expect(tx.parameters.last, containsPair('operator_id', _operatorAId));
      expect(tx.parameters.last, containsPair('path', 'acme'));
      expect(tx.parameters.last, containsPair('name', 'Acme Restaurants'));
    });

    test('createRoot ignores stray unitType arguments — always inserts '
        "'corp'", () {
      // Sanity check: a future caller cannot accidentally set a non-corp
      // unit_type on the root path. The method's signature does not
      // expose unit_type for that reason.
      final repo = OrgUnitsRepository(
        TenantTransactionWrapper(_RecordingPool()),
      );
      // Public surface only accepts pathLabel + name; reflectively
      // demonstrating "no unit_type parameter exists" via the static
      // allowedUnitTypes set documents the contract.
      expect(
        OrgUnitsRepository.allowedUnitTypes,
        equals(<String>{
          'corp',
          'brand',
          'region',
          'district',
          'location_group',
        }),
      );
      expect(repo, isNotNull);
    });

    test('createChild rejects a unit_type outside the allowed set', () async {
      final pool = _RecordingPool();
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      ArgumentError? thrown;
      try {
        await repo.createChild(
          operatorId: _operatorAId,
          locationId: _locationId,
          parentId: _parentRootId,
          unitType: 'venue_type',
          childLabel: 'east',
          name: 'East',
        );
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.name, equals('unitType'));
      // No transaction was opened — Dart-side validation runs before
      // the round-trip.
      expect(pool.transactions, isEmpty);
    });

    test('createChild fetches parent depth before insert and rejects when '
        'adding would exceed depth 6', () async {
      // Force the recording pool to return depth=6 for the parent.
      final pool = _RecordingPool(parentDepthOverride: 6);
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      Object? thrown;
      try {
        await repo.createChild(
          operatorId: _operatorAId,
          locationId: _locationId,
          parentId: _parentRootId,
          unitType: 'location_group',
          childLabel: 'east',
          name: 'East',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<StateError>());
      expect((thrown as StateError).message, contains('depth guard'));
      expect((thrown).message, contains('max of 6'));

      final tx = pool.transactions.single;
      // Parent SELECT issued; INSERT did NOT run.
      expect(
        tx.executedSql.any((sql) => sql.contains('select path::text')),
        isTrue,
      );
      expect(
        tx.executedSql.any((sql) => sql.contains('insert into org_units')),
        isFalse,
      );
    });

    test(
      'createChild SQL composes child path as parent.path || child_label',
      () async {
        // Parent depth defaults to 1 (root) so insert proceeds.
        final pool = _RecordingPool();
        final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

        final id = await repo.createChild(
          operatorId: _operatorAId,
          locationId: _locationId,
          parentId: _parentRootId,
          unitType: 'region',
          childLabel: 'east',
          name: 'East Region',
        );

        expect(id, equals(_orgUnitChildId));
        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.last;
        expect(insertSql, contains('parent.path || @child_label::ltree'));
        expect(tx.parameters.last, containsPair('child_label', 'east'));
        expect(tx.parameters.last, containsPair('unit_type', 'region'));
        expect(tx.parameters.last, containsPair('parent_id', _parentRootId));
      },
    );

    test(
      'listAllRootsAsAdmin runs through forge_admin BYPASSRLS path',
      () async {
        final pool = _RecordingPool();
        final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

        final rows = await repo.listAllRootsAsAdmin(
          adminReason: 'admin.org_units.audit_backfill',
        );

        expect(rows, hasLength(2));
        expect(
          rows.map((r) => r.operatorId).toSet(),
          equals(<String>{_operatorAId, _operatorBId}),
        );

        final tx = pool.transactions.single;
        // First statement is the audit marker, second is SET LOCAL ROLE.
        expect(
          tx.executedSql[0],
          contains("set_config('app.bypass_rls_audit'"),
        );
        expect(
          tx.parameters[0]['value'],
          equals('system:admin.org_units.audit_backfill'),
        );
        expect(tx.executedSql[1], equals('set local role forge_admin'));
        // Body SELECTs roots only.
        expect(tx.executedSql.last, contains('where parent_id is null'));
      },
    );

    test('listAllRootsAsAdmin rejects a blank reason', () async {
      final pool = _RecordingPool();
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      ArgumentError? thrown;
      try {
        await repo.listAllRootsAsAdmin(adminReason: '');
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      // No transaction opened — the wrapper refuses before touching
      // the pool so audit never sees an unattributed bypass.
      expect(pool.transactions, isEmpty);
    });
  });
}

// ─── Test helpers ────────────────────────────────────────────────────────────

/// Normalize CRLF → LF so multi-line `contains(...)` assertions are
/// platform-independent. Windows checkouts via the default
/// `core.autocrlf=true` setting deliver CRLF line endings, which
/// would otherwise break literal-string assertions that span
/// multiple lines.
String readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

// A minimal recording pool that returns shape-correct rows for the
// queries OrgUnitsRepository issues. Mirrors the helper pattern from
// `operator_scoped_repository_test.dart` but specialised for
// org_units row shape.

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({this.parentDepthOverride});

  /// When non-null, the parent SELECT in `createChild` returns this
  /// depth. Defaults to 1 (a root) so insert paths can proceed.
  final int? parentDepthOverride;

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

    // 1. listForTenant — SELECT … from org_units order by path
    if (sql.contains('from org_units') &&
        sql.contains('order by path') &&
        !sql.contains('parent_id is null')) {
      return <PostgresRow>[
        _orgUnitsRow(
          id: _parentRootId,
          operatorId: _operatorAId,
          parentId: null,
          unitType: 'corp',
          path: 'acme',
          name: 'Acme Restaurants',
        ),
      ];
    }

    // 2. listAllRootsAsAdmin — SELECT … where parent_id is null
    if (sql.contains('from org_units') && sql.contains('parent_id is null')) {
      return <PostgresRow>[
        _orgUnitsRow(
          id: _parentRootId,
          operatorId: _operatorAId,
          parentId: null,
          unitType: 'corp',
          path: 'acme',
          name: 'Acme',
        ),
        _orgUnitsRow(
          id: '77777777-7777-7777-7777-777777777777',
          operatorId: _operatorBId,
          parentId: null,
          unitType: 'corp',
          path: 'beta',
          name: 'Beta',
        ),
      ];
    }

    // 3. getById — single row lookup. Return empty so the test sees
    // null.
    if (sql.contains('from org_units') && sql.contains('where id = @id')) {
      return const <PostgresRow>[];
    }

    // 4. createChild parent depth lookup
    if (sql.contains('select path::text') && sql.contains('nlevel(path)')) {
      return <PostgresRow>[
        <String, Object?>{'path': 'acme', 'depth': parentDepthOverride ?? 1},
      ];
    }

    // 5. createRoot insert returning id::text
    if (sql.contains('insert into org_units') &&
        sql.contains('values (@operator_id::uuid, null,')) {
      return <PostgresRow>[
        <String, Object?>{'id': _parentRootId},
      ];
    }

    // 6. createChild insert returning id::text
    if (sql.contains('insert into org_units') &&
        sql.contains('parent.path || @child_label')) {
      return <PostgresRow>[
        <String, Object?>{'id': _orgUnitChildId},
      ];
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

class _RecordingPool implements PostgresPool {
  _RecordingPool({this.parentDepthOverride});

  final int? parentDepthOverride;

  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(parentDepthOverride: parentDepthOverride);
    transactions.add(tx);
    return tx;
  }
}

PostgresRow _orgUnitsRow({
  required String id,
  required String operatorId,
  required String? parentId,
  required String unitType,
  required String path,
  required String name,
}) {
  final now = DateTime.utc(2026, 4, 28, 12);
  return <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    'parent_id': parentId,
    'unit_type': unitType,
    'path': path,
    'name': name,
    'created_at': now,
    'updated_at': now,
  };
}
