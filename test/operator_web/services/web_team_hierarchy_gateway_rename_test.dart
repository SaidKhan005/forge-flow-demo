// GAP A1 — operator-web team-hierarchy gateway rename coverage.
//
// Pins the self-service rename wire shape on the live `package:http`
// impl (route + idempotency header + NO admin_reason) and the demo
// in-memory impl behaviour (duplicate-name-within-parent rejection
// with the locked copy, corp-root rename allowed, idempotent replay).
// Pure Dart via `MockClient` — no real network.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/demo_team_hierarchy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_hierarchy_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

void main() {
  final Uri kProxyBase = Uri.parse('https://proxy.forgeflow.test');
  Future<String?> tokenProvider() async => 'test-id-token';

  TeamOrgUnitRenameCommand cmd(String orgUnitId, String name) =>
      TeamOrgUnitRenameCommand(
        actorUserId: 'user-1',
        operatorId: 'op-1',
        locationId: 'loc-1',
        orgUnitId: orgUnitId,
        name: name,
      );

  group('WebTeamHierarchyGatewayLive.renameOrgUnit', () {
    test(
      'PATCHes /v1/auth/team/org-units/<id>/name with idempotency key '
      'and NO admin_reason (self-service)',
      () async {
        late http.Request captured;
        final client = MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'org_unit': <String, Object?>{
                'org_unit_id': 'unit-9',
                'parent_org_unit_id': 'root-1',
                'unit_type': 'region',
                'path': 'acme.renamed',
                'label': 'Renamed Region',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = WebTeamHierarchyGatewayLive(
          proxyBaseUri: kProxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        final renamed = await gateway.renameOrgUnit(
          cmd('unit-9', 'Renamed Region'),
          idempotencyKey: 'op-web-hierarchy-key-1',
        );

        expect(captured.method, equals('PATCH'));
        expect(
          captured.url.path,
          equals('/v1/auth/team/org-units/unit-9/name'),
        );
        expect(
          captured.headers['Idempotency-Key'],
          equals('op-web-hierarchy-key-1'),
        );
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        // Self-service rename carries name only — never admin_reason.
        expect(body, equals(<String, Object?>{'name': 'Renamed Region'}));
        expect(renamed.orgUnit.orgUnitId, equals('unit-9'));
        expect(renamed.orgUnit.label, equals('Renamed Region'));
      },
    );

    test('maps a non-2xx to WebTeamHierarchyError', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'org_unit_name_taken',
            'message': 'An org unit with this name already exists in '
                'this group.',
          }),
          409,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = WebTeamHierarchyGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      await expectLater(
        gateway.renameOrgUnit(
          cmd('unit-9', 'Dup'),
          idempotencyKey: 'k',
        ),
        throwsA(
          isA<WebTeamHierarchyError>().having(
            (e) => e.code,
            'code',
            'org_unit_name_taken',
          ),
        ),
      );
    });
  });

  group('DemoWebTeamHierarchyGateway.renameOrgUnit', () {
    test('renames an existing unit and replays on idempotency reuse',
        () async {
      final gateway = DemoWebTeamHierarchyGateway();
      final listed = await gateway.listOrgHierarchy(
        const TeamOrgHierarchyListCommand(
          actorUserId: 'u',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );
      // The corp root IS renameable (operator-facing Business label).
      final root = listed.orgUnits.firstWhere(
        (u) => u.parentOrgUnitId == null,
      );
      const key = 'demo-rename-key-1';
      final first = await gateway.renameOrgUnit(
        TeamOrgUnitRenameCommand(
          actorUserId: 'u',
          operatorId: 'op',
          locationId: 'loc',
          orgUnitId: root.orgUnitId,
          name: 'Renamed Business',
        ),
        idempotencyKey: key,
      );
      expect(first.orgUnit.label, equals('Renamed Business'));
      // Replay returns the original outcome, no second mutation.
      final replay = await gateway.renameOrgUnit(
        TeamOrgUnitRenameCommand(
          actorUserId: 'u',
          operatorId: 'op',
          locationId: 'loc',
          orgUnitId: root.orgUnitId,
          name: 'Different Name',
        ),
        idempotencyKey: key,
      );
      expect(replay.orgUnit.label, equals('Renamed Business'));
    });

    test('rejects a duplicate sibling name with the locked copy', () async {
      final gateway = DemoWebTeamHierarchyGateway();
      final listed = await gateway.listOrgHierarchy(
        const TeamOrgHierarchyListCommand(
          actorUserId: 'u',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );
      final root = listed.orgUnits.firstWhere(
        (u) => u.parentOrgUnitId == null,
      );
      // Create two siblings under root, then rename one onto the other.
      final a = await gateway.createOrgUnit(
        TeamOrgUnitCreateCommand(
          actorUserId: 'u',
          operatorId: 'op',
          locationId: 'loc',
          parentOrgUnitId: root.orgUnitId,
          unitType: 'region',
          label: 'alpha',
          name: 'Alpha',
        ),
        idempotencyKey: 'demo-create-a',
      );
      await gateway.createOrgUnit(
        TeamOrgUnitCreateCommand(
          actorUserId: 'u',
          operatorId: 'op',
          locationId: 'loc',
          parentOrgUnitId: root.orgUnitId,
          unitType: 'region',
          label: 'beta',
          name: 'Beta',
        ),
        idempotencyKey: 'demo-create-b',
      );
      await expectLater(
        gateway.renameOrgUnit(
          TeamOrgUnitRenameCommand(
            actorUserId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            orgUnitId: a.orgUnitId,
            name: 'Beta',
          ),
          idempotencyKey: 'demo-rename-dup',
        ),
        throwsA(
          isA<WebTeamHierarchyError>().having(
            (e) => e.message,
            'message',
            'An org unit with this name already exists in this group.',
          ),
        ),
      );
    });
  });
}
