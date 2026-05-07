// Phase 8 — `8.transport.revel-pos`. Production HTTP transport tests.
//
// Drives [RevelProductionApiClient] against a fake `http.Client` so the
// wire shape — URLs, headers, pagination, 429 backoff, typed errors,
// idempotency keys, TIMESTAMPTZ preservation, OAuth token exchange,
// API-AUTHENTICATION fallback — is pinned without a live vendor.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/revel_pos_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  group('exchangeClientCredentials (OAuth tier)', () {
    test('POSTs grant_type=client_credentials and parses access_token + ttl',
        () async {
      late http.Request seen;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        clock: () => DateTime.utc(2026, 5, 6, 12, 0, 0),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'jwt-abc',
              'expires_in': 3600,
              'token_type': 'Bearer',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      final client = RevelProductionApiClient(deps: deps);

      final token = await client.exchangeClientCredentials(
        clientId: 'cid',
        clientSecret: 'csecret',
        audience: 'https://api.revelsystems.com',
      );

      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://authentication.revelup.com/oauth/token');
      expect(seen.headers['content-type'],
          contains('application/x-www-form-urlencoded'));
      expect(seen.body, contains('grant_type=client_credentials'));
      expect(seen.body, contains('client_id=cid'));
      expect(seen.body, contains('client_secret=csecret'));

      expect(token.accessToken, 'jwt-abc');
      expect(token.expiresAt, DateTime.utc(2026, 5, 6, 13, 0, 0));
    });

    test('falls back to documented TTL when expires_in is missing', () async {
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        clock: () => DateTime.utc(2026, 5, 6, 12, 0, 0),
        httpClient: http_testing.MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{'access_token': 'jwt-xyz'}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          ),
        ),
      );
      final client = RevelProductionApiClient(deps: deps);
      final token = await client.exchangeClientCredentials(
        clientId: 'cid',
        clientSecret: 'csec',
        audience: 'https://api.revelsystems.com',
      );
      // Documented 86400s default.
      expect(
        token.expiresAt,
        DateTime.utc(2026, 5, 6, 12, 0, 0).add(const Duration(seconds: 86400)),
      );
    });
  });

  group('exchangeClientCredentials (apiKeyHeader tier)', () {
    test('does not hit OAuth endpoint; returns synthetic envelope',
        () async {
      var hits = 0;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.apiKeyHeader,
        sleep: (_) async {},
        clock: () => DateTime.utc(2026, 5, 6, 12, 0, 0),
        httpClient: http_testing.MockClient((_) async {
          hits += 1;
          return http.Response('', 200);
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      final token = await client.exchangeClientCredentials(
        clientId: 'k',
        clientSecret: 's',
        audience: '',
      );
      expect(hits, 0);
      expect(token.accessToken, 'k:s');
      expect(token.expiresAt.isAfter(DateTime.utc(2027, 1, 1)), true);
    });
  });

  group('listOrders happy path + auth', () {
    test('GET emits Bearer authorization + offset/limit pagination', () async {
      late http.Request seen;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        pageLimit: 50,
        sleep: (_) async {},
        clock: () => DateTime.utc(2026, 5, 6, 12, 0, 0),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': <Object?>[
                <String, Object?>{
                  'id': '111',
                  'created_date': '2026-05-05T18:00:00Z',
                  'updated_date': '2026-05-05T19:00:00Z',
                  'number_of_people': 2,
                  'final_total': '12.50',
                  'closed': true,
                },
              ],
              'meta': <String, Object?>{
                'next_offset': 50,
                'last_modified_seen': '2026-05-05T19:00:00Z',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      final client = RevelProductionApiClient(deps: deps);

      final page = await client.listOrders(
        accessToken: 'jwt-abc',
        modifiedSince: DateTime.utc(2026, 5, 1, 0, 0, 0),
        modifiedUntil: DateTime.utc(2026, 5, 6, 0, 0, 0),
      );

      expect(seen.method, 'GET');
      expect(seen.url.host, 'api.revelsystems.com');
      expect(seen.url.path, '/external/integrations');
      expect(seen.url.queryParameters['offset'], '0');
      expect(seen.url.queryParameters['limit'], '50');
      expect(seen.url.queryParameters['modified_since'], '2026-05-01T00:00:00.000Z');
      expect(seen.url.queryParameters['modified_until'], '2026-05-06T00:00:00.000Z');
      expect(seen.headers['authorization'], 'Bearer jwt-abc');
      expect(seen.headers['accept'], 'application/json');

      expect(page.records.single['id'], '111');
      expect(page.records.single['updated_date'], '2026-05-05T19:00:00Z');
      expect(page.nextCursor, '50');
      expect(page.lastModifiedSeen, DateTime.utc(2026, 5, 5, 19, 0, 0));
    });

    test('uses API-AUTHENTICATION header in apiKeyHeader mode', () async {
      late Map<String, String> seenHeaders;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.apiKeyHeader,
        sleep: (_) async {},
        httpClient: http_testing.MockClient((request) async {
          seenHeaders = Map<String, String>.from(request.headers);
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': const <Object?>[],
              'meta': const <String, Object?>{},
            }),
            200,
          );
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      await client.listOrders(
        accessToken: 'mykey:mysecret',
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );
      // package:http lowercases header keys; look up case-insensitively.
      String? lookup(String name) {
        final lower = name.toLowerCase();
        for (final entry in seenHeaders.entries) {
          if (entry.key.toLowerCase() == lower) return entry.value;
        }
        return null;
      }
      expect(lookup('API-AUTHENTICATION'), 'mykey:mysecret');
      expect(lookup('authorization'), isNull);
    });
  });

  group('listOrders pagination across pages', () {
    test('cursor offset advances and final page has null nextCursor',
        () async {
      final responses = <http.Response>[
        http.Response(
          jsonEncode(<String, Object?>{
            'records': <Object?>[
              <String, Object?>{
                'id': 'a',
                'updated_date': '2026-05-05T18:00:00Z',
              },
            ],
            'meta': <String, Object?>{'next_offset': 1},
          }),
          200,
        ),
        http.Response(
          jsonEncode(<String, Object?>{
            'records': <Object?>[
              <String, Object?>{
                'id': 'b',
                'updated_date': '2026-05-05T19:00:00Z',
              },
            ],
            'meta': <String, Object?>{
              'total_count': 2,
            },
          }),
          200,
        ),
      ];
      final seenOffsets = <String?>[];
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        pageLimit: 1,
        sleep: (_) async {},
        httpClient: http_testing.MockClient((request) async {
          seenOffsets.add(request.url.queryParameters['offset']);
          return responses.removeAt(0);
        }),
      );
      final client = RevelProductionApiClient(deps: deps);

      final page1 = await client.listOrders(
        accessToken: 'tok',
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );
      expect(page1.nextCursor, '1');
      final page2 = await client.listOrders(
        accessToken: 'tok',
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
        cursor: page1.nextCursor,
      );
      expect(page2.nextCursor, isNull);
      expect(seenOffsets, <String?>['0', '1']);
    });
  });

  group('error mapping', () {
    test('401 surfaces unauthorized with no retry', () async {
      var hits = 0;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        httpClient: http_testing.MockClient((_) async {
          hits += 1;
          return http.Response('{"error":"invalid_token"}', 401);
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      Object? caught;
      try {
        await client.listOrders(
          accessToken: 'expired',
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        );
      } catch (e) {
        caught = e;
      }
      expect(hits, 1);
      expect(caught, isA<RevelTransportException>());
      expect(
        (caught as RevelTransportException).kind,
        RevelTransportErrorKind.unauthorized,
      );
      expect(caught.statusCode, 401);
    });

    test('403 surfaces forbidden', () async {
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        httpClient: http_testing.MockClient(
          (_) async => http.Response('{}', 403),
        ),
      );
      final client = RevelProductionApiClient(deps: deps);
      try {
        await client.listOrders(
          accessToken: 't',
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        );
        fail('expected throw');
      } on RevelTransportException catch (e) {
        expect(e.kind, RevelTransportErrorKind.forbidden);
      }
    });
  });

  group('429 backoff', () {
    test('honors Retry-After (seconds) and retries until success', () async {
      var attempts = 0;
      final waits = <Duration>[];
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (d) async {
          waits.add(d);
        },
        // deterministic jitter
        random: Random(0),
        httpClient: http_testing.MockClient((_) async {
          attempts += 1;
          if (attempts == 1) {
            return http.Response(
              '{"error":"too_many_requests"}',
              429,
              headers: <String, String>{'retry-after': '2'},
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': const <Object?>[],
              'meta': const <String, Object?>{},
            }),
            200,
          );
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      await client.listOrders(
        accessToken: 't',
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );
      expect(attempts, 2);
      expect(waits, <Duration>[const Duration(seconds: 2)]);
    });

    test('exhausts retry budget and throws rateLimited', () async {
      var attempts = 0;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        maxRetries: 2,
        sleep: (_) async {},
        random: Random(0),
        httpClient: http_testing.MockClient((_) async {
          attempts += 1;
          return http.Response('{}', 429);
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      try {
        await client.listOrders(
          accessToken: 't',
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        );
        fail('expected throw');
      } on RevelTransportException catch (e) {
        expect(e.kind, RevelTransportErrorKind.rateLimited);
        expect(e.statusCode, 429);
        // initial attempt + 2 retries = 3 total
        expect(attempts, 3);
      }
    });
  });

  group('500 retry', () {
    test('500 retries and succeeds on second attempt', () async {
      var attempts = 0;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        random: Random(0),
        httpClient: http_testing.MockClient((_) async {
          attempts += 1;
          if (attempts == 1) {
            return http.Response('boom', 500);
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': const <Object?>[],
            }),
            200,
          );
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      final page = await client.listOrders(
        accessToken: 't',
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );
      expect(attempts, 2);
      expect(page.records, isEmpty);
    });

    test('exhausted 500 retries surfaces serverError', () async {
      var attempts = 0;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        maxRetries: 1,
        sleep: (_) async {},
        random: Random(0),
        httpClient: http_testing.MockClient((_) async {
          attempts += 1;
          return http.Response('boom', 503);
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      try {
        await client.listOrders(
          accessToken: 't',
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        );
        fail('expected throw');
      } on RevelTransportException catch (e) {
        expect(e.kind, RevelTransportErrorKind.serverError);
        expect(attempts, 2);
      }
    });
  });

  group('schema roundtrip', () {
    test('records preserve TIMESTAMPTZ strings unchanged for adapter', () async {
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        httpClient: http_testing.MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{
              'records': <Object?>[
                <String, Object?>{
                  'id': 42,
                  'created_date': '2026-05-05T18:00:00.000Z',
                  'updated_date': '2026-05-05T19:00:00.000Z',
                  'number_of_people': 4,
                  'final_total': 84.0,
                  'closed': true,
                },
              ],
              'meta': <String, Object?>{},
            }),
            200,
          ),
        ),
      );
      final client = RevelProductionApiClient(deps: deps);
      final page = await client.listOrders(
        accessToken: 't',
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );
      final row = page.records.single;
      expect(row['created_date'], '2026-05-05T18:00:00.000Z');
      expect(row['updated_date'], '2026-05-05T19:00:00.000Z');
      // The transport falls back to the latest record's updated_date
      // when meta.last_modified_seen is missing.
      expect(page.lastModifiedSeen, DateTime.utc(2026, 5, 5, 19, 0, 0));
    });
  });

  group('idempotency keys', () {
    test('registerWebhook POST emits Idempotency-Key header', () async {
      late http.Request seen;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        idempotencyKeyGenerator: () => 'rev-idem-001',
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{'subscription_id': 'sub_42'}),
            200,
          );
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      final id = await client.registerWebhook(
        accessToken: 'jwt',
        url: 'https://proxy.example/v1/webhooks/o/l/revel',
        events: const <String>['order.finalized'],
        signingSecret: 'whsec_x',
      );
      expect(id, 'sub_42');
      expect(seen.method, 'POST');
      expect(seen.headers['idempotency-key'], 'rev-idem-001');
      expect(seen.headers['authorization'], 'Bearer jwt');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['url'], 'https://proxy.example/v1/webhooks/o/l/revel');
      expect(body['events'], <String>['order.finalized']);
      expect(body['signing_secret'], 'whsec_x');
    });

    test('unregisterWebhook DELETE tolerates 404', () async {
      var hits = 0;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        idempotencyKeyGenerator: () => 'rev-idem-002',
        httpClient: http_testing.MockClient((_) async {
          hits += 1;
          return http.Response('', 404);
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      await client.unregisterWebhook(
        accessToken: 'jwt',
        subscriptionId: 'sub_404',
      );
      expect(hits, 1);
    });
  });

  group('sampleOrder', () {
    test('returns first record on success or empty map when none', () async {
      var which = 0;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        httpClient: http_testing.MockClient((_) async {
          which += 1;
          if (which == 1) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'records': <Object?>[
                  <String, Object?>{'id': 'sample-1', 'final_total': '20.00'},
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{'records': const <Object?>[]}),
            200,
          );
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      final s1 = await client.sampleOrder(accessToken: 't');
      expect(s1['id'], 'sample-1');
      final s2 = await client.sampleOrder(accessToken: 't');
      expect(s2, isEmpty);
    });
  });

  group('fetchOrder', () {
    test('returns the order map when wrapped under "order"', () async {
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        httpClient: http_testing.MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{
              'order': <String, Object?>{
                'id': '99',
                'updated_date': '2026-05-05T19:00:00Z',
              },
            }),
            200,
          ),
        ),
      );
      final client = RevelProductionApiClient(deps: deps);
      final order = await client.fetchOrder(accessToken: 't', orderId: '99');
      expect(order['id'], '99');
      expect(order['updated_date'], '2026-05-05T19:00:00Z');
    });
  });

  group('malformed response handling', () {
    test('non-JSON 2xx body throws malformedResponse', () async {
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        sleep: (_) async {},
        httpClient: http_testing.MockClient(
          (_) async => http.Response('<html>oops</html>', 200),
        ),
      );
      final client = RevelProductionApiClient(deps: deps);
      try {
        await client.listOrders(
          accessToken: 't',
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        );
        fail('expected throw');
      } on RevelTransportException catch (e) {
        expect(e.kind, RevelTransportErrorKind.malformedResponse);
      }
    });
  });

  group('network failure', () {
    test('repeated network errors exhaust budget and surface network kind',
        () async {
      var attempts = 0;
      final deps = RevelProductionApiClientDeps(
        authMode: RevelAuthMode.oauth,
        maxRetries: 1,
        sleep: (_) async {},
        random: Random(0),
        httpClient: http_testing.MockClient((_) async {
          attempts += 1;
          throw http.ClientException('connection reset by peer');
        }),
      );
      final client = RevelProductionApiClient(deps: deps);
      try {
        await client.listOrders(
          accessToken: 't',
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        );
        fail('expected throw');
      } on RevelTransportException catch (e) {
        expect(e.kind, RevelTransportErrorKind.network);
        expect(attempts, 2);
      }
    });
  });
}
