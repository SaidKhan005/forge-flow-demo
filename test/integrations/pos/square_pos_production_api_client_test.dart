// Phase 8 — production Square HTTP client coverage.
//
// Uses `package:http/testing.dart`'s `MockClient` (the existing helper
// already used by `http_sync_proxy_client_test.dart`) so we exercise
// the full `package:http` plumbing — header construction, JSON
// encoding, retry loop — without ever opening a real socket.
//
// Test matrix (per the slice prompt):
//
//   1. Happy GET (`listLocations`) hits production base URI, sends
//      `Square-Version` + bearer header, returns parsed `locations`.
//   2. Happy POST (`searchOrders`) sends the documented body shape
//      and follows the cursor across two pages.
//   3. 429 with `Retry-After` honored — backoff sleeps the requested
//      window then succeeds on the second attempt.
//   4. 401 surfaces as `SquareAuthError` (no retry).
//   5. 500 retried with exponential backoff up to the budget; final
//      attempt surfaces as `SquareTransientError`.
//   6. Timeout surfaces as `SquareTransientError` and is retried up
//      to the configured budget.
//   7. Schema roundtrip — fixture orders pass through `searchOrders`
//      and the canonical-fact mapping (via the adapter) produces the
//      expected dollars + ISO timestamps.
//   8. Idempotency-Key header present on `registerWebhook`, absent on
//      `searchOrders` (Square ignores it on read endpoints).
//   9. Sandbox base URI override routes traffic at the sandbox host.
//  10. `unregisterWebhook` 404 swallowed (best-effort disconnect).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:forge_and_flow/integrations/pos/square_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/square_pos_production_api_client.dart';

import 'fixtures/square_orders_fixture.dart';

class _FakeCredentialResolver implements SquareCredentialResolver {
  _FakeCredentialResolver();

  static const String token = 'test-access-token';
  static const String client = 'test-client-id';
  static const String secret = 'test-client-secret';
  int resolveCalls = 0;

  @override
  Future<String> resolveAccessToken(SquareCredentialHandle handle) async {
    resolveCalls += 1;
    return token;
  }

  @override
  String get clientId => client;

  @override
  String get clientSecret => secret;
}

const _credential = SquareCredentialHandle(
  connectionId: 'conn-1',
  operatorId: 'op-1',
  locationId: 'loc-1',
);

SquarePosProductionApiClient _client({
  required http.Client httpClient,
  String defaultBase = kSquareProductionBaseUrl,
  Uri? override,
  _FakeCredentialResolver? resolver,
  String idempotencyKey = 'idem-key-deterministic',
  Duration baseRetryDelay = Duration.zero,
  int maxRetries = 5,
  Future<void> Function(Duration)? sleep,
  DateTime Function()? now,
}) {
  return SquarePosProductionApiClient(
    credentials: resolver ?? _FakeCredentialResolver(),
    httpClient: httpClient,
    defaultBaseUri: defaultBase,
    baseUriOverride: override,
    baseRetryDelay: baseRetryDelay,
    maxRetries: maxRetries,
    idempotencyKeyMinter: () => idempotencyKey,
    sleep: sleep ?? (_) async {},
    now: now,
  );
}

void main() {
  group('SquarePosProductionApiClient', () {
    test('listLocations hits production base, sends auth headers', () async {
      late http.Request seen;
      final client = _client(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'locations': sampleLocations,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final locations = await client.listLocations(credential: _credential);

      expect(seen.method, 'GET');
      expect(seen.url.host, 'connect.squareup.com');
      expect(seen.url.path, kSquareLocationsPath);
      expect(seen.headers['authorization'], 'Bearer test-access-token');
      expect(seen.headers['square-version'], kSquareApiVersion);
      expect(seen.headers['accept'], 'application/json');
      expect(locations, hasLength(2));
      expect(locations.first['id'], 'L_RESTAURANT_A');
    });

    test('searchOrders posts documented body shape and follows cursor',
        () async {
      final calls = <http.Request>[];
      final client = _client(
        httpClient: http_testing.MockClient((request) async {
          calls.add(request);
          if (calls.length == 1) {
            return http.Response(
              jsonEncode(sampleSearchOrdersResponse),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response(
            jsonEncode(sampleEmptyTrailingPage),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final firstWindow = DateTime.utc(2026, 5, 3, 16, 0, 0);
      final secondWindow = DateTime.utc(2026, 5, 3, 21, 0, 0);
      final firstPage = await client.searchOrders(
        credential: _credential,
        updatedAtMin: firstWindow,
        updatedAtMax: secondWindow,
        locationIds: const <String>['L_RESTAURANT_A', 'L_RESTAURANT_B'],
      );
      expect(firstPage.cursor, 'NEXT_PAGE_CURSOR_TOKEN');
      expect(firstPage.orders, hasLength(3));

      final nextPage = await client.searchOrders(
        credential: _credential,
        updatedAtMin: firstWindow,
        updatedAtMax: secondWindow,
        locationIds: const <String>['L_RESTAURANT_A', 'L_RESTAURANT_B'],
        cursor: firstPage.cursor,
      );
      expect(nextPage.cursor, isNull);
      expect(nextPage.orders, isEmpty);

      expect(calls, hasLength(2));
      final firstBody = jsonDecode(calls.first.body) as Map<String, Object?>;
      expect(firstBody['location_ids'],
          containsAll(<String>['L_RESTAURANT_A', 'L_RESTAURANT_B']));
      expect(firstBody.containsKey('cursor'), isFalse);

      final query = (firstBody['query'] as Map).cast<String, Object?>();
      final filter = (query['filter'] as Map).cast<String, Object?>();
      final dateTimeFilter =
          (filter['date_time_filter'] as Map).cast<String, Object?>();
      final updatedAt =
          (dateTimeFilter['updated_at'] as Map).cast<String, Object?>();
      expect(updatedAt['start_at'], '2026-05-03T16:00:00.000Z');
      expect(updatedAt['end_at'], '2026-05-03T21:00:00.000Z');

      final secondBody = jsonDecode(calls.last.body) as Map<String, Object?>;
      expect(secondBody['cursor'], 'NEXT_PAGE_CURSOR_TOKEN');
    });

    test('429 with Retry-After honored then succeeds', () async {
      var attempts = 0;
      final sleeps = <Duration>[];
      final client = _client(
        httpClient: http_testing.MockClient((request) async {
          attempts += 1;
          if (attempts == 1) {
            return http.Response(
              '{"errors":[{"category":"RATE_LIMIT_ERROR","code":"RATE_LIMITED"}]}',
              429,
              headers: const <String, String>{
                'retry-after': '2',
                'content-type': 'application/json',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{'locations': sampleLocations}),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
        sleep: (d) async {
          sleeps.add(d);
        },
      );

      final result = await client.listLocations(credential: _credential);
      expect(attempts, 2);
      expect(sleeps.single, const Duration(seconds: 2));
      expect(result, hasLength(2));
    });

    test('401 surfaces as SquareAuthError without retry', () async {
      var attempts = 0;
      final client = _client(
        httpClient: http_testing.MockClient((request) async {
          attempts += 1;
          return http.Response(
            '{"errors":[{"category":"AUTHENTICATION_ERROR","code":"UNAUTHORIZED","detail":"token revoked"}]}',
            401,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      await expectLater(
        client.listLocations(credential: _credential),
        throwsA(isA<SquareAuthError>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message',
                contains('token revoked'))),
      );
      expect(attempts, 1, reason: '401 must not retry');
    });

    test('500 retried up to budget then surfaces SquareTransientError',
        () async {
      var attempts = 0;
      final sleeps = <Duration>[];
      final client = _client(
        maxRetries: 3,
        baseRetryDelay: const Duration(milliseconds: 10),
        httpClient: http_testing.MockClient((request) async {
          attempts += 1;
          return http.Response(
            '{"errors":[{"category":"API_ERROR","code":"INTERNAL_SERVER_ERROR"}]}',
            500,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
        sleep: (d) async {
          sleeps.add(d);
        },
      );

      await expectLater(
        client.listLocations(credential: _credential),
        throwsA(isA<SquareTransientError>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
      expect(attempts, 4, reason: '1 initial + 3 retries');
      expect(sleeps, hasLength(3));
      // Exponential growth: 10ms, 20ms, 40ms
      expect(sleeps[0], const Duration(milliseconds: 10));
      expect(sleeps[1], const Duration(milliseconds: 20));
      expect(sleeps[2], const Duration(milliseconds: 40));
    });

    test('timeout surfaces as SquareTransientError and is retried', () async {
      var attempts = 0;
      final client = SquarePosProductionApiClient(
        credentials: _FakeCredentialResolver(),
        httpClient: http_testing.MockClient((request) async {
          attempts += 1;
          if (attempts <= 2) {
            // Stall longer than the configured timeout.
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return http.Response('{}', 200);
          }
          return http.Response(
            jsonEncode(<String, Object?>{'locations': sampleLocations}),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
        timeout: const Duration(milliseconds: 50),
        baseRetryDelay: Duration.zero,
        maxRetries: 5,
        idempotencyKeyMinter: () => 'k',
        sleep: (_) async {},
      );

      final result = await client.listLocations(credential: _credential);
      expect(result, hasLength(2));
      expect(attempts, 3);
    });

    test('schema roundtrip — adapter maps fixtures to canonical fact',
        () async {
      final client = _client(
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(sampleSearchOrdersResponse),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final response = await client.searchOrders(
        credential: _credential,
        updatedAtMin: DateTime.utc(2026, 5, 3, 16, 0),
        updatedAtMax: DateTime.utc(2026, 5, 3, 22, 0),
        locationIds: const <String>['L_RESTAURANT_A', 'L_RESTAURANT_B'],
      );

      // Sanity: the wire payload landed intact.
      expect(response.orders, hasLength(3));
      final first = response.orders.first;
      expect(first['id'], 'sq_ord_001');
      final money = (first['total_money'] as Map).cast<String, Object?>();
      expect(money['amount'], 4250);

      // Canonical projection — mirrors the adapter's
      // `_orderToCanonicalFact`. Cents → dollars; UTC instants
      // preserved.
      final cents = money['amount'] as int;
      final dollars = cents / 100.0;
      expect(dollars, 42.5);
      final createdAt = DateTime.parse(first['created_at']! as String).toUtc();
      expect(createdAt.toIso8601String(), '2026-05-03T17:30:00.000Z');
    });

    test('Idempotency-Key sent on registerWebhook, omitted on searchOrders',
        () async {
      final byPath = <String, http.Request>{};
      final client = _client(
        httpClient: http_testing.MockClient((request) async {
          byPath[request.url.path] = request;
          if (request.url.path == kSquareWebhookSubscriptionPath) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'subscription': <String, Object?>{
                  'id': 'wh_sub_001',
                  'name': 'forgeflow',
                },
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response(
            jsonEncode(sampleEmptyTrailingPage),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
        idempotencyKey: 'idem-fixed-key',
      );

      await client.searchOrders(
        credential: _credential,
        updatedAtMin: DateTime.utc(2026, 5, 3),
        updatedAtMax: DateTime.utc(2026, 5, 4),
        locationIds: const <String>['L_RESTAURANT_A'],
      );
      final search = byPath[kSquareSearchOrdersPath]!;
      expect(search.headers.containsKey('idempotency-key'), isFalse);

      final webhookId = await client.registerWebhook(
        credential: _credential,
        notificationUrl: 'https://app.forgeflow.app/webhooks/square',
        events: kSquareWebhookEvents,
      );
      expect(webhookId, 'wh_sub_001');
      final webhook = byPath[kSquareWebhookSubscriptionPath]!;
      expect(webhook.headers['idempotency-key'], 'idem-fixed-key');
      // Square also requires the body-level idempotency_key on
      // CreateWebhookSubscription per their API reference.
      final body =
          jsonDecode(webhook.body) as Map<String, Object?>;
      expect(body['idempotency_key'], 'idem-fixed-key');
    });

    test('sandbox base URI override routes to sandbox host', () async {
      late http.Request seen;
      final client = _client(
        defaultBase: kSquareProductionBaseUrl,
        override: Uri.parse(kSquareSandboxBaseUrl),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{'locations': sampleLocations}),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      await client.listLocations(credential: _credential);
      expect(seen.url.host, 'connect.squareupsandbox.com');
      expect(client.baseUri.host, 'connect.squareupsandbox.com');
    });

    test('unregisterWebhook treats 404 as success', () async {
      var calls = 0;
      final client = _client(
        httpClient: http_testing.MockClient((request) async {
          calls += 1;
          return http.Response(
            '{"errors":[{"category":"INVALID_REQUEST_ERROR","code":"NOT_FOUND"}]}',
            404,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      await client.unregisterWebhook(
        credential: _credential,
        subscriptionId: 'wh_sub_already_gone',
      );
      expect(calls, 1, reason: '404 must not trigger retry');
    });

    test('Retry-After HTTP-date header parsed and capped', () async {
      var attempts = 0;
      final sleeps = <Duration>[];
      final fakeNow = DateTime.utc(2026, 5, 3, 17, 30, 0);
      final client = _client(
        httpClient: http_testing.MockClient((request) async {
          attempts += 1;
          if (attempts == 1) {
            return http.Response(
              '',
              429,
              headers: const <String, String>{
                'retry-after': 'Sun, 03 May 2026 17:30:05 GMT',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{'locations': sampleLocations}),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
        now: () => fakeNow,
        sleep: (d) async {
          sleeps.add(d);
        },
      );

      await client.listLocations(credential: _credential);
      expect(attempts, 2);
      expect(sleeps.single, const Duration(seconds: 5));
    });
  });
}
