// Phase 9 live-closeout - ProxyAuthOperationsGateway tests.
//
// Covers the app-side client for `/v1/admin/auth/*` Team/user-management
// routes. No live HTTP; every test injects a fake transport.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';

import '../tool/advisor_proxy/advisor_proxy.dart' as proxy;

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyAuthOperationsGateway', () {
    test(
      'createInvite POSTs narrow payload and parses invite response',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          postResponse: ProxyAuthOperationsResponse(
            statusCode: 201,
            body: <String, Object?>{
              'invite_id': 'invite-1',
              'expires_at': DateTime.utc(2026, 5, 5, 12).toIso8601String(),
            },
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
          idempotencyKeyFactory: () => 'idem-1',
        );

        final created = await gateway.createInvite(
          const TeamInviteCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            email: 'new.user@example.test',
            roleId: 'operator_staff',
            scopeType: 'operator_wide',
          ),
        );

        expect(created.inviteId, equals('invite-1'));
        final call = fake.posts.single;
        expect(call.url.path, equals(proxy.adminAuthInvitesPath));
        expect(
          call.headers[HttpHeaders.authorizationHeader],
          equals('Bearer id-token'),
        );
        expect(call.headers['Idempotency-Key'], equals('idem-1'));
        expect(
          call.body,
          equals(<String, Object?>{
            'email': 'new.user@example.test',
            'role_id': 'operator_staff',
            'scope_type': 'operator_wide',
          }),
        );
      },
    );

    test('createInvite maps proxy rejection to narrow error code', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 403,
          body: <String, Object?>{
            'error': 'permission_denied',
            'message': 'permission denied',
          },
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final thrown = await _captureError(
        gateway.createInvite(
          const TeamInviteCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            email: 'new.user@example.test',
            roleId: 'operator_staff',
            scopeType: 'operator_wide',
          ),
        ),
      );

      expect(thrown, isA<ProxyAuthOperationsError>());
      final error = thrown! as ProxyAuthOperationsError;
      expect(error.code, equals('permission_denied'));
      expect(error.statusCode, equals(403));
    });

    test('missing ID token fails before network', () async {
      final fake = _FakeAuthOpsHttpClient();
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => null,
        httpClient: fake,
      );

      final thrown = await _captureError(
        gateway.requestPasswordReset(
          const TeamPasswordResetCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            targetUserId: 'target',
          ),
        ),
      );

      expect(thrown, isA<ProxyAuthOperationsError>());
      expect((thrown! as ProxyAuthOperationsError).code, equals('no_id_token'));
      expect(fake.posts, isEmpty);
      expect(fake.deletes, isEmpty);
    });

    test('requestPasswordReset targets the admin user reset route', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true},
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      await gateway.requestPasswordReset(
        const TeamPasswordResetCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetUserId: 'target-user',
        ),
      );

      final call = fake.posts.single;
      expect(
        call.url.path,
        equals('${proxy.adminAuthUsersPrefix}target-user/reset-password'),
      );
      expect(call.body, isEmpty);
    });

    test(
      'createRoleGrant and revokeRoleGrant use the route contract',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          postResponse: const ProxyAuthOperationsResponse(
            statusCode: 201,
            body: <String, Object?>{'user_role_id': 'grant-1'},
          ),
          deleteResponse: const ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{'ok': true, 'revoked': true},
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final created = await gateway.createRoleGrant(
          const TeamRoleGrantCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            targetUserId: 'target-user',
            roleId: 'role-1',
            scopeType: 'location',
            targetLocationId: 'loc-a',
            reason: 'promotion',
          ),
        );
        final revoked = await gateway.revokeRoleGrant(
          const TeamRoleGrantRevokeCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            userRoleId: 'grant-1',
            targetUserId: 'target-user',
            reason: 'changed role',
          ),
        );

        expect(created.userRoleId, equals('grant-1'));
        expect(revoked.revoked, isTrue);
        expect(
          fake.posts.single.url.path,
          equals(proxy.adminAuthRoleGrantsPath),
        );
        expect(fake.posts.single.body['location_id'], equals('loc-a'));
        expect(
          fake.deletes.single.url.path,
          equals('${proxy.adminAuthRoleGrantPrefix}grant-1'),
        );
        expect(fake.deletes.single.body['user_id'], equals('target-user'));
      },
    );

    test('transport failures collapse to transport_error', () async {
      final fake = _FakeAuthOpsHttpClient.throws(StateError('secret://dsn'));
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final thrown = await _captureError(
        gateway.requestPasswordReset(
          const TeamPasswordResetCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            targetUserId: 'target',
          ),
        ),
      );

      expect(thrown, isA<ProxyAuthOperationsError>());
      final error = thrown! as ProxyAuthOperationsError;
      expect(error.code, equals('transport_error'));
      expect(error.message.contains('secret://dsn'), isFalse);
    });
  });
}

Future<Object?> _captureError(Future<void> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

class _FakeAuthOpsHttpClient implements ProxyAuthOperationsHttpClient {
  _FakeAuthOpsHttpClient({
    ProxyAuthOperationsResponse? postResponse,
    ProxyAuthOperationsResponse? deleteResponse,
  }) : _postResponse =
           postResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'ok': true},
           ),
       _deleteResponse =
           deleteResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'ok': true, 'revoked': true},
           );

  _FakeAuthOpsHttpClient.throws(Object error)
    : _postResponse = null,
      _deleteResponse = null,
      _error = error;

  final ProxyAuthOperationsResponse? _postResponse;
  final ProxyAuthOperationsResponse? _deleteResponse;
  Object? _error;

  final List<_CapturedAuthOpsCall> posts = <_CapturedAuthOpsCall>[];
  final List<_CapturedAuthOpsCall> deletes = <_CapturedAuthOpsCall>[];

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    if (_error != null) throw _error!;
    posts.add(_CapturedAuthOpsCall(url: url, headers: headers, body: body));
    return _postResponse!;
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    if (_error != null) throw _error!;
    deletes.add(_CapturedAuthOpsCall(url: url, headers: headers, body: body));
    return _deleteResponse!;
  }
}

class _CapturedAuthOpsCall {
  const _CapturedAuthOpsCall({
    required this.url,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
