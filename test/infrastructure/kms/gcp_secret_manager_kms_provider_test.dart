// Phase 11A.4 — unit tests for the real GCP Secret Manager KMS
// provider. Verifies the round-trip shape (URLs, headers, body,
// idempotent create) and the failing-closed contract (plaintext
// never leaks into thrown exceptions). Uses
// `package:http/testing.dart`'s `MockClient` to stub responses;
// mirrors the test style in
// `test/proxy/anthropic_http_complete_fn_test.dart` (relative
// imports, plain Dart closures, no mocking framework).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/infrastructure/kms/gcp_secret_manager_kms_provider.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_provider.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart'
    show OAuthAccessTokenProvider;

class _FakeAccessTokenProvider implements OAuthAccessTokenProvider {
  _FakeAccessTokenProvider(this.token);
  final String token;
  @override
  Future<String> accessToken() async => token;
}

http.Response _jsonResponse(int statusCode, Object? body) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json',
    },
  );
}

void main() {
  group('GcpSecretManagerKmsProvider', () {
    test('successful write — secret created + version added returns '
        'kms:// pointer + masked display', () async {
      final mock = MockClient((request) async {
        if (request.url.path.endsWith(':addVersion')) {
          return _jsonResponse(200, <String, Object?>{
            'name':
                'projects/p1/secrets/forge-flow-anthropic-api-key/versions/1',
          });
        }
        return _jsonResponse(200, <String, Object?>{
          'name': 'projects/p1/secrets/forge-flow-anthropic-api-key',
        });
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      final result = await provider.writeSecret(
        logicalKeyKind: 'anthropic',
        plaintext: 'sk-anthropic-supersecret-1234',
      );

      expect(result.secretName.startsWith('kms://gcp-secret-manager/projects/'),
          isTrue);
      expect(
        result.secretName,
        contains('/secrets/forge-flow-anthropic-api-key/versions/1'),
      );
      // maskCredentialForDisplay format: head4 + *** + tail4
      expect(result.maskedDisplay, equals('sk-a***1234'));
    });

    test('idempotent create — 409 on create, 200 on addVersion succeeds',
        () async {
      final mock = MockClient((request) async {
        if (request.url.path.endsWith(':addVersion')) {
          return _jsonResponse(200, <String, Object?>{
            'name':
                'projects/p1/secrets/forge-flow-anthropic-api-key/versions/7',
          });
        }
        // Conflict: secret already exists from a previous rotation.
        return http.Response('{"error":{"code":409}}', 409);
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      final result = await provider.writeSecret(
        logicalKeyKind: 'anthropic',
        plaintext: 'sk-anthropic-already-exists-key-9999',
      );

      expect(
        result.secretName,
        contains('/secrets/forge-flow-anthropic-api-key/versions/7'),
      );
    });

    test('hard create failure — 500 throws KmsWriteFailure without '
        'leaking plaintext', () async {
      const plaintext = 'sk-plaintext-should-never-leak-abcd1234';
      final mock = MockClient((request) async {
        return http.Response('upstream is down', 500);
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      try {
        await provider.writeSecret(
          logicalKeyKind: 'anthropic',
          plaintext: plaintext,
        );
        fail('expected KmsWriteFailure');
      } on KmsWriteFailure catch (error) {
        expect(error.message, contains('gcp_secret_manager_create_failed'));
        expect(error.message.contains(plaintext), isFalse);
        expect(error.toString().contains(plaintext), isFalse);
      }
    });

    test('addVersion failure — 200 create + 503 addVersion throws '
        'KmsWriteFailure', () async {
      const plaintext = 'sk-plaintext-should-never-leak-zzzz9999';
      final mock = MockClient((request) async {
        if (request.url.path.endsWith(':addVersion')) {
          return http.Response('add version unavailable', 503);
        }
        return _jsonResponse(200, <String, Object?>{
          'name': 'projects/p1/secrets/forge-flow-anthropic-api-key',
        });
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      try {
        await provider.writeSecret(
          logicalKeyKind: 'anthropic',
          plaintext: plaintext,
        );
        fail('expected KmsWriteFailure');
      } on KmsWriteFailure catch (error) {
        expect(
          error.message,
          contains('gcp_secret_manager_add_version_failed'),
        );
        expect(error.message.contains(plaintext), isFalse);
      }
    });

    test('error body sanitization — extracts code + status_text from '
        'a structured GCP error response', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(403, <String, Object?>{
          'error': <String, Object?>{
            'code': 403,
            'message': 'Permission denied on secret forge-flow-anthropic-api-key',
            'status': 'PERMISSION_DENIED',
          },
        });
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      try {
        await provider.writeSecret(
          logicalKeyKind: 'anthropic',
          plaintext: 'sk-anything',
        );
        fail('expected KmsWriteFailure');
      } on KmsWriteFailure catch (error) {
        expect(error.message, contains('status=403'));
        expect(error.message, contains('code=403'));
        expect(error.message, contains('status_text=PERMISSION_DENIED'));
      }
    });

    test('error body sanitization — base64-looking plaintext echoed in '
        'error response NEVER appears in the thrown exception', () async {
      // Simulate a misbehaving HTTP intermediary that echoes the
      // request payload back in the error response body. The
      // request body for addVersion contains
      // {"payload": {"data": "<base64-of-plaintext>"}}, so a 4xx
      // proxy error page that includes the request body would
      // ship the plaintext into the response.
      const plaintext =
          'sk-this-must-never-appear-in-audit-logs-deadbeef-cafef00d';
      final encodedPlaintext = base64Encode(utf8.encode(plaintext));
      final mock = MockClient((request) async {
        if (request.url.path.endsWith(':addVersion')) {
          // Misbehaving 503 response that includes the base64 payload
          // it received in the request, in the `error.message`.
          return _jsonResponse(503, <String, Object?>{
            'error': <String, Object?>{
              'code': 503,
              'status': 'UNAVAILABLE',
              'message':
                  'Backend rejected payload data: $encodedPlaintext '
                  'received via misbehaving intermediary',
            },
          });
        }
        return _jsonResponse(200, <String, Object?>{
          'name': 'projects/p1/secrets/forge-flow-anthropic-api-key',
        });
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      try {
        await provider.writeSecret(
          logicalKeyKind: 'anthropic',
          plaintext: plaintext,
        );
        fail('expected KmsWriteFailure');
      } on KmsWriteFailure catch (error) {
        // Plaintext must not appear, base64 must not appear, and
        // the GCP `error.message` (which contained the leaked
        // payload in this scenario) must not appear either.
        expect(error.message.contains(plaintext), isFalse,
            reason: 'plaintext leaked into KmsWriteFailure.message');
        expect(error.message.contains(encodedPlaintext), isFalse,
            reason: 'base64 plaintext leaked into KmsWriteFailure.message');
        expect(error.message.contains('Backend rejected payload data'), isFalse,
            reason: 'GCP error.message (which contained the echoed '
                'plaintext in this test) must not appear in audit-bound '
                'exception message');
        // But the safe code + status_text fields should still be there
        // for operator triage.
        expect(error.message, contains('code=503'));
        expect(error.message, contains('status_text=UNAVAILABLE'));
      }
    });

    test('outbound requests use Secret Manager URLs, Bearer auth, and '
        'base64-encoded payload', () async {
      const plaintext = 'sk-anthropic-roundtrip-abcdef';
      final captured = <http.BaseRequest>[];
      final mock = MockClient((request) async {
        captured.add(request);
        if (request.url.path.endsWith(':addVersion')) {
          return _jsonResponse(200, <String, Object?>{
            'name':
                'projects/proj-42/secrets/forge-flow-anthropic-api-key/versions/3',
          });
        }
        return _jsonResponse(200, <String, Object?>{
          'name': 'projects/proj-42/secrets/forge-flow-anthropic-api-key',
        });
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'proj-42',
        accessTokenProvider: _FakeAccessTokenProvider('fake-bearer-token'),
        httpClient: mock,
      );

      await provider.writeSecret(
        logicalKeyKind: 'anthropic',
        plaintext: plaintext,
      );

      expect(captured, hasLength(2));

      // Both URLs hit secretmanager.googleapis.com under
      // /v1/projects/proj-42/secrets...
      for (final request in captured) {
        expect(request.method, equals('POST'));
        expect(request.url.host, equals('secretmanager.googleapis.com'));
        expect(
          request.url.toString(),
          contains('/v1/projects/proj-42/secrets'),
        );
        expect(
          request.headers['Authorization'],
          equals('Bearer fake-bearer-token'),
        );
        expect(
          request.headers['Content-Type'],
          contains('application/json'),
        );
      }

      // First request: create. URL has ?secretId=forge-flow-...
      expect(
        captured[0].url.toString(),
        contains('secretId=forge-flow-anthropic-api-key'),
      );
      // Second request: addVersion path.
      expect(
        captured[1].url.path,
        endsWith(
          '/v1/projects/proj-42/secrets/'
          'forge-flow-anthropic-api-key:addVersion',
        ),
      );

      // addVersion body carries base64(utf8(plaintext)).
      final addVersionRequest = captured[1];
      if (addVersionRequest is! http.Request) {
        fail('expected http.Request for addVersion');
      }
      final body = jsonDecode(addVersionRequest.body) as Map<String, Object?>;
      final payload = body['payload'] as Map<String, Object?>;
      expect(
        payload['data'],
        equals(base64Encode(utf8.encode(plaintext))),
      );
    });

    test('timeout fires on slow upstream and surfaces KmsWriteFailure '
        'with timeout message', () async {
      final mock = MockClient((request) async {
        return Future<http.Response>.delayed(
          const Duration(seconds: 1),
          () => _jsonResponse(200, <String, Object?>{
            'name': 'projects/p1/secrets/forge-flow-anthropic-api-key',
          }),
        );
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
        timeout: const Duration(milliseconds: 100),
      );

      try {
        await provider.writeSecret(
          logicalKeyKind: 'anthropic',
          plaintext: 'sk-irrelevant-key-12345',
        );
        fail('expected KmsWriteFailure');
      } on KmsWriteFailure catch (error) {
        expect(error.message, contains('gcp_secret_manager_timeout'));
        expect(error.message, contains('anthropic'));
      }
    });

    test('plaintext never appears in KmsWriteFailure.toString() on 500',
        () async {
      const plaintext =
          'sk-uniq-marker-abc-DO-NOT-LEAK-THIS-STRING-9876543210';
      final mock = MockClient((request) async {
        return http.Response('totally broken upstream', 500);
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      try {
        await provider.writeSecret(
          logicalKeyKind: 'anthropic',
          plaintext: plaintext,
        );
        fail('expected KmsWriteFailure');
      } on KmsWriteFailure catch (error) {
        expect(error.toString().contains(plaintext), isFalse);
      }
    });

    test('lane name resolution — azure_db maps to forge-flow-azure-db-superuser',
        () async {
      late http.BaseRequest createRequest;
      final mock = MockClient((request) async {
        if (!request.url.path.endsWith(':addVersion')) {
          createRequest = request;
        }
        if (request.url.path.endsWith(':addVersion')) {
          return _jsonResponse(200, <String, Object?>{
            'name':
                'projects/p1/secrets/forge-flow-azure-db-superuser/versions/1',
          });
        }
        return _jsonResponse(200, <String, Object?>{
          'name': 'projects/p1/secrets/forge-flow-azure-db-superuser',
        });
      });

      final provider = GcpSecretManagerKmsProvider(
        projectId: 'p1',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      final result = await provider.writeSecret(
        logicalKeyKind: 'azure_db',
        plaintext: 'pg-superuser-password-1234567890',
      );

      expect(
        createRequest.url.toString(),
        contains('secretId=forge-flow-azure-db-superuser'),
      );
      expect(
        result.secretName,
        contains('/secrets/forge-flow-azure-db-superuser/versions/1'),
      );
    });
  });
}
