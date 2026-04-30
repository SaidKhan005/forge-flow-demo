// Phase 9.UX.4 — focused live-binding tests for the OrgUnitsRepository
// hierarchy helpers used by the Settings → Team → Org Hierarchy
// surface.
//
// Mirrors the `role_admin_live_binding_test.dart` pattern: a fake
// `PostgresPool` records executed SQL + parameters so the repository's
// SQL contract is verified without a live database. RLS is the backup
// safety net — these tests only verify the tenant-scoped repo writes
// the expected statements with `(operator_id, location_id)` injected
// via SET LOCAL inside `runInTenantContext`.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/org_units_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/role_permissions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/repository_auth_operations_gateway.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validParentId = '44444444-4444-4444-4444-444444444444';
const String _validTargetLocationId = '55555555-5555-5555-5555-555555555555';

void main() {
  group('OrgUnitsRepository.listLocationsForTenant', () {
    test('selects every visible location ordered by org_unit_path', () async {
      final pool = _OrgUnitsPool(
        locationRows: <PostgresRow>[
          <String, Object?>{
            'location_id': _validTargetLocationId,
            'operator_id': _validOpId,
            'parent_org_unit_id': _validParentId,
            'org_unit_path': 'acme.east',
            'name': 'Downtown',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final rows = await repo.listLocationsForTenant(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
      );
      expect(rows, hasLength(1));
      expect(rows.single.parentOrgUnitId, equals(_validParentId));
      expect(rows.single.orgUnitPath, equals('acme.east'));
      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains('from locations'));
      expect(sql, contains('order by org_unit_path'));
    });
  });

  group('RepositoryAuthOperationsGateway target-scope check (P1 fix)', () {
    test(
      'createOrgUnit refuses location-scoped actor with target_scope_required',
      () async {
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            // Actor holds ONLY a location-scoped grant — no
            // operator-wide grant. The Phase 9 manager contract
            // forbids this actor from mutating the operator
            // hierarchy, even when their role permission table
            // includes `team.roles.assign`.
            <String, Object?>{
              'user_role_id': '99999999-9999-9999-9999-999999999999',
              'user_id': _validUserId,
              'role_id': '88888888-8888-8888-8888-888888888888',
              'operator_id': _validOpId,
              'scope_type': 'location',
              'location_id': _validLocId,
              'org_unit_id': null,
              'effective_location_ids': <String>[_validLocId],
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
        final gateway = _gatewayWithPool(pool);

        AuthOperationRejected? captured;
        try {
          await gateway.createOrgUnit(
            const TeamOrgUnitCreateCommand(
              actorUserId: _validUserId,
              operatorId: _validOpId,
              locationId: _validLocId,
              parentOrgUnitId: _validParentId,
              unitType: 'region',
              label: 'east',
              name: 'East',
            ),
          );
        } on AuthOperationRejected catch (error) {
          captured = error;
        }

        expect(captured, isNotNull);
        expect(captured!.code, equals('target_scope_required'));
        expect(captured.statusCode, equals(403));
        // The repository INSERT must never run when the gate refuses.
        final txs = pool.transactions;
        expect(
          txs.any(
            (tx) => tx.executedSql.any(
              (sql) => sql.contains('insert into org_units'),
            ),
          ),
          isFalse,
        );
      },
    );

    test(
      'moveLocationToOrgUnit refuses location-scoped actor',
      () async {
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': '99999999-9999-9999-9999-999999999999',
              'user_id': _validUserId,
              'role_id': '88888888-8888-8888-8888-888888888888',
              'operator_id': _validOpId,
              'scope_type': 'location',
              'location_id': _validLocId,
              'org_unit_id': null,
              'effective_location_ids': <String>[_validLocId],
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
        final gateway = _gatewayWithPool(pool);

        AuthOperationRejected? captured;
        try {
          await gateway.moveLocationToOrgUnit(
            const TeamLocationOrgUnitMoveCommand(
              actorUserId: _validUserId,
              operatorId: _validOpId,
              locationId: _validLocId,
              targetLocationId: _validTargetLocationId,
              parentOrgUnitId: _validParentId,
            ),
          );
        } on AuthOperationRejected catch (error) {
          captured = error;
        }

        expect(captured, isNotNull);
        expect(captured!.code, equals('target_scope_required'));
        // No UPDATE on locations should have run.
        expect(
          pool.transactions.any(
            (tx) => tx.executedSql.any(
              (sql) => sql.contains('update locations'),
            ),
          ),
          isFalse,
        );
      },
    );

    test(
      'createOrgUnit allows operator-wide actor whose role carries '
      'team.roles.assign',
      () async {
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': '99999999-9999-9999-9999-999999999999',
              'user_id': _validUserId,
              'role_id': '88888888-8888-8888-8888-888888888888',
              'operator_id': _validOpId,
              'scope_type': 'operator_wide',
              'location_id': null,
              'org_unit_id': null,
              'effective_location_ids': const <String>[],
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
          rolePermissionsByRole: <String, List<PostgresRow>>{
            '88888888-8888-8888-8888-888888888888': <PostgresRow>[
              <String, Object?>{
                'role_id': '88888888-8888-8888-8888-888888888888',
                'permission_key': 'team.roles.assign',
                'effect': 'allow',
                'created_at': DateTime.utc(2026, 4, 1),
                'updated_at': DateTime.utc(2026, 4, 1),
              },
            ],
          },
          parentRows: <PostgresRow>[
            <String, Object?>{'path': 'acme', 'depth': 1},
          ],
          createChildId: '77777777-7777-7777-7777-777777777777',
        );
        final gateway = _gatewayWithPool(pool);

        final result = await gateway.createOrgUnit(
          const TeamOrgUnitCreateCommand(
            actorUserId: _validUserId,
            operatorId: _validOpId,
            locationId: _validLocId,
            parentOrgUnitId: _validParentId,
            unitType: 'region',
            label: 'east',
            name: 'East',
          ),
        );

        expect(result.orgUnitId, equals('77777777-7777-7777-7777-777777777777'));
      },
    );

    test(
      'createOrgUnit refuses mixed-scope actor whose operator-wide role '
      'lacks team.roles.assign',
      () async {
        // Mixed-scope: operator-wide STAFF (no `team.roles.assign`) +
        // location-scoped MANAGER (has `team.roles.assign`). The proxy
        // permission gate would pass because the manager role allows
        // the key, but the hierarchy gate must fail because no
        // operator-wide role carries the permission.
        const operatorWideRoleId = 'a1111111-1111-4111-8111-111111111111';
        const managerRoleId = 'b2222222-2222-4222-8222-222222222222';
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': '99999999-9999-9999-9999-999999999999',
              'user_id': _validUserId,
              'role_id': operatorWideRoleId,
              'operator_id': _validOpId,
              'scope_type': 'operator_wide',
              'location_id': null,
              'org_unit_id': null,
              'effective_location_ids': const <String>[],
              'valid_from': DateTime.utc(2026, 4, 1),
              'valid_until': null,
              'granted_by': _validUserId,
              'revoked_at': null,
              'revoked_by': null,
              'reason': null,
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'user_role_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'user_id': _validUserId,
              'role_id': managerRoleId,
              'operator_id': _validOpId,
              'scope_type': 'location',
              'location_id': _validLocId,
              'org_unit_id': null,
              'effective_location_ids': <String>[_validLocId],
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
          rolePermissionsByRole: <String, List<PostgresRow>>{
            // Operator-wide staff role: no `team.roles.assign`.
            operatorWideRoleId: const <PostgresRow>[],
            // Location-scoped manager role: HAS `team.roles.assign`,
            // but it must not satisfy the operator-wide gate.
            managerRoleId: <PostgresRow>[
              <String, Object?>{
                'role_id': managerRoleId,
                'permission_key': 'team.roles.assign',
                'effect': 'allow',
                'created_at': DateTime.utc(2026, 4, 1),
                'updated_at': DateTime.utc(2026, 4, 1),
              },
            ],
          },
        );
        final gateway = _gatewayWithPool(pool);

        AuthOperationRejected? captured;
        try {
          await gateway.createOrgUnit(
            const TeamOrgUnitCreateCommand(
              actorUserId: _validUserId,
              operatorId: _validOpId,
              locationId: _validLocId,
              parentOrgUnitId: _validParentId,
              unitType: 'region',
              label: 'east',
              name: 'East',
            ),
          );
        } on AuthOperationRejected catch (error) {
          captured = error;
        }

        expect(captured, isNotNull);
        expect(captured!.code, equals('target_scope_required'));
        expect(captured.message, contains('team.roles.assign'));
      },
    );

    test(
      'createInvite refuses location-scoped actor for org-unit scope',
      () async {
        // Location-scoped manager with `team.users.invite` on their
        // role tries to create an org-unit-scoped invite. The new
        // gate must reject before the firebase / postgres write.
        const managerRoleId = 'b2222222-2222-4222-8222-222222222222';
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'user_id': _validUserId,
              'role_id': managerRoleId,
              'operator_id': _validOpId,
              'scope_type': 'location',
              'location_id': _validLocId,
              'org_unit_id': null,
              'effective_location_ids': <String>[_validLocId],
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
          rolePermissionsByRole: <String, List<PostgresRow>>{
            managerRoleId: <PostgresRow>[
              <String, Object?>{
                'role_id': managerRoleId,
                'permission_key': 'team.users.invite',
                'effect': 'allow',
                'created_at': DateTime.utc(2026, 4, 1),
                'updated_at': DateTime.utc(2026, 4, 1),
              },
            ],
          },
        );
        final gateway = _gatewayWithPool(pool);

        AuthOperationRejected? captured;
        try {
          await gateway.createInvite(
            const TeamInviteCreateCommand(
              actorUserId: _validUserId,
              operatorId: _validOpId,
              locationId: _validLocId,
              email: 'regional@example.test',
              roleId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              scopeType: 'org_unit',
              targetOrgUnitId: _validParentId,
            ),
          );
        } on AuthOperationRejected catch (error) {
          captured = error;
        }

        expect(captured, isNotNull);
        expect(captured!.code, equals('target_scope_required'));
        // Firebase + Postgres invite writes must not have run. The
        // fake firebase client is the scaffold-failing one — if the
        // gate had passed we'd hit it and see a different error.
        // `target_scope_required` proves we short-circuited before
        // any external write.
      },
    );

    test(
      'createInvite for org-unit scope refuses mixed-scope actor whose '
      'operator-wide role lacks team.users.invite',
      () async {
        // Mixed-scope: operator-wide STAFF (no `team.users.invite`) +
        // location-scoped MANAGER (has `team.users.invite`). Without
        // the per-permission gate the actor would fall into the
        // "any operator-wide grant" path and be allowed to broaden
        // invite scope past their assigned location.
        const operatorWideRoleId = 'a1111111-1111-4111-8111-111111111111';
        const managerRoleId = 'b2222222-2222-4222-8222-222222222222';
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': '99999999-9999-9999-9999-999999999999',
              'user_id': _validUserId,
              'role_id': operatorWideRoleId,
              'operator_id': _validOpId,
              'scope_type': 'operator_wide',
              'location_id': null,
              'org_unit_id': null,
              'effective_location_ids': const <String>[],
              'valid_from': DateTime.utc(2026, 4, 1),
              'valid_until': null,
              'granted_by': _validUserId,
              'revoked_at': null,
              'revoked_by': null,
              'reason': null,
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'user_role_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'user_id': _validUserId,
              'role_id': managerRoleId,
              'operator_id': _validOpId,
              'scope_type': 'location',
              'location_id': _validLocId,
              'org_unit_id': null,
              'effective_location_ids': <String>[_validLocId],
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
          rolePermissionsByRole: <String, List<PostgresRow>>{
            operatorWideRoleId: const <PostgresRow>[],
            managerRoleId: <PostgresRow>[
              <String, Object?>{
                'role_id': managerRoleId,
                'permission_key': 'team.users.invite',
                'effect': 'allow',
                'created_at': DateTime.utc(2026, 4, 1),
                'updated_at': DateTime.utc(2026, 4, 1),
              },
            ],
          },
        );
        final gateway = _gatewayWithPool(pool);

        AuthOperationRejected? captured;
        try {
          await gateway.createInvite(
            const TeamInviteCreateCommand(
              actorUserId: _validUserId,
              operatorId: _validOpId,
              locationId: _validLocId,
              email: 'regional@example.test',
              roleId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              scopeType: 'org_unit',
              targetOrgUnitId: _validParentId,
            ),
          );
        } on AuthOperationRejected catch (error) {
          captured = error;
        }

        expect(captured, isNotNull);
        expect(captured!.code, equals('target_scope_required'));
        expect(captured.message, contains('team.users.invite'));
      },
    );

    test(
      'listOrgHierarchy still filters when actor has a weak operator-wide '
      'role plus a stronger location-scoped role',
      () async {
        // Mixed-scope: operator-wide STAFF (no `team.users.view`) +
        // location-scoped MANAGER (has `team.users.view`). The proxy
        // permission gate passes because the manager role allows the
        // key, but the listing must NOT show the full tree — only
        // the assigned location's branch.
        const operatorWideRoleId = 'a1111111-1111-4111-8111-111111111111';
        const managerRoleId = 'b2222222-2222-4222-8222-222222222222';
        const eastUnitId = 'd0000001-0000-4000-8000-000000000001';
        const westUnitId = 'd0000002-0000-4000-8000-000000000002';
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': '99999999-9999-9999-9999-999999999999',
              'user_id': _validUserId,
              'role_id': operatorWideRoleId,
              'operator_id': _validOpId,
              'scope_type': 'operator_wide',
              'location_id': null,
              'org_unit_id': null,
              'effective_location_ids': const <String>[],
              'valid_from': DateTime.utc(2026, 4, 1),
              'valid_until': null,
              'granted_by': _validUserId,
              'revoked_at': null,
              'revoked_by': null,
              'reason': null,
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'user_role_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'user_id': _validUserId,
              'role_id': managerRoleId,
              'operator_id': _validOpId,
              'scope_type': 'location',
              'location_id': _validLocId,
              'org_unit_id': null,
              'effective_location_ids': <String>[_validLocId],
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
          rolePermissionsByRole: <String, List<PostgresRow>>{
            // Operator-wide staff role does NOT carry team.users.view.
            operatorWideRoleId: const <PostgresRow>[],
            // Location-scoped manager role HAS team.users.view, but
            // it must not unlock the full tree.
            managerRoleId: <PostgresRow>[
              <String, Object?>{
                'role_id': managerRoleId,
                'permission_key': 'team.users.view',
                'effect': 'allow',
                'created_at': DateTime.utc(2026, 4, 1),
                'updated_at': DateTime.utc(2026, 4, 1),
              },
            ],
          },
          orgUnitRows: <PostgresRow>[
            <String, Object?>{
              'id': 'd0000000-0000-4000-8000-000000000000',
              'operator_id': _validOpId,
              'parent_id': null,
              'unit_type': 'corp',
              'path': 'acme',
              'name': 'ACME',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'id': eastUnitId,
              'operator_id': _validOpId,
              'parent_id': 'd0000000-0000-4000-8000-000000000000',
              'unit_type': 'region',
              'path': 'acme.east',
              'name': 'East',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'id': westUnitId,
              'operator_id': _validOpId,
              'parent_id': 'd0000000-0000-4000-8000-000000000000',
              'unit_type': 'region',
              'path': 'acme.west',
              'name': 'West',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
          ],
          locationRows: <PostgresRow>[
            <String, Object?>{
              'location_id': _validLocId,
              'operator_id': _validOpId,
              'parent_org_unit_id': eastUnitId,
              'org_unit_path': 'acme.east',
              'name': 'Downtown',
            },
            <String, Object?>{
              'location_id': _validTargetLocationId,
              'operator_id': _validOpId,
              'parent_org_unit_id': westUnitId,
              'org_unit_path': 'acme.west',
              'name': 'Plaza',
            },
          ],
        );
        final gateway = _gatewayWithPool(pool);

        final listed = await gateway.listOrgHierarchy(
          const TeamOrgHierarchyListCommand(
            actorUserId: _validUserId,
            operatorId: _validOpId,
            locationId: _validLocId,
          ),
        );

        // Filtered result: only the East branch + downtown location.
        final unitPaths = listed.orgUnits.map((u) => u.path).toSet();
        final locationIds = listed.locations.map((l) => l.locationId).toSet();
        expect(unitPaths, equals(<String>{'acme', 'acme.east'}));
        expect(locationIds, equals(<String>{_validLocId}));
      },
    );

    test(
      'listOrgHierarchy returns the full tree for an operator-wide actor '
      'whose role carries team.users.view',
      () async {
        const ownerRoleId = 'c3333333-3333-4333-8333-333333333333';
        const eastUnitId = 'd0000001-0000-4000-8000-000000000001';
        const westUnitId = 'd0000002-0000-4000-8000-000000000002';
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': '99999999-9999-9999-9999-999999999999',
              'user_id': _validUserId,
              'role_id': ownerRoleId,
              'operator_id': _validOpId,
              'scope_type': 'operator_wide',
              'location_id': null,
              'org_unit_id': null,
              'effective_location_ids': const <String>[],
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
          rolePermissionsByRole: <String, List<PostgresRow>>{
            ownerRoleId: <PostgresRow>[
              <String, Object?>{
                'role_id': ownerRoleId,
                'permission_key': 'team.users.view',
                'effect': 'allow',
                'created_at': DateTime.utc(2026, 4, 1),
                'updated_at': DateTime.utc(2026, 4, 1),
              },
            ],
          },
          orgUnitRows: <PostgresRow>[
            <String, Object?>{
              'id': 'd0000000-0000-4000-8000-000000000000',
              'operator_id': _validOpId,
              'parent_id': null,
              'unit_type': 'corp',
              'path': 'acme',
              'name': 'ACME',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'id': eastUnitId,
              'operator_id': _validOpId,
              'parent_id': 'd0000000-0000-4000-8000-000000000000',
              'unit_type': 'region',
              'path': 'acme.east',
              'name': 'East',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'id': westUnitId,
              'operator_id': _validOpId,
              'parent_id': 'd0000000-0000-4000-8000-000000000000',
              'unit_type': 'region',
              'path': 'acme.west',
              'name': 'West',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
          ],
          locationRows: <PostgresRow>[
            <String, Object?>{
              'location_id': _validLocId,
              'operator_id': _validOpId,
              'parent_org_unit_id': eastUnitId,
              'org_unit_path': 'acme.east',
              'name': 'Downtown',
            },
            <String, Object?>{
              'location_id': _validTargetLocationId,
              'operator_id': _validOpId,
              'parent_org_unit_id': westUnitId,
              'org_unit_path': 'acme.west',
              'name': 'Plaza',
            },
          ],
        );
        final gateway = _gatewayWithPool(pool);

        final listed = await gateway.listOrgHierarchy(
          const TeamOrgHierarchyListCommand(
            actorUserId: _validUserId,
            operatorId: _validOpId,
            locationId: _validLocId,
          ),
        );

        final unitPaths = listed.orgUnits.map((u) => u.path).toSet();
        final locationIds = listed.locations.map((l) => l.locationId).toSet();
        expect(
          unitPaths,
          equals(<String>{'acme', 'acme.east', 'acme.west'}),
        );
        expect(
          locationIds,
          equals(<String>{_validLocId, _validTargetLocationId}),
        );
      },
    );

    test(
      'listOrgHierarchy filters down to assigned locations and ancestor units '
      'for a location-scoped manager',
      () async {
        // Tree:
        //   root  acme           (path: acme)
        //   ├── east             (path: acme.east)
        //   │   ├── downtown loc (location_id: _validLocId, path: acme.east)
        //   └── west             (path: acme.west)
        //       └── plaza loc    (location_id: _validTargetLocationId,
        //                         path: acme.west)
        //
        // Manager has `effective_location_ids = [_validLocId]`, so they
        // should see `acme` + `acme.east` and the downtown location,
        // but NOT `acme.west` or the plaza location.
        const managerRoleId = 'b2222222-2222-4222-8222-222222222222';
        const eastUnitId = 'd0000001-0000-4000-8000-000000000001';
        const westUnitId = 'd0000002-0000-4000-8000-000000000002';
        final pool = _OrgUnitsPool(
          userRoleRows: <PostgresRow>[
            <String, Object?>{
              'user_role_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'user_id': _validUserId,
              'role_id': managerRoleId,
              'operator_id': _validOpId,
              'scope_type': 'location',
              'location_id': _validLocId,
              'org_unit_id': null,
              'effective_location_ids': <String>[_validLocId],
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
          orgUnitRows: <PostgresRow>[
            <String, Object?>{
              'id': 'd0000000-0000-4000-8000-000000000000',
              'operator_id': _validOpId,
              'parent_id': null,
              'unit_type': 'corp',
              'path': 'acme',
              'name': 'ACME',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'id': eastUnitId,
              'operator_id': _validOpId,
              'parent_id': 'd0000000-0000-4000-8000-000000000000',
              'unit_type': 'region',
              'path': 'acme.east',
              'name': 'East',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
            <String, Object?>{
              'id': westUnitId,
              'operator_id': _validOpId,
              'parent_id': 'd0000000-0000-4000-8000-000000000000',
              'unit_type': 'region',
              'path': 'acme.west',
              'name': 'West',
              'created_at': DateTime.utc(2026, 4, 1),
              'updated_at': DateTime.utc(2026, 4, 1),
            },
          ],
          locationRows: <PostgresRow>[
            <String, Object?>{
              'location_id': _validLocId,
              'operator_id': _validOpId,
              'parent_org_unit_id': eastUnitId,
              'org_unit_path': 'acme.east',
              'name': 'Downtown',
            },
            <String, Object?>{
              'location_id': _validTargetLocationId,
              'operator_id': _validOpId,
              'parent_org_unit_id': westUnitId,
              'org_unit_path': 'acme.west',
              'name': 'Plaza',
            },
          ],
        );
        final gateway = _gatewayWithPool(pool);

        final listed = await gateway.listOrgHierarchy(
          const TeamOrgHierarchyListCommand(
            actorUserId: _validUserId,
            operatorId: _validOpId,
            locationId: _validLocId,
          ),
        );

        final unitPaths = listed.orgUnits.map((u) => u.path).toSet();
        final locationIds = listed.locations.map((l) => l.locationId).toSet();
        expect(unitPaths, equals(<String>{'acme', 'acme.east'}));
        expect(locationIds, equals(<String>{_validLocId}));
      },
    );
  });

  group('OrgUnitsRepository.moveLocationToOrgUnit', () {
    test(
      'updates `locations.parent_org_unit_id` and keeps grants org-unit-scoped',
      () async {
        final pool = _OrgUnitsPool(
          parentRows: <PostgresRow>[const <String, Object?>{}],
          updateAffectedRows: 1,
        );
        final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
        final affected = await repo.moveLocationToOrgUnit(
          operatorId: _validOpId,
          locationId: _validLocId,
          targetLocationId: _validTargetLocationId,
          parentOrgUnitId: _validParentId,
          userId: _validUserId,
        );
        expect(affected, equals(1));
        final tx = pool.transactions.single;
        // Pre-flight parent-visibility check must run inside the same
        // transaction so RLS / tenant SET LOCAL applies; updates that
        // pointed at a cross-tenant parent never reach the UPDATE.
        expect(
          tx.executedSql.any((sql) => sql.contains('select 1 from org_units')),
          isTrue,
        );
        final updateIdx = tx.executedSql.indexWhere(
          (sql) => sql.contains('update locations'),
        );
        expect(updateIdx >= 0, isTrue);
        final updateParams = tx.parameters[updateIdx];
        expect(updateParams['parent_id'], equals(_validParentId));
        expect(updateParams['location_id'], equals(_validTargetLocationId));
        // Repo MUST NOT touch user_roles — that table's
        // `org_unit_id` is set when the grant is created, not when
        // a location moves between units.
        expect(
          tx.executedSql.any((sql) => sql.contains('user_roles')),
          isFalse,
        );
      },
    );

    test('refuses when parent_org_unit_id is not visible to tenant', () async {
      final pool = _OrgUnitsPool(parentRows: const <PostgresRow>[]);
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.moveLocationToOrgUnit(
          operatorId: _validOpId,
          locationId: _validLocId,
          targetLocationId: _validTargetLocationId,
          parentOrgUnitId: _validParentId,
        ),
        throwsStateError,
      );
      // Pre-flight ran but the UPDATE never did.
      final tx = pool.transactions.single;
      expect(
        tx.executedSql.any((sql) => sql.contains('update locations')),
        isFalse,
      );
    });
  });
}

class _OrgUnitsPool implements PostgresPool {
  _OrgUnitsPool({
    this.locationRows = const <PostgresRow>[],
    this.parentRows = const <PostgresRow>[],
    this.userRoleRows = const <PostgresRow>[],
    this.rolePermissionsByRole = const <String, List<PostgresRow>>{},
    this.orgUnitRows = const <PostgresRow>[],
    this.updateAffectedRows = 1,
    this.createChildId,
  });

  final List<PostgresRow> locationRows;
  final List<PostgresRow> parentRows;
  final List<PostgresRow> userRoleRows;
  final Map<String, List<PostgresRow>> rolePermissionsByRole;
  final List<PostgresRow> orgUnitRows;
  final int updateAffectedRows;
  final String? createChildId;

  final List<_OrgUnitsTransaction> transactions = <_OrgUnitsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _OrgUnitsTransaction(
      locationRows: locationRows,
      parentRows: parentRows,
      userRoleRows: userRoleRows,
      rolePermissionsByRole: rolePermissionsByRole,
      orgUnitRows: orgUnitRows,
      updateAffectedRows: updateAffectedRows,
      createChildId: createChildId,
    );
    transactions.add(tx);
    return tx;
  }
}

RepositoryAuthOperationsGateway _gatewayWithPool(_OrgUnitsPool pool) {
  final wrapper = TenantTransactionWrapper(pool);
  return RepositoryAuthOperationsGateway(
    firebaseAdmin: const ScaffoldFailingFirebaseAdminAuthClient(),
    usersRepository: UsersRepository(wrapper),
    rolesRepository: RolesRepository(wrapper),
    rolePermissionsRepository: RolePermissionsRepository(wrapper),
    userRolesRepository: UserRolesRepository(wrapper),
    authInvitesRepository: AuthInvitesRepository(wrapper),
    auditRepository: AuthEventsAuditRepository(wrapper),
    orgUnitsRepository: OrgUnitsRepository(wrapper),
  );
}

class _OrgUnitsTransaction extends PostgresTransaction {
  _OrgUnitsTransaction({
    required this.locationRows,
    required this.parentRows,
    required this.userRoleRows,
    required this.rolePermissionsByRole,
    required this.orgUnitRows,
    required this.updateAffectedRows,
    required this.createChildId,
  });

  final List<PostgresRow> locationRows;
  final List<PostgresRow> parentRows;
  final List<PostgresRow> userRoleRows;
  final Map<String, List<PostgresRow>> rolePermissionsByRole;
  final List<PostgresRow> orgUnitRows;
  final int updateAffectedRows;
  final String? createChildId;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from locations')) return locationRows;
    if (sql.contains('select path::text as path, nlevel(path)')) {
      return parentRows;
    }
    if (sql.contains('select 1 from org_units')) return parentRows;
    if (sql.contains('insert into org_units') &&
        sql.contains('returning id')) {
      final id = createChildId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'id': id},
      ];
    }
    if (sql.contains('from org_units')) return orgUnitRows;
    if (sql.contains('from role_permissions')) {
      final roleId = parameters['role_id'] as String?;
      if (roleId == null) return <PostgresRow>[];
      return rolePermissionsByRole[roleId] ?? const <PostgresRow>[];
    }
    if (sql.contains('from user_roles')) return userRoleRows;
    if (sql.contains('insert into auth_events_audit')) {
      // Audit repo expects a returning row; the actual id is opaque
      // to the gateway tests, so a stable placeholder keeps the
      // happy-path assertions on the operator-wide branch unblocked.
      return <PostgresRow>[
        <String, Object?>{'event_id': 'fake-audit-1'},
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
    if (sql.contains('update locations')) return updateAffectedRows;
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
  }
}
