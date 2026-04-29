// Phase 9 live-closeout B17/B19 tests.
//
// Covers:
//   * RolesRepository SQL contract: listVisibleRoles ordering
//     (global first, then role_key), insertOperatorRole RETURNING,
//     softDeleteOperatorRole guard (refuses when active grants
//     exist).
//   * RolePermissionsRepository: listForRole ordering, upsertCell
//     uses ON CONFLICT, deleteCell drops the row, effect validation
//     ('allow' / 'deny' only).
//   * UserRolesRepository: insertGrant inserts + bumps roles_version
//     atomically, revokeGrant updates + bumps when affected, listing
//     active grants filters by revoked_at + valid_until + valid_from.
//   * ScaffoldFailingProxyAdminPermissionGuard fails closed.
//   * InMemoryProxyAdminPermissionGuard: allow / default-deny /
//     explicit-deny / MFA stale-auth / reCAPTCHA reject /
//     reCAPTCHA challenge.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/role_permissions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validRoleId = '44444444-4444-4444-4444-444444444444';
const String _validUserRoleId = '55555555-5555-5555-5555-555555555555';

void main() {
  group('RolesRepository (B17 — fake Postgres)', () {
    test('listVisibleRoles selects every non-deleted row + orders global '
        'first then by role_key', () async {
      final pool = _RoleAdminPool(
        roleRows: <PostgresRow>[
          <String, Object?>{
            'role_id': _validRoleId,
            'operator_id': null,
            'role_key': 'super_admin',
            'display_name': 'Super Admin',
            'description': '',
            'is_seeded': true,
            'is_editable': false,
            'created_at': DateTime.utc(2026, 4, 26, 12),
            'updated_at': DateTime.utc(2026, 4, 26, 12),
            'deleted_at': null,
          },
        ],
      );
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      final roles = await repo.listVisibleRoles(
        operatorId: _validOpId,
        locationId: _validLocId,
      );
      expect(roles, hasLength(1));
      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains('from roles'));
      expect(sql, contains('deleted_at is null'));
      expect(sql, contains('case when operator_id is null then 0 else 1 end'));
    });

    test('insertOperatorRole inserts is_seeded=false + binds role_key + '
        'display_name', () async {
      final pool = _RoleAdminPool(returningRoleId: _validRoleId);
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      final id = await repo.insertOperatorRole(
        operatorId: _validOpId,
        locationId: _validLocId,
        createdByUserId: _validUserId,
        roleKey: 'manager_kitchen',
        displayName: 'Kitchen Manager',
      );
      expect(id, equals(_validRoleId));
      final tx = pool.transactions.single;
      final sql = tx.executedSql.last;
      expect(sql, contains('insert into roles'));
      expect(sql, contains('false, @is_editable'));
      expect(tx.parameters.last['role_key'], equals('manager_kitchen'));
      expect(tx.parameters.last['display_name'], equals('Kitchen Manager'));
    });

    test(
      'visibleRoleById filters by role_id and tenant-visible roles',
      () async {
        final pool = _RoleAdminPool(
          roleRows: <PostgresRow>[
            <String, Object?>{
              'role_id': _validRoleId,
              'operator_id': _validOpId,
              'role_key': 'manager_kitchen',
              'display_name': 'Kitchen Manager',
              'description': '',
              'is_seeded': false,
              'is_editable': true,
              'created_at': DateTime.utc(2026, 4, 26, 12),
              'updated_at': DateTime.utc(2026, 4, 26, 12),
              'deleted_at': null,
            },
          ],
        );
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        final role = await repo.visibleRoleById(
          operatorId: _validOpId,
          locationId: _validLocId,
          roleId: _validRoleId,
          actorUserId: _validUserId,
        );
        expect(role.roleKey, equals('manager_kitchen'));
        final sql = pool.transactions.single.executedSql.last;
        expect(sql, contains('where role_id = @role_id::uuid'));
        expect(sql, contains('operator_id = @operator_id::uuid'));
      },
    );

    test(
      'updateOperatorRole only touches editable operator custom roles',
      () async {
        final pool = _RoleAdminPool();
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        await repo.updateOperatorRole(
          operatorId: _validOpId,
          locationId: _validLocId,
          updatedByUserId: _validUserId,
          roleId: _validRoleId,
          displayName: 'Kitchen Captain',
          description: 'Owns kitchen handoff',
        );
        final tx = pool.transactions.single;
        final sql = tx.executedSql.last;
        expect(sql, contains('update roles'));
        expect(sql, contains('operator_id = @operator_id::uuid'));
        expect(sql, contains('is_seeded = false'));
        expect(sql, contains('is_editable = true'));
        expect(tx.parameters.last['display_name'], equals('Kitchen Captain'));
      },
    );

    test('softDeleteOperatorRole refuses when active grants exist', () async {
      final pool = _RoleAdminPool(
        returningRoleId: _validRoleId,
        activeGrantRowsForRole: <PostgresRow>[
          <String, Object?>{'?column?': 1},
        ],
      );
      final repo = RolesRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.softDeleteOperatorRole(
          operatorId: _validOpId,
          locationId: _validLocId,
          updatedByUserId: _validUserId,
          roleId: _validRoleId,
        ),
        throwsStateError,
      );
    });

    test(
      'softDeleteOperatorRole succeeds when no active grants exist',
      () async {
        final pool = _RoleAdminPool(returningRoleId: _validRoleId);
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        await repo.softDeleteOperatorRole(
          operatorId: _validOpId,
          locationId: _validLocId,
          updatedByUserId: _validUserId,
          roleId: _validRoleId,
        );
        final tx = pool.transactions.single;
        // Last executed SQL is the UPDATE.
        expect(tx.executedSql.last, contains('update roles'));
        expect(tx.executedSql.last, contains('deleted_at = now()'));
      },
    );
  });

  group('RolePermissionsRepository (B17 — fake Postgres)', () {
    test(
      'listForRole filters by role_id and orders by permission_key',
      () async {
        final pool = _RoleAdminPool(returningRoleId: _validRoleId);
        final repo = RolePermissionsRepository(TenantTransactionWrapper(pool));
        await repo.listForRole(
          operatorId: _validOpId,
          locationId: _validLocId,
          roleId: _validRoleId,
        );
        final sql = pool.transactions.single.executedSql.last;
        expect(sql, contains('from role_permissions'));
        expect(sql, contains('where role_id = @role_id'));
        expect(sql, contains('order by permission_key'));
      },
    );

    test(
      'upsertCell uses ON CONFLICT (role_id, permission_key) DO UPDATE',
      () async {
        final pool = _RoleAdminPool(returningRoleId: _validRoleId);
        final repo = RolePermissionsRepository(TenantTransactionWrapper(pool));
        await repo.upsertCell(
          operatorId: _validOpId,
          locationId: _validLocId,
          updatedByUserId: _validUserId,
          roleId: _validRoleId,
          permissionKey: 'team.users.invite',
          effect: 'allow',
        );
        final sql = pool.transactions.single.executedSql.last;
        expect(sql, contains('on conflict (role_id, permission_key)'));
        expect(sql, contains('do update'));
        expect(sql, contains('set effect = excluded.effect'));
      },
    );

    test('upsertCell rejects effects other than allow/deny', () async {
      final pool = _RoleAdminPool(returningRoleId: _validRoleId);
      final repo = RolePermissionsRepository(TenantTransactionWrapper(pool));
      expect(
        () => repo.upsertCell(
          operatorId: _validOpId,
          locationId: _validLocId,
          updatedByUserId: _validUserId,
          roleId: _validRoleId,
          permissionKey: 'team.users.invite',
          effect: 'maybe',
        ),
        throwsArgumentError,
      );
    });

    test('deleteCell removes by (role_id, permission_key)', () async {
      final pool = _RoleAdminPool(returningRoleId: _validRoleId);
      final repo = RolePermissionsRepository(TenantTransactionWrapper(pool));
      await repo.deleteCell(
        operatorId: _validOpId,
        locationId: _validLocId,
        updatedByUserId: _validUserId,
        roleId: _validRoleId,
        permissionKey: 'team.users.invite',
      );
      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains('delete from role_permissions'));
      expect(sql, contains('role_id = @role_id'));
      expect(sql, contains('permission_key = @permission_key'));
    });
  });

  group('UserRolesRepository (B17 — fake Postgres)', () {
    test('insertGrant operator_wide inserts scope_type + bumps '
        'users.roles_version atomically', () async {
      final pool = _RoleAdminPool(returningUserRoleId: _validUserRoleId);
      final repo = UserRolesRepository(TenantTransactionWrapper(pool));
      final id = await repo.insertGrant(
        operatorId: _validOpId,
        locationId: _validLocId,
        actorUserId: _validUserId,
        targetUserId: '99999999-9999-9999-9999-999999999999',
        roleId: _validRoleId,
        scopeType: UserRoleScope.operatorWide,
      );
      expect(id, equals(_validUserRoleId));
      final tx = pool.transactions.single;
      // INSERT is the first non-SET-LOCAL SQL; UPDATE roles_version
      // is the last.
      final insertIdx = tx.executedSql.indexWhere(
        (sql) => sql.contains('insert into user_roles'),
      );
      expect(insertIdx, greaterThanOrEqualTo(0));
      // 9.0a regression guard: scope_type must appear in the INSERT
      // column list AND values clause AND parameter map.
      final insertSql = tx.executedSql[insertIdx];
      expect(insertSql, contains('scope_type'));
      expect(insertSql, contains('@scope_type'));
      final insertParams = tx.parameters[insertIdx];
      expect(insertParams['scope_type'], equals('operator_wide'));
      // operator_wide grants must NOT bind a location_id.
      expect(insertParams['location_id'], isNull);
      expect(insertParams['org_unit_id'], isNull);
      expect(
        tx.executedSql.last,
        equals(
          'update users '
          'set roles_version = roles_version + 1 '
          'where user_id = @user_id::uuid',
        ),
      );
    });

    test('insertGrant location scope binds scope_type=location AND the '
        'grantLocationId', () async {
      final pool = _RoleAdminPool(returningUserRoleId: _validUserRoleId);
      final repo = UserRolesRepository(TenantTransactionWrapper(pool));
      const String grantLoc = '88888888-8888-8888-8888-888888888888';
      final id = await repo.insertGrant(
        operatorId: _validOpId,
        locationId: _validLocId,
        actorUserId: _validUserId,
        targetUserId: '99999999-9999-9999-9999-999999999999',
        roleId: _validRoleId,
        scopeType: UserRoleScope.location,
        grantLocationId: grantLoc,
      );
      expect(id, equals(_validUserRoleId));
      final tx = pool.transactions.single;
      final insertIdx = tx.executedSql.indexWhere(
        (sql) => sql.contains('insert into user_roles'),
      );
      final insertParams = tx.parameters[insertIdx];
      expect(insertParams['scope_type'], equals('location'));
      expect(insertParams['location_id'], equals(grantLoc));
      expect(insertParams['org_unit_id'], isNull);
    });

    test('insertGrant org_unit scope binds scope_type=org_unit AND the '
        'grantOrgUnitId', () async {
      final pool = _RoleAdminPool(returningUserRoleId: _validUserRoleId);
      final repo = UserRolesRepository(TenantTransactionWrapper(pool));
      const String grantOrgUnit = '77777777-7777-4777-8777-777777777777';
      final id = await repo.insertGrant(
        operatorId: _validOpId,
        locationId: _validLocId,
        actorUserId: _validUserId,
        targetUserId: '99999999-9999-9999-9999-999999999999',
        roleId: _validRoleId,
        scopeType: UserRoleScope.orgUnit,
        grantOrgUnitId: grantOrgUnit,
      );
      expect(id, equals(_validUserRoleId));
      final tx = pool.transactions.single;
      final insertIdx = tx.executedSql.indexWhere(
        (sql) => sql.contains('insert into user_roles'),
      );
      final insertParams = tx.parameters[insertIdx];
      expect(insertParams['scope_type'], equals('org_unit'));
      expect(insertParams['location_id'], isNull);
      expect(insertParams['org_unit_id'], equals(grantOrgUnit));
    });

    test('insertGrant location scope without grantLocationId throws '
        'ArgumentError synchronously before any SQL runs', () {
      final pool = _RoleAdminPool(returningUserRoleId: _validUserRoleId);
      final repo = UserRolesRepository(TenantTransactionWrapper(pool));
      // Closure form: the throw is intentionally synchronous so the
      // proxy never opens a transaction it then has to roll back.
      expect(
        () => repo.insertGrant(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
          targetUserId: '99999999-9999-9999-9999-999999999999',
          roleId: _validRoleId,
          scopeType: UserRoleScope.location,
          // grantLocationId omitted → mismatch.
        ),
        throwsArgumentError,
      );
      // No transaction was opened; the validation runs before
      // withTenant().
      expect(pool.transactions, isEmpty);
    });

    test('insertGrant org_unit scope without grantOrgUnitId throws '
        'ArgumentError synchronously before any SQL runs', () {
      final pool = _RoleAdminPool(returningUserRoleId: _validUserRoleId);
      final repo = UserRolesRepository(TenantTransactionWrapper(pool));
      expect(
        () => repo.insertGrant(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
          targetUserId: '99999999-9999-9999-9999-999999999999',
          roleId: _validRoleId,
          scopeType: UserRoleScope.orgUnit,
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });

    test('insertGrant operator_wide WITH grantLocationId throws '
        'ArgumentError synchronously before any SQL runs', () {
      final pool = _RoleAdminPool(returningUserRoleId: _validUserRoleId);
      final repo = UserRolesRepository(TenantTransactionWrapper(pool));
      expect(
        () => repo.insertGrant(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
          targetUserId: '99999999-9999-9999-9999-999999999999',
          roleId: _validRoleId,
          scopeType: UserRoleScope.operatorWide,
          grantLocationId: '88888888-8888-8888-8888-888888888888',
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });

    test('UserRoleScope.fromGrantLocationId derives operator_wide from null '
        'and location from a non-empty id', () {
      expect(
        UserRoleScope.fromGrantLocationId(null),
        equals(UserRoleScope.operatorWide),
      );
      expect(
        UserRoleScope.fromGrantLocationId(''),
        equals(UserRoleScope.operatorWide),
      );
      expect(
        UserRoleScope.fromGrantLocationId(_validLocId),
        equals(UserRoleScope.location),
      );
    });

    test(
      'revokeGrant bumps roles_version only when a row was affected',
      () async {
        final pool = _RoleAdminPool(
          returningUserRoleId: _validUserRoleId,
          revokeAffectedRows: 0,
        );
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        await repo.revokeGrant(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
          userRoleId: _validUserRoleId,
          targetUserId: '99999999-9999-9999-9999-999999999999',
        );
        final tx = pool.transactions.single;
        // UPDATE user_roles ran but UPDATE users.roles_version did NOT.
        expect(
          tx.executedSql.any((sql) => sql.contains('update user_roles')),
          isTrue,
        );
        expect(
          tx.executedSql.any((sql) => sql.contains('roles_version + 1')),
          isFalse,
        );
      },
    );

    test(
      'revokeGrant DOES bump roles_version when a row was affected',
      () async {
        final pool = _RoleAdminPool(
          returningUserRoleId: _validUserRoleId,
          revokeAffectedRows: 1,
        );
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        await repo.revokeGrant(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
          userRoleId: _validUserRoleId,
          targetUserId: '99999999-9999-9999-9999-999999999999',
        );
        expect(
          pool.transactions.single.executedSql.any(
            (sql) => sql.contains('roles_version + 1'),
          ),
          isTrue,
        );
      },
    );

    test('activeGrantsForUser filters by revoked_at + valid_until + '
        'valid_from', () async {
      final pool = _RoleAdminPool(
        userRoleRows: <PostgresRow>[
          <String, Object?>{
            'user_role_id': _validUserRoleId,
            'user_id': _validUserId,
            'role_id': _validRoleId,
            'operator_id': _validOpId,
            'location_id': null,
            'valid_from': DateTime.utc(2026, 4, 1),
            'valid_until': null,
            'granted_by': _validUserId,
            'revoked_at': null,
            'revoked_by': null,
            'reason': null,
            'created_at': DateTime.utc(2026, 4, 1),
            'updated_at': DateTime.utc(2026, 4, 1),
          },
        ],
      );
      final repo = UserRolesRepository(TenantTransactionWrapper(pool));
      final grants = await repo.activeGrantsForUser(
        operatorId: _validOpId,
        locationId: _validLocId,
        targetUserId: _validUserId,
      );
      expect(grants, hasLength(1));
      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains('revoked_at is null'));
      expect(sql, contains('valid_until is null or valid_until > now()'));
      expect(sql, contains('valid_from <= now()'));
    });

    test(
      'bumpActiveGrantHoldersForRole bumps users via active role grants',
      () async {
        final pool = _RoleAdminPool();
        final repo = UserRolesRepository(TenantTransactionWrapper(pool));
        await repo.bumpActiveGrantHoldersForRole(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
          roleId: _validRoleId,
        );
        final tx = pool.transactions.single;
        final sql = tx.executedSql.last;
        expect(sql, contains('update users'));
        expect(sql, contains('roles_version = roles_version + 1'));
        expect(sql, contains('exists ('));
        expect(sql, contains('user_roles.role_id = @role_id::uuid'));
      },
    );
  });

  group('ProxyAdminPermissionGuard (B19)', () {
    final fixedNow = DateTime.utc(2026, 4, 26, 12);
    final freshAt = fixedNow.subtract(const Duration(minutes: 1));
    final staleAt = fixedNow.subtract(const Duration(minutes: 10));

    test(
      'ScaffoldFailingProxyAdminPermissionGuard throws on every call',
      () async {
        const guard = ScaffoldFailingProxyAdminPermissionGuard();
        await expectLater(
          guard.evaluate(
            ProxyAdminGuardContext(
              actorUserId: _validUserId,
              operatorId: _validOpId,
              locationId: _validLocId,
              lastFreshAuthAt: freshAt,
              requestedPermissionKey: 'team.users.view',
            ),
          ),
          throwsStateError,
        );
      },
    );

    test('default deny when no entry exists for (user, key)', () async {
      final guard = InMemoryProxyAdminPermissionGuard(
        permissionEffects: const <String, PermissionEffect>{},
        now: () => fixedNow,
      );
      final decision = await guard.evaluate(
        ProxyAdminGuardContext(
          actorUserId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          lastFreshAuthAt: freshAt,
          requestedPermissionKey: 'team.users.view',
        ),
      );
      expect(decision, isA<ProxyAdminDeniedDefault>());
    });

    test('explicit deny entry returns ProxyAdminDeniedExplicit', () async {
      final guard = InMemoryProxyAdminPermissionGuard(
        permissionEffects: <String, PermissionEffect>{
          '$_validUserId|team.users.view': PermissionEffect.deny,
        },
        now: () => fixedNow,
      );
      final decision = await guard.evaluate(
        ProxyAdminGuardContext(
          actorUserId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          lastFreshAuthAt: freshAt,
          requestedPermissionKey: 'team.users.view',
        ),
      );
      expect(decision, isA<ProxyAdminDeniedExplicit>());
    });

    test('allow entry returns Allowed when MFA + reCAPTCHA pass', () async {
      final guard = InMemoryProxyAdminPermissionGuard(
        permissionEffects: <String, PermissionEffect>{
          '$_validUserId|team.users.invite': PermissionEffect.allow,
        },
        requiresMfaKeys: const <String>{'team.users.invite'},
        now: () => fixedNow,
      );
      final decision = await guard.evaluate(
        ProxyAdminGuardContext(
          actorUserId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          lastFreshAuthAt: freshAt,
          requestedPermissionKey: 'team.users.invite',
        ),
      );
      expect(decision, isA<ProxyAdminAllowed>());
    });

    test('MFA-required key + stale auth -> ProxyAdminMfaStaleAuth', () async {
      final guard = InMemoryProxyAdminPermissionGuard(
        permissionEffects: <String, PermissionEffect>{
          '$_validUserId|team.users.invite': PermissionEffect.allow,
        },
        requiresMfaKeys: const <String>{'team.users.invite'},
        now: () => fixedNow,
      );
      final decision = await guard.evaluate(
        ProxyAdminGuardContext(
          actorUserId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          lastFreshAuthAt: staleAt,
          requestedPermissionKey: 'team.users.invite',
        ),
      );
      expect(decision, isA<ProxyAdminMfaStaleAuth>());
    });

    test(
      'reCAPTCHA-protected key + reject outcome -> ProxyAdminRejected',
      () async {
        final guard = InMemoryProxyAdminPermissionGuard(
          permissionEffects: <String, PermissionEffect>{
            '$_validUserId|team.users.view': PermissionEffect.allow,
          },
          recaptchaProtectedKeys: const <String>{'team.users.view'},
          now: () => fixedNow,
        );
        final decision = await guard.evaluate(
          ProxyAdminGuardContext(
            actorUserId: _validUserId,
            operatorId: _validOpId,
            locationId: _validLocId,
            lastFreshAuthAt: freshAt,
            requestedPermissionKey: 'team.users.view',
            recaptchaOutcome: ProxyAdminGuardRecaptcha.reject,
          ),
        );
        expect(decision, isA<ProxyAdminRejected>());
      },
    );

    test('reCAPTCHA-protected key + challenge outcome -> '
        'ProxyAdminChallengeRequired', () async {
      final guard = InMemoryProxyAdminPermissionGuard(
        permissionEffects: <String, PermissionEffect>{
          '$_validUserId|team.users.view': PermissionEffect.allow,
        },
        recaptchaProtectedKeys: const <String>{'team.users.view'},
        now: () => fixedNow,
      );
      final decision = await guard.evaluate(
        ProxyAdminGuardContext(
          actorUserId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          lastFreshAuthAt: freshAt,
          requestedPermissionKey: 'team.users.view',
          recaptchaOutcome: ProxyAdminGuardRecaptcha.challenge,
        ),
      );
      expect(decision, isA<ProxyAdminChallengeRequired>());
    });

    test('reCAPTCHA-protected key + missing outcome -> ProxyAdminRejected '
        '(fail-closed)', () async {
      final guard = InMemoryProxyAdminPermissionGuard(
        permissionEffects: <String, PermissionEffect>{
          '$_validUserId|team.users.view': PermissionEffect.allow,
        },
        recaptchaProtectedKeys: const <String>{'team.users.view'},
        now: () => fixedNow,
      );
      final decision = await guard.evaluate(
        ProxyAdminGuardContext(
          actorUserId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          lastFreshAuthAt: freshAt,
          requestedPermissionKey: 'team.users.view',
        ),
      );
      expect(decision, isA<ProxyAdminRejected>());
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────

class _RoleAdminPool implements PostgresPool {
  _RoleAdminPool({
    this.returningRoleId,
    this.returningUserRoleId,
    this.roleRows = const <PostgresRow>[],
    this.userRoleRows = const <PostgresRow>[],
    this.activeGrantRowsForRole = const <PostgresRow>[],
    this.revokeAffectedRows = 1,
  });

  final String? returningRoleId;
  final String? returningUserRoleId;
  final List<PostgresRow> roleRows;
  final List<PostgresRow> userRoleRows;
  final List<PostgresRow> activeGrantRowsForRole;
  final int revokeAffectedRows;

  final List<_RoleAdminTransaction> transactions = <_RoleAdminTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RoleAdminTransaction(
      returningRoleId: returningRoleId,
      returningUserRoleId: returningUserRoleId,
      roleRows: roleRows,
      userRoleRows: userRoleRows,
      activeGrantRowsForRole: activeGrantRowsForRole,
      revokeAffectedRows: revokeAffectedRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _RoleAdminTransaction extends PostgresTransaction {
  _RoleAdminTransaction({
    required this.returningRoleId,
    required this.returningUserRoleId,
    required this.roleRows,
    required this.userRoleRows,
    required this.activeGrantRowsForRole,
    required this.revokeAffectedRows,
  });

  final String? returningRoleId;
  final String? returningUserRoleId;
  final List<PostgresRow> roleRows;
  final List<PostgresRow> userRoleRows;
  final List<PostgresRow> activeGrantRowsForRole;
  final int revokeAffectedRows;
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
    if (sql.contains('insert into roles') &&
        sql.contains('returning role_id')) {
      final id = returningRoleId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'role_id': id},
      ];
    }
    if (sql.contains('insert into user_roles') &&
        sql.contains('returning user_role_id')) {
      final id = returningUserRoleId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'user_role_id': id},
      ];
    }
    if (sql.contains('select 1 from user_roles')) {
      return activeGrantRowsForRole;
    }
    if (sql.contains('from roles')) {
      return roleRows;
    }
    if (sql.contains('from user_roles')) {
      return userRoleRows;
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
    if (sql.contains('update user_roles') &&
        sql.contains('revoked_at = now()')) {
      return revokeAffectedRows;
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
