// Phase 11A.13 - Roles + Hierarchy + Sessions admin gateway tests.
//
// Three coverage groups, mirroring the 11A.12 Members gateway test
// shape:
//
//   * `InMemoryRolesHierarchySessionsAdminGateway` - exercises the
//     demo gateway's command/response shapes, the audit-row shape,
//     the forge_admin gate, the admin_reason gate, the idempotency
//     contract, and the cannot_revoke_self defence.
//
//   * Audit-action enum conformance to § "Audit-row shape" of the
//     parity contract: identical canonical fact rows across
//     self-service and admin paths, so the locked vocabulary stays
//     in the `team.*` / `admin.session.*` family.
//
//   * `HttpRolesHierarchySessionsAdminGateway` - pins the wire format
//     of the live gateway against a mocked `http.Client`: paths +
//     payload + idempotency-key header + bearer token + 403 mapping.
//
// Authority: docs/contracts/team_roles_hierarchy_console_parity_contract.md.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  group('InMemoryRolesHierarchySessionsAdminGateway list APIs', () {
    test(
      'listRoles returns seeded + custom roles for the picked operator',
      () async {
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          rolesByOperator: kDemoRolesByOperator(),
        );
        final dinerRoles = await gateway.listRoles(
          operatorId: kDemoDinerOperatorId,
        );
        final sunsetRoles = await gateway.listRoles(
          operatorId: kDemoSunsetOperatorId,
        );
        expect(dinerRoles.where((r) => r.isSeeded), isNotEmpty);
        expect(dinerRoles.where((r) => !r.isSeeded), isNotEmpty);
        const expectedSeededKeys = <String>{
          'operator_owner',
          'operator_general_manager',
          'location_manager',
          'supervisor',
          'finance_analyst',
          'auditor_compliance',
          'training_lead',
          'team_admin',
        };
        expect(
          dinerRoles.where((r) => r.isSeeded).map((r) => r.roleKey).toSet(),
          equals(expectedSeededKeys),
        );
        expect(
          sunsetRoles.map((r) => r.roleKey).toSet(),
          equals(expectedSeededKeys),
        );
        expect(
          sunsetRoles.every((r) => r.isSeeded),
          isTrue,
          reason: 'sunset demo seed has no custom roles',
        );
      },
    );

    test('listOrgUnits returns the operator-scoped tree', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      );
      final units = await gateway.listOrgUnits(
        operatorId: kDemoDinerOperatorId,
      );
      final roots = units.where((u) => u.parentOrgUnitId == null).toList();
      expect(roots, hasLength(1));
      expect(roots.single.name, equals('Demo Diner Co.'));
      final children = units.where((u) => u.parentOrgUnitId != null).toList();
      expect(
        children.map((u) => u.name).toSet(),
        equals(<String>{'East region', 'West region'}),
      );
    });

    test('listSessions returns one row per auth_sessions row', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        sessionsByOperator: kDemoSessionsByOperator(),
      );
      final sessions = await gateway.listSessions(
        operatorId: kDemoDinerOperatorId,
      );
      expect(sessions, hasLength(3));
      for (final s in sessions) {
        expect(s.userEmail, isNotEmpty);
        expect(s.deviceFingerprint, isNotEmpty);
        expect(s.ipGeoCity, isNotEmpty);
      }
    });
  });

  group('forge_admin + admin_reason gates', () {
    test(
      'every mutation throws Forbidden when actorIsForgeAdmin is false',
      () async {
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          rolesByOperator: kDemoRolesByOperator(),
          orgUnitsByOperator: kDemoOrgUnitsByOperator(),
          locationsByOperator: kDemoHierarchyLocationsByOperator(),
          sessionsByOperator: kDemoSessionsByOperator(),
        );
        await expectLater(
          gateway.editSeededRole(
            operatorId: kDemoDinerOperatorId,
            roleId: 'role-seed-operator-owner',
            permissionKeys: const <String>['team.users.view'],
            idempotencyKey: 'k1',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<RolesHierarchySessionsForbiddenException>()),
        );
        await expectLater(
          gateway.createCustomRole(
            operatorId: kDemoDinerOperatorId,
            roleKey: 'custom.test',
            displayName: 'T',
            description: '',
            permissionKeys: const <String>[],
            idempotencyKey: 'k2',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<RolesHierarchySessionsForbiddenException>()),
        );
        await expectLater(
          gateway.deleteCustomRole(
            operatorId: kDemoDinerOperatorId,
            roleId: 'role-custom-floor-captain',
            idempotencyKey: 'k3',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<RolesHierarchySessionsForbiddenException>()),
        );
        await expectLater(
          gateway.createOrgUnit(
            operatorId: kDemoDinerOperatorId,
            parentOrgUnitId: kDemoDinerOrgUnitRoot,
            unitType: 'region',
            label: 'north',
            name: 'North region',
            idempotencyKey: 'k4',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<RolesHierarchySessionsForbiddenException>()),
        );
        await expectLater(
          gateway.moveOrgUnit(
            operatorId: kDemoDinerOperatorId,
            orgUnitId: kDemoDinerOrgUnitEast,
            newParentOrgUnitId: kDemoDinerOrgUnitRoot,
            idempotencyKey: 'k5',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<RolesHierarchySessionsForbiddenException>()),
        );
        await expectLater(
          gateway.moveLocation(
            operatorId: kDemoDinerOperatorId,
            locationId: kDemoDinerLocationToronto,
            newOrgUnitId: kDemoDinerOrgUnitWest,
            idempotencyKey: 'k6',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<RolesHierarchySessionsForbiddenException>()),
        );
        await expectLater(
          gateway.forceLogoutSession(
            operatorId: kDemoDinerOperatorId,
            sessionId: 'session-diner-owner-mobile',
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'k7',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<RolesHierarchySessionsForbiddenException>()),
        );
        expect(gateway.capturedAuditEvents, isEmpty);
      },
    );

    test('every mutation rejects empty admin_reason', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
        sessionsByOperator: kDemoSessionsByOperator(),
      );
      for (final call in <Future<void> Function()>[
        () => gateway.editSeededRole(
          operatorId: kDemoDinerOperatorId,
          roleId: 'role-seed-operator-owner',
          permissionKeys: const <String>['team.users.view'],
          idempotencyKey: 'k1',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '   ',
        ),
        () => gateway.createCustomRole(
          operatorId: kDemoDinerOperatorId,
          roleKey: 'custom.x',
          displayName: 'X',
          description: '',
          permissionKeys: const <String>[],
          idempotencyKey: 'k2',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '',
        ),
        () => gateway.createOrgUnit(
          operatorId: kDemoDinerOperatorId,
          parentOrgUnitId: kDemoDinerOrgUnitRoot,
          unitType: 'region',
          label: 'north',
          name: 'North region',
          idempotencyKey: 'k3',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '',
        ),
        () => gateway.moveOrgUnit(
          operatorId: kDemoDinerOperatorId,
          orgUnitId: kDemoDinerOrgUnitEast,
          newParentOrgUnitId: kDemoDinerOrgUnitRoot,
          idempotencyKey: 'k4',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '',
        ),
        () => gateway.moveLocation(
          operatorId: kDemoDinerOperatorId,
          locationId: kDemoDinerLocationToronto,
          newOrgUnitId: kDemoDinerOrgUnitWest,
          idempotencyKey: 'k5',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '',
        ),
        () => gateway.forceLogoutSession(
          operatorId: kDemoDinerOperatorId,
          sessionId: 'session-diner-owner-mobile',
          userId: 'demo-user-diner-owner',
          idempotencyKey: 'k6',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '',
        ),
      ]) {
        await expectLater(
          call(),
          throwsA(
            isA<RolesHierarchySessionsGatewayError>().having(
              (e) => e.errorCode,
              'errorCode',
              equals('admin_reason_required'),
            ),
          ),
        );
      }
    });
  });

  group('audit-row shape (parity § Audit-row shape)', () {
    test(
      'every captured audit event carries forge_admin + locked action + admin_reason + business_date',
      () async {
        final clock = DateTime.utc(2026, 5, 5, 12, 30);
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          rolesByOperator: kDemoRolesByOperator(),
          orgUnitsByOperator: kDemoOrgUnitsByOperator(),
          locationsByOperator: kDemoHierarchyLocationsByOperator(),
          sessionsByOperator: kDemoSessionsByOperator(),
          clock: () => clock,
        );
        await gateway.editSeededRole(
          operatorId: kDemoDinerOperatorId,
          roleId: 'role-seed-supervisor',
          permissionKeys: const <String>['team.users.view'],
          idempotencyKey: 'k-edit',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'audit-edit',
        );
        await gateway.moveOrgUnit(
          operatorId: kDemoDinerOperatorId,
          orgUnitId: kDemoDinerOrgUnitEast,
          newParentOrgUnitId: kDemoDinerOrgUnitWest,
          idempotencyKey: 'k-move',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'reorg',
        );
        await gateway.forceLogoutSession(
          operatorId: kDemoDinerOperatorId,
          sessionId: 'session-diner-owner-mobile',
          userId: 'demo-user-diner-owner',
          idempotencyKey: 'k-revoke',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'walkthrough verification',
        );
        final actions = gateway.capturedAuditEvents
            .map((e) => e.action)
            .toList();
        expect(
          actions,
          equals(<String>[
            'team.roles.edit_seeded',
            'team.org_unit.move',
            'admin.session.force_logout',
          ]),
        );
        for (final event in gateway.capturedAuditEvents) {
          expect(event.actorKind, equals('forge_admin'));
          expect(event.actorUserId, equals('demo-super-admin'));
          expect(event.adminReason, isNotEmpty);
          expect(event.businessDate, equals(DateTime.utc(2026, 5, 5)));
          expect(event.operatorId, equals(kDemoDinerOperatorId));
        }
      },
    );

    test(
      'create + delete custom role audit rows use the locked team.* enum',
      () async {
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          rolesByOperator: kDemoRolesByOperator(),
        );
        final created = await gateway.createCustomRole(
          operatorId: kDemoDinerOperatorId,
          roleKey: 'custom.line_lead',
          displayName: 'Line Lead',
          description: 'Lead line cook',
          permissionKeys: const <String>['team.users.view'],
          idempotencyKey: 'k-create',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'support-onboarding',
        );
        await gateway.deleteCustomRole(
          operatorId: kDemoDinerOperatorId,
          roleId: created.roleId,
          idempotencyKey: 'k-delete',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'cleanup',
        );
        expect(
          gateway.capturedAuditEvents.map((e) => e.action),
          equals(<String>[
            'team.roles.create_custom',
            'team.roles.delete_custom',
          ]),
        );
      },
    );

    test(
      'custom role audit payload tags permission changes by product',
      () async {
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          rolesByOperator: kDemoRolesByOperator(),
        );
        final created = await gateway.createCustomRole(
          operatorId: kDemoDinerOperatorId,
          roleKey: 'custom.product_lead',
          displayName: 'Product Lead',
          description: 'Cross-product lead',
          permissionKeys: const <String>[
            'forgeflow.shift.view',
            'product.barrio.access',
          ],
          idempotencyKey: 'k-product-create',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'support-onboarding',
        );

        final event = gateway.capturedAuditEvents.single;
        expect(event.action, equals('team.roles.create_custom'));
        expect(event.targetId, equals(created.roleId));
        final changePayload =
            event.payload['change_payload'] as Map<String, Object?>;
        expect(changePayload['change_count'], equals(2));
        final changes = (changePayload['changes']! as List)
            .cast<Map<String, Object?>>();
        final forgeflow = changes.singleWhere(
          (entry) => entry['permission_key'] == 'forgeflow.shift.view',
        );
        final barrio = changes.singleWhere(
          (entry) => entry['permission_key'] == 'product.barrio.access',
        );
        expect(forgeflow['product'], equals('forgeflow'));
        expect(forgeflow['from'], equals('inherit'));
        expect(forgeflow['to'], equals('allow'));
        expect(barrio['product'], equals('barrio'));
        expect(barrio['from'], equals('inherit'));
        expect(barrio['to'], equals('allow'));
      },
    );

    test('move location writes team.location.move action', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
      );
      await gateway.moveLocation(
        operatorId: kDemoDinerOperatorId,
        locationId: kDemoDinerLocationToronto,
        newOrgUnitId: kDemoDinerOrgUnitWest,
        idempotencyKey: 'k-move-loc',
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'realignment',
      );
      expect(
        gateway.capturedAuditEvents.single.action,
        equals('team.location.move'),
      );
    });

    test('create org unit writes team.org_unit.create action', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      );
      final created = await gateway.createOrgUnit(
        operatorId: kDemoDinerOperatorId,
        parentOrgUnitId: kDemoDinerOrgUnitRoot,
        unitType: 'district',
        label: 'north',
        name: 'North district',
        idempotencyKey: 'k-create-org-unit',
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'add child for support walkthrough',
      );

      expect(created.parentOrgUnitId, equals(kDemoDinerOrgUnitRoot));
      expect(created.name, equals('North district'));
      final event = gateway.capturedAuditEvents.single;
      expect(event.action, equals('team.org_unit.create'));
      expect(event.targetKind, equals('org_unit'));
      expect(event.targetId, equals(created.orgUnitId));
      expect(event.adminReason, equals('add child for support walkthrough'));
      expect(event.payload['unit_type'], equals('district'));
      expect(event.payload['label'], equals('north'));
    });

    test(
      'rename org unit writes team.org_unit.rename with before/after',
      () async {
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        );
        final before = (await gateway.listOrgUnits(
          operatorId: kDemoDinerOperatorId,
        )).firstWhere((u) => u.orgUnitId == kDemoDinerOrgUnitRoot);
        final renamed = await gateway.renameOrgUnit(
          operatorId: kDemoDinerOperatorId,
          orgUnitId: kDemoDinerOrgUnitRoot,
          name: 'Renamed Business',
          idempotencyKey: 'k-rename-org-unit',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'operator requested business label change',
        );

        // Corp root IS renameable (operator-facing Business label).
        expect(renamed.orgUnitId, equals(kDemoDinerOrgUnitRoot));
        expect(renamed.name, equals('Renamed Business'));
        expect(renamed.parentOrgUnitId, isNull);
        final event = gateway.capturedAuditEvents.single;
        expect(event.action, equals('team.org_unit.rename'));
        expect(event.targetKind, equals('org_unit'));
        expect(event.targetId, equals(kDemoDinerOrgUnitRoot));
        expect(
          event.adminReason,
          equals('operator requested business label change'),
        );
        expect(event.actorKind, equals('forge_admin'));
        expect((event.payload['before'] as Map)['name'], equals(before.name));
        expect(
          (event.payload['after'] as Map)['name'],
          equals('Renamed Business'),
        );
      },
    );

    test('rename org unit rejects a non-forge-admin actor', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      );
      await expectLater(
        gateway.renameOrgUnit(
          operatorId: kDemoDinerOperatorId,
          orgUnitId: kDemoDinerOrgUnitRoot,
          name: 'Nope',
          idempotencyKey: 'k-rename-not-admin',
          actorUserId: 'demo-operator',
          actorIsForgeAdmin: false,
          adminReason: 'r',
        ),
        throwsA(isA<RolesHierarchySessionsForbiddenException>()),
      );
      expect(gateway.capturedAuditEvents, isEmpty);
    });

    test('rename org unit rejects a missing admin_reason', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      );
      await expectLater(
        gateway.renameOrgUnit(
          operatorId: kDemoDinerOperatorId,
          orgUnitId: kDemoDinerOrgUnitRoot,
          name: 'Nope',
          idempotencyKey: 'k-rename-no-reason',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '   ',
        ),
        throwsA(
          isA<RolesHierarchySessionsGatewayError>().having(
            (e) => e.errorCode,
            'errorCode',
            'admin_reason_required',
          ),
        ),
      );
      expect(gateway.capturedAuditEvents, isEmpty);
    });

    test(
      'rename org unit rejects a duplicate sibling name (locked copy)',
      () async {
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        );
        // Fixture already has 'East region' and 'West region' as siblings
        // under the root. Renaming East onto West's name must be rejected
        // with the locked duplicate copy.
        await expectLater(
          gateway.renameOrgUnit(
            operatorId: kDemoDinerOperatorId,
            orgUnitId: kDemoDinerOrgUnitEast,
            name: 'West region',
            idempotencyKey: 'k-dup-rename',
            actorUserId: 'demo-super-admin',
            actorIsForgeAdmin: true,
            adminReason: 'r',
          ),
          throwsA(
            isA<RolesHierarchySessionsGatewayError>().having(
              (e) => e.message,
              'message',
              HierarchyValidationCopy.orgUnitNameDuplicate,
            ),
          ),
        );
        expect(gateway.capturedAuditEvents, isEmpty);
      },
    );

    test('idempotent retry on renameOrgUnit returns the same row', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      );
      const key = 'idem-rename-org-unit';
      final first = await gateway.renameOrgUnit(
        operatorId: kDemoDinerOperatorId,
        orgUnitId: kDemoDinerOrgUnitRoot,
        name: 'First Name',
        idempotencyKey: key,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'r',
      );
      final second = await gateway.renameOrgUnit(
        operatorId: kDemoDinerOperatorId,
        orgUnitId: kDemoDinerOrgUnitRoot,
        name: 'Second Name',
        idempotencyKey: key,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'r',
      );

      expect(identical(first, second), isTrue);
      expect(gateway.capturedAuditEvents, hasLength(1));
    });
  });

  group('idempotency', () {
    test('idempotent retry on createCustomRole returns the same row', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
      );
      const key = 'idem-create';
      final first = await gateway.createCustomRole(
        operatorId: kDemoDinerOperatorId,
        roleKey: 'custom.first',
        displayName: 'First',
        description: '',
        permissionKeys: const <String>[],
        idempotencyKey: key,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'r',
      );
      final second = await gateway.createCustomRole(
        operatorId: kDemoDinerOperatorId,
        roleKey: 'custom.second',
        displayName: 'Second',
        description: '',
        permissionKeys: const <String>[],
        idempotencyKey: key,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'r',
      );
      expect(identical(first, second), isTrue);
      expect(gateway.capturedAuditEvents, hasLength(1));
    });

    test('idempotent retry on createOrgUnit returns the same row', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      );
      const key = 'idem-create-org-unit';
      final first = await gateway.createOrgUnit(
        operatorId: kDemoDinerOperatorId,
        parentOrgUnitId: kDemoDinerOrgUnitRoot,
        unitType: 'region',
        label: 'north',
        name: 'North region',
        idempotencyKey: key,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'r',
      );
      final second = await gateway.createOrgUnit(
        operatorId: kDemoDinerOperatorId,
        parentOrgUnitId: kDemoDinerOrgUnitRoot,
        unitType: 'district',
        label: 'south',
        name: 'South district',
        idempotencyKey: key,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'r',
      );

      expect(identical(first, second), isTrue);
      expect(gateway.capturedAuditEvents, hasLength(1));
      final units = await gateway.listOrgUnits(
        operatorId: kDemoDinerOperatorId,
      );
      expect(
        units.where((u) => u.parentOrgUnitId == kDemoDinerOrgUnitRoot),
        hasLength(3),
      );
    });

    test(
      'idempotent retry on forceLogoutSession does not double-audit',
      () async {
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          sessionsByOperator: kDemoSessionsByOperator(),
        );
        const key = 'idem-revoke';
        await gateway.forceLogoutSession(
          operatorId: kDemoDinerOperatorId,
          sessionId: 'session-diner-owner-mobile',
          userId: 'demo-user-diner-owner',
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        );
        await gateway.forceLogoutSession(
          operatorId: kDemoDinerOperatorId,
          sessionId: 'session-diner-owner-mobile',
          userId: 'demo-user-diner-owner',
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        );
        expect(gateway.capturedAuditEvents, hasLength(1));
      },
    );
  });

  group('sessions: cannot revoke own admin session', () {
    test(
      'forceLogoutSession throws cannot_revoke_self when targeted user is the admin',
      () async {
        final gateway = InMemoryRolesHierarchySessionsAdminGateway(
          sessionsByOperator: kDemoSessionsByOperator(),
        );
        await expectLater(
          gateway.forceLogoutSession(
            operatorId: kDemoDinerOperatorId,
            sessionId: 'session-diner-owner-mobile',
            userId: 'demo-super-admin',
            idempotencyKey: 'k-self',
            actorUserId: 'demo-super-admin',
            actorIsForgeAdmin: true,
            adminReason: 'r',
          ),
          throwsA(
            isA<RolesHierarchySessionsGatewayError>().having(
              (e) => e.errorCode,
              'errorCode',
              equals('cannot_revoke_self'),
            ),
          ),
        );
        // No audit row written.
        expect(gateway.capturedAuditEvents, isEmpty);
      },
    );
  });

  group('hierarchy validation', () {
    test('moveOrgUnit rejects moving a unit under itself', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      );
      await expectLater(
        gateway.moveOrgUnit(
          operatorId: kDemoDinerOperatorId,
          orgUnitId: kDemoDinerOrgUnitEast,
          newParentOrgUnitId: kDemoDinerOrgUnitEast,
          idempotencyKey: 'k-cycle',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        ),
        throwsA(
          isA<RolesHierarchySessionsGatewayError>()
              .having((e) => e.errorCode, 'errorCode', equals('cycle_detected'))
              .having(
                (e) => e.message,
                'message',
                equals(HierarchyValidationCopy.cycleDetected),
              ),
        ),
      );
    });

    test('editSeededRole rejects a non-seeded role', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
      );
      await expectLater(
        gateway.editSeededRole(
          operatorId: kDemoDinerOperatorId,
          roleId: 'role-custom-floor-captain',
          permissionKeys: const <String>['team.users.view'],
          idempotencyKey: 'k',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        ),
        throwsA(
          isA<RolesHierarchySessionsGatewayError>().having(
            (e) => e.errorCode,
            'errorCode',
            equals('not_seeded_role'),
          ),
        ),
      );
    });

    test('deleteCustomRole rejects a seeded role', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
      );
      await expectLater(
        gateway.deleteCustomRole(
          operatorId: kDemoDinerOperatorId,
          roleId: 'role-seed-operator-owner',
          idempotencyKey: 'k',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        ),
        throwsA(
          isA<RolesHierarchySessionsGatewayError>().having(
            (e) => e.errorCode,
            'errorCode',
            equals('cannot_delete_seeded'),
          ),
        ),
      );
    });
  });

  group('HttpRolesHierarchySessionsAdminGateway wire format', () {
    test(
      'forceLogoutSession pins POST /v1/admin/auth/sessions/<id>/revoke + admin_reason + idempotency',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response('{}', 200);
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        await gateway.forceLogoutSession(
          operatorId: 'op-1',
          sessionId: 'sess-1',
          userId: 'user-1',
          idempotencyKey: 'idem-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'walkthrough verification',
        );
        expect(captured.method, equals('POST'));
        expect(
          captured.url.path,
          equals('/v1/admin/auth/sessions/sess-1/revoke'),
        );
        expect(captured.headers['Idempotency-Key'], equals('idem-1'));
        expect(captured.headers['authorization'], equals('Bearer tok'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['operator_id'], equals('op-1'));
        expect(body['user_id'], equals('user-1'));
        expect(body['admin_reason'], equals('walkthrough verification'));
      },
    );

    test('listSessions GET sends operator_id query parameter', () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'sessions': const <Object?>[]}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpRolesHierarchySessionsAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await gateway.listSessions(operatorId: 'op-1');
      expect(captured.method, equals('GET'));
      expect(captured.url.path, equals('/v1/admin/auth/sessions'));
      expect(captured.url.queryParameters['operator_id'], equals('op-1'));
    });

    test('read parsers accept live proxy label-oriented payloads', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        final path = request.url.path;
        if (path.endsWith('/roles')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'roles': <Object?>[
                <String, Object?>{
                  'role_id': 'supervisor',
                  'role_key': 'supervisor',
                  'role_label': 'Supervisor',
                  'is_seeded': true,
                  'permission_keys': <String>['team.users.view'],
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/org-units')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'org_units': <Object?>[
                <String, Object?>{'org_unit_id': 'unit-1', 'label': 'Front'},
              ],
              'locations': <Object?>[
                <String, Object?>{
                  'location_id': 'loc-1',
                  'location_label': '95 Water Street',
                  'parent_org_unit_id': 'unit-1',
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'sessions': <Object?>[
              <String, Object?>{
                'session_id': 'sess-1',
                'user_id': 'u1',
                'user_email': 'user@op.test',
                'last_active_at': '2026-05-06T15:00:00Z',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpRolesHierarchySessionsAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final roles = await gateway.listRoles(operatorId: 'op-1');
      final units = await gateway.listOrgUnits(operatorId: 'op-1');
      final locations = await gateway.listHierarchyLocations(
        operatorId: 'op-1',
      );
      final sessions = await gateway.listSessions(operatorId: 'op-1');

      expect(roles.single.roleKey, equals('supervisor'));
      expect(roles.single.displayName, equals('Supervisor'));
      expect(units.single.name, equals('Front'));
      expect(locations.single.name, equals('95 Water Street'));
      expect(locations.single.orgUnitId, equals('unit-1'));
      expect(sessions.single.userDisplayName, equals('user@op.test'));
      expect(sessions.single.deviceFingerprint, equals('Unknown device'));
      expect(sessions.single.createdAt, equals(sessions.single.lastActiveAt));
    });

    test(
      'listRoles requires role_id and does not treat role_key as the mutation id',
      () async {
        final mock = http_testing.MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'roles': <Object?>[
                <String, Object?>{
                  'role_key': 'custom.floor_captain',
                  'display_name': 'Floor Captain',
                  'is_seeded': false,
                  'permission_keys': const <String>[],
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        await expectLater(
          gateway.listRoles(operatorId: 'op-1'),
          throwsStateError,
        );
      },
    );

    test(
      'listOrgUnits GET pins /v1/admin/auth/org-units + operator_id',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'org_units': <Object?>[
                <String, Object?>{'org_unit_id': 'unit-1', 'name': 'Front'},
              ],
              'locations': const <Object?>[],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        final units = await gateway.listOrgUnits(operatorId: 'op-1');

        expect(captured.method, equals('GET'));
        expect(captured.url.path, equals('/v1/admin/auth/org-units'));
        expect(captured.url.queryParameters['operator_id'], equals('op-1'));
        expect(captured.headers['authorization'], equals('Bearer tok'));
        expect(units.single.orgUnitId, equals('unit-1'));
      },
    );

    test(
      'hierarchy reads coalesce simultaneous org-unit and location loads',
      () async {
        var orgUnitRequests = 0;
        final mock = http_testing.MockClient((http.Request request) async {
          if (request.url.path.endsWith('/org-units')) {
            orgUnitRequests += 1;
            return http.Response(
              jsonEncode(<String, Object?>{
                'org_units': <Object?>[
                  <String, Object?>{'org_unit_id': 'unit-1', 'name': 'Front'},
                ],
                'locations': <Object?>[
                  <String, Object?>{
                    'location_id': 'loc-1',
                    'name': '95 Water Street',
                    'org_unit_id': 'unit-1',
                  },
                ],
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        final results = await Future.wait<Object>([
          gateway.listOrgUnits(operatorId: 'op-1'),
          gateway.listHierarchyLocations(operatorId: 'op-1'),
        ]);

        expect((results[0] as List<OrgUnitAdminNode>).single.name, 'Front');
        expect(
          (results[1] as List<HierarchyLocationLeaf>).single.name,
          '95 Water Street',
        );
        expect(orgUnitRequests, equals(1));
      },
    );

    test('createCustomRole POST pins payload + admin_reason', () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'role': <String, Object?>{
              'role_id': 'r1',
              'role_key': 'custom.lead',
              'display_name': 'Lead',
              'description': '',
              'is_seeded': false,
              'permission_keys': <String>['team.users.view'],
              'operator_id': 'op-1',
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpRolesHierarchySessionsAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await gateway.createCustomRole(
        operatorId: 'op-1',
        roleKey: 'custom.lead',
        displayName: 'Lead',
        description: '',
        permissionKeys: const <String>['team.users.view'],
        idempotencyKey: 'idem-1',
        actorUserId: 'admin-1',
        actorIsForgeAdmin: true,
        adminReason: 'support',
      );
      expect(captured.url.path, equals('/v1/admin/auth/roles'));
      expect(captured.method, equals('POST'));
      expect(captured.headers['Idempotency-Key'], equals('idem-1'));
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      expect(body['operator_id'], equals('op-1'));
      expect(body['role_key'], equals('custom.lead'));
      expect(body['admin_reason'], equals('support'));
      expect(body['reason'], equals('support'));
      expect(
        body['permissions'],
        equals(<Object?>[
          <String, String>{
            'permission_key': 'team.users.view',
            'effect': 'allow',
          },
        ]),
      );
      expect(body.containsKey('permission_keys'), isFalse);
    });

    test(
      'updateCustomRole PATCH pins role id + replacement permissions',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'role': <String, Object?>{
                'role_id': 'r1',
                'role_key': 'custom.lead',
                'display_name': 'Lead',
                'description': 'Updated',
                'is_seeded': false,
                'permission_keys': <String>['team.roles.assign'],
                'operator_id': 'op-1',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        await gateway.updateCustomRole(
          operatorId: 'op-1',
          roleId: 'r1',
          displayName: 'Lead',
          description: 'Updated',
          previousPermissionKeys: const <String>['team.users.view'],
          permissionKeys: const <String>['team.roles.assign'],
          idempotencyKey: 'idem-patch-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'support',
        );

        expect(captured.method, equals('PATCH'));
        expect(captured.url.path, equals('/v1/admin/auth/roles/r1'));
        expect(captured.headers['Idempotency-Key'], equals('idem-patch-1'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['operator_id'], equals('op-1'));
        expect(body['display_name'], equals('Lead'));
        expect(body['description'], equals('Updated'));
        expect(body['admin_reason'], equals('support'));
        expect(body['reason'], equals('support'));
        expect(
          body['permissions'],
          equals(<Object?>[
            <String, String>{
              'permission_key': 'team.roles.assign',
              'effect': 'allow',
            },
            <String, String>{
              'permission_key': 'team.users.view',
              'effect': 'inherit',
            },
          ]),
        );
      },
    );

    test(
      'createOrgUnit POST pins /v1/admin/auth/org-units + body + idempotency + admin_reason',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{'org_unit_id': 'unit-north'}),
            201,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        final created = await gateway.createOrgUnit(
          operatorId: 'op-1',
          parentOrgUnitId: 'unit-root',
          unitType: 'district',
          label: 'north',
          name: 'North district',
          idempotencyKey: 'idem-org-unit-create-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'operator requested hierarchy setup',
        );

        expect(captured.method, equals('POST'));
        expect(captured.url.path, equals('/v1/admin/auth/org-units'));
        expect(
          captured.headers['Idempotency-Key'],
          equals('idem-org-unit-create-1'),
        );
        expect(captured.headers['authorization'], equals('Bearer tok'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(
          body,
          equals(<String, Object?>{
            'operator_id': 'op-1',
            'parent_org_unit_id': 'unit-root',
            'unit_type': 'district',
            'label': 'north',
            'name': 'North district',
            'admin_reason': 'operator requested hierarchy setup',
          }),
        );
        expect(created.orgUnitId, equals('unit-north'));
        expect(created.operatorId, equals('op-1'));
        expect(created.parentOrgUnitId, equals('unit-root'));
        expect(created.name, equals('North district'));
      },
    );

    test(
      'moveLocation PATCH pins /v1/admin/auth/locations/<id>/org-unit + parent_org_unit_id',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{'ok': true, 'moved': true}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        final moved = await gateway.moveLocation(
          operatorId: 'op-1',
          locationId: 'loc-1',
          newOrgUnitId: 'unit-2',
          idempotencyKey: 'idem-move-location-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'hierarchy realignment',
        );

        expect(captured.method, equals('PATCH'));
        expect(
          captured.url.path,
          equals('/v1/admin/auth/locations/loc-1/org-unit'),
        );
        expect(
          captured.headers['Idempotency-Key'],
          equals('idem-move-location-1'),
        );
        expect(captured.headers['authorization'], equals('Bearer tok'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(
          body,
          equals(<String, Object?>{
            'operator_id': 'op-1',
            'parent_org_unit_id': 'unit-2',
            'admin_reason': 'hierarchy realignment',
          }),
        );
        expect(moved.locationId, equals('loc-1'));
        expect(moved.operatorId, equals('op-1'));
        expect(moved.orgUnitId, equals('unit-2'));
      },
    );

    test(
      'moveOrgUnit PATCH pins /v1/admin/auth/org-units/<id>/parent + parent_org_unit_id',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'org_unit': <String, Object?>{
                'org_unit_id': 'unit-1',
                'operator_id': 'op-1',
                'parent_org_unit_id': 'unit-2',
                'name': 'East',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        final moved = await gateway.moveOrgUnit(
          operatorId: 'op-1',
          orgUnitId: 'unit-1',
          newParentOrgUnitId: 'unit-2',
          idempotencyKey: 'idem-move-org-unit-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'hierarchy realignment',
        );

        expect(captured.method, equals('PATCH'));
        expect(
          captured.url.path,
          equals('/v1/admin/auth/org-units/unit-1/parent'),
        );
        expect(
          captured.headers['Idempotency-Key'],
          equals('idem-move-org-unit-1'),
        );
        expect(captured.headers['authorization'], equals('Bearer tok'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(
          body,
          equals(<String, Object?>{
            'operator_id': 'op-1',
            'parent_org_unit_id': 'unit-2',
            'admin_reason': 'hierarchy realignment',
          }),
        );
        expect(moved.orgUnitId, equals('unit-1'));
        expect(moved.parentOrgUnitId, equals('unit-2'));
      },
    );

    test(
      'renameOrgUnit PATCH pins /v1/admin/auth/org-units/<id>/name + name',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'org_unit': <String, Object?>{
                'org_unit_id': 'unit-1',
                'operator_id': 'op-1',
                'parent_org_unit_id': 'unit-2',
                'name': 'Pacific',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        final renamed = await gateway.renameOrgUnit(
          operatorId: 'op-1',
          orgUnitId: 'unit-1',
          name: 'Pacific',
          idempotencyKey: 'idem-rename-org-unit-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'operator requested rename',
        );

        expect(captured.method, equals('PATCH'));
        expect(
          captured.url.path,
          equals('/v1/admin/auth/org-units/unit-1/name'),
        );
        expect(
          captured.headers['Idempotency-Key'],
          equals('idem-rename-org-unit-1'),
        );
        expect(captured.headers['authorization'], equals('Bearer tok'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(
          body,
          equals(<String, Object?>{
            'operator_id': 'op-1',
            'name': 'Pacific',
            'admin_reason': 'operator requested rename',
          }),
        );
        expect(renamed.orgUnitId, equals('unit-1'));
        expect(renamed.name, equals('Pacific'));
      },
    );

    test(
      'renameOrgUnit rejects a missing admin_reason before any HTTP call',
      () async {
        var called = false;
        final mock = http_testing.MockClient((http.Request request) async {
          called = true;
          return http.Response('{}', 200);
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        await expectLater(
          gateway.renameOrgUnit(
            operatorId: 'op-1',
            orgUnitId: 'unit-1',
            name: 'Pacific',
            idempotencyKey: 'idem-rename-no-reason',
            actorUserId: 'admin-1',
            actorIsForgeAdmin: true,
            adminReason: '   ',
          ),
          throwsA(
            isA<RolesHierarchySessionsGatewayError>().having(
              (e) => e.errorCode,
              'errorCode',
              'admin_reason_required',
            ),
          ),
        );
        expect(called, isFalse);
      },
    );

    test(
      'suspendOrgUnit PATCH pins lifecycle route and parses status',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'org_unit': <String, Object?>{
                'org_unit_id': 'unit-1',
                'operator_id': 'op-1',
                'parent_org_unit_id': 'unit-2',
                'name': 'East',
                'suspended_at': '2026-05-08T12:00:00.000Z',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        final suspended = await gateway.suspendOrgUnit(
          operatorId: 'op-1',
          orgUnitId: 'unit-1',
          idempotencyKey: 'idem-suspend-org-unit-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'temporarily pause branch',
        );

        expect(captured.method, equals('PATCH'));
        expect(
          captured.url.path,
          equals('/v1/admin/auth/org-units/unit-1/suspend'),
        );
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(
          body,
          equals(<String, Object?>{
            'operator_id': 'op-1',
            'admin_reason': 'temporarily pause branch',
          }),
        );
        expect(suspended.suspendedAt, isNotNull);
      },
    );

    test(
      'deleteLocation POST pins lifecycle route with admin reason',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{'ok': true, 'deleted': true}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        await gateway.deleteLocation(
          operatorId: 'op-1',
          locationId: 'loc-1',
          idempotencyKey: 'idem-delete-location-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'duplicate location cleanup',
        );

        expect(captured.method, equals('POST'));
        expect(
          captured.url.path,
          equals('/v1/admin/auth/locations/loc-1/delete'),
        );
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(
          body,
          equals(<String, Object?>{
            'operator_id': 'op-1',
            'admin_reason': 'duplicate location cleanup',
          }),
        );
      },
    );

    test('non-forge-admin caller never reaches the network', () async {
      var hits = 0;
      final mock = http_testing.MockClient((http.Request request) async {
        hits += 1;
        return http.Response('', 500);
      });
      final gateway = HttpRolesHierarchySessionsAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await expectLater(
        gateway.forceLogoutSession(
          operatorId: 'op-1',
          sessionId: 'sess-1',
          userId: 'user-1',
          idempotencyKey: 'idem-1',
          actorUserId: 'non-admin',
          actorIsForgeAdmin: false,
          adminReason: 'r',
        ),
        throwsA(isA<RolesHierarchySessionsForbiddenException>()),
      );
      expect(hits, equals(0));
    });

    test('proxy 403 maps to Forbidden', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'permission_denied',
            'message': 'forge_admin required',
          }),
          403,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpRolesHierarchySessionsAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await expectLater(
        gateway.forceLogoutSession(
          operatorId: 'op-1',
          sessionId: 'sess-1',
          userId: 'user-1',
          idempotencyKey: 'idem-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        ),
        throwsA(isA<RolesHierarchySessionsForbiddenException>()),
      );
    });

    test(
      'proxy validation_failed/cannot_revoke_self preserves errorCode',
      () async {
        final mock = http_testing.MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'cannot_revoke_self',
              'message':
                  'You cannot sign yourself out from this surface. '
                  'Use admin sign-out instead.',
            }),
            400,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpRolesHierarchySessionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        await expectLater(
          gateway.forceLogoutSession(
            operatorId: 'op-1',
            sessionId: 'sess-1',
            userId: 'admin-1',
            idempotencyKey: 'idem-1',
            actorUserId: 'admin-1',
            actorIsForgeAdmin: true,
            adminReason: 'r',
          ),
          throwsA(
            isA<RolesHierarchySessionsGatewayError>()
                .having((e) => e.statusCode, 'statusCode', equals(400))
                .having(
                  (e) => e.errorCode,
                  'errorCode',
                  equals('cannot_revoke_self'),
                ),
          ),
        );
      },
    );
  });

  group('locked validation copy', () {
    test('HierarchyValidationCopy strings match the parity contract', () {
      expect(
        HierarchyValidationCopy.orgUnitNameEmpty,
        equals('Org unit name is required.'),
      );
      expect(
        HierarchyValidationCopy.orgUnitNameDuplicate,
        equals('An org unit with this name already exists in this group.'),
      );
      expect(
        HierarchyValidationCopy.cycleDetected,
        equals('Cannot move into a child of itself.'),
      );
    });

    test('no operator-facing literal contains an em dash', () {
      const literals = <String>[
        HierarchyValidationCopy.orgUnitNameEmpty,
        HierarchyValidationCopy.orgUnitNameDuplicate,
        HierarchyValidationCopy.cycleDetected,
        SessionsValidationCopy.cannotRevokeSelf,
      ];
      for (final label in literals) {
        expect(label.contains('—'), isFalse, reason: label);
      }
      for (final label in kRoleDisplayNamesForAdmin.values) {
        expect(label.contains('—'), isFalse, reason: label);
      }
    });
  });
}
