// Phase 8.transport.opentable-reservation — production OpenTable
// HTTP client tests.
//
// Drives [OpenTableReservationProductionApiClient] against a
// `package:http/testing.dart` MockClient so every transport seam is
// exercised without a partner credential or sandbox tenant. Coverage:
//
//   1. Happy-path GET /v1/reservations/search — bearer header set,
//      query params encoded, body decoded.
//   2. Pagination — `next_cursor` round-trips and the watermark
//      `lastModifiedSeen` reflects the latest `modified_at` on the
//      page.
//   3. 429 backoff — first response 429, retry honors `Retry-After`,
//      then succeeds; injected fake-sleep records the wait duration.
//   4. 401 surfaces as `OpenTableAuthException` (no retry).
//   5. Schema round-trip preserves the restaurant-local time-zone
//      offset on `seated_at` / `reserved_at` (CLAUDE.md Time
//      Guardrails — restaurant-local timing wins; the offset is NOT
//      stripped to UTC by the transport).
//
// Plus banned-items grep + idempotency-key on POSTs to enforce the
// V1 lean cut 2 boundaries from the prompt.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_reservation_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  group('listReservations', () {
    test('GET happy path: bearer, query params, decoded records', () async {
      final captured = <http.Request>[];
      final mock = http_testing.MockClient((http.Request request) async {
        captured.add(request);
        expect(request.method, 'GET');
        expect(
          request.url.path,
          kOpenTableReservationsSearchPath,
        );
        expect(request.url.queryParameters['restaurant_id'], 'rid-9876');
        expect(request.url.queryParameters['modified_since'], isNotEmpty);
        expect(request.url.queryParameters['modified_until'], isNotEmpty);
        expect(request.url.queryParameters['page_size'], '100');
        expect(request.headers['authorization'], 'Bearer access-token-fake');
        expect(request.headers['accept'], 'application/json');
        return http.Response(
          json.encode(<String, Object?>{
            'reservations': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'OT-1001',
                'restaurant_id': 'rid-9876',
                'reserved_at': '2026-05-10T19:30:00Z',
                'modified_at': '2026-05-04T12:00:00Z',
                'party_size': 2,
                'status': 'booked',
              },
            ],
            'next_cursor': null,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = _makeClient(mock);
      final page = await client.listReservations(
        accessToken: 'access-token-fake',
        restaurantId: 'rid-9876',
        modifiedSince: DateTime.utc(2026, 5, 4, 11, 0, 0),
        modifiedUntil: DateTime.utc(2026, 5, 4, 12, 30, 0),
      );
      expect(page.records, hasLength(1));
      expect(page.records.single['id'], 'OT-1001');
      expect(page.nextCursor, isNull);
      expect(
        page.lastModifiedSeen.toUtc(),
        DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      expect(captured, hasLength(1));
    });

    test('pagination: next_cursor surfaces, page 2 forwards cursor', () async {
      var page = 0;
      final mock = http_testing.MockClient((http.Request request) async {
        page += 1;
        if (page == 1) {
          expect(request.url.queryParameters['cursor'], isNull);
          return http.Response(
            json.encode(<String, Object?>{
              'reservations': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'OT-1',
                  'modified_at': '2026-05-04T10:00:00Z',
                  'reserved_at': '2026-05-10T19:30:00Z',
                  'party_size': 2,
                  'status': 'booked',
                },
                <String, Object?>{
                  'id': 'OT-2',
                  'modified_at': '2026-05-04T11:00:00Z',
                  'reserved_at': '2026-05-10T20:00:00Z',
                  'party_size': 4,
                  'status': 'seated',
                },
              ],
              'next_cursor': 'cursor-page-2',
            }),
            200,
          );
        }
        expect(request.url.queryParameters['cursor'], 'cursor-page-2');
        return http.Response(
          json.encode(<String, Object?>{
            'reservations': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'OT-3',
                'modified_at': '2026-05-04T12:30:00Z',
                'reserved_at': '2026-05-10T21:00:00Z',
                'party_size': 3,
                'status': 'completed',
              },
            ],
            'next_cursor': null,
          }),
          200,
        );
      });
      final client = _makeClient(mock);
      final p1 = await client.listReservations(
        accessToken: 'tok',
        restaurantId: 'rid',
        modifiedSince: DateTime.utc(2026, 5, 4),
        modifiedUntil: DateTime.utc(2026, 5, 5),
      );
      expect(p1.records, hasLength(2));
      expect(p1.nextCursor, 'cursor-page-2');
      expect(
        p1.lastModifiedSeen.toUtc(),
        DateTime.utc(2026, 5, 4, 11, 0, 0),
      );
      final p2 = await client.listReservations(
        accessToken: 'tok',
        restaurantId: 'rid',
        modifiedSince: DateTime.utc(2026, 5, 4),
        modifiedUntil: DateTime.utc(2026, 5, 5),
        cursor: p1.nextCursor,
      );
      expect(p2.records, hasLength(1));
      expect(p2.nextCursor, isNull);
      expect(
        p2.lastModifiedSeen.toUtc(),
        DateTime.utc(2026, 5, 4, 12, 30, 0),
      );
    });

    test('429 then 200: retry honors Retry-After, sleep recorded', () async {
      var attempts = 0;
      final mock = http_testing.MockClient((http.Request request) async {
        attempts += 1;
        if (attempts == 1) {
          return http.Response(
            json.encode(<String, Object?>{'error': 'rate_limited'}),
            429,
            headers: <String, String>{'retry-after': '1'},
          );
        }
        return http.Response(
          json.encode(<String, Object?>{
            'reservations': <Map<String, Object?>>[],
            'next_cursor': null,
          }),
          200,
        );
      });
      final sleeps = <Duration>[];
      final client = _makeClient(
        mock,
        sleep: (d) async {
          sleeps.add(d);
        },
      );
      final page = await client.listReservations(
        accessToken: 'tok',
        restaurantId: 'rid',
        modifiedSince: DateTime.utc(2026, 5, 4),
        modifiedUntil: DateTime.utc(2026, 5, 5),
      );
      expect(attempts, 2);
      expect(sleeps, hasLength(1));
      expect(sleeps.single, const Duration(seconds: 1));
      expect(page.records, isEmpty);
    });

    test('429 retry budget exhausted → OpenTableRateLimitedException', () async {
      var attempts = 0;
      final mock = http_testing.MockClient((http.Request request) async {
        attempts += 1;
        return http.Response(
          json.encode(<String, Object?>{'error': 'rate_limited'}),
          429,
          headers: <String, String>{'retry-after': '0'},
        );
      });
      final client = _makeClient(
        mock,
        sleep: (_) async {},
        maxRateLimitRetries: 2,
      );
      await expectLater(
        () => client.listReservations(
          accessToken: 'tok',
          restaurantId: 'rid',
          modifiedSince: DateTime.utc(2026, 5, 4),
          modifiedUntil: DateTime.utc(2026, 5, 5),
        ),
        throwsA(isA<OpenTableRateLimitedException>()),
      );
      // Initial attempt + 2 retries == 3 total.
      expect(attempts, 3);
    });

    test('401 surfaces as OpenTableAuthException (no retry)', () async {
      var attempts = 0;
      final mock = http_testing.MockClient((http.Request request) async {
        attempts += 1;
        return http.Response('unauthorized', 401);
      });
      final client = _makeClient(mock);
      await expectLater(
        () => client.listReservations(
          accessToken: 'expired',
          restaurantId: 'rid',
          modifiedSince: DateTime.utc(2026, 5, 4),
          modifiedUntil: DateTime.utc(2026, 5, 5),
        ),
        throwsA(isA<OpenTableAuthException>()),
      );
      expect(attempts, 1);
    });
  });

  group('schema roundtrip — restaurant-local TZ preserved', () {
    test(
      'reserved_at + seated_at offsets survive transport (CLAUDE.md Time Guardrails)',
      () async {
        // Restaurant in Eastern Daylight Time (-04:00). The transport
        // MUST pass the offset string through to the canonical-fact
        // map so the sink / dashboard can render the local instant.
        // If the transport stripped the offset (called .toUtc() on
        // the string and re-stringified) this test would fail because
        // the suffix would be `Z` rather than `-04:00`.
        const reservedAtLocal = '2026-05-10T19:30:00-04:00';
        const seatedAtLocal = '2026-05-10T19:35:12-04:00';
        const cancelledAtLocal = '2026-05-10T20:01:00-04:00';
        final mock = http_testing.MockClient((http.Request request) async {
          return http.Response(
            json.encode(<String, Object?>{
              'reservations': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'OT-tz',
                  'restaurant_id': 'rid-9876',
                  'reserved_at': reservedAtLocal,
                  'seated_at': seatedAtLocal,
                  'cancelled_at': cancelledAtLocal,
                  'modified_at': '2026-05-04T12:00:00-04:00',
                  'party_size': 2,
                  'status': 'seated',
                },
              ],
              'next_cursor': null,
            }),
            200,
          );
        });
        final client = _makeClient(mock);
        final page = await client.listReservations(
          accessToken: 'tok',
          restaurantId: 'rid-9876',
          modifiedSince: DateTime.utc(2026, 5, 4),
          modifiedUntil: DateTime.utc(2026, 5, 5),
        );
        final record = page.records.single;
        // Offset string is restaurant-local (-04:00), NOT
        // UTC-stripped (Z). Asserting the literal suffix is the
        // contract: the transport stays neutral on time projection.
        expect(record['reserved_at'], reservedAtLocal);
        expect(record['seated_at'], seatedAtLocal);
        expect(record['cancelled_at'], cancelledAtLocal);
        // Sanity: the suffix is not 'Z'.
        expect((record['seated_at']! as String).endsWith('-04:00'), isTrue);
        expect((record['seated_at']! as String).endsWith('Z'), isFalse);
        // The watermark instant is computed from `modified_at`; that
        // is allowed to be UTC since DateTime is an instant. The raw
        // string still survives in the record map.
        expect(
          page.lastModifiedSeen.isAtSameMomentAs(
            DateTime.utc(2026, 5, 4, 16, 0, 0),
          ),
          isTrue,
          reason:
              '12:00 -04:00 is the same instant as 16:00 UTC; record string is unchanged.',
        );
      },
    );

    test('fetchReservation preserves vendor envelope verbatim', () async {
      const reservedAtLocal = '2026-05-10T19:30:00-05:00';
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          json.encode(<String, Object?>{
            'reservation': <String, Object?>{
              'id': 'OT-detail',
              'reserved_at': reservedAtLocal,
              'party_size': 4,
              'status': 'booked',
            },
          }),
          200,
        );
      });
      final client = _makeClient(mock);
      final record = await client.fetchReservation(
        accessToken: 'tok',
        restaurantId: 'rid',
        reservationId: 'OT-detail',
      );
      expect(record['reserved_at'], reservedAtLocal);
    });
  });

  group('OAuth + idempotency on POSTs', () {
    test('exchangeAuthorizationCode posts form, decodes token', () async {
      http.Request? captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          json.encode(<String, Object?>{
            'access_token': 'access-1',
            'refresh_token': 'refresh-1',
            'expires_in': 3600,
          }),
          200,
        );
      });
      final client = _makeClient(mock);
      final token = await client.exchangeAuthorizationCode(
        authorizationCode: 'code-xyz',
        redirectUri: 'https://proxy.example/cb',
      );
      expect(token.accessToken, 'access-1');
      expect(token.refreshToken, 'refresh-1');
      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(captured!.url.path, kOpenTableOAuthTokenPath);
      expect(
        captured!.headers['content-type'],
        startsWith('application/x-www-form-urlencoded'),
      );
      // POSTs MUST carry an Idempotency-Key per the prompt.
      expect(captured!.headers['idempotency-key'], isNotEmpty);
      // Form fields encoded.
      expect(captured!.bodyFields['grant_type'], 'authorization_code');
      expect(captured!.bodyFields['code'], 'code-xyz');
      expect(captured!.bodyFields['redirect_uri'], 'https://proxy.example/cb');
    });

    test('refresh posts grant_type=refresh_token + Idempotency-Key', () async {
      http.Request? captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          json.encode(<String, Object?>{
            'access_token': 'access-2',
            'refresh_token': 'refresh-2',
            'expires_in': 1800,
          }),
          200,
        );
      });
      final client = _makeClient(
        mock,
        idempotencyKeyMinter: () => 'key-fixed-001',
      );
      final token = await client.refresh(refreshToken: 'old-refresh');
      expect(token.accessToken, 'access-2');
      expect(captured!.bodyFields['grant_type'], 'refresh_token');
      expect(captured!.bodyFields['refresh_token'], 'old-refresh');
      expect(captured!.headers['idempotency-key'], 'key-fixed-001');
    });

    test('registerWebhook posts JSON + Idempotency-Key, returns id', () async {
      http.Request? captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          json.encode(<String, Object?>{
            'subscription_id': 'sub-abc',
          }),
          201,
        );
      });
      final client = _makeClient(
        mock,
        idempotencyKeyMinter: () => 'key-webhook-001',
      );
      final id = await client.registerWebhook(
        accessToken: 'tok',
        restaurantId: 'rid-9876',
        url: 'https://proxy.example/v1/webhooks/op/loc/opentable',
        events: const <String>['reservation.modified'],
        signingSecret: 'whsec_x',
      );
      expect(id, 'sub-abc');
      expect(captured!.method, 'POST');
      expect(captured!.url.path, kOpenTableWebhookSubscriptionsPath);
      expect(captured!.headers['idempotency-key'], 'key-webhook-001');
      expect(captured!.headers['content-type'], 'application/json');
      final body = json.decode(captured!.body) as Map<String, Object?>;
      expect(body['restaurant_id'], 'rid-9876');
      expect(body['events'], <String>['reservation.modified']);
    });

    test('unregisterWebhook DELETE carries Idempotency-Key', () async {
      http.Request? captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response('', 204);
      });
      final client = _makeClient(
        mock,
        idempotencyKeyMinter: () => 'key-unsub-001',
      );
      await client.unregisterWebhook(
        accessToken: 'tok',
        restaurantId: 'rid',
        subscriptionId: 'sub-abc',
      );
      expect(captured!.method, 'DELETE');
      expect(captured!.url.path, '$kOpenTableWebhookSubscriptionsPath/sub-abc');
      expect(captured!.headers['idempotency-key'], 'key-unsub-001');
    });
  });

  group('env override + sampleReservation', () {
    test('fromEnvironment honors OPENTABLE_API_BASE_URL + OAUTH_BASE_URL',
        () async {
      Uri? capturedUri;
      final mock = http_testing.MockClient((http.Request request) async {
        capturedUri = request.url;
        return http.Response(
          json.encode(<String, Object?>{
            'reservations': <Map<String, Object?>>[],
          }),
          200,
        );
      });
      final client = OpenTableReservationProductionApiClient.fromEnvironment(
        httpClient: mock,
        credentialStore: StaticOpenTableCredentialStore(
          clientId: 'cid',
          clientSecret: 'sec',
        ),
        environment: const <String, String>{
          'OPENTABLE_API_BASE_URL': 'https://sandbox.platform.opentable.com',
          'OPENTABLE_OAUTH_BASE_URL': 'https://sandbox.oauth.opentable.com',
        },
      );
      await client.sampleReservation(accessToken: 'tok', restaurantId: 'rid');
      expect(capturedUri!.host, 'sandbox.platform.opentable.com');
      expect(capturedUri!.queryParameters['page_size'], '1');
    });

    test('sampleReservation returns first record or empty map', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          json.encode(<String, Object?>{
            'reservations': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'OT-sample',
                'reserved_at': '2026-05-10T19:30:00-04:00',
                'party_size': 2,
                'status': 'booked',
              },
            ],
          }),
          200,
        );
      });
      final client = _makeClient(mock);
      final record = await client.sampleReservation(
        accessToken: 'tok',
        restaurantId: 'rid',
      );
      expect(record['id'], 'OT-sample');
      // Offset preserved end-to-end.
      expect(record['reserved_at'], '2026-05-10T19:30:00-04:00');
    });
  });

  group('typed errors', () {
    test('5xx surfaces as OpenTableHttpException', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response('boom', 500);
      });
      final client = _makeClient(mock);
      await expectLater(
        () => client.listReservations(
          accessToken: 'tok',
          restaurantId: 'rid',
          modifiedSince: DateTime.utc(2026, 5, 4),
          modifiedUntil: DateTime.utc(2026, 5, 5),
        ),
        throwsA(isA<OpenTableHttpException>()),
      );
    });

    test('malformed JSON surfaces as OpenTableMalformedResponseException',
        () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response('not-json', 200);
      });
      final client = _makeClient(mock);
      await expectLater(
        () => client.listReservations(
          accessToken: 'tok',
          restaurantId: 'rid',
          modifiedSince: DateTime.utc(2026, 5, 4),
          modifiedUntil: DateTime.utc(2026, 5, 5),
        ),
        throwsA(isA<OpenTableMalformedResponseException>()),
      );
    });

    test('OAuth missing access_token → OpenTableMalformedResponseException',
        () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          json.encode(<String, Object?>{'refresh_token': 'r', 'expires_in': 60}),
          200,
        );
      });
      final client = _makeClient(mock);
      await expectLater(
        () => client.exchangeAuthorizationCode(
          authorizationCode: 'c',
          redirectUri: 'https://x/cb',
        ),
        throwsA(isA<OpenTableMalformedResponseException>()),
      );
    });
  });

  group('banned-items grep', () {
    test('source file refuses V1 lean cut 2 banned surfaces', () {
      final source = File(
        'lib/integrations/reservation/opentable_reservation_production_api_client.dart',
      ).readAsStringSync();
      // V1 lean cut 2 + prompt boundaries — none of these surfaces
      // may sneak back in via the production transport. Cite the
      // banned token; do NOT assert on commentary that mentions them
      // (such as the file-level rationale block) — the grep targets
      // executable substrings only. Comments and string literals
      // outside of the banned-feature implementations are fine.
      expect(
        source,
        isNot(contains('parse_warnings')),
        reason: 'parse_warnings column banned (V1 lean cut 2).',
      );
      expect(
        source,
        isNot(contains('parse_partial')),
        reason: 'parse_partial column banned (V1 lean cut 2).',
      );
      // pgmq is not available on Azure — the proxy uses
      // FOR UPDATE SKIP LOCKED + Cloud Tasks; a transport must not
      // refer to pgmq at all.
      expect(
        source,
        isNot(contains('pgmq')),
        reason: 'pgmq is not on the Azure extension list.',
      );
    });
  });
}

OpenTableReservationProductionApiClient _makeClient(
  http.Client httpClient, {
  Future<void> Function(Duration)? sleep,
  String Function()? idempotencyKeyMinter,
  int? maxRateLimitRetries,
  DateTime Function()? now,
}) {
  return OpenTableReservationProductionApiClient(
    httpClient: httpClient,
    credentialStore: StaticOpenTableCredentialStore(
      clientId: 'forge-client-id',
      clientSecret: 'forge-client-secret',
    ),
    sleep: sleep ?? (_) async {},
    idempotencyKeyMinter:
        idempotencyKeyMinter ?? () => 'idem-test-${DateTime.now().microsecond}',
    maxRateLimitRetries: maxRateLimitRetries ?? 5,
    now: now ?? () => DateTime.utc(2026, 5, 4, 12, 0, 0),
  );
}
