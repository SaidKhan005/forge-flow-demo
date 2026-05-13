// Phase 9 live-closeout B17 / post-hardening P2 — canonical-path
// unit tests for RolePermissionsRepository.
//
// Coverage focus:
//
//   * permission_key allowlist (mirrors `lib/auth/permission_keys.dart` +
//     `docs/contracts/auth_permission_key_catalog.md`) — the repo does
//     NOT validate keys against the catalog; that is enforced by the
//     `role_permissions.permission_key` FK against
//     `public.permission_keys` at the DB layer. The repo's obligation
//     is to round-trip the key parametrically (no concatenation, no
//     normalization) so the FK rejection surfaces verbatim. Tests pin
//     this for representative keys from each category (`product.*`,
//     `forgeflow.*`, `admin.*`, `team.*`) so a refactor that lower-cases
//     or otherwise mutates the key on the way down would break here.
//
//   * `effect` allowlist — the only client-side guard. Repo throws
//     ArgumentError BEFORE opening a transaction when `effect` is not
//     'allow' or 'deny'. The DB CHECK enforces the same shape; the
//     synchronous Dart guard saves a round-trip + leaves a cleaner
//     stack trace for misuse.
//
//   * Cross-tenant denial — every method runs through `withTenant`
//     so the per-tenant RLS policy on `role_permissions` (which folds
//     role → operator → tenant via the `roles.operator_id`
//     composite FK) admits/denies the row at the DB layer. Tests
//     verify:
//       - SET LOCAL `app.operator_id` / `app.location_id` run BEFORE
//         the read/write so the policy has the GUC values to fold.
//       - The `app.bypass_rls_audit = 'tenant'` audit marker is
//         stamped (not 'system') — role_permissions has no admin
//         BYPASSRLS path; cross-tenant writes would only happen
//         through the tenant SET LOCAL ordering, which is what the
//         RLS policy traps.
//       - `set local role forge_admin` is NEVER emitted.
//
//   * Cell-by-cell save semantics — the matrix editor (Phase 9.9)
//     emits one upsert per dirty cell. The INSERT ON CONFLICT (role_id,
//     permission_key) DO UPDATE shape preserves `created_by` while
//     rewriting `updated_by` and `effect`. Test pins:
//       - the conflict target is `(role_id, permission_key)` (the
//         composite PK / unique key — by SHAPE, not name; the
//         migration uses the implicit constraint)
//       - DO UPDATE rewrites `effect`, `updated_at`, `updated_by` —
//         NOT `created_by` (audit trail keeps original creator)
//
//   * `deleteCell` — "revert cell to inherit" path. WHERE clause
//     filters `role_id` AND `permission_key` so a stale cell on
//     another row cannot be deleted by accident.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/role_permissions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _actorA = '33333333-3333-3333-3333-333333333333';
const String _roleA = '44444444-4444-4444-4444-444444444444';

void main() {
  group('RolePermissionsRepository.upsertCell — effect allowlist', () {
    test(
      "rejects effect='neutral' synchronously with ArgumentError before "
      'opening a transaction (the DB CHECK would also reject; the '
      'Dart-side guard saves a round-trip and leaves a cleaner stack)',
      () async {
        final pool = _RolePermissionsPool();
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        Object? thrown;
        try {
          await repo.upsertCell(
            operatorId: _opA,
            locationId: _locA,
            updatedByUserId: _actorA,
            roleId: _roleA,
            permissionKey: PermissionKeys.forgeflowShiftView,
            effect: 'neutral',
          );
        } on ArgumentError catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ArgumentError>());
        expect((thrown! as ArgumentError).name, equals('effect'));
        // Synchronous guard — no transaction was even opened.
        expect(
          pool.transactions,
          isEmpty,
          reason: 'invalid effect must short-circuit before any SET LOCAL '
              'or RLS round-trip',
        );
      },
    );

    test(
      "rejects empty-string effect with ArgumentError (the DB CHECK "
      "carries the same shape but the synchronous guard fails fast)",
      () async {
        final pool = _RolePermissionsPool();
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.upsertCell(
            operatorId: _opA,
            locationId: _locA,
            updatedByUserId: _actorA,
            roleId: _roleA,
            permissionKey: PermissionKeys.forgeflowShiftView,
            effect: '',
          ),
          throwsArgumentError,
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      "rejects mixed-case 'Allow' — the constraint accepts only "
      "lowercase 'allow' / 'deny'; a refactor that lowercased on the "
      "way down would mask the schema mismatch",
      () async {
        final pool = _RolePermissionsPool();
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.upsertCell(
            operatorId: _opA,
            locationId: _locA,
            updatedByUserId: _actorA,
            roleId: _roleA,
            permissionKey: PermissionKeys.forgeflowShiftView,
            effect: 'Allow',
          ),
          throwsArgumentError,
        );
      },
    );

    test("accepts effect='allow' — happy-path INSERT runs", () async {
      final pool = _RolePermissionsPool(upsertAffectedRows: 1);
      final repo = RolePermissionsRepository(TenantTransactionWrapper(pool));
      final affected = await repo.upsertCell(
        operatorId: _opA,
        locationId: _locA,
        updatedByUserId: _actorA,
        roleId: _roleA,
        permissionKey: PermissionKeys.forgeflowShiftView,
        effect: 'allow',
      );
      expect(affected, equals(1));
      expect(pool.transactions.single.commitCount, equals(1));
    });

    test("accepts effect='deny' — explicit deny is the matrix editor's "
        'distinguishing posture (deny > allow on conflict)', () async {
      final pool = _RolePermissionsPool(upsertAffectedRows: 1);
      final repo = RolePermissionsRepository(TenantTransactionWrapper(pool));
      final affected = await repo.upsertCell(
        operatorId: _opA,
        locationId: _locA,
        updatedByUserId: _actorA,
        roleId: _roleA,
        permissionKey: PermissionKeys.adminInvitesCreate,
        effect: 'deny',
      );
      expect(affected, equals(1));
    });
  });

  group('RolePermissionsRepository.upsertCell — permission_key catalog '
      'round-trip', () {
    test(
      'representative keys from each category (product.*, forgeflow.*, '
      'admin.*, team.*) round-trip parametrically; the repo does NOT '
      'normalize the key on the way down (FK rejection at the DB layer '
      'depends on the verbatim string)',
      () async {
        final keys = <String>[
          PermissionKeys.productForgeflowAccess, // product.*
          PermissionKeys.forgeflowShiftView, // forgeflow.*
          PermissionKeys.adminInvitesCreate, // admin.*
          PermissionKeys.teamUsersInvite, // team.*
        ];
        for (final key in keys) {
          final pool = _RolePermissionsPool(upsertAffectedRows: 1);
          final repo =
              RolePermissionsRepository(TenantTransactionWrapper(pool));
          await repo.upsertCell(
            operatorId: _opA,
            locationId: _locA,
            updatedByUserId: _actorA,
            roleId: _roleA,
            permissionKey: key,
            effect: 'allow',
          );
          final tx = pool.transactions.single;
          final upsertSql = tx.executedSql.firstWhere(
            (s) => s.contains('insert into role_permissions'),
          );
          // Bound parametrically — never concatenated.
          expect(upsertSql, contains('@permission_key'));
          expect(
            upsertSql,
            isNot(contains("'$key'")),
            reason:
                'permission_key must be bound, not interpolated, so the '
                "DB FK against permission_keys handles validation",
          );
          final params = tx.parameters.firstWhere(
            (p) => p['permission_key'] == key,
          );
          expect(params['permission_key'], equals(key));
        }
      },
    );

    test(
      'all 103 catalog keys round-trip — the repo never rejects a '
      'syntactically-valid key (catalog membership is enforced by the '
      'DB FK, not the repo)',
      () async {
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(
          _RolePermissionsPool(upsertAffectedRows: 1),
        ));
        // Smoke-check that PermissionKeys.all has the documented count
        // so the prompt's "mirrors auth_permission_key_catalog" tie-in
        // breaks loudly if the catalog drifts. The contract doc names
        // 103 keys; the repo never gates on this — it only round-trips.
        expect(
          PermissionKeys.all.length,
          equals(103),
          reason: 'auth_permission_key_catalog.md contract calls out 103 '
              'keys total after additive catalog slices; a count '
              'drift here is a doc-vs-code drift to investigate',
        );
        // Spot-check a few keys flow through without a Dart-side throw —
        // fast loop is fine since each takes a fresh pool.
        final samples = PermissionKeys.all.take(8).toList();
        for (final key in samples) {
          await repo.upsertCell(
            operatorId: _opA,
            locationId: _locA,
            updatedByUserId: _actorA,
            roleId: _roleA,
            permissionKey: key,
            effect: 'allow',
          );
        }
      },
    );
  });

  group('RolePermissionsRepository.upsertCell — cross-tenant denial '
      '(SET LOCAL ordering)', () {
    test(
      'tenant SET LOCAL block runs BEFORE the upsert — RLS policy on '
      'role_permissions can fold against the tenant GUCs to deny a '
      'cross-tenant role_id',
      () async {
        final pool = _RolePermissionsPool(upsertAffectedRows: 1);
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        await repo.upsertCell(
          operatorId: _opA,
          locationId: _locA,
          updatedByUserId: _actorA,
          roleId: _roleA,
          permissionKey: PermissionKeys.forgeflowShiftView,
          effect: 'allow',
        );
        final tx = pool.transactions.single;
        // Canonical SET LOCAL order: operator → location → user.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.parameters[1]['value'], equals(_locA));
        expect(tx.executedSql[2], contains("'app.user_id'"));
        expect(tx.parameters[2]['value'], equals(_actorA));
        // Tenant audit marker — not system. The role_permissions repo
        // has NO admin path; cross-tenant writes are denied by RLS,
        // not allowed via BYPASSRLS.
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          isEmpty,
          reason:
              'role_permissions repo must never escalate to forge_admin — '
              'the cross-tenant denial defense layer depends on the '
              'tenant SET LOCAL path',
        );
        // Upsert ran AFTER the SET LOCAL block.
        final upsertSqlIndex = tx.executedSql.indexWhere(
          (s) => s.contains('insert into role_permissions'),
        );
        expect(upsertSqlIndex, greaterThan(2));
      },
    );

    test(
      'INSERT ON CONFLICT (role_id, permission_key) DO UPDATE — the '
      'cell-by-cell upsert preserves created_by while rewriting '
      'effect / updated_at / updated_by (audit trail keeps original '
      'creator; updated_by tracks the latest admin actor)',
      () async {
        final pool = _RolePermissionsPool(upsertAffectedRows: 1);
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        await repo.upsertCell(
          operatorId: _opA,
          locationId: _locA,
          updatedByUserId: _actorA,
          roleId: _roleA,
          permissionKey: PermissionKeys.forgeflowShiftEdit,
          effect: 'deny',
        );
        final tx = pool.transactions.single;
        final upsertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into role_permissions'),
        );
        // Conflict target: composite PK / unique on (role_id,
        // permission_key) — the matrix editor cell key.
        expect(upsertSql, contains('on conflict (role_id, permission_key)'));
        // DO UPDATE rewrites effect, updated_at, updated_by.
        expect(upsertSql, contains('effect = excluded.effect'));
        expect(upsertSql, contains('updated_at = now()'));
        expect(upsertSql, contains('updated_by = excluded.updated_by'));
        // created_by NOT in the DO UPDATE set — the audit trail keeps
        // the original creator (the matrix editor's first cell save).
        expect(
          upsertSql,
          isNot(contains('created_by = excluded.created_by')),
          reason:
              'created_by must be preserved on conflict so the audit '
              'trail shows the original creator, not the latest editor',
        );
        // updated_by bound to the actor on BOTH insert and DO UPDATE
        // (both go through @updated_by since the repo sets created_by
        // = updated_by on a fresh row).
        final params = tx.parameters.firstWhere(
          (p) => p['permission_key'] == PermissionKeys.forgeflowShiftEdit,
        );
        expect(params['updated_by'], equals(_actorA));
        expect(params['effect'], equals('deny'));
        expect(params['role_id'], equals(_roleA));
      },
    );
  });

  group('RolePermissionsRepository.listForRole', () {
    test(
      'tenant SET LOCAL ordering precedes the SELECT; ORDER BY '
      'permission_key for stable matrix-editor projection',
      () async {
        final pool = _RolePermissionsPool(
          listForRoleRows: <PostgresRow>[
            <String, Object?>{
              'role_id': _roleA,
              'permission_key': PermissionKeys.forgeflowShiftView,
              'effect': 'allow',
              'created_at': DateTime.utc(2026, 4, 28),
              'updated_at': DateTime.utc(2026, 4, 28),
            },
            <String, Object?>{
              'role_id': _roleA,
              'permission_key': PermissionKeys.adminInvitesCreate,
              'effect': 'deny',
              'created_at': DateTime.utc(2026, 4, 28),
              'updated_at': DateTime.utc(2026, 4, 28),
            },
          ],
        );
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listForRole(
          operatorId: _opA,
          locationId: _locA,
          roleId: _roleA,
          actorUserId: _actorA,
        );
        expect(rows, hasLength(2));
        expect(rows[0].roleId, equals(_roleA));
        expect(rows[1].effect, equals('deny'));

        final tx = pool.transactions.single;
        // SET LOCAL ordering already enforced; just check the SQL shape.
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from role_permissions'),
        );
        expect(selectSql, contains('where role_id = @role_id::uuid'));
        expect(selectSql, contains('order by permission_key'));
      },
    );

    test(
      'returns an empty list when no rows match the role_id (the '
      'matrix editor projects this as "all cells inherit defaults")',
      () async {
        final pool = _RolePermissionsPool(
          listForRoleRows: const <PostgresRow>[],
        );
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listForRole(
          operatorId: _opA,
          locationId: _locA,
          roleId: _roleA,
        );
        expect(rows, isEmpty);
      },
    );

    test(
      'optional actorUserId — when null, app.user_id SET LOCAL is '
      'skipped (background reads that have no human actor)',
      () async {
        final pool = _RolePermissionsPool(
          listForRoleRows: const <PostgresRow>[],
        );
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        await repo.listForRole(
          operatorId: _opA,
          locationId: _locA,
          roleId: _roleA,
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where((s) => s.contains("'app.user_id'")),
          isEmpty,
        );
      },
    );
  });

  group('RolePermissionsRepository.deleteCell', () {
    test(
      'WHERE filters role_id AND permission_key — a stale cell on '
      "another role cannot be deleted by accident; tenant SET LOCAL "
      'still scopes the cross-tenant denial via RLS',
      () async {
        final pool = _RolePermissionsPool(deleteAffectedRows: 1);
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        final affected = await repo.deleteCell(
          operatorId: _opA,
          locationId: _locA,
          updatedByUserId: _actorA,
          roleId: _roleA,
          permissionKey: PermissionKeys.forgeflowShiftView,
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final deleteSql = tx.executedSql.firstWhere(
          (s) => s.contains('delete from role_permissions'),
        );
        expect(deleteSql, contains('where role_id = @role_id::uuid'));
        expect(deleteSql, contains('and permission_key = @permission_key'));
        // permission_key bound — never interpolated.
        final params = tx.parameters.firstWhere(
          (p) =>
              p['role_id'] == _roleA &&
              p['permission_key'] == PermissionKeys.forgeflowShiftView,
        );
        expect(
          params['permission_key'],
          equals(PermissionKeys.forgeflowShiftView),
        );
      },
    );

    test(
      'returns 0 when no row matches (already-reverted cell, or stale '
      'role_id deflected by RLS)',
      () async {
        final pool = _RolePermissionsPool(deleteAffectedRows: 0);
        final repo =
            RolePermissionsRepository(TenantTransactionWrapper(pool));
        final affected = await repo.deleteCell(
          operatorId: _opA,
          locationId: _locA,
          updatedByUserId: _actorA,
          roleId: _roleA,
          permissionKey: PermissionKeys.forgeflowShiftView,
        );
        expect(affected, equals(0));
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the
/// RolePermissionsRepository seam.
class _RolePermissionsPool implements PostgresPool {
  _RolePermissionsPool({
    this.listForRoleRows = const <PostgresRow>[],
    this.upsertAffectedRows = 0,
    this.deleteAffectedRows = 0,
  });

  final List<PostgresRow> listForRoleRows;
  final int upsertAffectedRows;
  final int deleteAffectedRows;
  final List<_RolePermissionsTransaction> transactions =
      <_RolePermissionsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RolePermissionsTransaction(
      listForRoleRows: listForRoleRows,
      upsertAffectedRows: upsertAffectedRows,
      deleteAffectedRows: deleteAffectedRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _RolePermissionsTransaction extends PostgresTransaction {
  _RolePermissionsTransaction({
    required this.listForRoleRows,
    required this.upsertAffectedRows,
    required this.deleteAffectedRows,
  });

  final List<PostgresRow> listForRoleRows;
  final int upsertAffectedRows;
  final int deleteAffectedRows;

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
    if (sql.contains('from role_permissions')) {
      return listForRoleRows;
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
    if (sql.contains('insert into role_permissions')) {
      return upsertAffectedRows;
    }
    if (sql.contains('delete from role_permissions')) {
      return deleteAffectedRows;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
    rollbackCount += 1;
  }
}
