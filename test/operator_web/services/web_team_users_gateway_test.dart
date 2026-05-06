// Phase 11W.1 - Live team-users HTTP gateway wire test.
//
// Pins the route paths + idempotency-key header shape the
// `WebTeamUsersGatewayLive` impl sends across the wire. Uses
// `MockClient` from `package:http` so the test runs in pure Dart
// (no real network).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/web_team_users_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

void main() {
  final Uri kProxyBase = Uri.parse('https://proxy.forgeflow.test');

  Future<String?> tokenProvider() async => 'test-id-token';

  group('WebTeamUsersGatewayLive', () {
    test('listUsers GETs /v1/auth/team/users with bearer token + no '
        'idempotency key', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'users': <Map<String, Object?>>[
              <String, Object?>{
                'user_id': 'u1',
                'email': 'u1@example.test',
                'display_name': 'User One',
                'role_id': 'r1',
                'role_label': 'Owner',
                'status': 'active',
                'mfa_enrolled': true,
              },
            ],
          }),
          200,
        );
      });
      final gateway = WebTeamUsersGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      final result = await gateway.listUsers(
        const TeamUserListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );

      expect(result.users, hasLength(1));
      expect(result.users.first.userId, 'u1');
      expect(captured.method, 'GET');
      expect(captured.url.scheme, 'https');
      expect(captured.url.host, 'proxy.forgeflow.test');
      expect(captured.url.path, WebTeamUsersPaths.users);
      expect(captured.headers['authorization'], 'Bearer test-id-token');
      // Reads do not carry idempotency keys.
      expect(captured.headers.containsKey('Idempotency-Key'), isFalse);
    });

    test('createInvite POSTs /v1/auth/team/invites with the screen-supplied '
        'idempotency key threaded through', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'invite_id': 'invite-99',
            'expires_at': '2026-05-12T17:00:00Z',
          }),
          201,
        );
      });
      final gateway = WebTeamUsersGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      final created = await gateway.createInvite(
        const TeamInviteCreateCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          email: 'new@example.test',
          roleId: 'r1',
          scopeType: 'location',
          targetLocationId: 'loc',
        ),
        idempotencyKey: 'op-web-members-uid-123-1',
      );

      expect(created.inviteId, 'invite-99');
      expect(captured.method, 'POST');
      expect(captured.url.path, WebTeamUsersPaths.invites);
      expect(captured.headers['Idempotency-Key'], 'op-web-members-uid-123-1');
      expect(captured.headers['authorization'], 'Bearer test-id-token');
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      expect(body['email'], 'new@example.test');
      expect(body['role_id'], 'r1');
      expect(body['scope_type'], 'location');
      expect(body['location_id'], 'loc');
    });

    test('suspendUser POSTs to /v1/auth/team/users/{id}/suspend', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'updated': true}),
          200,
        );
      });
      final gateway = WebTeamUsersGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      final result = await gateway.suspendUser(
        const TeamUserStatusCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetUserId: 'u-suspend-me',
          reason: 'op_web_members_suspend',
        ),
        idempotencyKey: 'idem-suspend-1',
      );

      expect(result.updated, isTrue);
      expect(captured.method, 'POST');
      expect(
        captured.url.path,
        WebTeamUsersPaths.userAction('u-suspend-me', 'suspend'),
      );
      expect(captured.headers['Idempotency-Key'], 'idem-suspend-1');
    });

    test(
      'non-2xx response surfaces a WebTeamUsersError with the proxy code',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'forbidden',
              'message': 'Caller is not allowed',
            }),
            403,
          );
        });
        final gateway = WebTeamUsersGatewayLive(
          proxyBaseUri: kProxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        await expectLater(
          gateway.listUsers(
            const TeamUserListCommand(
              actorUserId: 'actor',
              operatorId: 'op',
              locationId: 'loc',
            ),
          ),
          throwsA(
            isA<WebTeamUsersError>()
                .having((e) => e.code, 'code', 'forbidden')
                .having((e) => e.statusCode, 'statusCode', 403),
          ),
        );
      },
    );

    test('the gateway never mints its own idempotency key - the caller key '
        'is sent verbatim on every retry', () async {
      final captured = <http.Request>[];
      final client = MockClient((request) async {
        captured.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{'updated': true}),
          200,
        );
      });
      final gateway = WebTeamUsersGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );
      const cmd = TeamUserStatusCommand(
        actorUserId: 'actor',
        operatorId: 'op',
        locationId: 'loc',
        targetUserId: 'u-replay',
        reason: 'replay',
      );
      const key = 'caller-supplied-replay-key';
      await gateway.suspendUser(cmd, idempotencyKey: key);
      await gateway.suspendUser(cmd, idempotencyKey: key);
      expect(captured, hasLength(2));
      expect(captured[0].headers['Idempotency-Key'], key);
      expect(captured[1].headers['Idempotency-Key'], key);
    });

    test(
      'missing id token throws no_id_token error before any HTTP call',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls += 1;
          return http.Response('{}', 200);
        });
        final gateway = WebTeamUsersGatewayLive(
          proxyBaseUri: kProxyBase,
          idTokenProvider: () async => null,
          httpClient: client,
        );

        await expectLater(
          gateway.listUsers(
            const TeamUserListCommand(
              actorUserId: 'actor',
              operatorId: 'op',
              locationId: 'loc',
            ),
          ),
          throwsA(
            isA<WebTeamUsersError>().having(
              (e) => e.code,
              'code',
              'no_id_token',
            ),
          ),
        );
        expect(calls, 0);
      },
    );
  });
}
