// B3 role-key hybrid identifier sweep - operator-web role gateway.
//
// Pins that operator-web role mutations send role_id over the wire. The
// presentation slug (`role_key`) remains read-only catalog data.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/web_team_roles_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

void main() {
  final proxyBase = Uri.parse('https://proxy.forgeflow.test');

  Future<String?> tokenProvider() async => 'test-id-token';

  group('WebTeamRolesGatewayLive role_id mutations', () {
    test(
      'patchRole uses role_id in the path and never sends role_key',
      () async {
        late http.Request captured;
        final client = MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'role': _roleJson(displayName: 'Floor Captain'),
              'bumped_users': 0,
            }),
            200,
          );
        });
        final gateway = WebTeamRolesGatewayLive(
          proxyBaseUri: proxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        final patched = await gateway.patchRole(
          const TeamRolePatchCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            roleId: '44444444-4444-4444-8444-444444444444',
            displayName: 'Floor Captain',
          ),
          idempotencyKey: 'idem-role-patch',
        );

        expect(patched.bumpedUsers, equals(0));
        expect(
          captured.url.path,
          equals('/v1/auth/team/roles/44444444-4444-4444-8444-444444444444'),
        );
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['display_name'], equals('Floor Captain'));
        expect(body.containsKey('role_key'), isFalse);
      },
    );

    test('createRoleGrant sends role_id only', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'user_role_id': 'grant-1'}),
          201,
        );
      });
      final gateway = WebTeamRolesGatewayLive(
        proxyBaseUri: proxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      await gateway.createRoleGrant(
        const TeamRoleGrantCreateCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetUserId: 'user-1',
          roleId: '44444444-4444-4444-8444-444444444444',
          scopeType: 'operator_wide',
        ),
        idempotencyKey: 'idem-role-grant',
      );

      expect(captured.url.path, equals('/v1/auth/team/role-grants'));
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      expect(body['role_id'], equals('44444444-4444-4444-8444-444444444444'));
      expect(body.containsKey('role_key'), isFalse);
    });

    test(
      'listRoles requires role_id alongside presentation role_key',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'roles': <Object?>[
                <String, Object?>{
                  'role_key': 'custom.floor_captain',
                  'display_name': 'Floor Captain',
                  'description': '',
                  'is_seeded': false,
                  'is_editable': true,
                  'permissions': const <Object?>[],
                },
              ],
            }),
            200,
          );
        });
        final gateway = WebTeamRolesGatewayLive(
          proxyBaseUri: proxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        await expectLater(
          gateway.listRoles(
            const TeamRoleCatalogListCommand(
              actorUserId: 'actor',
              operatorId: 'op',
              locationId: 'loc',
            ),
          ),
          throwsA(isA<WebTeamRolesError>()),
        );
      },
    );
  });
}

Map<String, Object?> _roleJson({String displayName = 'Kitchen Lead'}) {
  return <String, Object?>{
    'role_id': '44444444-4444-4444-8444-444444444444',
    'role_key': 'custom.kitchen_lead',
    'display_name': displayName,
    'description': '',
    'is_seeded': false,
    'is_editable': true,
    'operator_id': 'op',
    'permissions': const <Object?>[],
  };
}
