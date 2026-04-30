// Phase 9 live-closeout - ProxyMfaOperationsGateway tests.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/proxy_mfa_operations_gateway.dart';

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyMfaOperationsGateway', () {
    test('beginTotpEnrollment posts user email and parses setup', () async {
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'factor_id': 'factor-session-1',
            'secret_base32': 'JBSWY3DPEHPK3PXP',
            'otp_auth_url': 'otpauth://totp/Forge:user@example.test',
          },
        ),
      );
      final gateway = ProxyMfaOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final setup = await gateway.beginTotpEnrollment(
        const MfaTotpBeginCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          userEmail: 'user@example.test',
          issuerName: 'Forge & Flow',
        ),
      );

      expect(setup.factorId, equals('factor-session-1'));
      final call = fake.posts.single;
      expect(call.url.path, equals(ProxyMfaOperationsGateway.totpBeginPath));
      expect(
        call.headers[HttpHeaders.authorizationHeader],
        equals('Bearer id-token'),
      );
      expect(call.body['user_email'], equals('user@example.test'));
    });

    test('confirmTotpEnrollment parses display-once recovery codes', () async {
      final fake = _FakeMfaHttpClient(
        response: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'factor_id': 'totp-db-factor',
            'recovery_codes': <String>['ABCD-EFGH-JKMN'],
          },
        ),
      );
      final gateway = ProxyMfaOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final result = await gateway.confirmTotpEnrollment(
        const MfaTotpConfirmCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          factorId: 'factor-session-1',
          oneTimeCode: '123456',
          issuerName: 'Forge & Flow',
        ),
      );

      expect(result.factorId, equals('totp-db-factor'));
      expect(result.recoveryCodesPlaintext, equals(<String>['ABCD-EFGH-JKMN']));
      expect(
        fake.posts.single.url.path,
        equals(ProxyMfaOperationsGateway.totpConfirmPath),
      );
    });

    test(
      'non-200 response maps to MfaOperationRejected with retry metadata',
      () async {
        final retryAt = DateTime.utc(2026, 4, 28, 12, 1);
        final fake = _FakeMfaHttpClient(
          response: ProxyAuthOperationsResponse(
            statusCode: 429,
            body: <String, Object?>{
              'error': 'recovery_code_rate_limited',
              'message': 'Too many attempts.',
              'retry_after': retryAt.toIso8601String(),
            },
          ),
        );
        final gateway = ProxyMfaOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final error = await _captureError(
          gateway.consumeRecoveryCode(
            const RecoveryCodeConsumeCommand(
              actorUserId: 'actor',
              operatorId: 'op',
              locationId: 'loc',
              rawCode: 'ABCD-EFGH-JKMN',
            ),
          ),
        );

        expect(error, isA<MfaOperationRejected>());
        final rejected = error! as MfaOperationRejected;
        expect(rejected.code, equals('recovery_code_rate_limited'));
        expect(rejected.retryAfter, equals(retryAt));
      },
    );

    test(
      'listFactors posts to factor list path and parses summaries',
      () async {
        final enrolledAt = DateTime.utc(2026, 4, 30, 12);
        final fake = _FakeMfaHttpClient(
          response: ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'factors': <Map<String, Object?>>[
                <String, Object?>{
                  'factor_id': 'totp-db-factor',
                  'factor_type': 'totp',
                  'enrolled_at': enrolledAt.toIso8601String(),
                  'issuer_label': 'Forge & Flow',
                  'can_revoke': true,
                },
              ],
            },
          ),
        );
        final gateway = ProxyMfaOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final result = await gateway.listFactors(
          const MfaListFactorsCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );

        expect(result.factors.single.factorId, equals('totp-db-factor'));
        expect(result.factors.single.enrolledAt, equals(enrolledAt));
        expect(
          fake.posts.single.url.path,
          equals(ProxyMfaOperationsGateway.factorsListPath),
        );
      },
    );

    test(
      'revokeFactor posts factor id and parses delayed removal request',
      () async {
        final executeAfter = DateTime.utc(2026, 5, 1, 12);
        final fake = _FakeMfaHttpClient(
          response: ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'revoked': false,
              'request_id': 'mfa-removal-1',
              'execute_after': executeAfter.toIso8601String(),
            },
          ),
        );
        final gateway = ProxyMfaOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final result = await gateway.revokeFactor(
          const MfaRevokeFactorCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            factorId: 'totp-db-factor',
            stepUpProofId: 'fresh-proof',
          ),
        );

        expect(result.revoked, isFalse);
        expect(result.requestId, equals('mfa-removal-1'));
        expect(result.executeAfter, equals(executeAfter));
        final call = fake.posts.single;
        expect(
          call.url.path,
          equals(ProxyMfaOperationsGateway.factorsRevokePath),
        );
        expect(call.body['factor_id'], equals('totp-db-factor'));
        expect(call.body['step_up_proof_id'], equals('fresh-proof'));
      },
    );

    test('missing ID token fails before network', () async {
      final fake = _FakeMfaHttpClient();
      final gateway = ProxyMfaOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => null,
        httpClient: fake,
      );

      final error = await _captureError(
        gateway.consumeRecoveryCode(
          const RecoveryCodeConsumeCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            rawCode: 'ABCD-EFGH-JKMN',
          ),
        ),
      );

      expect(error, isA<MfaOperationRejected>());
      expect((error! as MfaOperationRejected).code, equals('no_id_token'));
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

class _FakeMfaHttpClient implements ProxyAuthOperationsHttpClient {
  _FakeMfaHttpClient({
    this.response = const ProxyAuthOperationsResponse(
      statusCode: 200,
      body: <String, Object?>{'ok': true, 'factor_id': 'factor-db-1'},
    ),
  });

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
