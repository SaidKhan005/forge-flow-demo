// Phase 8 (`8.transport.clover-pos`) — production API client tests.
//
// Covers:
//   * listOrders happy path: filter shape, offset/limit, returns
//     CloverOrdersPage with verbatim element JSON.
//   * Pagination terminator: `nextOffset == null` when page < limit;
//     `nextOffset == offset + count` when page == limit.
//   * 429 retry honours `Retry-After`; gives up after the retry budget.
//   * 401 maps to CloverApiAuthException without retry.
//   * 500 retries until budget; surfaces CloverApiServerException.
//   * Timeout maps to CloverApiTimeoutException after retries.
//   * Schema violation: non-JSON body / wrong shape.
//   * registerWebhook posts to `/v3/apps/{aId}/webhooks` with
//     Idempotency-Key header.
//   * unregisterWebhook DELETEs `/v3/apps/{aId}/webhooks/{id}`.
//   * Default base URL is production; sandbox factory swaps to sandbox.
//   * Bearer token is fetched per call.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

const String _merchantId = 'M-9001';
const String _appId = 'app-id';
const String _merchantToken = 'mt-token';
const String _appToken = 'at-token';

CloverPosProductionApiClient _build({
  required http.Client client,
  String merchantToken = _merchantToken,
  String appToken = _appToken,
  Duration requestTimeout = const Duration(seconds: 30),
  int maxRetries = 4,
  CloverSleeper? sleep,
  Uri? baseUri,
}) {
  return CloverPosProductionApiClient(
    httpClient: client,
    merchantTokenSource: () async => merchantToken,
    appTokenSource: () => appToken,
    appIdSource: () => _appId,
    requestTimeout: requestTimeout,
    maxRetries: maxRetries,
    sleep: sleep ?? (_) async {},
    baseUri: baseUri,
  );
}

void main() {
  group('CloverPosProductionApiClient — base URL', () {
    test('default constructor uses kCloverProductionBaseUrl', () {
      final client = _build(
        client: http_testing.MockClient((_) async => http.Response('', 200)),
      );
      expect(client.baseUri.toString(), kCloverProductionBaseUrl);
    });

    test('sandbox factory uses kCloverSandboxBaseUrl', () {
      final client = CloverPosProductionApiClient.sandbox(
        httpClient: http_testing.MockClient((_) async => http.Response('', 200)),
        merchantTokenSource: () async => _merchantToken,
        appTokenSource: () => _appToken,
        appIdSource: () => _appId,
        sleep: (_) async {},
      );
      expect(client.baseUri.toString(), kCloverSandboxBaseUrl);
    });
  });

  group('CloverPosProductionApiClient — listOrders', () {
    test('happy path: filter shape, bearer auth, returns elements', () async {
      late http.Request capturedRequest;
      final mock = http_testing.MockClient((http.Request req) async {
        capturedRequest = req;
        return http.Response(
          jsonEncode(<String, Object?>{
            'elements': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'O-1',
                'createdTime': 1735_689_600_000,
                'modifiedTime': 1735_689_900_000,
                'total': 4500,
                'state': 'paid',
              },
            ],
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      });
      final client = _build(client: mock);

      final page = await client.listOrders(
        merchantId: _merchantId,
        modifiedFrom: DateTime.utc(2025, 1, 1),
        modifiedTo: DateTime.utc(2025, 1, 2),
        offset: 0,
        limit: 100,
      );

      expect(page.elements, hasLength(1));
      expect(page.elements.first['id'], 'O-1');
      // Page < limit -> chain exhausted.
      expect(page.nextOffset, isNull);

      expect(capturedRequest.method, 'GET');
      expect(capturedRequest.url.path, '/v3/merchants/$_merchantId/orders');
      expect(
        capturedRequest.url.queryParametersAll['filter'],
        contains('modifiedTime>=${DateTime.utc(2025, 1, 1).millisecondsSinceEpoch}'),
      );
      expect(
        capturedRequest.url.queryParametersAll['filter'],
        contains('modifiedTime<=${DateTime.utc(2025, 1, 2).millisecondsSinceEpoch}'),
      );
      expect(capturedRequest.url.queryParameters['offset'], '0');
      expect(capturedRequest.url.queryParameters['limit'], '100');
      expect(capturedRequest.headers['Authorization'], 'Bearer $_merchantToken');
    });

    test('full page returns nextOffset == offset + count', () async {
      final mock = http_testing.MockClient((http.Request req) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'elements': List<Map<String, Object?>>.generate(
              5,
              (i) => <String, Object?>{
                'id': 'O-$i',
                'createdTime': 1735_689_600_000,
                'modifiedTime': 1735_689_900_000,
                'total': 100 + i,
                'state': 'paid',
              },
            ),
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = _build(client: mock);
      final page = await client.listOrders(
        merchantId: _merchantId,
        modifiedFrom: DateTime.utc(2025, 1, 1),
        modifiedTo: DateTime.utc(2025, 1, 2),
        offset: 10,
        limit: 5,
      );
      expect(page.elements, hasLength(5));
      expect(page.nextOffset, 15);
    });

    test('rejects invalid args', () async {
      final client = _build(
        client: http_testing.MockClient((_) async => http.Response('', 200)),
      );
      expect(
        () => client.listOrders(
          merchantId: '',
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsArgumentError,
      );
      expect(
        () => client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: -1,
          limit: 100,
        ),
        throwsArgumentError,
      );
      expect(
        () => client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: kCloverApiHardLimitCap + 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 2),
          modifiedTo: DateTime.utc(2025, 1, 1),
          offset: 0,
          limit: 100,
        ),
        throwsArgumentError,
      );
    });
  });

  group('CloverPosProductionApiClient — getOrder', () {
    test('GETs /v3/merchants/{m}/orders/{o}', () async {
      late http.Request capturedRequest;
      final mock = http_testing.MockClient((http.Request req) async {
        capturedRequest = req;
        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 'O-77',
            'createdTime': 1,
            'modifiedTime': 2,
            'total': 99,
            'state': 'paid',
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = _build(client: mock);
      final order = await client.getOrder(
        merchantId: _merchantId,
        orderId: 'O-77',
      );
      expect(order['id'], 'O-77');
      expect(capturedRequest.url.path, '/v3/merchants/$_merchantId/orders/O-77');
    });
  });

  group('CloverPosProductionApiClient — 429 handling', () {
    test('retries after Retry-After then succeeds', () async {
      var calls = 0;
      final mock = http_testing.MockClient((http.Request req) async {
        calls += 1;
        if (calls == 1) {
          return http.Response(
            '{"error": "rate limited"}',
            429,
            headers: const <String, String>{'retry-after': '1'},
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'elements': const <Map<String, Object?>>[],
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final waits = <Duration>[];
      final client = _build(
        client: mock,
        sleep: (d) async {
          waits.add(d);
        },
      );
      final page = await client.listOrders(
        merchantId: _merchantId,
        modifiedFrom: DateTime.utc(2025, 1, 1),
        modifiedTo: DateTime.utc(2025, 1, 2),
        offset: 0,
        limit: 100,
      );
      expect(page.elements, isEmpty);
      expect(calls, 2);
      expect(waits, hasLength(1));
      expect(waits.single, const Duration(seconds: 1));
    });

    test('throws CloverApiRateLimitedException after budget exhausted', () async {
      final mock = http_testing.MockClient((http.Request req) async {
        return http.Response('rate limited', 429);
      });
      final client = _build(client: mock, maxRetries: 1);
      await expectLater(
        client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsA(isA<CloverApiRateLimitedException>()),
      );
    });
  });

  group('CloverPosProductionApiClient — auth + permanent errors', () {
    test('401 throws CloverApiAuthException with no retry', () async {
      var calls = 0;
      final mock = http_testing.MockClient((http.Request req) async {
        calls += 1;
        return http.Response('unauthorised', 401);
      });
      final client = _build(client: mock);
      await expectLater(
        client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsA(isA<CloverApiAuthException>()),
      );
      expect(calls, 1, reason: 'auth errors must not retry');
    });

    test('400 throws CloverApiClientErrorException with no retry', () async {
      var calls = 0;
      final mock = http_testing.MockClient((http.Request req) async {
        calls += 1;
        return http.Response('bad filter', 400);
      });
      final client = _build(client: mock);
      await expectLater(
        client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsA(isA<CloverApiClientErrorException>()),
      );
      expect(calls, 1);
    });
  });

  group('CloverPosProductionApiClient — 500 + timeout', () {
    test('500 retries until budget then throws CloverApiServerException',
        () async {
      var calls = 0;
      final mock = http_testing.MockClient((http.Request req) async {
        calls += 1;
        return http.Response('boom', 500);
      });
      final client = _build(client: mock, maxRetries: 2);
      await expectLater(
        client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsA(isA<CloverApiServerException>()),
      );
      expect(calls, 3, reason: 'maxRetries=2 means 3 total attempts');
    });

    test('timeout throws CloverApiTimeoutException after retries', () async {
      var calls = 0;
      final mock = http_testing.MockClient((http.Request req) async {
        calls += 1;
        // Simulate by making the response generation slower than the
        // request timeout.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('', 200);
      });
      final client = _build(
        client: mock,
        requestTimeout: const Duration(milliseconds: 5),
        maxRetries: 1,
      );
      await expectLater(
        client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsA(isA<CloverApiTimeoutException>()),
      );
      expect(calls, 2);
    });
  });

  group('CloverPosProductionApiClient — schema violation', () {
    test('non-JSON body throws CloverApiResponseFormatException', () async {
      final mock = http_testing.MockClient((http.Request req) async {
        return http.Response(
          '<html>not json</html>',
          200,
          headers: const <String, String>{'content-type': 'text/html'},
        );
      });
      final client = _build(client: mock);
      await expectLater(
        client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsA(isA<CloverApiResponseFormatException>()),
      );
    });

    test('JSON array (not object) throws schema error', () async {
      final mock = http_testing.MockClient((http.Request req) async {
        return http.Response(
          '[]',
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = _build(client: mock);
      await expectLater(
        client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsA(isA<CloverApiResponseFormatException>()),
      );
    });
  });

  group('CloverPosProductionApiClient — registerWebhook', () {
    test('POSTs /v3/apps/{aId}/webhooks with Idempotency-Key + bearer',
        () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request req) async {
        captured = req;
        return http.Response(
          jsonEncode(<String, Object?>{'id': 'sub-1'}),
          201,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = _build(client: mock);
      final id = await client.registerWebhook(
        merchantId: _merchantId,
        callbackUrl: 'https://app.forgeflow.app/v1/integrations/clover/webhook',
        eventTypes: const <String>['O'],
      );
      expect(id, 'sub-1');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/v3/apps/$_appId/webhooks');
      expect(captured.headers['Authorization'], 'Bearer $_appToken');
      expect(
        captured.headers['Idempotency-Key'],
        isNotNull,
        reason: 'Idempotency-Key required on POST /v3/apps/{aId}/webhooks',
      );
      expect(captured.headers['Idempotency-Key'], isNotEmpty);
      final decoded = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(decoded['merchantId'], _merchantId);
      expect(decoded['url'], 'https://app.forgeflow.app/v1/integrations/clover/webhook');
      expect(decoded['eventTypes'], <String>['O']);
    });

    test('same logical request reuses the same idempotency key', () async {
      final keys = <String>[];
      final mock = http_testing.MockClient((http.Request req) async {
        keys.add(req.headers['Idempotency-Key']!);
        return http.Response(
          jsonEncode(<String, Object?>{'id': 'sub-1'}),
          201,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = _build(client: mock);
      await client.registerWebhook(
        merchantId: _merchantId,
        callbackUrl: 'https://x.example/cb',
        eventTypes: const <String>['O'],
      );
      await client.registerWebhook(
        merchantId: _merchantId,
        callbackUrl: 'https://x.example/cb',
        eventTypes: const <String>['O'],
      );
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
    });

    test('schema violation when response missing id', () async {
      final mock = http_testing.MockClient((http.Request req) async {
        return http.Response(
          jsonEncode(<String, Object?>{}),
          201,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = _build(client: mock);
      await expectLater(
        client.registerWebhook(
          merchantId: _merchantId,
          callbackUrl: 'https://x.example/cb',
          eventTypes: const <String>['O'],
        ),
        throwsA(isA<CloverApiResponseFormatException>()),
      );
    });
  });

  group('CloverPosProductionApiClient — unregisterWebhook', () {
    test('DELETEs /v3/apps/{aId}/webhooks/{id} and accepts empty body',
        () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request req) async {
        captured = req;
        return http.Response('', 204);
      });
      final client = _build(client: mock);
      await client.unregisterWebhook(
        merchantId: _merchantId,
        subscriptionId: 'sub-1',
      );
      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/v3/apps/$_appId/webhooks/sub-1');
    });

    test('rejects empty subscription id', () async {
      final client = _build(
        client: http_testing.MockClient((_) async => http.Response('', 204)),
      );
      expect(
        () => client.unregisterWebhook(
          merchantId: _merchantId,
          subscriptionId: '',
        ),
        throwsArgumentError,
      );
    });
  });

  group('CloverPosProductionApiClient — token resolution', () {
    test('throws when merchant token source returns empty', () async {
      final client = CloverPosProductionApiClient(
        httpClient:
            http_testing.MockClient((_) async => http.Response('{}', 200)),
        merchantTokenSource: () async => '',
        appTokenSource: () => _appToken,
        appIdSource: () => _appId,
        sleep: (_) async {},
      );
      await expectLater(
        client.listOrders(
          merchantId: _merchantId,
          modifiedFrom: DateTime.utc(2025, 1, 1),
          modifiedTo: DateTime.utc(2025, 1, 2),
          offset: 0,
          limit: 100,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when app id source returns empty', () async {
      final client = CloverPosProductionApiClient(
        httpClient: http_testing.MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{'id': 'x'}),
            201,
            headers: const <String, String>{'content-type': 'application/json'},
          ),
        ),
        merchantTokenSource: () async => _merchantToken,
        appTokenSource: () => _appToken,
        appIdSource: () => '',
        sleep: (_) async {},
      );
      await expectLater(
        client.registerWebhook(
          merchantId: _merchantId,
          callbackUrl: 'https://x.example/cb',
          eventTypes: const <String>['O'],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // The api client is a CloverApiClient — keep that contract pinned so
  // a refactor that breaks the implements clause is caught at compile
  // time.
  test('implements CloverApiClient', () {
    final client = _build(
      client: http_testing.MockClient((_) async => http.Response('', 200)),
    );
    expect(client, isA<CloverApiClient>());
  });
}
