// Phase 9.UX.7 - ProxyPasswordResetGateway tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/password_reset_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_password_reset_gateway.dart';

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyPasswordResetGateway.requestReset', () {
    test('posts the email to /v1/auth/password/reset/request', () async {
      final fake = _FakePasswordResetHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true},
        ),
      );
      final gateway = ProxyPasswordResetGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
        idempotencyKeyFactory: () => 'idem-req',
      );

      await gateway.requestReset(
        const PasswordResetRequestCommand(email: 'demo@forgeflow.test'),
      );

      final call = fake.posts.single;
      expect(
        call.url.path,
        equals(ProxyPasswordResetGateway.requestPath),
      );
      expect(call.headers['Idempotency-Key'], equals('idem-req'));
      expect(call.body['email'], equals('demo@forgeflow.test'));
    });

    test(
      'forwards a caller-supplied Idempotency-Key instead of generating one',
      () async {
        final fake = _FakePasswordResetHttpClient(
          response: const ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{'ok': true},
          ),
        );
        final gateway = ProxyPasswordResetGateway(
          proxyBaseUri: baseUri,
          httpClient: fake,
          idempotencyKeyFactory: () =>
              fail('factory must not run when caller supplies a key'),
        );

        await gateway.requestReset(
          const PasswordResetRequestCommand(
            email: 'demo@forgeflow.test',
            idempotencyKey: 'screen-owned-key',
          ),
        );

        expect(
          fake.posts.single.headers['Idempotency-Key'],
          equals('screen-owned-key'),
        );
      },
    );

    test('treats 202 as success (queued)', () async {
      final fake = _FakePasswordResetHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 202,
          body: <String, Object?>{},
        ),
      );
      final gateway = ProxyPasswordResetGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final result = await gateway.requestReset(
        const PasswordResetRequestCommand(email: 'demo@forgeflow.test'),
      );

      expect(result, isA<PasswordResetRequested>());
    });

    test('maps 429 to rate_limited rejection', () async {
      final fake = _FakePasswordResetHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 429,
          body: <String, Object?>{
            'error': 'rate_limited',
            'message': 'too many',
          },
        ),
      );
      final gateway = ProxyPasswordResetGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final error = await _captureError(
        gateway.requestReset(
          const PasswordResetRequestCommand(email: 'demo@forgeflow.test'),
        ),
      );

      expect(error, isA<PasswordResetRejected>());
      final rejected = error! as PasswordResetRejected;
      expect(rejected.code, equals('rate_limited'));
      expect(rejected.statusCode, equals(429));
    });

    test('non-200 maps to PasswordResetRejected with proxy error code',
        () async {
      final fake = _FakePasswordResetHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 503,
          body: <String, Object?>{
            'error': 'password_reset_unavailable',
            'message': 'try again later',
          },
        ),
      );
      final gateway = ProxyPasswordResetGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final error = await _captureError(
        gateway.requestReset(
          const PasswordResetRequestCommand(email: 'demo@forgeflow.test'),
        ),
      );

      expect(error, isA<PasswordResetRejected>());
      final rejected = error! as PasswordResetRejected;
      expect(rejected.code, equals('password_reset_unavailable'));
      expect(rejected.statusCode, equals(503));
    });
  });

  group('ProxyPasswordResetGateway.confirmReset', () {
    test('posts oob_code + new_password to /confirm', () async {
      final fake = _FakePasswordResetHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'hibp_unavailable': false},
        ),
      );
      final gateway = ProxyPasswordResetGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
        idempotencyKeyFactory: () => 'idem-confirm',
      );

      final result = await gateway.confirmReset(
        const PasswordResetConfirmRequest(
          oobCode: 'oob-123',
          newPassword: 'fresh-secret-2026',
        ),
      );

      expect(result.hibpUnavailable, isFalse);
      final call = fake.posts.single;
      expect(call.url.path, equals(ProxyPasswordResetGateway.confirmPath));
      expect(call.headers['Idempotency-Key'], equals('idem-confirm'));
      expect(call.body['oob_code'], equals('oob-123'));
      expect(call.body['new_password'], equals('fresh-secret-2026'));
    });

    test(
      'forwards a caller-supplied Idempotency-Key on /confirm so a UI '
      'retry replays the cached 200 instead of burning the oobCode',
      () async {
        final fake = _FakePasswordResetHttpClient(
          response: const ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{'ok': true},
          ),
        );
        final gateway = ProxyPasswordResetGateway(
          proxyBaseUri: baseUri,
          httpClient: fake,
          idempotencyKeyFactory: () =>
              fail('factory must not run when caller supplies a key'),
        );

        await gateway.confirmReset(
          const PasswordResetConfirmRequest(
            oobCode: 'oob-456',
            newPassword: 'fresh-secret-2026',
            idempotencyKey: 'screen-owned-confirm-key',
          ),
        );

        expect(
          fake.posts.single.headers['Idempotency-Key'],
          equals('screen-owned-confirm-key'),
        );
      },
    );

    test('preserves hibp_unavailable flag from proxy response', () async {
      final fake = _FakePasswordResetHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'hibp_unavailable': true},
        ),
      );
      final gateway = ProxyPasswordResetGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final result = await gateway.confirmReset(
        const PasswordResetConfirmRequest(
          oobCode: 'oob-456',
          newPassword: 'fresh-secret-2026',
        ),
      );

      expect(result.hibpUnavailable, isTrue);
    });

    test('maps policy/HIBP/history rejections with rejection codes', () async {
      final fake = _FakePasswordResetHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 422,
          body: <String, Object?>{
            'error': 'password_pwned',
            'message': 'Choose a password that has not appeared in a breach.',
            'rejections': <String>['pwned_in_breach'],
          },
        ),
      );
      final gateway = ProxyPasswordResetGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final error = await _captureError(
        gateway.confirmReset(
          const PasswordResetConfirmRequest(
            oobCode: 'oob-456',
            newPassword: 'leaked-password',
          ),
        ),
      );

      expect(error, isA<PasswordResetRejected>());
      final rejected = error! as PasswordResetRejected;
      expect(rejected.code, equals('password_pwned'));
      expect(rejected.statusCode, equals(422));
      expect(rejected.rejections, equals(<String>['pwned_in_breach']));
    });

    test('history reuse rejection surfaces reused_from_history', () async {
      final fake = _FakePasswordResetHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 422,
          body: <String, Object?>{
            'error': 'password_reused',
            'message': 'Choose another password.',
            'rejections': <String>['reused_from_history'],
          },
        ),
      );
      final gateway = ProxyPasswordResetGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final error = await _captureError(
        gateway.confirmReset(
          const PasswordResetConfirmRequest(
            oobCode: 'oob-456',
            newPassword: 'old-secret-2026',
          ),
        ),
      );

      expect(error, isA<PasswordResetRejected>());
      final rejected = error! as PasswordResetRejected;
      expect(rejected.code, equals('password_reused'));
      expect(rejected.rejections, equals(<String>['reused_from_history']));
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

class _FakePasswordResetHttpClient implements ProxyAuthOperationsHttpClient {
  _FakePasswordResetHttpClient({
    this.response = const ProxyAuthOperationsResponse(
      statusCode: 200,
      body: <String, Object?>{'ok': true},
    ),
  });

  final ProxyAuthOperationsResponse response;
  final posts = <_CapturedPasswordResetCall>[];

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
    posts.add(_CapturedPasswordResetCall(url, headers, body));
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

class _CapturedPasswordResetCall {
  const _CapturedPasswordResetCall(this.url, this.headers, this.body);

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
