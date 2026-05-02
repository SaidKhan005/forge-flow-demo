// L5 follow-up - ProxyMfaRecoveryRequestGateway boundary-contract tests.
//
// Closes the proxy adapter coverage gap from POST_HARDENING_FOLLOWUPS P2.
// Mirrors the fake-HTTP pattern from
// test/proxy_mfa_operations_gateway_test.dart so the suite stays consistent.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';
import 'package:forge_and_flow/services/mfa/proxy_mfa_recovery_request_gateway.dart';

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyMfaRecoveryRequestGateway', () {
    test(
      '202 + queued=true propagates request_id and posts to recovery path',
      () async {
        final fake = _FakeMfaHttpClient(
          response: const ProxyAuthOperationsResponse(
            statusCode: 202,
            body: <String, Object?>{
              'queued': true,
              'request_id': 'recovery-request-1',
            },
          ),
        );
        final gateway = ProxyMfaRecoveryRequestGateway(
          proxyBaseUri: baseUri,
          httpClient: fake,
        );

        final result = await gateway.requestRecovery(
          const MfaRecoveryRequestCommand(email: 'locked@example.test'),
        );

        expect(result.queued, isTrue);
        expect(result.requestId, equals('recovery-request-1'));
        final call = fake.posts.single;
        expect(
          call.url.toString(),
          equals(
            'https://forge-flow-proxy.example.com/v1/auth/mfa/recovery/request',
          ),
        );
        expect(
          call.url.path,
          equals(ProxyMfaRecoveryRequestGateway.recoveryRequestPath),
        );
        expect(call.body['email'], equals('locked@example.test'));
        expect(call.body['reason'], equals('mfa_challenge_no_factor_access'));
      },
    );

    test(
      '202 + queued=false (silent acceptance) returns null request_id',
      () async {
        final fake = _FakeMfaHttpClient(
          response: const ProxyAuthOperationsResponse(
            statusCode: 202,
            body: <String, Object?>{'queued': false},
          ),
        );
        final gateway = ProxyMfaRecoveryRequestGateway(
          proxyBaseUri: baseUri,
          httpClient: fake,
        );

        final result = await gateway.requestRecovery(
          const MfaRecoveryRequestCommand(email: 'unknown@example.test'),
        );

        expect(result.queued, isFalse);
        expect(result.requestId, isNull);
      },
    );

    test('202 with missing queued field defaults to queued=false', () async {
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 202,
          body: <String, Object?>{},
        ),
      );
      final gateway = ProxyMfaRecoveryRequestGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'locked@example.test'),
      );

      expect(result.queued, isFalse);
      expect(result.requestId, isNull);
    });

    test('202 with non-bool queued ("true" string) resolves to false', () async {
      // Strict equality — only literal `true` flips queued. Defends against
      // proxy responses that accidentally serialize bools as strings.
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 202,
          body: <String, Object?>{'queued': 'true'},
        ),
      );
      final gateway = ProxyMfaRecoveryRequestGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'locked@example.test'),
      );

      expect(result.queued, isFalse);
    });

    test('202 with non-string request_id returns null requestId', () async {
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 202,
          body: <String, Object?>{'queued': true, 'request_id': 12345},
        ),
      );
      final gateway = ProxyMfaRecoveryRequestGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'locked@example.test'),
      );

      expect(result.queued, isTrue);
      expect(result.requestId, isNull);
    });

    test('202 with whitespace-only request_id trims to null', () async {
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 202,
          body: <String, Object?>{'queued': true, 'request_id': '   '},
        ),
      );
      final gateway = ProxyMfaRecoveryRequestGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'locked@example.test'),
      );

      expect(result.queued, isTrue);
      expect(result.requestId, isNull);
    });

    test(
      'non-202 maps to MfaRecoveryRequestRejected with code/message/statusCode',
      () async {
        final fake = _FakeMfaHttpClient(
          response: const ProxyAuthOperationsResponse(
            statusCode: 400,
            body: <String, Object?>{
              'error': 'invalid_email',
              'message': 'Enter a valid email address.',
            },
          ),
        );
        final gateway = ProxyMfaRecoveryRequestGateway(
          proxyBaseUri: baseUri,
          httpClient: fake,
        );

        final error = await _captureError(
          gateway.requestRecovery(
            const MfaRecoveryRequestCommand(email: 'invalid'),
          ),
        );

        expect(error, isA<MfaRecoveryRequestRejected>());
        final rejected = error! as MfaRecoveryRequestRejected;
        expect(rejected.code, equals('invalid_email'));
        expect(rejected.message, equals('Enter a valid email address.'));
        expect(rejected.statusCode, equals(400));
      },
    );

    test(
      'non-202 with empty body falls back to mfa_recovery_failed default',
      () async {
        final fake = _FakeMfaHttpClient(
          response: const ProxyAuthOperationsResponse(
            statusCode: 503,
            body: <String, Object?>{},
          ),
        );
        final gateway = ProxyMfaRecoveryRequestGateway(
          proxyBaseUri: baseUri,
          httpClient: fake,
        );

        final error = await _captureError(
          gateway.requestRecovery(
            const MfaRecoveryRequestCommand(email: 'locked@example.test'),
          ),
        );

        expect(error, isA<MfaRecoveryRequestRejected>());
        final rejected = error! as MfaRecoveryRequestRejected;
        expect(rejected.code, equals('mfa_recovery_failed'));
        expect(rejected.message, equals('MFA recovery request failed.'));
        expect(rejected.statusCode, equals(503));
      },
    );

    test(
      'non-202 with non-string error and whitespace message uses defaults',
      () async {
        final fake = _FakeMfaHttpClient(
          response: const ProxyAuthOperationsResponse(
            statusCode: 422,
            body: <String, Object?>{'error': 12345, 'message': '   '},
          ),
        );
        final gateway = ProxyMfaRecoveryRequestGateway(
          proxyBaseUri: baseUri,
          httpClient: fake,
        );

        final error = await _captureError(
          gateway.requestRecovery(
            const MfaRecoveryRequestCommand(email: 'locked@example.test'),
          ),
        );

        expect(error, isA<MfaRecoveryRequestRejected>());
        final rejected = error! as MfaRecoveryRequestRejected;
        expect(rejected.code, equals('mfa_recovery_failed'));
        expect(rejected.message, equals('MFA recovery request failed.'));
        expect(rejected.statusCode, equals(422));
      },
    );

    test('forwards a custom reason verbatim', () async {
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 202,
          body: <String, Object?>{'queued': true},
        ),
      );
      final gateway = ProxyMfaRecoveryRequestGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(
          email: 'user@example.test',
          reason: 'mfa_challenge_lost_device',
        ),
      );

      expect(
        fake.posts.single.body['reason'],
        equals('mfa_challenge_lost_device'),
      );
    });

    test('forwards email verbatim without client-side normalization', () async {
      // Normalization is the proxy's job (RepositoryMfaRecoveryRequestGateway
      // lowercases + trims server-side). The thin client must not pre-empt.
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 202,
          body: <String, Object?>{'queued': true},
        ),
      );
      final gateway = ProxyMfaRecoveryRequestGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'Locked@Example.TEST  '),
      );

      expect(
        fake.posts.single.body['email'],
        equals('Locked@Example.TEST  '),
      );
    });

    test('does not inject Authorization header (pre-auth surface)', () async {
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 202,
          body: <String, Object?>{'queued': true},
        ),
      );
      final gateway = ProxyMfaRecoveryRequestGateway(
        proxyBaseUri: baseUri,
        httpClient: fake,
      );

      await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'locked@example.test'),
      );

      expect(fake.posts.single.headers, isEmpty);
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

class _FakeMfaHttpClient implements ProxyAuthOperationsHttpClient {
  _FakeMfaHttpClient({required this.response});

  final ProxyAuthOperationsResponse response;
  final posts = <_CapturedMfaCall>[];

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
    posts.add(_CapturedMfaCall(url, headers, body));
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
  }) {
    throw StateError('not used');
  }
}

class _CapturedMfaCall {
  const _CapturedMfaCall(this.url, this.headers, this.body);

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
