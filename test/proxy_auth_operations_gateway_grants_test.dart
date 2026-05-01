// Phase 9.UX.grant-payload — ProxyAuthOperationsGateway team-users
// grants serialize/deserialize.
//
// Pins the additive `grants` array on the `/v1/admin/auth/users`
// HTTP response: existing callers that ignore the field continue to
// work, and new clients deserialize the full per-grant scope payload.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyAuthOperationsGateway team-users grants payload', () {
    test('listUsers deserializes a multi-grant payload', () async {
      final fake = _FakeAuthOpsHttpClient(
        getResponse: ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'users': <Object?>[
              <String, Object?>{
                'user_id': 'user-multi',
                'email': 'multi@example.test',
                'display_name': 'Multi Grant',
                'role_id': 'role-owner',
                'role_label': 'Owner',
                'status': 'active',
                'mfa_enrolled': true,
                'user_role_id': 'grant-op-wide',
                'grants': <Object?>[
                  <String, Object?>{
                    'user_role_id': 'grant-op-wide',
                    'role_id': 'role-owner',
                    'role_label': 'Owner',
                    'scope_type': 'operator_wide',
                    'effective_location_ids': const <String>[],
                  },
                  <String, Object?>{
                    'user_role_id': 'grant-org-east',
                    'role_id': 'role-manager',
                    'role_label': 'Manager',
                    'scope_type': 'org_unit',
                    'org_unit_id': 'unit-east',
                    'source_org_unit_id': 'unit-east',
                    'effective_location_ids': <String>[
                      'loc-vancouver',
                      'loc-burnaby',
                    ],
                  },
                  <String, Object?>{
                    'user_role_id': 'grant-loc-1',
                    'role_id': 'role-supervisor',
                    'role_label': 'Supervisor',
                    'scope_type': 'location',
                    'location_id': 'loc-vancouver',
                    'effective_location_ids': <String>['loc-vancouver'],
                  },
                ],
              },
            ],
          },
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final listed = await gateway.listUsers(
        const TeamUserListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );

      expect(listed.users, hasLength(1));
      final user = listed.users.single;
      expect(user.grants, hasLength(3));
      final byScope = <String, TeamGrantSnapshot>{
        for (final grant in user.grants) grant.scopeType: grant,
      };
      expect(byScope.keys.toSet(), <String>{
        'operator_wide',
        'org_unit',
        'location',
      });
      expect(byScope['operator_wide']!.userRoleId, equals('grant-op-wide'));
      // Authoritative role labels round-trip — clients never have to
      // wait on a separate role-catalog load to label per-grant rows.
      expect(byScope['operator_wide']!.roleLabel, equals('Owner'));
      expect(byScope['org_unit']!.orgUnitId, equals('unit-east'));
      expect(byScope['org_unit']!.roleLabel, equals('Manager'));
      expect(
        byScope['org_unit']!.effectiveLocationIds,
        equals(<String>['loc-vancouver', 'loc-burnaby']),
      );
      expect(byScope['location']!.locationId, equals('loc-vancouver'));
      expect(byScope['location']!.roleLabel, equals('Supervisor'));
    });

    test(
      'older proxies that omit role_label deserialize to grants with '
      'roleLabel = null (forward-compat)',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          getResponse: ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'users': <Object?>[
                <String, Object?>{
                  'user_id': 'user-1',
                  'email': 'jane@example.test',
                  'display_name': 'Jane Owner',
                  'role_id': 'role-1',
                  'role_label': 'Owner',
                  'status': 'active',
                  'mfa_enrolled': true,
                  'user_role_id': 'grant-1',
                  'grants': <Object?>[
                    <String, Object?>{
                      'user_role_id': 'grant-1',
                      'role_id': 'role-1',
                      // role_label intentionally omitted.
                      'scope_type': 'operator_wide',
                    },
                  ],
                },
              ],
            },
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final listed = await gateway.listUsers(
          const TeamUserListCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );

        // Field is nullable so older proxies that haven't rolled out
        // the additive label still deserialize cleanly.
        expect(listed.users.single.grants.single.roleLabel, isNull);
      },
    );

    test(
      'listUsers backward-compat: response without grants yields empty list',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          getResponse: ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'users': <Object?>[
                <String, Object?>{
                  'user_id': 'user-1',
                  'email': 'jane@example.test',
                  'display_name': 'Jane Owner',
                  'role_id': 'role-1',
                  'role_label': 'Owner',
                  'status': 'active',
                  'mfa_enrolled': true,
                  'user_role_id': 'grant-1',
                },
              ],
            },
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final listed = await gateway.listUsers(
          const TeamUserListCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );

        expect(listed.users.single.grants, isEmpty);
      },
    );

    test(
      'malformed grants array raises ProxyAuthOperationsError',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          getResponse: ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'users': <Object?>[
                <String, Object?>{
                  'user_id': 'user-1',
                  'email': 'jane@example.test',
                  'display_name': 'Jane',
                  'role_id': 'role-1',
                  'role_label': 'Owner',
                  'status': 'active',
                  'mfa_enrolled': false,
                  'grants': 'not-a-list',
                },
              ],
            },
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        await expectLater(
          gateway.listUsers(
            const TeamUserListCommand(
              actorUserId: 'actor',
              operatorId: 'op',
              locationId: 'loc',
            ),
          ),
          throwsA(isA<ProxyAuthOperationsError>()),
        );
      },
    );
  });
}

class _FakeAuthOpsHttpClient implements ProxyAuthOperationsHttpClient {
  _FakeAuthOpsHttpClient({required ProxyAuthOperationsResponse getResponse})
    : _getResponse = getResponse;

  final ProxyAuthOperationsResponse _getResponse;

  @override
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    return _getResponse;
  }

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw UnimplementedError('not exercised by this test');
  }

  @override
  Future<ProxyAuthOperationsResponse> patchJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw UnimplementedError('not exercised by this test');
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw UnimplementedError('not exercised by this test');
  }
}
