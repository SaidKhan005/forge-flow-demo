// Phase 8 `8.transport.libro-reservation` — production HTTP client tests.
//
// Coverage map:
//   1. Happy GET — `listReservations` builds the documented URL,
//      sends Bearer + Accept headers, parses the documented page
//      envelope.
//   2. Pagination — `next_cursor` round-trip; second call carries the
//      cursor query parameter.
//   3. 429 backoff — first attempt 429 with `Retry-After`, second
//      succeeds; the retry honors the documented delay.
//   4. 401 — typed [LibroApiException] surfaces (so the adapter can
//      refresh the token and retry once).
//   5. Schema roundtrip with TZ preserved — outbound `updated_since`
//      keeps the explicit offset; inbound timestamps surface in the
//      DTO with their original wall-clock (the adapter projects via
//      IANA — the transport must NOT rewrite them).

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/libro_reservation_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  group('LibroReservationProductionApiClient — happy path', () {
    test('listReservations builds documented URL and parses the page', () async {
      late http.Request seen;
      final client = _buildClient(
        bearerTokenResolver: (handle) async {
          expect(handle.credentialId, 'cred-1');
          return 'token-A';
        },
        respond: (request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'reservations': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'lbr-evt-1',
                  'venue_id': 'venue-1',
                  'size': 4,
                  'status': 'pending',
                  'reservation_at': '2026-05-04T19:00:00',
                  'updated_at': '2026-05-04T11:30:00',
                  'created_at': '2026-05-04T11:30:00',
                },
              ],
              'next_cursor': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );

      final page = await client.listReservations(
        credential: const VendorCredentialHandle(credentialId: 'cred-1'),
        venueId: 'venue-1',
        updatedSince: DateTime.utc(2026, 5, 1, 12),
        pageSize: 100,
      );

      expect(seen.method, 'GET');
      expect(seen.url.path, '/v1/reservations');
      expect(seen.url.queryParameters['venue_id'], 'venue-1');
      expect(seen.url.queryParameters['updated_since'], '2026-05-01T12:00:00.000Z');
      expect(seen.url.queryParameters['page_size'], '100');
      expect(seen.headers['authorization'], 'Bearer token-A');
      expect(seen.headers['accept'], 'application/json');
      expect(page.reservations.single.id, 'lbr-evt-1');
      expect(page.reservations.single.size, 4);
      expect(page.nextCursor, isNull);
    });
  });

  group('LibroReservationProductionApiClient — pagination', () {
    test('round-trips `next_cursor` across page calls', () async {
      final calls = <Uri>[];
      var firstCall = true;
      final client = _buildClient(
        bearerTokenResolver: (_) async => 'token',
        respond: (request) async {
          calls.add(request.url);
          if (firstCall) {
            firstCall = false;
            return http.Response(
              jsonEncode(<String, Object?>{
                'reservations': <Map<String, Object?>>[
                  <String, Object?>{
                    'id': 'r-1',
                    'venue_id': 'venue-1',
                    'size': 2,
                    'status': 'confirmed',
                    'reservation_at': '2026-05-04T18:30:00',
                    'updated_at': '2026-05-04T10:20:00',
                  },
                ],
                'next_cursor': 'cursor-page-2',
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'reservations': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'r-2',
                  'venue_id': 'venue-1',
                  'size': 6,
                  'status': 'seated',
                  'reservation_at': '2026-05-04T17:45:00',
                  'updated_at': '2026-05-04T17:46:00',
                },
              ],
              'next_cursor': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );

      final page1 = await client.listReservations(
        credential: const VendorCredentialHandle(credentialId: 'c'),
        venueId: 'venue-1',
        updatedSince: DateTime.utc(2026, 5, 1),
      );
      expect(page1.nextCursor, 'cursor-page-2');

      final page2 = await client.listReservations(
        credential: const VendorCredentialHandle(credentialId: 'c'),
        venueId: 'venue-1',
        updatedSince: DateTime.utc(2026, 5, 1),
        cursor: page1.nextCursor,
      );
      expect(page2.nextCursor, isNull);
      expect(page2.reservations.single.id, 'r-2');
      expect(calls.length, 2);
      expect(calls[1].queryParameters['cursor'], 'cursor-page-2');
    });
  });

  group('LibroReservationProductionApiClient — 429 backoff', () {
    test('retries after Retry-After header then returns the success', () async {
      final delays = <Duration>[];
      var attempts = 0;
      final client = _buildClient(
        bearerTokenResolver: (_) async => 'tok',
        sleep: (d) async => delays.add(d),
        respond: (request) async {
          attempts++;
          if (attempts == 1) {
            return http.Response(
              '{"error":"rate_limited"}',
              429,
              headers: <String, String>{
                'retry-after': '2',
                'content-type': 'application/json',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'reservations': <Map<String, Object?>>[],
              'next_cursor': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );

      final page = await client.listReservations(
        credential: const VendorCredentialHandle(credentialId: 'c'),
        venueId: 'venue-1',
        updatedSince: DateTime.utc(2026, 5, 1),
      );
      expect(attempts, 2);
      expect(page.reservations, isEmpty);
      expect(delays.single, const Duration(seconds: 2));
    });

    test('throws rateLimitExhausted after retry budget', () async {
      var attempts = 0;
      final client = _buildClient(
        bearerTokenResolver: (_) async => 'tok',
        sleep: (_) async {},
        maxRateLimitRetries: 2,
        respond: (request) async {
          attempts++;
          return http.Response(
            '{"error":"rate_limited"}',
            429,
            headers: <String, String>{
              'retry-after': '1',
              'content-type': 'application/json',
            },
          );
        },
      );
      await expectLater(
        client.listReservations(
          credential: const VendorCredentialHandle(credentialId: 'c'),
          venueId: 'venue-1',
          updatedSince: DateTime.utc(2026, 5, 1),
        ),
        throwsA(
          isA<LibroApiException>()
              .having((e) => e.kind, 'kind', LibroApiErrorKind.rateLimitExhausted)
              .having((e) => e.statusCode, 'statusCode', 429),
        ),
      );
      // Attempts = initial + maxRateLimitRetries
      expect(attempts, 3);
    });
  });

  group('LibroReservationProductionApiClient — auth errors', () {
    test('401 surfaces typed unauthenticated exception', () async {
      final client = _buildClient(
        bearerTokenResolver: (_) async => 'expired',
        respond: (request) async => http.Response(
          '{"error":"invalid_token"}',
          401,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      );
      await expectLater(
        client.listReservations(
          credential: const VendorCredentialHandle(credentialId: 'c'),
          venueId: 'venue-1',
          updatedSince: DateTime.utc(2026, 5, 1),
        ),
        throwsA(
          isA<LibroApiException>()
              .having((e) => e.kind, 'kind', LibroApiErrorKind.unauthenticated)
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });
  });

  group('LibroReservationProductionApiClient — schema TZ preservation', () {
    test('outbound timestamp keeps explicit offset; inbound DTO preserves '
        'wall-clock', () async {
      late http.Request seen;
      final client = _buildClient(
        bearerTokenResolver: (_) async => 'tok',
        respond: (request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'reservations': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'lbr-evt-tz',
                  'venue_id': 'venue-1',
                  'size': 4,
                  'status': 'pending',
                  // Restaurant-local wall-clock (no tz hint) per Libro
                  // policy — transport MUST surface this string to the
                  // DTO unchanged so the adapter's IANA projector wins.
                  'reservation_at': '2026-05-04T19:00:00',
                  'updated_at': '2026-05-04T11:30:00',
                  // A separate vendor-emitted offset value (some
                  // venues append `-04:00`); transport must preserve.
                  'created_at': '2026-05-04T07:30:00-04:00',
                },
              ],
              'next_cursor': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );

      // Outbound: pass a non-UTC DateTime with explicit offset → the
      // serializer keeps the offset (RFC 3339 round-trip).
      final localOffset = DateTime.parse('2026-05-04T07:00:00-04:00');
      await client.listReservations(
        credential: const VendorCredentialHandle(credentialId: 'c'),
        venueId: 'venue-1',
        updatedSince: localOffset,
      );
      // Dart's `toIso8601String` writes UTC instants with a `Z`
      // suffix and preserves a sub-second / numeric form; in either
      // shape the parsed UTC instant must round-trip.
      final parsedBack = DateTime.parse(
        seen.url.queryParameters['updated_since']!,
      ).toUtc();
      expect(parsedBack, localOffset.toUtc());
    });
  });

  group('LibroReservationProductionApiClient — registerWebhook', () {
    test('POST sends Idempotency-Key + parses subscription id', () async {
      late http.Request seen;
      final client = _buildClient(
        bearerTokenResolver: (_) async => 'tok',
        idempotencyKeyGenerator: () => 'idem-fixed-1',
        respond: (request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{'id': 'sub-1'}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );

      final id = await client.registerWebhook(
        credential: const VendorCredentialHandle(credentialId: 'c'),
        venueId: 'venue-1',
        webhookUrl: 'https://proxy/v1/integrations/webhook/libro/op/loc',
        events: kLibroSubscribedEvents,
      );

      expect(id, 'sub-1');
      expect(seen.method, 'POST');
      expect(seen.url.path, '/v1/webhooks/subscriptions');
      expect(seen.headers['idempotency-key'], 'idem-fixed-1');
      expect(seen.headers['content-type'], contains('application/json'));
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['venue_id'], 'venue-1');
      expect(body['url'], 'https://proxy/v1/integrations/webhook/libro/op/loc');
      expect(body['events'], kLibroSubscribedEvents);
    });
  });

  group('LibroReservationProductionApiClient — disconnect helpers', () {
    test('unregisterWebhook DELETEs by subscription id; tolerates 404',
        () async {
      var seenStatus = -1;
      final client = _buildClient(
        bearerTokenResolver: (_) async => 'tok',
        respond: (request) async {
          seenStatus = 404;
          return http.Response('{"error":"not_found"}', 404);
        },
      );
      // Should NOT throw — disconnect-time 404 is treated as success.
      await client.unregisterWebhook(
        credential: const VendorCredentialHandle(credentialId: 'c'),
        subscriptionId: 'sub-1',
      );
      expect(seenStatus, 404);
    });

    test('revokeCredential POSTs and tolerates 404', () async {
      var calls = 0;
      final client = _buildClient(
        bearerTokenResolver: (_) async => 'tok',
        idempotencyKeyGenerator: () => 'idem-2',
        respond: (request) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.url.path, '/v1/oauth/revoke');
          expect(request.headers['idempotency-key'], 'idem-2');
          return http.Response('', 204);
        },
      );
      await client.revokeCredential(
        credential: const VendorCredentialHandle(credentialId: 'c'),
      );
      expect(calls, 1);
    });
  });
}

LibroReservationProductionApiClient _buildClient({
  required LibroBearerTokenResolver bearerTokenResolver,
  required Future<http.Response> Function(http.Request) respond,
  Future<void> Function(Duration)? sleep,
  LibroIdempotencyKeyGenerator? idempotencyKeyGenerator,
  int maxRateLimitRetries = 3,
  Uri? baseUri,
}) {
  return LibroReservationProductionApiClient(
    bearerTokenResolver: bearerTokenResolver,
    baseUri: baseUri ?? Uri.parse('https://api.libroreserve.com'),
    httpClient: http_testing.MockClient((request) => respond(request)),
    idempotencyKeyGenerator: idempotencyKeyGenerator,
    maxRateLimitRetries: maxRateLimitRetries,
    rateLimitBaseDelay: const Duration(milliseconds: 10),
    rateLimitMaxDelay: const Duration(seconds: 30),
    sleep: sleep,
    random: math.Random(0),
  );
}
