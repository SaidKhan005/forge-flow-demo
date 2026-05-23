// G63 — operator-web security gateway error-envelope conformance.
//
// Pins that WebSecurityGatewayLive routes its failure classification
// through the shared envelope: existing error outcomes are preserved
// (code / statusCode / rejections unchanged), the 403 freshness sentinels
// classify as mfaFreshnessRedirect, and a 409 idempotency_key_conflict on
// an idempotent boolean write is recognised as already-applied rather
// than surfaced as a hard error.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/auth/mfa_freshness_redirect_listener.dart';
import 'package:forge_and_flow/operator_web/auth/step_up_challenge_handler.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_error_envelope.dart';
import 'package:forge_and_flow/operator_web/services/web_security_gateway.dart';

void main() {
  final proxyBase = Uri.parse('https://proxy.forgeflow.test');
  Future<String?> tokenProvider() async => 'test-id-token';

  WebSecurityGatewayLive gatewayWith(MockClient client) =>
      WebSecurityGatewayLive(
        proxyBaseUri: proxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

  group('G63 security gateway envelope conformance', () {
    test(
      'cancelFactorRemoval treats a 409 idempotency_key_conflict as '
      'already-applied (cancelled == true, no throw)',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{'error': 'idempotency_key_conflict'}),
            409,
          );
        });

        final result = await gatewayWith(client).cancelFactorRemoval(
          requestId: 'removal-1',
          idempotencyKey: 'idem-cancel-replay',
        );
        expect(result.cancelled, isTrue);
      },
    );

    test(
      'requestMfaRecovery treats a 409 idempotency_key_conflict as already '
      'queued (queued == true, no throw)',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{'error': 'idempotency_key_conflict'}),
            409,
          );
        });

        final result = await gatewayWith(client).requestMfaRecovery(
          email: 'op@example.test',
          idempotencyKey: 'idem-recovery-replay',
        );
        expect(result.queued, isTrue);
      },
    );

    test(
      'a password-policy 400 still throws with code + rejections preserved '
      'and a validation kind (no regression)',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'password_policy_failed',
              'message': 'Password too weak',
              'rejections': <String>['too_short'],
            }),
            400,
          );
        });

        await expectLater(
          gatewayWith(client).changePassword(
            currentPassword: 'old',
            newPassword: 'short',
            idempotencyKey: 'idem-pw-1',
          ),
          throwsA(
            isA<WebSecurityError>()
                .having((e) => e.code, 'code', 'password_policy_failed')
                .having((e) => e.statusCode, 'statusCode', 400)
                .having((e) => e.rejections, 'rejections', <String>['too_short'])
                .having(
                  (e) => e.kind,
                  'kind',
                  OperatorWebErrorKind.validation,
                ),
          ),
        );
      },
    );

    test('a 403 mfa_freshness_required classifies as mfaFreshnessRedirect', () {
      const error = WebSecurityError(
        code: MfaFreshnessRedirectPayload.errorCode,
        message: 'fresh authentication is required',
        statusCode: 403,
      );
      expect(error.kind, OperatorWebErrorKind.mfaFreshnessRedirect);
    });

    test(
      'a 403 step-up insufficient_user_authentication classifies as '
      'mfaFreshnessRedirect (same remedy)',
      () {
        const error = WebSecurityError(
          code: kStepUpErrorCode,
          message: 'step up required',
          statusCode: 403,
        );
        expect(error.kind, OperatorWebErrorKind.mfaFreshnessRedirect);
      },
    );

    test('a plain 403 classifies as permissionDenied', () {
      const error = WebSecurityError(
        code: 'forbidden',
        message: 'nope',
        statusCode: 403,
      );
      expect(error.kind, OperatorWebErrorKind.permissionDenied);
    });
  });
}
