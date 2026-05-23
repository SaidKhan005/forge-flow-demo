// Slice E — admin hierarchy-mutation gate tests.
//
// Mirrors the integration gateway's "Slice E3 rotation gate" test group
// (`test/admin/integration_admin_gateway_test.dart`). Each hierarchy
// MUTATE method on `RolesHierarchySessionsAdminGateway` is gated on its
// `admin.hierarchy.*` key via the shared `evaluateHierarchyMutationGate`
// helper, using "key-first with role fallback, byte-identical when
// permissions empty":
//
//   * No resolver wired  -> no gate (BYTE-IDENTICAL to pre-slice; this
//     is what every current caller does).
//   * Permissions NON-EMPTY -> allow iff the set contains the method's
//     required key; otherwise deny (even for super_admin).
//   * Permissions EMPTY + role resolver wired -> fall back to the role
//     check. The `admin.hierarchy.*` keys default-grant to super_admin +
//     ff_support ONLY, so the fallback ALLOWS those two and denies all
//     other roles.
//
// Covered for BOTH gateway implementations (the in-memory demo gateway
// and the live Http gateway) and across all five keys.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:http/http.dart' as http;

void main() {
  // ─── In-memory (demo) gateway ─────────────────────────────────────
  //
  // Builds a demo gateway seeded with the standard demo fixtures so that
  // an ALLOWED mutation has real state to act on. DENIED mutations throw
  // before any state lookup, so the seed is irrelevant there.
  InMemoryRolesHierarchySessionsAdminGateway demoGateway({
    RolesHierarchySessionsRoleResolver? roleResolver,
    RolesHierarchySessionsPermissionResolver? permissionResolver,
  }) {
    return InMemoryRolesHierarchySessionsAdminGateway(
      rolesByOperator: kDemoRolesByOperator(),
      orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      locationsByOperator: kDemoHierarchyLocationsByOperator(),
      sessionsByOperator: kDemoSessionsByOperator(),
      roleResolver: roleResolver,
      permissionResolver: permissionResolver,
    );
  }

  // Representative mutation per key, driven against the demo gateway.
  // Each closure performs ONE mutation that, when the gate allows,
  // succeeds against the seeded demo fixtures.
  Future<void> rename(InMemoryRolesHierarchySessionsAdminGateway g) async {
    await g.renameOrgUnit(
      operatorId: kDemoDinerOperatorId,
      orgUnitId: kDemoDinerOrgUnitEast,
      name: 'East region renamed',
      idempotencyKey: 'gate-rename-${DateTime.now().microsecondsSinceEpoch}',
      actorUserId: 'admin-x',
      actorIsForgeAdmin: true,
      adminReason: 'slice E gate test',
    );
  }

  Future<void> move(InMemoryRolesHierarchySessionsAdminGateway g) async {
    await g.moveOrgUnit(
      operatorId: kDemoDinerOperatorId,
      orgUnitId: kDemoDinerOrgUnitEast,
      newParentOrgUnitId: kDemoDinerOrgUnitWest,
      idempotencyKey: 'gate-move-${DateTime.now().microsecondsSinceEpoch}',
      actorUserId: 'admin-x',
      actorIsForgeAdmin: true,
      adminReason: 'slice E gate test',
    );
  }

  Future<void> suspend(InMemoryRolesHierarchySessionsAdminGateway g) async {
    await g.suspendOrgUnit(
      operatorId: kDemoDinerOperatorId,
      orgUnitId: kDemoDinerOrgUnitEast,
      idempotencyKey: 'gate-suspend-${DateTime.now().microsecondsSinceEpoch}',
      actorUserId: 'admin-x',
      actorIsForgeAdmin: true,
      adminReason: 'slice E gate test',
    );
  }

  group('InMemory hierarchy gate — rename (admin.hierarchy.rename)', () {
    test('no resolver: rename proceeds (byte-identical)', () async {
      // Demo / widget-test default — no gate.
      await rename(demoGateway());
    });

    test('empty perms + super_admin role: ALLOWED (fallback)', () async {
      await rename(
        demoGateway(
          roleResolver: () async => <String>[PermissionKeys.roleSuperAdmin],
          permissionResolver: () async => const <String>{},
        ),
      );
    });

    test('empty perms + ff_support role: ALLOWED (fallback)', () async {
      await rename(
        demoGateway(
          roleResolver: () async => <String>[PermissionKeys.roleFfSupport],
          permissionResolver: () async => const <String>{},
        ),
      );
    });

    test('empty perms + operator-tier role: DENIED (fallback)', () async {
      // admin.hierarchy.* default-grants to super_admin + ff_support
      // ONLY, so an operator_owner falls outside the fallback grant.
      await expectLater(
        () => rename(
          demoGateway(
            roleResolver: () async =>
                <String>[PermissionKeys.roleOperatorOwner],
            permissionResolver: () async => const <String>{},
          ),
        ),
        throwsA(isA<RolesHierarchySessionsGatewayError>()),
      );
    });

    test('perms WITH the key: ALLOWED for a non-super_admin role', () async {
      await rename(
        demoGateway(
          roleResolver: () async => const <String>['ops_reviewer'],
          permissionResolver: () async =>
              <String>{PermissionKeys.adminHierarchyRename},
        ),
      );
    });

    test('perms WITHOUT the key: DENIED even for super_admin', () async {
      await expectLater(
        () => rename(
          demoGateway(
            roleResolver: () async => <String>[PermissionKeys.roleSuperAdmin],
            // Non-empty but lacks admin.hierarchy.rename.
            permissionResolver: () async =>
                <String>{PermissionKeys.adminHierarchyCreate},
          ),
        ),
        throwsA(isA<RolesHierarchySessionsGatewayError>()),
      );
    });

    test('both resolvers null: no gate', () async {
      await rename(
        demoGateway(roleResolver: null, permissionResolver: null),
      );
    });
  });

  group('InMemory hierarchy gate — move (admin.hierarchy.move)', () {
    test('perms WITHOUT the key: DENIED even for super_admin', () async {
      await expectLater(
        () => move(
          demoGateway(
            roleResolver: () async => <String>[PermissionKeys.roleSuperAdmin],
            permissionResolver: () async =>
                const <String>{'integration.toast.view'},
          ),
        ),
        throwsA(isA<RolesHierarchySessionsGatewayError>()),
      );
    });

    test('perms WITH the key: ALLOWED', () async {
      await move(
        demoGateway(
          permissionResolver: () async =>
              <String>{PermissionKeys.adminHierarchyMove},
        ),
      );
    });

    test('empty perms + ff_support: ALLOWED (fallback)', () async {
      await move(
        demoGateway(
          roleResolver: () async => <String>[PermissionKeys.roleFfSupport],
          permissionResolver: () async => const <String>{},
        ),
      );
    });
  });

  group('InMemory hierarchy gate — suspend (admin.hierarchy.suspend)', () {
    test('empty perms + operator-tier role: DENIED (fallback)', () async {
      await expectLater(
        () => suspend(
          demoGateway(
            roleResolver: () async =>
                <String>[PermissionKeys.roleLocationManager],
            permissionResolver: () async => const <String>{},
          ),
        ),
        throwsA(isA<RolesHierarchySessionsGatewayError>()),
      );
    });

    test('perms WITH the key: ALLOWED', () async {
      await suspend(
        demoGateway(
          permissionResolver: () async =>
              <String>{PermissionKeys.adminHierarchySuspend},
        ),
      );
    });

    test('no resolver: suspend proceeds (byte-identical)', () async {
      await suspend(demoGateway());
    });
  });

  // ─── Http gateway ─────────────────────────────────────────────────
  //
  // A mutation POST/PATCH succeeds with a canned response when the gate
  // ALLOWS; when the gate DENIES, the throw happens before any HTTP
  // call, so `captured` stays empty.
  group('Http hierarchy gate — create (admin.hierarchy.create)', () {
    HttpRolesHierarchySessionsAdminGateway httpGateway(
      List<_CapturedRequest> captured, {
      RolesHierarchySessionsRoleResolver? roleResolver,
      RolesHierarchySessionsPermissionResolver? permissionResolver,
    }) {
      return HttpRolesHierarchySessionsAdminGateway(
        baseUri: Uri.parse('https://proxy.example.com'),
        bearerTokenProvider: () async => 'fake.token',
        httpClient: _CannedClient(
          captured: captured,
          response: _Fixture(
            statusCode: 200,
            body: <String, Object?>{
              'org_unit': <String, Object?>{
                'org_unit_id': 'org-e-1',
                'name': 'New region',
                'operator_id': 'op-1',
                'parent_org_unit_id': 'root-1',
                'unit_type': 'region',
              },
            },
          ),
        ),
        roleResolver: roleResolver,
        permissionResolver: permissionResolver,
      );
    }

    Future<void> create(HttpRolesHierarchySessionsAdminGateway g) async {
      await g.createOrgUnit(
        operatorId: 'op-1',
        parentOrgUnitId: 'root-1',
        unitType: 'region',
        label: 'New region',
        name: 'New region',
        idempotencyKey: 'e-create',
        actorUserId: 'admin-x',
        actorIsForgeAdmin: true,
        adminReason: 'slice E gate test',
      );
    }

    test('no resolver: create POSTs (byte-identical / server-enforced)',
        () async {
      final captured = <_CapturedRequest>[];
      await create(httpGateway(captured));
      expect(captured.single.method, equals('POST'));
      expect(captured.single.uri.path, equals('/v1/admin/auth/org-units'));
    });

    test('empty perms + super_admin: ALLOWED (fallback) and POSTs', () async {
      final captured = <_CapturedRequest>[];
      await create(
        httpGateway(
          captured,
          roleResolver: () async => <String>[PermissionKeys.roleSuperAdmin],
          permissionResolver: () async => const <String>{},
        ),
      );
      expect(captured.single.method, equals('POST'));
    });

    test('empty perms + ff_support: ALLOWED (fallback)', () async {
      final captured = <_CapturedRequest>[];
      await create(
        httpGateway(
          captured,
          roleResolver: () async => <String>[PermissionKeys.roleFfSupport],
          permissionResolver: () async => const <String>{},
        ),
      );
      expect(captured.single.method, equals('POST'));
    });

    test('empty perms + operator-tier role: DENIED before any HTTP call',
        () async {
      final captured = <_CapturedRequest>[];
      await expectLater(
        () => create(
          httpGateway(
            captured,
            roleResolver: () async =>
                <String>[PermissionKeys.roleOperatorOwner],
            permissionResolver: () async => const <String>{},
          ),
        ),
        throwsA(isA<RolesHierarchySessionsGatewayError>()),
      );
      expect(captured, isEmpty);
    });

    test('perms WITH admin.hierarchy.create: ALLOWED for non-super_admin',
        () async {
      final captured = <_CapturedRequest>[];
      await create(
        httpGateway(
          captured,
          roleResolver: () async => const <String>['ops_reviewer'],
          permissionResolver: () async =>
              <String>{PermissionKeys.adminHierarchyCreate},
        ),
      );
      expect(captured.single.uri.path, equals('/v1/admin/auth/org-units'));
    });

    test('perms WITHOUT the key: DENIED before any HTTP call, even super_admin',
        () async {
      final captured = <_CapturedRequest>[];
      await expectLater(
        () => create(
          httpGateway(
            captured,
            roleResolver: () async => <String>[PermissionKeys.roleSuperAdmin],
            permissionResolver: () async =>
                <String>{PermissionKeys.adminHierarchyMove},
          ),
        ),
        throwsA(isA<RolesHierarchySessionsGatewayError>()),
      );
      expect(captured, isEmpty);
    });
  });

  group('Http hierarchy gate — delete (admin.hierarchy.delete)', () {
    HttpRolesHierarchySessionsAdminGateway httpGateway(
      List<_CapturedRequest> captured, {
      RolesHierarchySessionsRoleResolver? roleResolver,
      RolesHierarchySessionsPermissionResolver? permissionResolver,
    }) {
      return HttpRolesHierarchySessionsAdminGateway(
        baseUri: Uri.parse('https://proxy.example.com'),
        bearerTokenProvider: () async => 'fake.token',
        httpClient: _CannedClient(
          captured: captured,
          response: _Fixture(statusCode: 200, body: const <String, Object?>{}),
        ),
        roleResolver: roleResolver,
        permissionResolver: permissionResolver,
      );
    }

    Future<void> deleteLocation(
      HttpRolesHierarchySessionsAdminGateway g,
    ) async {
      await g.deleteLocation(
        operatorId: 'op-1',
        locationId: 'loc-1',
        idempotencyKey: 'e-delete',
        actorUserId: 'admin-x',
        actorIsForgeAdmin: true,
        adminReason: 'slice E gate test',
      );
    }

    test('perms WITHOUT the key: DENIED before any HTTP call', () async {
      final captured = <_CapturedRequest>[];
      await expectLater(
        () => deleteLocation(
          httpGateway(
            captured,
            roleResolver: () async => <String>[PermissionKeys.roleSuperAdmin],
            permissionResolver: () async =>
                <String>{PermissionKeys.adminHierarchyCreate},
          ),
        ),
        throwsA(isA<RolesHierarchySessionsGatewayError>()),
      );
      expect(captured, isEmpty);
    });

    test('perms WITH admin.hierarchy.delete: ALLOWED and POSTs', () async {
      final captured = <_CapturedRequest>[];
      await deleteLocation(
        httpGateway(
          captured,
          permissionResolver: () async =>
              <String>{PermissionKeys.adminHierarchyDelete},
        ),
      );
      expect(captured.single.method, equals('POST'));
      expect(captured.single.uri.path, contains('/delete'));
    });

    test('no resolver: delete POSTs (byte-identical)', () async {
      final captured = <_CapturedRequest>[];
      await deleteLocation(httpGateway(captured));
      expect(captured.single.method, equals('POST'));
    });
  });
}

// ─── Test helpers (mirrors the E3 test's _SingleResponseClient) ──────

class _CapturedRequest {
  _CapturedRequest({required this.method, required this.uri});
  final String method;
  final Uri uri;
}

class _Fixture {
  _Fixture({required this.statusCode, required this.body});
  final int statusCode;
  final Map<String, Object?> body;
}

class _CannedClient extends http.BaseClient {
  _CannedClient({required this.captured, required this.response});

  final List<_CapturedRequest> captured;
  final _Fixture response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().toBytes();
    captured.add(
      _CapturedRequest(method: request.method, uri: request.url),
    );
    final encoded = utf8.encode(jsonEncode(response.body));
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[encoded]),
      response.statusCode,
      contentLength: encoded.length,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}
