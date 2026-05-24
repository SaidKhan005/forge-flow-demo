// Forge & Flow — Cloud Run capacity READ client tests.
//
// Unit tests for the read seam added to
// `lib/infrastructure/cloud_run/cloud_run_admin_client.dart`:
//   - `CloudRunCapacityReader` abstraction (callers depend on this),
//   - `CloudRunServiceCapacity` typed result,
//   - `HttpCloudRunAdminClient.readServiceCapacity()` parsing of the
//     Cloud Run Admin API v2 `GET service` response, and
//   - a FAKE reader + the `NoOpCloudRunAdminClient` capacity fallback.
//
// No live GCP: `package:http/testing.dart`'s `MockClient` stubs the
// Admin API, and `_FakeCloudRunCapacityReader` proves callers can be
// driven entirely off the abstraction. Mirrors the fake/MockClient
// style in `cloud_run_admin_client_test.dart` (relative-free imports,
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

/// A pure fake of the read abstraction — proves a caller can depend on
/// [CloudRunCapacityReader] alone, with no HTTP client and no GCP.
class _FakeCloudRunCapacityReader implements CloudRunCapacityReader {
  _FakeCloudRunCapacityReader(this._capacity);
  final CloudRunServiceCapacity _capacity;
  int callCount = 0;
  @override
  Future<CloudRunServiceCapacity> readServiceCapacity() async {
    callCount += 1;
    return _capacity;
  }
}

/// A fake reader that fails, to prove error propagation through the
/// abstraction is observable by callers.
class _ThrowingCloudRunCapacityReader implements CloudRunCapacityReader {
  @override
  Future<CloudRunServiceCapacity> readServiceCapacity() async {
    throw CloudRunAdminError(message: 'fake_failure', statusCode: 500);
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
  group('CloudRunServiceCapacity', () {
    test('holds all fields and treats null as unknown (not zero)', () {
      const capacity = CloudRunServiceCapacity(
        serviceName: 'forge-flow-advisor-proxy',
        activeInstanceCount: 3,
        minInstances: 1,
        maxInstances: 10,
        servingRevisionId: 'forge-flow-advisor-proxy-00042-abc',
      );
      expect(capacity.serviceName, 'forge-flow-advisor-proxy');
      expect(capacity.activeInstanceCount, 3);
      expect(capacity.minInstances, 1);
      expect(capacity.maxInstances, 10);
      expect(capacity.servingRevisionId, 'forge-flow-advisor-proxy-00042-abc');

      const unknown = CloudRunServiceCapacity(serviceName: 's');
      // Nulls are honest "unknown" sentinels — never coerced to 0.
      expect(unknown.activeInstanceCount, isNull);
      expect(unknown.minInstances, isNull);
      expect(unknown.maxInstances, isNull);
      expect(unknown.servingRevisionId, isNull);
    });

    test('toString includes the key fields for diagnostics', () {
      const capacity = CloudRunServiceCapacity(
        serviceName: 'svc',
        activeInstanceCount: 2,
        minInstances: 0,
        maxInstances: 5,
        servingRevisionId: 'svc-00001-xyz',
      );
      final text = capacity.toString();
      expect(text, contains('svc'));
      expect(text, contains('2'));
      expect(text, contains('svc-00001-xyz'));
    });
  });

  group('CloudRunCapacityReader (fake, abstraction-only)', () {
    test('a caller can depend on the abstraction and read a snapshot',
        () async {
      const expected = CloudRunServiceCapacity(
        serviceName: 'svc',
        activeInstanceCount: 4,
        minInstances: 2,
        maxInstances: 8,
        servingRevisionId: 'svc-00009-def',
      );
      final CloudRunCapacityReader reader =
          _FakeCloudRunCapacityReader(expected);

      final result = await reader.readServiceCapacity();

      expect(result.serviceName, 'svc');
      expect(result.activeInstanceCount, 4);
      expect(result.minInstances, 2);
      expect(result.maxInstances, 8);
      expect(result.servingRevisionId, 'svc-00009-def');
      expect((reader as _FakeCloudRunCapacityReader).callCount, 1);
    });

    test('errors surface through the abstraction', () async {
      final CloudRunCapacityReader reader = _ThrowingCloudRunCapacityReader();
      await expectLater(
        reader.readServiceCapacity(),
        throwsA(
          isA<CloudRunAdminError>()
              .having((e) => e.message, 'message', 'fake_failure')
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });
  });

  group('HttpCloudRunAdminClient.readServiceCapacity (MockClient)', () {
    test('parses a full GET service response into capacity', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'name':
              'projects/test-project/locations/test-region/services/'
                  'forge-flow-advisor-proxy',
          'latestReadyRevision':
              'projects/test-project/locations/test-region/services/'
                  'forge-flow-advisor-proxy/revisions/'
                  'forge-flow-advisor-proxy-00042-abc',
          'template': <String, Object?>{
            'scaling': <String, Object?>{
              'minInstanceCount': 1,
              'maxInstanceCount': 10,
            },
            // Defensive parse path: not a documented v2 field, but if a
            // future API revision surfaces it under template we read it.
            'observedInstanceCount': 3,
          },
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'test-project',
        region: 'test-region',
        serviceName: 'forge-flow-advisor-proxy',
        accessTokenProvider: _FakeAccessTokenProvider('fake-token'),
        httpClient: mock,
      );

      final capacity = await client.readServiceCapacity();

      // Service + revision are reduced to their short ids.
      expect(capacity.serviceName, 'forge-flow-advisor-proxy');
      expect(capacity.servingRevisionId, 'forge-flow-advisor-proxy-00042-abc');
      expect(capacity.minInstances, 1);
      expect(capacity.maxInstances, 10);
      expect(capacity.activeInstanceCount, 3);
    });

    test('outbound request: GET, correct v2 URL, readMask, auth header, '
        'no token leak', () async {
      http.BaseRequest? captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, const <String, Object?>{
          'name': 'projects/p/locations/r/services/s',
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'test-project',
        region: 'test-region',
        serviceName: 'test-service',
        accessTokenProvider: _FakeAccessTokenProvider('secret-token'),
        httpClient: mock,
      );

      await client.readServiceCapacity();

      final req = captured;
      expect(req, isNotNull);
      expect(req!.method, equals('GET'));

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
      expect(url.queryParameters['readMask'], contains('latestReadyRevision'));
      expect(url.queryParameters['readMask'], contains('template.scaling'));

      expect(req.headers['Authorization'], equals('Bearer secret-token'));
      expect(req.headers['Accept'], contains('application/json'));
    });

    test('missing scaling + missing revision yields nulls, not zeros',
        () async {
      // A healthy service running on platform-default scaling: Cloud Run
      // omits the zero/default fields. We must report "unknown" (null),
      // never a fabricated 0 (Metric Honesty Doctrine).
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'name': 'projects/p/locations/r/services/lean-svc',
          // no latestReadyRevision, no template.scaling
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 'lean-svc',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      final capacity = await client.readServiceCapacity();
      expect(capacity.serviceName, 'lean-svc');
      expect(capacity.minInstances, isNull);
      expect(capacity.maxInstances, isNull);
      expect(capacity.activeInstanceCount, isNull);
      expect(capacity.servingRevisionId, isNull);
    });

    test('int64 fields serialized as JSON strings are parsed as ints',
        () async {
      // Cloud Run may serialize int64 scaling fields as strings.
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'name': 'projects/p/locations/r/services/s',
          'template': <String, Object?>{
            'scaling': <String, Object?>{
              'minInstanceCount': '0',
              'maxInstanceCount': '100',
            },
          },
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      final capacity = await client.readServiceCapacity();
      expect(capacity.minInstances, 0);
      expect(capacity.maxInstances, 100);
    });

    test('falls back to the configured service name when name absent',
        () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, const <String, Object?>{
          'template': <String, Object?>{
            'scaling': <String, Object?>{'minInstanceCount': 2},
          },
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 'configured-service',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      final capacity = await client.readServiceCapacity();
      expect(capacity.serviceName, 'configured-service');
      expect(capacity.minInstances, 2);
    });

    test('non-200 throws CloudRunAdminError with decoded message', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(403, <String, Object?>{
          'error': <String, Object?>{'message': 'permission denied'},
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      await expectLater(
        client.readServiceCapacity(),
        throwsA(
          isA<CloudRunAdminError>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', contains('permission denied')),
        ),
      );
    });

    test('empty 200 body throws CloudRunAdminError', () async {
      final mock = MockClient((request) async {
        return http.Response('', 200);
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      await expectLater(
        client.readServiceCapacity(),
        throwsA(
          isA<CloudRunAdminError>()
              .having((e) => e.message, 'message', 'cloud_run_get_response_empty'),
        ),
      );
    });

    test('malformed (non-JSON-object) 200 body throws CloudRunAdminError',
        () async {
      final mock = MockClient((request) async {
        // Valid JSON, but an array — not the expected object.
        return http.Response('[1,2,3]', 200,
            headers: const <String, String>{'content-type': 'application/json'});
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
      );

      await expectLater(
        client.readServiceCapacity(),
        throwsA(
          isA<CloudRunAdminError>().having(
            (e) => e.message,
            'message',
            'cloud_run_get_response_malformed',
          ),
        ),
      );
    });

    test('timeout throws CloudRunAdminError with timeout message', () async {
      final mock = MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return _jsonResponse(200, const <String, Object?>{
          'name': 'projects/p/locations/r/services/s',
        });
      });

      final client = HttpCloudRunAdminClient(
        projectId: 'p',
        region: 'r',
        serviceName: 's',
        accessTokenProvider: _FakeAccessTokenProvider('tok'),
        httpClient: mock,
        timeout: const Duration(milliseconds: 100),
      );

      await expectLater(
        client.readServiceCapacity(),
        throwsA(
          isA<CloudRunAdminError>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.message, 'message', 'cloud_run_get_timeout'),
        ),
      );
    });
  });

  group('NoOpCloudRunAdminClient as CloudRunCapacityReader', () {
    test('returns an all-unknown snapshot with the default service name',
        () async {
      const CloudRunCapacityReader reader = NoOpCloudRunAdminClient();
      final capacity = await reader.readServiceCapacity();
      expect(capacity.serviceName, 'no-op-cloud-run');
      expect(capacity.activeInstanceCount, isNull);
      expect(capacity.minInstances, isNull);
      expect(capacity.maxInstances, isNull);
      expect(capacity.servingRevisionId, isNull);
    });

    test('honors an overridden service name', () async {
      const reader = NoOpCloudRunAdminClient(serviceName: 'local-fake');
      final capacity = await reader.readServiceCapacity();
      expect(capacity.serviceName, 'local-fake');
    });
  });
}
