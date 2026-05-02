// Phase 9 live-closeout B17 / 9.0a / post-hardening P2 — canonical-
// path unit tests for UserRolesRepository.
//
// Coverage focus:
//
//   * Scope-payload CHECK enforcement (9.0a):
//     `user_roles.scope_type` has a NOT NULL + CHECK constraint that
//     accepts only `'operator_wide'`, `'org_unit'`, `'location'`. The
//     repository validates the (scopeType, grantLocationId,
//     grantOrgUnitId) triple BEFORE opening a transaction so typos at
//     the call site break loudly without depending on the DB CHECK.
//     Tests pin every violation path (six combinations) plus the
//     three accepted shapes.
//
//   * `users.roles_version` bump — every successful grant insert /
//     revoke MUST bump the affected user's roles_version inside the
//     same transaction so the proxy's permission cache (Phase 9.6)
//     invalidates exactly when the grant lands. Tests pin:
//       - insert succeeds → bump runs once
//       - revoke affects ≥1 row → bump runs once
//       - revoke affects 0 rows → bump SKIPPED (so a no-op revoke
//         doesn't burn cache invalidation budget)
//       - bumpActiveGrantHoldersForRole emits the right EXISTS shape
//         so a custom-role permission edit invalidates every active
//         holder
//
//   * Tenant predicate folding — every method goes through
//     `withTenant`; verify SET LOCAL `app.operator_id` /
//     `app.location_id` (and `app.user_id` when present) run before
//     the SELECT/INSERT/UPDATE so the per-tenant RLS policy folds.
//
//   * `UserRoleScope` value object — `sqlKey` matches the 9.0a CHECK
//     values exactly; `fromSqlKey` rejects unknowns with a named
//     ArgumentError; `fromGrantLocationId` legacy convention
//     (null / empty → operatorWide; non-empty → location).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _actorA = '33333333-3333-3333-3333-333333333333';
const String _targetUser = '44444444-4444-4444-4444-444444444444';
const String _roleA = '55555555-5555-5555-5555-555555555555';
const String _orgUnitA = '66666666-6666-6666-6666-666666666666';
const String _grantLoc = '77777777-7777-7777-7777-777777777777';
const String _userRoleId = '88888888-8888-8888-8888-888888888888';

void main() {
  group('UserRoleScope value object', () {
    test(
      'sqlKey produces the locked 9.0a CHECK constraint values',
      () {
        expect(UserRoleScope.operatorWide.sqlKey, equals('operator_wide'));
        expect(UserRoleScope.orgUnit.sqlKey, equals('org_unit'));
        expect(UserRoleScope.location.sqlKey, equals('location'));
      },
    );

    test('fromSqlKey round-trips every accepted value', () {
      expect(
        UserRoleScope.fromSqlKey('operator_wide'),
        equals(UserRoleScope.operatorWide),
      );
      expect(
        UserRoleScope.fromSqlKey('org_unit'),
        equals(UserRoleScope.orgUnit),
      );
      expect(
        UserRoleScope.fromSqlKey('location'),
        equals(UserRoleScope.location),
      );
    });

    test('fromSqlKey rejects unknown values with ArgumentError', () {
      expect(
        () => UserRoleScope.fromSqlKey('global'),
        throwsArgumentError,
      );
      expect(
        () => UserRoleScope.fromSqlKey(''),
        throwsArgumentError,
      );
    });

    test(
      'fromGrantLocationId: legacy "null = operator-wide" convention',
      () {
        expect(
          UserRoleScope.fromGrantLocationId(null),
          equals(UserRoleScope.operatorWide),
        );
        expect(
          UserRoleScope.fromGrantLocationId(''),
          equals(UserRoleScope.operatorWide),
          reason: 'empty string also treated as null per legacy callers',
        );
        expect(
          UserRoleScope.fromGrantLocationId(_grantLoc),
          equals(UserRoleScope.location),
        );
      },
    );
  });

  group('UserRolesRepository.activeGrantsForUser (tenant-scoped read)', () {
    test(
      'SET LOCAL operator_id / location_id / user_id run before the '
      'SELECT so the per-tenant RLS policy folds; SELECT predicate '
      'filters to active grants only',
      () async {
        final pool = _RolesPool(
          activeGrantRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': _userRoleId,
              'user_id': _targetUser,
              'role_id': _roleA,
              'operator_id': _opA,
              'location_id': null,
              'org_unit_id': null,
              'scope_type': 'operator_wide',
              'effective_location_ids': const <String>[],
              'valid_from': DateTime.utc(2026, 4, 28),
              'valid_until': null,
              'granted_by': _actorA,
              'revoked_at': null,
              'revoked_by': null,
              'reason': null,
              'created_at': DateTime.utc(2026, 4, 28),
              'updated_at': DateTime.utc(2026, 4, 28),
            },
          ],
        );
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        final rows = await repo.activeGrantsForUser(
          operatorId: _opA,
          locationId: _locA,
          targetUserId: _targetUser,
          actorUserId: _actorA,
        );
        expect(rows, hasLength(1));
        expect(rows.single.userRoleId, equals(_userRoleId));
        expect(rows.single.scopeType, equals('operator_wide'));

        final tx = pool.transactions.single;
        // Tenant-scoping GUCs ran first, in the canonical order.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.parameters[1]['value'], equals(_locA));
        expect(tx.executedSql[2], contains("'app.user_id'"));
        expect(tx.parameters[2]['value'], equals(_actorA));
        // Predicate shape — active grants only.
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from user_roles'),
        );
        expect(selectSql, contains('where user_id = @user_id::uuid'));
        expect(selectSql, contains('and operator_id = @operator_id::uuid'));
        expect(selectSql, contains('and revoked_at is null'));
        expect(selectSql, contains('valid_until is null or valid_until > now()'));
        expect(selectSql, contains('and valid_from <= now()'));
      },
    );
  });

  group('UserRolesRepository.insertGrant — scope CHECK enforcement', () {
    test(
      'scopeType=location WITHOUT grantLocationId throws ArgumentError '
      'before opening a transaction',
      () async {
        final pool = _RolesPool();
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        Object? thrown;
        try {
          await repo.insertGrant(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: _actorA,
            targetUserId: _targetUser,
            roleId: _roleA,
            scopeType: UserRoleScope.location,
          );
        } on ArgumentError catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ArgumentError>());
        expect((thrown! as ArgumentError).name, equals('grantLocationId'));
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'scopeType=location WITH grantOrgUnitId also set throws '
      'ArgumentError (mixed-shape grant)',
      () async {
        final pool = _RolesPool();
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        Object? thrown;
        try {
          await repo.insertGrant(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: _actorA,
            targetUserId: _targetUser,
            roleId: _roleA,
            scopeType: UserRoleScope.location,
            grantLocationId: _grantLoc,
            grantOrgUnitId: _orgUnitA,
          );
        } on ArgumentError catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ArgumentError>());
        expect((thrown! as ArgumentError).name, equals('grantOrgUnitId'));
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'scopeType=org_unit WITHOUT grantOrgUnitId throws ArgumentError',
      () async {
        final pool = _RolesPool();
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        // insertGrant validates synchronously (the body throws BEFORE
        // returning a Future), so wrap in a closure so the matcher
        // sees the throw.
        await expectLater(
          () => repo.insertGrant(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: _actorA,
            targetUserId: _targetUser,
            roleId: _roleA,
            scopeType: UserRoleScope.orgUnit,
          ),
          throwsArgumentError,
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'scopeType=org_unit WITH grantLocationId also set throws '
      'ArgumentError (mixed-shape grant)',
      () async {
        final pool = _RolesPool();
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        Object? thrown;
        try {
          await repo.insertGrant(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: _actorA,
            targetUserId: _targetUser,
            roleId: _roleA,
            scopeType: UserRoleScope.orgUnit,
            grantOrgUnitId: _orgUnitA,
            grantLocationId: _grantLoc,
          );
        } on ArgumentError catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ArgumentError>());
        expect((thrown! as ArgumentError).name, equals('grantLocationId'));
      },
    );

    test(
      'scopeType=operator_wide WITH grantLocationId throws '
      'ArgumentError (operator-wide grants forbid location id)',
      () async {
        final pool = _RolesPool();
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.insertGrant(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: _actorA,
            targetUserId: _targetUser,
            roleId: _roleA,
            scopeType: UserRoleScope.operatorWide,
            grantLocationId: _grantLoc,
          ),
          throwsArgumentError,
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'scopeType=operator_wide WITH grantOrgUnitId throws '
      'ArgumentError (operator-wide grants forbid org_unit id too)',
      () async {
        final pool = _RolesPool();
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.insertGrant(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: _actorA,
            targetUserId: _targetUser,
            roleId: _roleA,
            scopeType: UserRoleScope.operatorWide,
            grantOrgUnitId: _orgUnitA,
          ),
          throwsArgumentError,
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'happy path — scopeType=location with grantLocationId set: '
      'INSERT runs, scope_type binding matches the enum sqlKey, and '
      'roles_version bump on `users` runs in the SAME transaction',
      () async {
        final pool = _RolesPool(insertedUserRoleId: _userRoleId);
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        final id = await repo.insertGrant(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
          targetUserId: _targetUser,
          roleId: _roleA,
          scopeType: UserRoleScope.location,
          grantLocationId: _grantLoc,
        );
        expect(id, equals(_userRoleId));

        final tx = pool.transactions.single;
        // INSERT into user_roles bound the scope_type as the enum sqlKey.
        final insertParams = tx.parameters.firstWhere(
          (p) => p['scope_type'] == 'location',
        );
        expect(insertParams['user_id'], equals(_targetUser));
        expect(insertParams['role_id'], equals(_roleA));
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_grantLoc));
        expect(insertParams['org_unit_id'], isNull);
        expect(insertParams['actor'], equals(_actorA));

        // Roles-version bump runs inside the SAME transaction.
        final bumpStatements = tx.executedSql.where(
          (s) =>
              s.contains('update users') &&
              s.contains('set roles_version = roles_version + 1') &&
              s.contains('where user_id = @user_id::uuid'),
        );
        expect(
          bumpStatements,
          hasLength(1),
          reason:
              'permission cache invalidates exactly when the grant '
              'commits — bump must share the insert\'s transaction',
        );
        expect(tx.commitCount, equals(1));
      },
    );

    test(
      'happy path — scopeType=org_unit with grantOrgUnitId set: '
      'org_unit_id binds, location_id null',
      () async {
        final pool = _RolesPool(insertedUserRoleId: _userRoleId);
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        await repo.insertGrant(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
          targetUserId: _targetUser,
          roleId: _roleA,
          scopeType: UserRoleScope.orgUnit,
          grantOrgUnitId: _orgUnitA,
        );
        final tx = pool.transactions.single;
        final insertParams = tx.parameters.firstWhere(
          (p) => p['scope_type'] == 'org_unit',
        );
        expect(insertParams['org_unit_id'], equals(_orgUnitA));
        expect(insertParams['location_id'], isNull);
      },
    );

    test(
      'happy path — scopeType=operator_wide: both location_id and '
      'org_unit_id bound as null; scope_type = "operator_wide"',
      () async {
        final pool = _RolesPool(insertedUserRoleId: _userRoleId);
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        await repo.insertGrant(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
          targetUserId: _targetUser,
          roleId: _roleA,
          scopeType: UserRoleScope.operatorWide,
        );
        final tx = pool.transactions.single;
        final insertParams = tx.parameters.firstWhere(
          (p) => p['scope_type'] == 'operator_wide',
        );
        expect(insertParams['location_id'], isNull);
        expect(insertParams['org_unit_id'], isNull);
      },
    );

    test(
      'INSERT returns no rows (RLS denial) → throws StateError; the '
      'roles_version bump must not run for a failed grant',
      () async {
        final pool = _RolesPool(insertedUserRoleId: null);
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.insertGrant(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: _actorA,
            targetUserId: _targetUser,
            roleId: _roleA,
            scopeType: UserRoleScope.operatorWide,
          ),
          throwsStateError,
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (s) =>
                s.contains('update users') &&
                s.contains('roles_version = roles_version + 1'),
          ),
          isEmpty,
          reason: 'failed grant must not invalidate the permission cache',
        );
      },
    );
  });

  group('UserRolesRepository.revokeGrant — bump only when affected > 0', () {
    test(
      'affected ≥ 1: roles_version bump runs once in the same '
      'transaction',
      () async {
        final pool = _RolesPool(revokeAffectedRows: 1);
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        final affected = await repo.revokeGrant(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
          userRoleId: _userRoleId,
          targetUserId: _targetUser,
        );
        expect(affected, equals(1));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (s) =>
                s.contains('update users') &&
                s.contains('roles_version = roles_version + 1'),
          ),
          hasLength(1),
        );
      },
    );

    test(
      'affected = 0 (no-op revoke or already-revoked grant): bump '
      'SKIPPED — invalidating the cache for a no-op write would burn '
      'budget for no semantic change',
      () async {
        final pool = _RolesPool(revokeAffectedRows: 0);
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        final affected = await repo.revokeGrant(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
          userRoleId: _userRoleId,
          targetUserId: _targetUser,
        );
        expect(affected, equals(0));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (s) =>
                s.contains('update users') &&
                s.contains('roles_version = roles_version + 1'),
          ),
          isEmpty,
        );
      },
    );
  });

  group(
      'UserRolesRepository.bumpActiveGrantHoldersForRole '
      '(custom-role permission edit fan-out)', () {
    test(
      'UPDATE shape: bumps every user with an ACTIVE grant for the '
      'role inside the operator. EXISTS subquery filters on '
      'revoked_at IS NULL + validity window so revoked / expired '
      'grants do not trigger a roles_version bump',
      () async {
        final pool = _RolesPool(bumpAffectedRows: 5);
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        final affected = await repo.bumpActiveGrantHoldersForRole(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
          roleId: _roleA,
        );
        expect(affected, equals(5));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update users') &&
              s.contains('roles_version = roles_version + 1') &&
              s.contains('exists ('),
        );
        expect(updateSql, contains('from user_roles'));
        expect(updateSql, contains('user_roles.role_id = @role_id::uuid'));
        expect(updateSql, contains('user_roles.revoked_at is null'));
        expect(updateSql, contains(
          'user_roles.valid_until is null or user_roles.valid_until > now()',
        ));
        expect(updateSql, contains('user_roles.valid_from <= now()'));

        final params = tx.parameters.firstWhere(
          (p) => p['role_id'] == _roleA,
        );
        expect(params['operator_id'], equals(_opA));
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the UserRolesRepository
/// seam.
///
/// `insertedUserRoleId` controls what the grant INSERT's `RETURNING
/// user_role_id` hands back; pass `null` for empty rows (RLS denial).
///
/// `revokeAffectedRows` controls what the revoke UPDATE returns as
/// the affected-row count.
///
/// `bumpAffectedRows` controls the bumpActiveGrantHoldersForRole
/// affected-row count.
///
/// `activeGrantRows` controls what activeGrantsForUser returns.
class _RolesPool implements PostgresPool {
  _RolesPool({
    this.insertedUserRoleId,
    this.revokeAffectedRows = 0,
    this.bumpAffectedRows = 0,
    this.activeGrantRows = const <PostgresRow>[],
  });

  final String? insertedUserRoleId;
  final int revokeAffectedRows;
  final int bumpAffectedRows;
  final List<PostgresRow> activeGrantRows;
  final List<_RolesTransaction> transactions = <_RolesTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RolesTransaction(
      insertedUserRoleId: insertedUserRoleId,
      revokeAffectedRows: revokeAffectedRows,
      bumpAffectedRows: bumpAffectedRows,
      activeGrantRows: activeGrantRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _RolesTransaction extends PostgresTransaction {
  _RolesTransaction({
    required this.insertedUserRoleId,
    required this.revokeAffectedRows,
    required this.bumpAffectedRows,
    required this.activeGrantRows,
  });

  final String? insertedUserRoleId;
  final int revokeAffectedRows;
  final int bumpAffectedRows;
  final List<PostgresRow> activeGrantRows;

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
    if (sql.contains('insert into user_roles') &&
        sql.contains('returning user_role_id::text as user_role_id')) {
      if (insertedUserRoleId == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'user_role_id': insertedUserRoleId},
      ];
    }
    if (sql.contains('from user_roles')) {
      return activeGrantRows;
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
    if (sql.contains('update user_roles') &&
        sql.contains('set revoked_at = now()')) {
      return revokeAffectedRows;
    }
    if (sql.contains('update users') &&
        sql.contains('exists (')) {
      return bumpAffectedRows;
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
