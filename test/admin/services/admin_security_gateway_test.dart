// Audit fix-first #7 (cross-surface parity finding G4) — admin
// self-service Security gateway tests.
//
// Pins:
//   * The HTTP gateway hits the SAME Phase 9 / 11A.1 self-service
//     proxy routes the operator-web + mobile clients use, with the
//     bearer token + a caller-stable Idempotency-Key on every
//     state-changing POST.
//   * beginTotpEnrollment sends `{user_email}` and parses
//     `{factor_id,secret_base32,otp_auth_url}`.
//   * confirmTotpEnrollment sends `{factor_id,one_time_code}` and the
//     SAME idempotency key the begin call used (the screen layer
//     supplies one stable key per enroll action — no G60 bug).
//   * changePassword sends `{current_password,new_password}` and
//     surfaces the proxy `rejections` array.
//   * requestMfaRecovery posts `{email,reason}` UNauthenticated (no
//     Authorization header) and accepts 202.
//   * listFactors parses the `/v1/auth/mfa/factors/list` row shape.
//   * Proxy 4xx/5xx surfaces as AdminSecurityGatewayError (fail-closed
//     — the screen never proceeds as if the action succeeded).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:forge_and_flow/admin/services/admin_security_gateway.dart';

void main() {
  group('HttpAdminSecurityGateway', () {
    test('listFactors posts to /v1/auth/mfa/factors/list with the bearer',
        () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming((request, _) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'factors': <Object?>[
              <String, Object?>{
                'factor_id': 'f1',
                'factor_type': 'totp',
                'enrolled_at': '2026-04-16T10:00:00Z',
                'issuer_label': 'Forge & Flow',
              },
            ],
          }))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final listed = await gateway.listFactors();

      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/auth/mfa/factors/list');
      expect(captured.headers['authorization'], 'Bearer tok');
      expect(listed.hasEnrolledFactor, isTrue);
      expect(listed.factors.single.factorId, 'f1');
    });

    test('beginTotpEnrollment sends user_email + parses the setup artifact',
        () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming((request, _) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'factor_id': 'pending-1',
            'secret_base32': 'JBSWY3DPEHPK3PXP',
            'otp_auth_url': 'otpauth://totp/FF:admin?secret=JBSWY3DPEHPK3PXP',
          }))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final enrollment = await gateway.beginTotpEnrollment(
        userEmail: 'admin@forgeflow.test',
        idempotencyKey: 'idem-enroll-1',
      );

      expect(captured.url.path, '/v1/auth/mfa/totp/begin');
      expect(captured.headers['Idempotency-Key'], 'idem-enroll-1');
      expect(
        jsonDecode(captured.body),
        <String, Object?>{'user_email': 'admin@forgeflow.test'},
      );
      expect(enrollment.factorId, 'pending-1');
      expect(enrollment.secretBase32, 'JBSWY3DPEHPK3PXP');
      expect(enrollment.otpAuthUrl, contains('otpauth://'));
    });

    test(
        'confirmTotpEnrollment reuses the SAME caller-stable key the begin '
        'action used (no fresh-key-per-call G60 bug)', () async {
      final keysByPath = <String, String>{};
      final client = http_testing.MockClient.streaming((request, _) async {
        keysByPath[request.url.path] =
            request.headers['Idempotency-Key'] ?? '';
        final body = request.url.path.endsWith('/begin')
            ? jsonEncode(<String, Object?>{
                'factor_id': 'pending-1',
                'secret_base32': 'JBSWY3DPEHPK3PXP',
                'otp_auth_url': 'otpauth://totp/FF:a?secret=JBSWY3DPEHPK3PXP',
              })
            : jsonEncode(<String, Object?>{'factor_id': 'confirmed-1'});
        return http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      // The screen mints ONE key for the whole enroll action chain.
      const actionKey = 'idem-enroll-action-1';
      await gateway.beginTotpEnrollment(
        userEmail: 'admin@forgeflow.test',
        idempotencyKey: actionKey,
      );
      final confirmed = await gateway.confirmTotpEnrollment(
        factorId: 'pending-1',
        oneTimeCode: '123456',
        idempotencyKey: actionKey,
      );

      expect(confirmed.factorId, 'confirmed-1');
      expect(keysByPath['/v1/auth/mfa/totp/begin'], actionKey);
      expect(keysByPath['/v1/auth/mfa/totp/confirm'], actionKey,
          reason:
              'Both legs of the enroll action must carry the SAME caller-'
              'stable key so a retry replays the original 2xx.');
    });

    test('changePassword posts the password fields + surfaces rejections',
        () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming((request, _) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'error': 'password_policy',
            'message': 'new password failed policy',
            'rejections': <String>['too_short', 'breached'],
          }))),
          422,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      Object? caught;
      try {
        await gateway.changePassword(
          currentPassword: 'old-secret',
          newPassword: 'short',
          idempotencyKey: 'idem-pw-1',
        );
      } catch (error) {
        caught = error;
      }

      expect(captured.url.path, '/v1/auth/password/change');
      expect(captured.headers['Idempotency-Key'], 'idem-pw-1');
      expect(jsonDecode(captured.body), <String, Object?>{
        'current_password': 'old-secret',
        'new_password': 'short',
      });
      expect(caught, isA<AdminSecurityGatewayError>());
      final err = caught! as AdminSecurityGatewayError;
      expect(err.statusCode, 422);
      expect(err.rejections, <String>['too_short', 'breached']);
    });

    test('changePassword 200 returns the hibp flag', () async {
      final client = http_testing.MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'ok': true,
            'hibp_unavailable': true,
          }))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final result = await gateway.changePassword(
        currentPassword: 'old',
        newPassword: 'a-long-enough-password-1!',
        idempotencyKey: 'idem-pw-2',
      );

      expect(result.hibpUnavailable, isTrue);
    });

    test(
        'requestMfaRecovery runs UNauthenticated, posts email+reason, '
        'accepts 202', () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming((request, _) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'ok': true,
            'queued': true,
            'request_id': 'rec-1',
          }))),
          202,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        // Even if a token is available, recovery must NOT attach it.
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final requested = await gateway.requestMfaRecovery(
        email: 'admin@forgeflow.test',
        reason: 'admin_lost_authenticator',
        idempotencyKey: 'idem-rec-1',
      );

      expect(captured.url.path, '/v1/auth/mfa/recovery/request');
      expect(captured.headers.containsKey('authorization'), isFalse,
          reason:
              'Recovery is for a locked-out admin who cannot present a '
              'fresh factor — it must run unauthenticated.');
      expect(captured.headers['Idempotency-Key'], 'idem-rec-1');
      expect(jsonDecode(captured.body), <String, Object?>{
        'email': 'admin@forgeflow.test',
        'reason': 'admin_lost_authenticator',
      });
      expect(requested.queued, isTrue);
      expect(requested.requestId, 'rec-1');
    });

    test(
        'listFactors parses the removal_requests array into a pending '
        'removal summary', () async {
      final client = http_testing.MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'factors': <Object?>[
              <String, Object?>{
                'factor_id': 'f1',
                'factor_type': 'totp',
                'enrolled_at': '2026-04-16T10:00:00Z',
                'issuer_label': 'Forge & Flow',
              },
            ],
            'removal_requests': <Object?>[
              <String, Object?>{
                'request_id': 'rm-1',
                'factor_id': 'f1',
                'status': 'pending',
                'execute_after': '2026-05-15T12:30:00Z',
              },
            ],
          }))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final listed = await gateway.listFactors();
      expect(listed.removalRequests, hasLength(1));
      final pending = listed.pendingRemoval;
      expect(pending, isNotNull);
      expect(pending!.requestId, 'rm-1');
      expect(pending.factorId, 'f1');
      expect(pending.executeAfter, DateTime.utc(2026, 5, 15, 12, 30));
    });

    test(
        'requestFactorRemoval posts factor_id to /factors/revoke with a key '
        'and parses revoked:false + request_id + execute_after', () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming((request, _) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'ok': true,
            'revoked': false,
            'request_id': 'rm-9',
            'execute_after': '2026-05-15T12:30:00Z',
          }))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final result = await gateway.requestFactorRemoval(
        factorId: 'f1',
        idempotencyKey: 'idem-revoke-1',
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/auth/mfa/factors/revoke');
      expect(captured.headers['authorization'], 'Bearer tok');
      expect(captured.headers['Idempotency-Key'], 'idem-revoke-1');
      expect(jsonDecode(captured.body), <String, Object?>{'factor_id': 'f1'});
      // Self-service removal is always the delayed request.
      expect(result.revoked, isFalse);
      expect(result.requestId, 'rm-9');
      expect(result.executeAfter, DateTime.utc(2026, 5, 15, 12, 30));
    });

    test(
        'cancelFactorRemoval posts request_id to /removal/cancel with a key '
        'and parses cancelled', () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming((request, _) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'ok': true,
            'cancelled': true,
          }))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final result = await gateway.cancelFactorRemoval(
        requestId: 'rm-9',
        idempotencyKey: 'idem-cancel-1',
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/auth/mfa/factors/removal/cancel');
      expect(captured.headers['Idempotency-Key'], 'idem-cancel-1');
      expect(jsonDecode(captured.body), <String, Object?>{'request_id': 'rm-9'});
      expect(result.cancelled, isTrue);
    });

    test(
        'requestFactorRemoval surfaces a 403 mfa_freshness_required as a '
        'requiresFreshSignIn error (fail-closed)', () async {
      final client = http_testing.MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'error': 'mfa_freshness_required',
            'message': 'fresh step-up required',
          }))),
          403,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      Object? caught;
      try {
        await gateway.requestFactorRemoval(
          factorId: 'f1',
          idempotencyKey: 'k',
        );
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<AdminSecurityGatewayError>());
      final err = caught! as AdminSecurityGatewayError;
      expect(err.statusCode, 403);
      expect(err.requiresFreshSignIn, isTrue);
    });

    test('surfaces a proxy 503 as AdminSecurityGatewayError (fail-closed)',
        () async {
      final client = http_testing.MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'error': 'mfa_operations_not_configured',
            'message': 'route requires an MfaOperationsGateway',
          }))),
          503,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSecurityGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      Object? caught;
      try {
        await gateway.beginTotpEnrollment(
          userEmail: 'admin@forgeflow.test',
          idempotencyKey: 'k',
        );
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<AdminSecurityGatewayError>());
      expect((caught! as AdminSecurityGatewayError).statusCode, 503);
    });
  });

  group('InMemoryAdminSecurityGateway (demo fallback)', () {
    test('starts with no enrolled factor and enrolls through confirm',
        () async {
      final gateway = InMemoryAdminSecurityGateway();
      expect((await gateway.listFactors()).hasEnrolledFactor, isFalse);

      final enrollment = await gateway.beginTotpEnrollment(
        userEmail: 'admin@forgeflow.test',
        idempotencyKey: 'k1',
      );
      final confirmed = await gateway.confirmTotpEnrollment(
        factorId: enrollment.factorId,
        oneTimeCode: '123456',
        idempotencyKey: 'k1',
      );

      expect(confirmed.factorId, enrollment.factorId);
      expect((await gateway.listFactors()).hasEnrolledFactor, isTrue);
      expect(gateway.idempotencyKeys, contains('k1'));
    });

    test('rejects a short password with a policy rejection', () async {
      final gateway = InMemoryAdminSecurityGateway();
      Object? caught;
      try {
        await gateway.changePassword(
          currentPassword: 'old',
          newPassword: 'short',
          idempotencyKey: 'k',
        );
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<AdminSecurityGatewayError>());
      expect((caught! as AdminSecurityGatewayError).rejections,
          contains('too_short'));
    });

    test(
        'requestFactorRemoval schedules a 24h delayed removal and listFactors '
        'reflects the pending state', () async {
      final now = DateTime.utc(2026, 5, 14, 12, 30);
      final gateway = InMemoryAdminSecurityGateway(
        seedEnrolledFactor: true,
        now: () => now,
      );
      final factor = (await gateway.listFactors()).factors.single;

      final result = await gateway.requestFactorRemoval(
        factorId: factor.factorId,
        idempotencyKey: 'rm-key-1',
      );

      // Always the delayed request, never an immediate revoke.
      expect(result.revoked, isFalse);
      expect(result.requestId, isNotNull);
      expect(result.executeAfter, now.add(const Duration(hours: 24)));
      expect(gateway.idempotencyKeys, contains('rm-key-1'));

      final listed = await gateway.listFactors();
      expect(listed.hasEnrolledFactor, isTrue,
          reason: 'The factor is still enrolled until the grace window runs.');
      expect(listed.pendingRemoval, isNotNull);
      expect(listed.pendingRemoval!.requestId, result.requestId);
      expect(
        listed.pendingRemoval!.executeAfter,
        now.add(const Duration(hours: 24)),
      );
    });

    test('cancelFactorRemoval clears the pending removal', () async {
      final now = DateTime.utc(2026, 5, 14, 12, 30);
      final gateway = InMemoryAdminSecurityGateway(
        seedEnrolledFactor: true,
        now: () => now,
      );
      final factor = (await gateway.listFactors()).factors.single;
      final requested = await gateway.requestFactorRemoval(
        factorId: factor.factorId,
        idempotencyKey: 'rm-key-1',
      );
      expect((await gateway.listFactors()).pendingRemoval, isNotNull);

      final cancelled = await gateway.cancelFactorRemoval(
        requestId: requested.requestId!,
        idempotencyKey: 'cancel-key-1',
      );

      expect(cancelled.cancelled, isTrue);
      expect(gateway.idempotencyKeys, contains('cancel-key-1'));
      expect((await gateway.listFactors()).pendingRemoval, isNull);
      expect((await gateway.listFactors()).hasEnrolledFactor, isTrue);
    });
  });
}
