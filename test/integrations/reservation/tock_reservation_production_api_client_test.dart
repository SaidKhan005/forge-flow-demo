// Phase 8.transport.tock-reservation — production HTTP client tests.
//
// All tests run against `package:http`'s `MockClient` — no live HTTP.
// Coverage:
//   1. Happy path: verifyApiKey + fetchSampleReservation +
//      fetchReservationsPage + fetchReservationById each round-trip
//      against the documented endpoint with bearer auth.
//   2. Pagination stitching: cursor token from `nextPageToken` flows
//      through to subsequent calls.
//   3. 429 backoff: transport retries up to the configured budget
//      then surfaces TockTransportException(rateLimited).
//   4. 401 unauthorized: typed exception fires.
//   5. Schema roundtrip with TZ preserved end-to-end (the request body
//      MUST carry the inbound offset, not a UTC-coerced shape).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  group('TockReservationProductionApiClient', () {
    late http_testing.MockClient mockHttp;
    late List<http.Request> seenRequests;
    late int rateLimitedCallsRemaining;
    late List<Duration> sleepCalls;

    Map<String, String> defaultHeaders() => const <String, String>{
          'content-type': 'application/json',
        };

    String encodeBody(Object? body) =>
        jsonEncode(body ?? const <String, Object?>{});

    setUp(() {
      seenRequests = <http.Request>[];
      rateLimitedCallsRemaining = 0;
      sleepCalls = <Duration>[];
    });

    test('verifyApiKey: GET /businesses/{id} with bearer auth → handle',
        () async {
      mockHttp = http_testing.MockClient((request) async {
        seenRequests.add(request);
        return http.Response(
          encodeBody(<String, Object?>{
            'id': 'bus_123',
            'businessId': 'bus_123',
            'timezone': 'America/Toronto',
          }),
          200,
          headers: defaultHeaders(),
        );
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        idempotencyKeyFactory: () => 'idem-fixed-1',
        sleeper: (d) async => sleepCalls.add(d),
      );

      final handle = await client.verifyApiKey(
        operatorId: 'op-1',
        locationId: 'loc-1',
        businessId: 'bus_123',
        apiKey: 'sk_live_test',
      );

      expect(seenRequests.length, 1);
      final req = seenRequests.single;
      expect(req.method, 'GET');
      expect(req.url.host, 'api.exploretock.com');
      expect(req.url.path, '/businesses/bus_123');
      expect(req.headers['authorization'], 'Bearer sk_live_test');
      expect(req.headers['accept'], 'application/json');
      expect(handle.businessId, 'bus_123');
    });

    test('verifyApiKey throws credentialMissing on empty pasted key',
        () async {
      mockHttp = http_testing.MockClient((request) async {
        return http.Response('{}', 200, headers: defaultHeaders());
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        sleeper: (d) async {},
      );
      expect(
        () => client.verifyApiKey(
          operatorId: 'op-1',
          locationId: 'loc-1',
          businessId: 'bus_123',
          apiKey: '',
        ),
        throwsA(isA<TockTransportException>().having(
          (e) => e.kind,
          'kind',
          TockTransportErrorKind.credentialMissing,
        )),
      );
    });

    test('fetchSampleReservation: posts search with pageSize=1', () async {
      mockHttp = http_testing.MockClient((request) async {
        seenRequests.add(request);
        return http.Response(
          encodeBody(<String, Object?>{
            'reservations': <Object?>[
              <String, Object?>{
                'id': 'res-1',
                'businessId': 'bus-1',
                'partySize': 4,
                'status': 'SEATED',
                'serviceDateTimestamp': '2026-05-04T19:00:00.000Z',
                'lastUpdatedTimestamp': '2026-05-04T19:10:00.000Z',
                'createdTimestamp': '2026-05-01T14:22:00.000Z',
              },
            ],
          }),
          200,
          headers: defaultHeaders(),
        );
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_live_x'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        idempotencyKeyFactory: () => 'idem-2',
        sleeper: (d) async => sleepCalls.add(d),
      );

      final sample = await client.fetchSampleReservation(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus-1',
        ),
      );

      expect(seenRequests.length, 1);
      final req = seenRequests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/reservations/search');
      expect(req.headers['authorization'], 'Bearer sk_live_x');
      expect(req.headers['idempotency-key'], 'idem-2');
      final decoded = jsonDecode(req.body) as Map<String, Object?>;
      expect(decoded['businessId'], 'bus-1');
      expect(decoded['pageSize'], 1);
      expect(sample['id'], 'res-1');
      expect(sample['status'], 'SEATED');
    });

    test(
        'fetchSampleReservation: empty list returns empty map (auth still validated)',
        () async {
      mockHttp = http_testing.MockClient((request) async {
        seenRequests.add(request);
        return http.Response(
          encodeBody(<String, Object?>{'reservations': <Object?>[]}),
          200,
          headers: defaultHeaders(),
        );
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_live_x'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        sleeper: (d) async {},
      );

      final sample = await client.fetchSampleReservation(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus-1',
        ),
      );

      expect(sample, isEmpty);
    });

    test(
        'fetchReservationsPage: pagination stitches via nextPageToken; '
        'TZ-preserved window in body', () async {
      // Two pages: page 1 returns nextPageToken=cursor-2; page 2 returns null.
      var hits = 0;
      mockHttp = http_testing.MockClient((request) async {
        seenRequests.add(request);
        hits++;
        final reqBody = jsonDecode(request.body) as Map<String, Object?>;
        if (hits == 1) {
          expect(reqBody['pageToken'], isNull);
          return http.Response(
            encodeBody(<String, Object?>{
              'reservations': <Object?>[
                <String, Object?>{
                  'id': 'p1-1',
                  'lastUpdatedTimestamp': '2026-05-04T18:00:00.000-04:00',
                },
                <String, Object?>{
                  'id': 'p1-2',
                  'lastUpdatedTimestamp': '2026-05-04T18:30:00.000-04:00',
                },
              ],
              'nextPageToken': 'cursor-2',
            }),
            200,
            headers: defaultHeaders(),
          );
        }
        expect(reqBody['pageToken'], 'cursor-2');
        return http.Response(
          encodeBody(<String, Object?>{
            'reservations': <Object?>[
              <String, Object?>{
                'id': 'p2-1',
                'lastUpdatedTimestamp': '2026-05-04T19:30:00.000-04:00',
              },
            ],
            'nextPageToken': null,
          }),
          200,
          headers: defaultHeaders(),
        );
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_live_y'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        idempotencyKeyFactory: () => 'idem-page',
        sleeper: (d) async {},
      );

      // Window with restaurant-local offset (-04:00). Body MUST preserve.
      final windowStart = DateTime.parse('2026-05-04T00:00:00.000-04:00');
      final windowEnd = DateTime.parse('2026-05-05T00:00:00.000-04:00');

      final page1 = await client.fetchReservationsPage(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus-1',
        ),
        windowStart: windowStart,
        windowEnd: windowEnd,
      );

      final page1Body =
          jsonDecode(seenRequests.first.body) as Map<String, Object?>;
      // TIMESTAMPTZ preservation: the wire shape is ISO-8601 UTC, but
      // the moment MUST equal the original (offset-equivalent) instant.
      expect(
        DateTime.parse(page1Body['windowStart']! as String).toUtc(),
        windowStart.toUtc(),
      );
      expect(
        DateTime.parse(page1Body['windowEnd']! as String).toUtc(),
        windowEnd.toUtc(),
      );
      expect(page1.reservations.length, 2);
      expect(page1.nextCursor, 'cursor-2');
      expect(
        page1.lastModifiedSeen.toIso8601String(),
        DateTime.parse('2026-05-04T18:30:00.000-04:00').toIso8601String(),
      );

      final page2 = await client.fetchReservationsPage(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus-1',
        ),
        windowStart: windowStart,
        windowEnd: windowEnd,
        resumeFromCursor: page1.nextCursor,
      );
      expect(page2.nextCursor, isNull);
      expect(page2.reservations.single['id'], 'p2-1');
    });

    test('fetchReservationById: 404 returns null, otherwise parsed map',
        () async {
      var hits = 0;
      mockHttp = http_testing.MockClient((request) async {
        seenRequests.add(request);
        hits++;
        if (hits == 1) {
          return http.Response('{"id":"res-9","status":"EXPECTED"}', 200,
              headers: defaultHeaders());
        }
        return http.Response('{}', 404, headers: defaultHeaders());
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_live_z'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        sleeper: (d) async {},
      );

      final found = await client.fetchReservationById(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus-1',
        ),
        reservationId: 'res-9',
      );
      expect(found, isNotNull);
      expect(found!['id'], 'res-9');
      expect(seenRequests.first.url.path, '/reservations/res-9');

      final missing = await client.fetchReservationById(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus-1',
        ),
        reservationId: 'res-missing',
      );
      expect(missing, isNull);
    });

    test('429 backoff: retries up to the budget then surfaces rateLimited',
        () async {
      mockHttp = http_testing.MockClient((request) async {
        rateLimitedCallsRemaining++;
        return http.Response('{}', 429, headers: <String, String>{
          'content-type': 'application/json',
          'retry-after': '1',
        });
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_live_q'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        rateLimitMaxRetries: 3,
        sleeper: (d) async => sleepCalls.add(d),
        idempotencyKeyFactory: () => 'idem-429',
      );

      try {
        await client.fetchSampleReservation(
          credentials: const TockCredentialHandle(
            connectionId: 'conn-1',
            businessId: 'bus-1',
          ),
        );
        fail('expected TockTransportException');
      } on TockTransportException catch (error) {
        expect(error.kind, TockTransportErrorKind.rateLimited);
        expect(error.statusCode, 429);
      }

      // 1 initial attempt + 3 retries = 4 calls; 3 sleeps between them.
      expect(rateLimitedCallsRemaining, 4);
      expect(sleepCalls.length, 3);
      // Retry-After=1 honored on every sleep.
      for (final d in sleepCalls) {
        expect(d, const Duration(seconds: 1));
      }
    });

    test('429 then 200: transport recovers without surfacing the limit',
        () async {
      var hits = 0;
      mockHttp = http_testing.MockClient((request) async {
        hits++;
        if (hits == 1) {
          return http.Response('{}', 429, headers: <String, String>{
            'content-type': 'application/json',
            'retry-after': '0',
          });
        }
        return http.Response(
          encodeBody(<String, Object?>{'reservations': <Object?>[]}),
          200,
          headers: defaultHeaders(),
        );
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_live_r'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        rateLimitMaxRetries: 3,
        sleeper: (d) async => sleepCalls.add(d),
        idempotencyKeyFactory: () => 'idem-429-recover',
      );
      final sample = await client.fetchSampleReservation(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus-1',
        ),
      );
      expect(sample, isEmpty);
      expect(hits, 2);
      // One sleep between attempts.
      expect(sleepCalls.length, 1);
    });

    test('401 unauthorized surfaces TockTransportException.unauthorized',
        () async {
      mockHttp = http_testing.MockClient((request) async {
        return http.Response('{"error":"invalid_key"}', 401,
            headers: defaultHeaders());
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_bad'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        sleeper: (d) async {},
      );
      try {
        await client.fetchSampleReservation(
          credentials: const TockCredentialHandle(
            connectionId: 'conn-1',
            businessId: 'bus-1',
          ),
        );
        fail('expected TockTransportException');
      } on TockTransportException catch (error) {
        expect(error.kind, TockTransportErrorKind.unauthorized);
        expect(error.statusCode, 401);
      }
    });

    test('schema roundtrip: vendor payload preserved field-for-field',
        () async {
      final vendorPayload = <String, Object?>{
        'id': 'res_d1f9cd4a-4f4b-4d6e-9b7d-9a4f1f7c8e21',
        'businessId': 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
        'createdTimestamp': '2026-05-01T14:22:00.000-04:00',
        'lastUpdatedTimestamp': '2026-05-04T19:10:00.000-04:00',
        'serviceDateTimestamp': '2026-05-04T19:00:00.000-04:00',
        'partySize': 4,
        'status': 'SEATED',
      };
      mockHttp = http_testing.MockClient((request) async {
        return http.Response(
          encodeBody(<String, Object?>{
            'reservations': <Object?>[vendorPayload],
            'nextPageToken': null,
          }),
          200,
          headers: defaultHeaders(),
        );
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_live_s'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        sleeper: (d) async {},
      );

      final page = await client.fetchReservationsPage(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
        ),
        windowStart: DateTime.parse('2026-05-04T00:00:00.000-04:00'),
        windowEnd: DateTime.parse('2026-05-05T00:00:00.000-04:00'),
      );

      expect(page.reservations.length, 1);
      final got = page.reservations.single;
      expect(got, vendorPayload,
          reason:
              'vendor payload must round-trip through the transport untouched');
      // TZ preserved on the parsed lastModifiedSeen.
      expect(
        page.lastModifiedSeen,
        DateTime.parse('2026-05-04T19:10:00.000-04:00'),
      );
    });

    test('non-UTC base URI with prefix path is preserved on resolve',
        () async {
      mockHttp = http_testing.MockClient((request) async {
        seenRequests.add(request);
        return http.Response('{"id":"bus_1"}', 200, headers: defaultHeaders());
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://sandbox.exploretock.com/partner/'),
        sleeper: (d) async {},
      );
      await client.verifyApiKey(
        operatorId: 'op',
        locationId: 'loc',
        businessId: 'bus_1',
        apiKey: 'sk_live_a',
      );
      expect(seenRequests.single.url.path, '/partner/businesses/bus_1');
    });

    test('5xx triggers retry then succeeds', () async {
      var hits = 0;
      mockHttp = http_testing.MockClient((request) async {
        hits++;
        if (hits == 1) {
          return http.Response('{}', 503, headers: defaultHeaders());
        }
        return http.Response(
          encodeBody(<String, Object?>{'reservations': <Object?>[]}),
          200,
          headers: defaultHeaders(),
        );
      });
      final client = TockReservationProductionApiClient(
        credentialResolver: const TockPassThroughCredentialResolver(
          apiKeyByHandle: <String, String>{'conn-1': 'sk_live'},
        ),
        httpClient: mockHttp,
        baseUri: Uri.parse('https://api.exploretock.com'),
        rateLimitMaxRetries: 3,
        sleeper: (d) async => sleepCalls.add(d),
      );
      final sample = await client.fetchSampleReservation(
        credentials: const TockCredentialHandle(
          connectionId: 'conn-1',
          businessId: 'bus-1',
        ),
      );
      expect(sample, isEmpty);
      expect(hits, 2);
      expect(sleepCalls.length, 1);
    });
  });
}
