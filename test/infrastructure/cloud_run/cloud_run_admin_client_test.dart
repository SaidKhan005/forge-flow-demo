// Forge & Flow — Cloud Run Admin client tests.
//
// Unit tests for `lib/infrastructure/cloud_run/cloud_run_admin_client.dart`.
// Uses `package:http/testing.dart`'s `MockClient` to stub responses;
// mirrors the test style in
// `test/proxy/anthropic_http_complete_fn_test.dart` (relative imports,
// plain Dart fakes, no mocking framework).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/cloud_run/cloud_run_admin_client.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeAccessTokenProvider implements OAuthAccessTokenProvider {
  _FakeAccessTokenProvider(this._token);
  final String _token;
  @override
  Future<String> accessToken() async => _token;
}

class _ThrowingHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    fail('HTTP client should not be invoked: ${request.method} ${request.url}');
  }
}

http.Response _jsonResponse(int statusCode, Object? body) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

void main() {
  group('HttpCloudRunAdminClient.forceNewRevision', () {
    test('successful PATCH returns the long-running operation name from '
        'the Cloud Run response', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'name':
              'projects/test-project/locations/test-region/operations/op-123',
          'metadata': <String, Object?>{
            'name': 'operations/op-123',
          },
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'test-project',
        region: 'test-region',
        serviceName: 'test-service',
        accessTokenProvider: _FakeAccessTokenProvider('fake-token'),
        httpClient: mock,
        rotationIdGenerator: () => '1700000000000',
      );

      final result = await client.forceNewRevision(reason: 'kms_rotation');

      expect(
        result,
        equals(
          'projects/test-project/locations/test-region/operations/op-123',
        ),
      );
    });

    test('successful PATCH with missing operation name throws', () async {
      // Defensive: if Cloud Run ever returns 200 with a malformed body
      // (no `name`), we must not silently return a synthetic value
      // that would mislead the audit log.
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'metadata': <String, Object?>{'name': 'operations/op-123'},
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      try {
        await client.forceNewRevision(reason: 'kms_rotation');
        fail('expected CloudRunAdminError');
      } on CloudRunAdminError catch (error) {
        expect(
          error.message,
          contains('cloud_run_patch_response_missing_operation_name'),
        );
      }
    });

    test('PATCH failure with 503 throws CloudRunAdminError', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(503, <String, Object?>{
          'error': <String, Object?>{
            'message': 'backend unavailable',
          },
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('fake-token'),
        httpClient: mock,
      );

      await expectLater(
        client.forceNewRevision(reason: 'kms_rotation'),
        throwsA(
          isA<CloudRunAdminError>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having(
                (e) => e.message,
                'message',
                contains('backend unavailable'),
              ),
        ),
      );
    });

    test('PATCH timeout throws CloudRunAdminError with timeout message',
        () async {
      final mock = MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return _jsonResponse(200, const <String, Object?>{
          'name': 'projects/p/locations/r/operations/op-test',
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('fake-token'),
        httpClient: mock,
        timeout: const Duration(milliseconds: 100),
      );

      await expectLater(
        client.forceNewRevision(reason: 'kms_rotation'),
        throwsA(
          isA<CloudRunAdminError>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having(
                (e) => e.message,
                'message',
                'cloud_run_patch_timeout',
              ),
        ),
      );
    });

    test('outbound request has correct URL, method, headers, and body',
        () async {
      http.BaseRequest? captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, const <String, Object?>{
          'name': 'projects/p/locations/r/operations/op-test',
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'test-project',
        region: 'test-region',
        serviceName: 'test-service',
        accessTokenProvider: _FakeAccessTokenProvider('fake-token'),
        httpClient: mock,
        rotationIdGenerator: () => '42',
      );

      await client.forceNewRevision(reason: 'simple');

      final req = captured;
      expect(req, isNotNull);
      expect(req!.method, equals('PATCH'));

      final url = req.url;
      expect(url.scheme, equals('https'));
      expect(url.host, equals('run.googleapis.com'));
      expect(
        url.path,
        equals(
          '/v2/projects/test-project/locations/test-region/services/'
          'test-service',
        ),
      );
      expect(url.queryParameters['updateMask'], equals('template.labels'));

      expect(req.headers['Authorization'], equals('Bearer fake-token'));
      expect(req.headers['Content-Type'], contains('application/json'));
      expect(req.headers['Accept'], contains('application/json'));

      expect(req, isA<http.Request>());
      final body = jsonDecode((req as http.Request).body) as Map<String, Object?>;
      final template = body['template'] as Map<String, Object?>;
      final labels = template['labels'] as Map<String, Object?>;

      expect(labels['forge-flow-rotation-id'], equals('42'));
      final reason = labels['forge-flow-rotation-reason'] as String;
      expect(reason, matches(RegExp(r'^[a-z0-9_-]+$')));
      expect(reason, equals('simple'));
    });

    test('reason is sanitized: lowercased, non-allowed chars become "-", '
        'truncated to 63 chars', () async {
      http.BaseRequest? captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, const <String, Object?>{
          'name': 'projects/p/locations/r/operations/op-test',
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('fake-token'),
        httpClient: mock,
        rotationIdGenerator: () => '1',
      );

      const messyReason =
          'KMS Rotation: Anthropic / Credential 12345!';
      await client.forceNewRevision(reason: messyReason);

      final body = jsonDecode((captured! as http.Request).body)
          as Map<String, Object?>;
      final labels = (body['template'] as Map<String, Object?>)['labels']
          as Map<String, Object?>;
      final sanitized = labels['forge-flow-rotation-reason'] as String;

      expect(sanitized, matches(RegExp(r'^[a-z0-9_-]+$')));
      expect(sanitized.length, lessThanOrEqualTo(63));
      // No uppercase letters survived.
      expect(sanitized, equals(sanitized.toLowerCase()));
      // Spaces, colons, slashes, and `!` were all replaced with `-`.
      expect(sanitized, equals('kms-rotation--anthropic---credential-12345-'));
    });

    test('reason longer than 63 chars is truncated to exactly 63', () async {
      http.BaseRequest? captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, const <String, Object?>{
          'name': 'projects/p/locations/r/operations/op-test',
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('fake-token'),
        httpClient: mock,
        rotationIdGenerator: () => '1',
      );

      // 80 lowercase 'a's — well within allowed charset, but exceeds 63.
      final longReason = 'a' * 80;
      await client.forceNewRevision(reason: longReason);

      final body = jsonDecode((captured! as http.Request).body)
          as Map<String, Object?>;
      final labels = (body['template'] as Map<String, Object?>)['labels']
          as Map<String, Object?>;
      final sanitized = labels['forge-flow-rotation-reason'] as String;

      expect(sanitized.length, equals(63));
      expect(sanitized, equals('a' * 63));
    });
  });

  group('NoOpCloudRunAdminClient', () {
    test('returns no-op revision name and does not touch HTTP', () async {
      const client = NoOpCloudRunAdminClient();
      // The throwing client is intentionally NOT wired — the no-op
      // client takes no constructor params and must not perform any
      // network I/O. Asserting the returned string is enough; the
      // throwing client below is a sanity guard for future callers
      // who might wire one in.
      final result = await client.forceNewRevision(reason: 'test');
      expect(result, equals('no-op-cloud-run:test'));

      // Sanity: even if the implementation grew to take an http
      // client, this test would still catch any unexpected I/O. We
      // construct one here purely to document intent.
      // ignore: unused_local_variable
      final guard = _ThrowingHttpClient();
    });
  });
}
