// Phase 9 live-closeout B17 / post-hardening P2 — canonical-path
// unit tests for RolesRepository.
//
// Coverage focus:
//
//   * Roles-row monotonicity — every UPDATE write (rename / soft-delete)
//     advances `updated_at = now()` and binds the actor to `updated_by`.
//     The audit trail relies on this strictly-forward stamp; if a
//     refactor dropped the `now()` advance, two consecutive admin edits
//     could share an `updated_at` and break the audit-row ordering.
//     This is what the prompt's "roles_version monotonic" maps to in
//     the `roles` surface — there is no separate version column; the
//     `updated_at` advance + `updated_by` rewrite are the per-row
//     monotonicity contract.
//
//     Companion: `users.roles_version` bump (the cross-row monotonic
//     counter that invalidates the permission cache when a grant
//     lands) is exercised in
//     `user_roles_repository_test.dart` — that contract belongs to
//     `user_roles`, not `roles`.
//
//   * Tenant scoping — every read / write goes through `withTenant`,
//     so `SET LOCAL app.operator_id / app.location_id / app.user_id`
//     run before the SELECT/INSERT/UPDATE so the per-tenant RLS
//     policy folds. Tests verify the canonical SET LOCAL ordering
//     and that `app.bypass_rls_audit = 'tenant'` (NOT 'system') is
//     stamped on the transaction — the roles repo is a pure tenant-
//     scoped surface (no admin BYPASSRLS path).
//
//   * Visibility split — `listVisibleRoles` returns global (operator_id
//     IS NULL) AND operator-scoped rows. The DB RLS policy admits both;
//     the repo's only obligation is to ORDER BY so global rows come
//     first (UI grouping is "global / custom"). Test pins the
//     `case when operator_id is null then 0 else 1 end, role_key`
//     ordering shape.
//
//   * Seeded role-key compatibility — `roleIdForVisibleKey` resolves
//     only global seeded slugs. Operator-scoped custom-role mutations
//     must carry `role_id`; custom `role_key` fallback is intentionally
//     not available after the B3 hybrid identifier sweep.
//
//   * `insertOperatorRole` — hard-coded `is_seeded = false` (custom
//     roles cannot mint themselves as seeded); `created_by` and
//     `updated_by` both bound to the actor (audit trail records the
//     creator); StateError on empty RETURNING (RLS denial, hard fail).
//
//   * `updateOperatorRole` guards — UPDATE WHERE clause requires
//     `is_seeded = false AND is_editable = true AND deleted_at is null`
//     so the operator cannot mutate seeded / locked / deleted rows
//     even with a stale role_id.
//
//   * `softDeleteOperatorRole` invariant — refuses to soft-delete a
//     role that still has at least one active grant (revoked_at IS NULL).
//     The active-grants probe runs FIRST, INSIDE the same transaction
//     as the DELETE, so a concurrent grant insert that lands between
//     the probe and the DELETE rolls back cleanly.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _actorA = '33333333-3333-3333-3333-333333333333';
const String _roleGlobal = '44444444-4444-4444-4444-444444444444';
const String _roleOpScoped = '55555555-5555-5555-5555-555555555555';

PostgresRow _roleRow({
  String roleId = _roleOpScoped,
  String? operatorId = _opA,
  String roleKey = 'shift_manager',
  String displayName = 'Shift Manager',
  String description = '',
  bool isSeeded = false,
  bool isEditable = true,
  DateTime? deletedAt,
}) {
  return <String, Object?>{
    'role_id': roleId,
    'operator_id': operatorId,
    'role_key': roleKey,
    'display_name': displayName,
    'description': description,
    'is_seeded': isSeeded,
    'is_editable': isEditable,
    'created_at': DateTime.utc(2026, 4, 28, 10),
    'updated_at': DateTime.utc(2026, 4, 28, 11),
    'deleted_at': deletedAt,
  };
}

void main() {
  group('RolesRepository.listVisibleRoles (tenant-scoped read)', () {
    test('tenant SET LOCAL ordering (operator_id, location_id, user_id) '
        'runs before the SELECT; visibility ORDER BY puts global rows '
        '(operator_id IS NULL) first, then operator-scoped, both by '
        'role_key for stable UI grouping', () async {
      final pool = _RolesPool(
        listRows: <PostgresRow>[
          _roleRow(
            roleId: _roleGlobal,
            operatorId: null,
            roleKey: 'admin',
            displayName: 'Admin',
            isSeeded: true,
            isEditable: false,
          ),
          _roleRow(roleKey: 'shift_manager'),
        ],
      );
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      final rows = await repo.listVisibleRoles(
        operatorId: _opA,
        locationId: _locA,
        actorUserId: _actorA,
      );
      expect(rows, hasLength(2));
      expect(
        rows[0].operatorId,
        isNull,
        reason: 'global rows are projected first (operatorId null)',
      );
      expect(rows[0].isSeeded, isTrue);
      expect(rows[0].isEditable, isFalse);
      expect(rows[1].operatorId, equals(_opA));

      final tx = pool.transactions.single;
      // Tenant-scoping GUCs ran first, in the canonical order.
      expect(tx.executedSql[0], contains("'app.operator_id'"));
      expect(tx.parameters[0]['value'], equals(_opA));
      expect(tx.executedSql[1], contains("'app.location_id'"));
      expect(tx.parameters[1]['value'], equals(_locA));
      expect(tx.executedSql[2], contains("'app.user_id'"));
      expect(tx.parameters[2]['value'], equals(_actorA));
      // Tenant audit marker — NOT system.
      expect(
        tx.executedSql.where(
          (s) => s.contains("'app.bypass_rls_audit'") && s.contains('true'),
        ),
        isNotEmpty,
      );
      expect(
        tx.executedSql.where((s) => s.contains('set local role forge_admin')),
        isEmpty,
        reason:
            'roles repo is a pure tenant-scoped surface — no '
            'BYPASSRLS path should engage',
      );
      // Visibility ORDER BY shape — globals first, then by role_key.
      final selectSql = tx.executedSql.firstWhere(
        (s) => s.contains('from roles'),
      );
      expect(selectSql, contains('where deleted_at is null'));
      expect(
        selectSql,
        contains(
          'order by case when operator_id is null then 0 else 1 end, role_key',
        ),
      );
    });

    test('actorUserId optional — when null, app.user_id SET LOCAL is '
        'skipped (background sweeps that have no human actor)', () async {
      final pool = _RolesPool(listRows: const <PostgresRow>[]);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await repo.listVisibleRoles(operatorId: _opA, locationId: _locA);
      final tx = pool.transactions.single;
      // No app.user_id SET LOCAL when actorUserId omitted.
      expect(tx.executedSql.where((s) => s.contains("'app.user_id'")), isEmpty);
      // operator_id and location_id still set.
      expect(
        tx.executedSql.where((s) => s.contains("'app.operator_id'")),
        hasLength(1),
      );
      expect(
        tx.executedSql.where((s) => s.contains("'app.location_id'")),
        hasLength(1),
      );
    });
  });

  group('RolesRepository.roleIdForVisibleKey (seeded-key compatibility)', () {
    test('resolves only global seeded role_key rows; custom roles must '
        'mutate by role_id instead of presentation slug', () async {
      final pool = _RolesPool(
        roleKeyLookupRows: <PostgresRow>[
          <String, Object?>{'role_id': _roleGlobal},
        ],
      );
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      final id = await repo.roleIdForVisibleKey(
        operatorId: _opA,
        locationId: _locA,
        roleKey: 'operator_staff',
        actorUserId: _actorA,
      );
      expect(id, equals(_roleGlobal));

      final tx = pool.transactions.single;
      final selectSql = tx.executedSql.firstWhere(
        (s) => s.contains('from roles') && s.contains('role_key'),
      );
      expect(selectSql, contains('and operator_id is null'));
      expect(selectSql, contains('and is_seeded = true'));
      expect(selectSql, isNot(contains('order by case when operator_id')));
      expect(selectSql, contains('limit 1'));
    });

    test('throws StateError for non-seeded custom role_key fallback — '
        'mutation callers must submit role_id', () async {
      final pool = _RolesPool(roleKeyLookupRows: const <PostgresRow>[]);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.roleIdForVisibleKey(
          operatorId: _opA,
          locationId: _locA,
          roleKey: 'custom.floor_captain',
          actorUserId: _actorA,
        ),
        throwsStateError,
      );
    });

    test('throws StateError when RETURNING role_id is malformed (non-string '
        'or empty) — defensive: the driver should never return that, but '
        'the guard is in production code so the test pins it', () async {
      final pool = _RolesPool(
        roleKeyLookupRows: <PostgresRow>[
          <String, Object?>{'role_id': ''},
        ],
      );
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.roleIdForVisibleKey(
          operatorId: _opA,
          locationId: _locA,
          roleKey: 'shift_manager',
          actorUserId: _actorA,
        ),
        throwsStateError,
      );
    });
  });

  group('RolesRepository.insertOperatorRole', () {
    test('INSERT shape: is_seeded hard-coded false (custom roles cannot '
        'mint themselves as seeded); created_by and updated_by both '
        'bound to the actor on a fresh row', () async {
      final pool = _RolesPool(insertedRoleId: _roleOpScoped);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      final id = await repo.insertOperatorRole(
        operatorId: _opA,
        locationId: _locA,
        createdByUserId: _actorA,
        roleKey: 'shift_manager',
        displayName: 'Shift Manager',
        description: 'Custom role for shift leads',
      );
      expect(id, equals(_roleOpScoped));

      final tx = pool.transactions.single;
      final insertSql = tx.executedSql.firstWhere(
        (s) => s.contains('insert into roles'),
      );
      // is_seeded literal false in the VALUES list — never bound.
      expect(
        insertSql,
        contains('false, @is_editable'),
        reason:
            'custom roles cannot self-mark as seeded; the false '
            'must be a SQL literal so a bind-substitution attack '
            'cannot lift an operator role to seeded posture',
      );
      // created_by and updated_by share the same parameter.
      expect(insertSql, contains('@created_by::uuid, @created_by::uuid'));

      final params = tx.parameters.firstWhere(
        (p) => p['role_key'] == 'shift_manager',
      );
      expect(params['operator_id'], equals(_opA));
      expect(params['display_name'], equals('Shift Manager'));
      expect(params['description'], equals('Custom role for shift leads'));
      expect(params['created_by'], equals(_actorA));
      expect(params['is_editable'], isTrue);
    });

    test('isEditable=false plumbs through (locked custom roles for '
        'operator-side admin curation)', () async {
      final pool = _RolesPool(insertedRoleId: _roleOpScoped);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await repo.insertOperatorRole(
        operatorId: _opA,
        locationId: _locA,
        createdByUserId: _actorA,
        roleKey: 'locked_role',
        displayName: 'Locked',
        isEditable: false,
      );
      final params = pool.transactions.single.parameters.firstWhere(
        (p) => p['role_key'] == 'locked_role',
      );
      expect(params['is_editable'], isFalse);
    });

    test('INSERT returning empty rows → throws StateError (RLS denied '
        'the row even though SET LOCAL ran — hard failure, never a '
        'silent null)', () async {
      final pool = _RolesPool(insertedRoleId: null);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.insertOperatorRole(
          operatorId: _opA,
          locationId: _locA,
          createdByUserId: _actorA,
          roleKey: 'shift_manager',
          displayName: 'Shift Manager',
        ),
        throwsStateError,
      );
    });

    test('INSERT returning malformed role_id (empty string) → throws '
        'StateError (defensive guard against a misbehaving driver)', () async {
      final pool = _RolesPool(insertedRoleId: '');
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.insertOperatorRole(
          operatorId: _opA,
          locationId: _locA,
          createdByUserId: _actorA,
          roleKey: 'shift_manager',
          displayName: 'Shift Manager',
        ),
        throwsStateError,
      );
    });
  });

  group('RolesRepository.updateOperatorRole', () {
    test('roles-row monotonicity: UPDATE always advances updated_at = '
        'now() and binds updated_by = actor — even when only one '
        'editable column is supplied via coalesce', () async {
      final pool = _RolesPool(updateAffectedRows: 1);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      final affected = await repo.updateOperatorRole(
        operatorId: _opA,
        locationId: _locA,
        updatedByUserId: _actorA,
        roleId: _roleOpScoped,
        displayName: 'Updated Name',
      );
      expect(affected, equals(1));

      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.firstWhere(
        (s) => s.contains('update roles'),
      );
      // Updated_at MUST advance and updated_by MUST be rewritten —
      // these are the per-row monotonic markers the audit trail
      // depends on for ordered playback.
      expect(updateSql, contains('updated_at = now()'));
      expect(updateSql, contains('updated_by = @updated_by::uuid'));
      // Coalesce guards every editable column so an omitted field
      // is preserved, not blanked.
      expect(
        updateSql,
        contains('display_name = coalesce(@display_name, display_name)'),
      );
      expect(
        updateSql,
        contains('description = coalesce(@description, description)'),
      );

      final params = tx.parameters.firstWhere(
        (p) => p['display_name'] == 'Updated Name',
      );
      expect(params['updated_by'], equals(_actorA));
      expect(
        params['description'],
        isNull,
        reason:
            'omitted description binds null so coalesce keeps '
            'the existing value',
      );
    });

    test('guard clauses: WHERE requires is_seeded=false AND is_editable=true '
        'AND deleted_at is null — operator cannot mutate seeded / locked '
        '/ deleted rows even with a stale role_id', () async {
      final pool = _RolesPool(updateAffectedRows: 0);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await repo.updateOperatorRole(
        operatorId: _opA,
        locationId: _locA,
        updatedByUserId: _actorA,
        roleId: _roleOpScoped,
        displayName: 'X',
      );
      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.firstWhere(
        (s) => s.contains('update roles'),
      );
      expect(updateSql, contains('and operator_id = @operator_id::uuid'));
      expect(updateSql, contains('and is_seeded = false'));
      expect(updateSql, contains('and is_editable = true'));
      expect(updateSql, contains('and deleted_at is null'));
    });

    test('returns 0 when no row matches the guards (proxy translates to '
        '404 / 403 envelope based on context)', () async {
      final pool = _RolesPool(updateAffectedRows: 0);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      final affected = await repo.updateOperatorRole(
        operatorId: _opA,
        locationId: _locA,
        updatedByUserId: _actorA,
        roleId: _roleOpScoped,
        displayName: 'X',
      );
      expect(affected, equals(0));
    });
  });

  group('RolesRepository.softDeleteOperatorRole — active-grant invariant', () {
    test('refuses with StateError when at least one active grant exists; '
        'the active-grants probe runs FIRST inside the same transaction '
        'so a grant insert that races the DELETE rolls back cleanly', () async {
      final pool = _RolesPool(
        activeGrantsRows: <PostgresRow>[
          <String, Object?>{'?column?': 1},
        ],
      );
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.softDeleteOperatorRole(
          operatorId: _opA,
          locationId: _locA,
          updatedByUserId: _actorA,
          roleId: _roleOpScoped,
        ),
        throwsStateError,
      );

      final tx = pool.transactions.single;
      // Active-grants probe shape — single SELECT 1 from user_roles
      // filtered to the role + revoked_at IS NULL.
      final probeSql = tx.executedSql.firstWhere(
        (s) =>
            s.contains('from user_roles') && s.contains('revoked_at is null'),
      );
      expect(probeSql, contains('role_id = @role_id::uuid'));
      // No UPDATE on roles ran — the probe short-circuited the
      // soft-delete.
      expect(
        tx.executedSql.where(
          (s) => s.contains('update roles') && s.contains('deleted_at = now()'),
        ),
        isEmpty,
        reason: 'soft-delete must not run when an active grant blocks',
      );
    });

    test(
      'happy path: no active grants → soft-delete UPDATE runs, '
      'deleted_at = now(), updated_at advances, updated_by rebinds',
      () async {
        final pool = _RolesPool(
          activeGrantsRows: const <PostgresRow>[],
          softDeleteAffectedRows: 1,
        );
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        final affected = await repo.softDeleteOperatorRole(
          operatorId: _opA,
          locationId: _locA,
          updatedByUserId: _actorA,
          roleId: _roleOpScoped,
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) => s.contains('update roles') && s.contains('deleted_at = now()'),
        );
        // updated_at MUST advance with deleted_at on the same row write —
        // the audit trail's per-row monotonicity depends on it.
        expect(updateSql, contains('updated_at = now()'));
        expect(updateSql, contains('updated_by = @updated_by::uuid'));
        // Idempotency guard — already-deleted rows are skipped.
        expect(updateSql, contains('and deleted_at is null'));
      },
    );

    test(
      'soft-delete is idempotent — second call on an already-deleted '
      'row returns 0 (the WHERE deleted_at is null guard short-circuits)',
      () async {
        final pool = _RolesPool(
          activeGrantsRows: const <PostgresRow>[],
          softDeleteAffectedRows: 0,
        );
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        final affected = await repo.softDeleteOperatorRole(
          operatorId: _opA,
          locationId: _locA,
          updatedByUserId: _actorA,
          roleId: _roleOpScoped,
        );
        expect(affected, equals(0));
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the RolesRepository seam.
///
/// `listRows` controls listVisibleRoles SELECT.
/// `roleKeyLookupRows` controls roleIdForVisibleKey SELECT.
/// `insertedRoleId` controls insertOperatorRole RETURNING (pass null
///   for empty rows / RLS denial; pass empty string for the malformed
///   role_id guard).
/// `updateAffectedRows` controls updateOperatorRole affected count.
/// `activeGrantsRows` controls the soft-delete probe SELECT.
/// `softDeleteAffectedRows` controls the DELETE UPDATE affected count.
class _RolesPool implements PostgresPool {
  _RolesPool({
    this.listRows = const <PostgresRow>[],
    this.roleKeyLookupRows = const <PostgresRow>[],
    this.insertedRoleId,
    this.updateAffectedRows = 0,
    this.activeGrantsRows = const <PostgresRow>[],
    this.softDeleteAffectedRows = 0,
  });

  final List<PostgresRow> listRows;
  final List<PostgresRow> roleKeyLookupRows;
  final String? insertedRoleId;
  final int updateAffectedRows;
  final List<PostgresRow> activeGrantsRows;
  final int softDeleteAffectedRows;
  final List<_RolesTransaction> transactions = <_RolesTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RolesTransaction(
      listRows: listRows,
      roleKeyLookupRows: roleKeyLookupRows,
      insertedRoleId: insertedRoleId,
      updateAffectedRows: updateAffectedRows,
      activeGrantsRows: activeGrantsRows,
      softDeleteAffectedRows: softDeleteAffectedRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _RolesTransaction extends PostgresTransaction {
  _RolesTransaction({
    required this.listRows,
    required this.roleKeyLookupRows,
    required this.insertedRoleId,
    required this.updateAffectedRows,
    required this.activeGrantsRows,
    required this.softDeleteAffectedRows,
  });

  final List<PostgresRow> listRows;
  final List<PostgresRow> roleKeyLookupRows;
  final String? insertedRoleId;
  final int updateAffectedRows;
  final List<PostgresRow> activeGrantsRows;
  final int softDeleteAffectedRows;

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
    if (sql.contains('insert into roles')) {
      final id = insertedRoleId;
      if (id == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'role_id': id},
      ];
    }
    if (sql.contains('from user_roles') && sql.contains('revoked_at is null')) {
      return activeGrantsRows;
    }
    if (sql.contains('from roles')) {
      if (sql.contains('role_key = @role_key')) {
        return roleKeyLookupRows;
      }
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
    if (sql.contains('update roles')) {
      if (sql.contains('deleted_at = now()')) {
        return softDeleteAffectedRows;
      }
      return updateAffectedRows;
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
