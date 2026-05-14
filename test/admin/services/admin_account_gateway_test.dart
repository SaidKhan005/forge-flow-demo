// Wave 2 W-3 — admin self-service account gateway tests.
//
// Pins:
//   * The HTTP gateway hits `PATCH /v1/auth/self/profile` with the
//     bearer token, the Idempotency-Key, and the JSON body shape the
//     proxy expects (display_name / email only — no admin_reason, no
//     target user id).
//   * The 4xx proxy error surfaces as `AdminAccountGatewayError`.
//   * The in-memory demo gateway echoes the patched fields back, and
//     mirrors the proxy's `email_changed` / `display_name_changed`
//     signals.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:forge_and_flow/admin/services/admin_account_gateway.dart';

void main() {
  group('HttpAdminAccountGateway', () {
    test('patchSelfProfile sends the expected wire payload', () async {
      late http.Request capturedRequest;
      final client = http_testing.MockClient.streaming(
        (request, stream) async {
          capturedRequest = request as http.Request;
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(<String, Object?>{
              'ok': true,
              'user': <String, Object?>{
                'user_id': 'admin-1',
                'email': 'admin@new-domain.com',
                'display_name': 'Alex Admin',
                'email_changed': true,
                'display_name_changed': true,
              },
            }))),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );
      final gateway = HttpAdminAccountGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'test-token',
        httpClient: client,
      );

      final result = await gateway.patchSelfProfile(
        displayName: 'Alex Admin',
        email: 'admin@new-domain.com',
        idempotencyKey: 'idem-1',
      );

      expect(capturedRequest.method, 'PATCH');
      expect(capturedRequest.url.path, '/v1/auth/self/profile');
      expect(capturedRequest.headers['authorization'], 'Bearer test-token');
      expect(capturedRequest.headers['Idempotency-Key'], 'idem-1');
      final body = jsonDecode(capturedRequest.body) as Map<String, Object?>;
      expect(body, <String, Object?>{
        'display_name': 'Alex Admin',
        'email': 'admin@new-domain.com',
      });
      expect(body.containsKey('admin_reason'), isFalse,
          reason: 'Self-edit must NOT require admin_reason.');
      expect(body.containsKey('user_id'), isFalse,
          reason: 'Self-edit must NOT carry a client-supplied target id.');

      expect(result.userId, 'admin-1');
      expect(result.email, 'admin@new-domain.com');
      expect(result.displayName, 'Alex Admin');
      expect(result.emailChanged, isTrue);
      expect(result.displayNameChanged, isTrue);
    });

    test('patchSelfProfile rejects all-null body before hitting HTTP', () async {
      final client =
          http_testing.MockClient((request) async => http.Response('', 200));
      final gateway = HttpAdminAccountGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'test-token',
        httpClient: client,
      );

      Object? caught;
      try {
        await gateway.patchSelfProfile(
          displayName: '',
          email: null,
          idempotencyKey: 'idem-empty',
        );
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<AdminAccountGatewayError>());
      final err = caught! as AdminAccountGatewayError;
      expect(err.statusCode, 400);
      expect(err.errorCode, 'no_profile_fields');
    });

    test('patchSelfProfile surfaces proxy 4xx as gateway error', () async {
      final client = http_testing.MockClient.streaming(
        (request, stream) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(<String, Object?>{
              'error': 'invalid_email',
              'message': 'email must be a syntactically valid address',
            }))),
            400,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );
      final gateway = HttpAdminAccountGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'test-token',
        httpClient: client,
      );

      Object? caught;
      try {
        await gateway.patchSelfProfile(
          email: 'broken',
          idempotencyKey: 'idem-bad',
        );
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<AdminAccountGatewayError>());
      final err = caught! as AdminAccountGatewayError;
      expect(err.statusCode, 400);
      expect(err.errorCode, 'invalid_email');
    });
  });

  group('InMemoryAdminAccountGateway', () {
    test('patchSelfProfile updates the in-memory snapshot', () async {
      final gateway = InMemoryAdminAccountGateway(
        initialDisplayName: 'Alex',
        initialEmail: 'alex@old.test',
      );

      final result = await gateway.patchSelfProfile(
        displayName: 'Alex Davies',
        email: 'alex@new.test',
        idempotencyKey: 'idem-1',
      );

      expect(result.displayName, 'Alex Davies');
      expect(result.email, 'alex@new.test');
      expect(result.emailChanged, isTrue);
      expect(result.displayNameChanged, isTrue);
      expect(gateway.currentDisplayName, 'Alex Davies');
      expect(gateway.currentEmail, 'alex@new.test');
      expect(gateway.calls.single.idempotencyKey, 'idem-1');
    });

    test(
        'patchSelfProfile flags emailChanged false when the value is '
        'unchanged (case-insensitive)', () async {
      final gateway = InMemoryAdminAccountGateway(
        initialDisplayName: 'Alex',
        initialEmail: 'alex@brio.test',
      );

      final result = await gateway.patchSelfProfile(
        displayName: 'Alex Renamed',
        email: 'ALEX@BRIO.TEST',
        idempotencyKey: 'idem-2',
      );

      expect(result.displayNameChanged, isTrue);
      expect(result.emailChanged, isFalse,
          reason:
              'Case-only email diff should NOT trigger an emailChanged flag.');
    });
  });
}
