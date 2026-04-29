// Phase 9 live-closeout - ProxyPasswordChangeGateway tests.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_password_change_gateway.dart';

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyPasswordChangeGateway', () {
    test('posts signed-in password-change payload', () async {
      final fake = _FakePasswordChangeHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'hibp_unavailable': false},
        ),
      );
      final gateway = ProxyPasswordChangeGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
        idempotencyKeyFactory: () => 'idem-1',
      );

      final result = await gateway.changePassword(
        const PasswordChangeCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          currentPassword: 'old-secret',
          newPassword: 'new-secret',
        ),
      );

      expect(result.hibpUnavailable, isFalse);
      final call = fake.posts.single;
      expect(call.url.path, equals(ProxyPasswordChangeGateway.changePath));
      expect(
        call.headers[HttpHeaders.authorizationHeader],
        equals('Bearer id-token'),
      );
      expect(call.headers['Idempotency-Key'], equals('idem-1'));
      expect(call.body['current_password'], equals('old-secret'));
      expect(call.body['new_password'], equals('new-secret'));
    });

    test('maps proxy rejection to PasswordChangeRejected', () async {
      final fake = _FakePasswordChangeHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 422,
          body: <String, Object?>{
            'error': 'password_reused',
            'message': 'Choose another password.',
            'rejections': <String>['reused_from_history'],
          },
        ),
      );
      final gateway = ProxyPasswordChangeGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final error = await _captureError(
        gateway.changePassword(
          const PasswordChangeCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            currentPassword: 'old-secret',
            newPassword: 'new-secret',
          ),
        ),
      );

      expect(error, isA<PasswordChangeRejected>());
      final rejected = error! as PasswordChangeRejected;
      expect(rejected.code, equals('password_reused'));
      expect(rejected.statusCode, equals(422));
      expect(rejected.rejections, equals(<String>['reused_from_history']));
    });

    test('missing ID token fails before network', () async {
      final fake = _FakePasswordChangeHttpClient();
      final gateway = ProxyPasswordChangeGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => null,
        httpClient: fake,
      );

      final error = await _captureError(
        gateway.changePassword(
          const PasswordChangeCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            currentPassword: 'old-secret',
            newPassword: 'new-secret',
          ),
        ),
      );

      expect(error, isA<PasswordChangeRejected>());
      expect((error! as PasswordChangeRejected).code, equals('no_id_token'));
      expect(fake.posts, isEmpty);
    });
  });
}

Future<Object?> _captureError(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

class _FakePasswordChangeHttpClient implements ProxyAuthOperationsHttpClient {
  _FakePasswordChangeHttpClient({
    this.response = const ProxyAuthOperationsResponse(
      statusCode: 200,
      body: <String, Object?>{'ok': true},
    ),
  });

  final ProxyAuthOperationsResponse response;
  final posts = <_CapturedPasswordChangeCall>[];

  @override
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) {
    throw StateError('not used');
  }

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    posts.add(_CapturedPasswordChangeCall(url, headers, body));
    return response;
  }

  @override
  Future<ProxyAuthOperationsResponse> patchJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    throw StateError('not used');
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw StateError('not used');
  }
}

class _CapturedPasswordChangeCall {
  const _CapturedPasswordChangeCall(this.url, this.headers, this.body);

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
