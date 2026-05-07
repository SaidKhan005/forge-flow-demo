// Phase 8.transport.sevenrooms-reservation — production HTTP transport
// tests.
//
// Covers the documented seams of the SevenRooms production API client:
//   1. Auth POST → token persisted via credential store.
//   2. Happy GET reservations page (auth header, vendor query params).
//   3. Cursor-style pagination (next_page_token threaded between pages).
//   4. 429 backoff respects Retry-After + retries until success.
//   5. 401 → SevenRoomsAuthException (typed terminal failure).
//   6. Schema roundtrip preserves vendor TZ offsets unchanged.
//   7. Backfill path uses /2_2/reservations/export endpoint.
//   8. Sample reservation returns first record from page-size=1 GET.
//   9. Webhook subscribe MUST throw — manualPaste guard.
//
// `package:http/testing.dart`'s MockClient is the fake for every HTTP
// round trip; no real network is reached.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_reservation_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

const String _credentialId = 'cred-access-1';
const String _venueId = 'sr-venue-7c2f';

void main() {
  group('SevenRoomsAuthProductionApiClient', () {
    test('exchange happy path persists access_token + returns venue_id',
        () async {
      late http.Request seenRequest;
      late String seenBody;
      final store = _RecordingCredentialStore(persistResult: 'cred-issued-7');
      final mock = http_testing.MockClient((request) async {
        seenRequest = request;
        seenBody = request.body;
        return http.Response(
          jsonEncode(<String, Object?>{
            'access_token': 'bearer-token-xyz',
            'expires_in': 3600,
            'venue_id': _venueId,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final auth = _buildAuthClient(httpClient: mock, credentialStore: store);

      final result = await auth.authenticate(
        clientId: 'partner-client-abc',
        clientSecret: 'partner-secret-xyz',
        venueId: _venueId,
      );

      expect(seenRequest.method, 'POST');
      expect(seenRequest.url.path, kSevenRoomsAuthPath);
      expect(seenRequest.headers['authorization'], isNull,
          reason: 'auth POST must not present a stale bearer');
      expect(seenRequest.headers['idempotency-key'], isNotNull);
      expect(seenRequest.headers['idempotency-key'], startsWith('sr-'));
      final decoded = jsonDecode(seenBody) as Map<String, Object?>;
      expect(decoded['client_id'], 'partner-client-abc');
      expect(decoded['client_secret'], 'partner-secret-xyz');
      expect(decoded['venue_id'], _venueId);
      expect(decoded['grant_type'], 'client_credentials');
      expect(result.accessTokenCredentialId, 'cred-issued-7');
      expect(result.venueId, _venueId);
      expect(store.persistedTokens.single.accessToken, 'bearer-token-xyz');
      expect(store.persistedTokens.single.lifetime, const Duration(seconds: 3600));
    });

    test('401 → SevenRoomsAuthException', () async {
      final mock = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'invalid_credentials'}),
          401,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final auth = _buildAuthClient(httpClient: mock);
      expect(
        () => auth.authenticate(
          clientId: 'cid',
          clientSecret: 'csec',
          venueId: _venueId,
        ),
        throwsA(isA<SevenRoomsAuthException>()),
      );
    });

    test('missing access_token in response → schema exception', () async {
      final mock = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'venue_id': _venueId}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final auth = _buildAuthClient(httpClient: mock);
      expect(
        () => auth.authenticate(
          clientId: 'cid',
          clientSecret: 'csec',
          venueId: _venueId,
        ),
        throwsA(isA<SevenRoomsSchemaException>()),
      );
    });

    test('revoke() is a best-effort no-op (no upstream endpoint documented)',
        () async {
      final auth = _buildAuthClient(
        httpClient: http_testing.MockClient((_) async {
          fail('revoke must not hit the network when no endpoint is documented');
        }),
      );
      await auth.revoke(accessTokenCredentialId: _credentialId);
    });
  });

  group('SevenRoomsReservationsProductionApiClient', () {
    test(
      'happy GET sets bearer auth + vendor query params + returns one page',
      () async {
        late http.Request seen;
        final mock = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'reservations': <Object?>[
                <String, Object?>{
                  'id': 'sr-resv-1001',
                  'arrival_time': '2026-05-04T22:30:00.000-04:00',
                  'party_size': 2,
                  'status': 'BOOKED',
                  'last_updated_at': '2026-05-04T18:00:00.000Z',
                  'venue_id': _venueId,
                },
              ],
              'next_page_token': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final reservations = _buildReservationsClient(httpClient: mock);

        final page = await reservations.fetchReservationsPage(
          accessTokenCredentialId: _credentialId,
          venueId: _venueId,
          windowStartUtc: DateTime.utc(2026, 5, 1, 0, 0),
          windowEndUtc: DateTime.utc(2026, 5, 4, 12, 0),
          pageSize: 100,
          useExport: false,
        );

        expect(seen.method, 'GET');
        expect(seen.url.path, kSevenRoomsReservationsPath);
        expect(seen.url.queryParameters['venue_id'], _venueId);
        expect(seen.url.queryParameters['page_size'], '100');
        expect(seen.url.queryParameters['updated_since'],
            '2026-05-01T00:00:00.000Z');
        expect(seen.url.queryParameters['updated_until'],
            '2026-05-04T12:00:00.000Z');
        expect(seen.headers['authorization'], 'Bearer bearer-token-xyz');
        expect(seen.headers['user-agent'], contains('sevenrooms-reservation'));
        expect(page.reservations, hasLength(1));
        expect(page.reservations.first['id'], 'sr-resv-1001');
        expect(page.nextPageToken, isNull);
      },
    );

    test(
      'pagination threads next_page_token between calls; backfill uses '
      '/2_2/reservations/export',
      () async {
        final seenUrls = <Uri>[];
        var call = 0;
        final mock = http_testing.MockClient((request) async {
          seenUrls.add(request.url);
          call += 1;
          if (call == 1) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'reservations': <Object?>[
                  <String, Object?>{
                    'id': 'sr-resv-1001',
                    'arrival_time': '2026-05-04T22:30:00.000-04:00',
                    'party_size': 2,
                    'status': 'BOOKED',
                    'last_updated_at': '2026-05-04T18:00:00.000Z',
                  },
                ],
                'next_page_token': 'cursor-2',
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'reservations': <Object?>[
                <String, Object?>{
                  'id': 'sr-resv-1002',
                  'arrival_time': '2026-05-04T22:45:00.000-04:00',
                  'party_size': 4,
                  'status': 'ARRIVED',
                  'last_updated_at': '2026-05-04T22:50:00.000Z',
                },
              ],
              'next_page_token': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final reservations = _buildReservationsClient(httpClient: mock);

        final page1 = await reservations.fetchReservationsPage(
          accessTokenCredentialId: _credentialId,
          venueId: _venueId,
          windowStartUtc: DateTime.utc(2026, 3, 6),
          windowEndUtc: DateTime.utc(2026, 5, 4, 12),
          pageSize: 100,
          useExport: true,
        );
        final page2 = await reservations.fetchReservationsPage(
          accessTokenCredentialId: _credentialId,
          venueId: _venueId,
          windowStartUtc: DateTime.utc(2026, 3, 6),
          windowEndUtc: DateTime.utc(2026, 5, 4, 12),
          pageSize: 100,
          useExport: true,
          cursorToken: page1.nextPageToken,
        );

        expect(seenUrls, hasLength(2));
        expect(seenUrls[0].path, kSevenRoomsReservationsExportPath);
        expect(seenUrls[1].path, kSevenRoomsReservationsExportPath);
        expect(seenUrls[0].queryParameters['page_token'], isNull);
        expect(seenUrls[1].queryParameters['page_token'], 'cursor-2');
        expect(page1.nextPageToken, 'cursor-2');
        expect(page2.nextPageToken, isNull);
        expect(page2.reservations.first['id'], 'sr-resv-1002');
      },
    );

    test('429 backoff retries respecting Retry-After then succeeds', () async {
      var calls = 0;
      final mock = http_testing.MockClient((request) async {
        calls += 1;
        if (calls < 3) {
          return http.Response(
            '{"error": "rate_limited"}',
            429,
            headers: <String, String>{
              'content-type': 'application/json',
              'retry-after': '0',
            },
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'reservations': <Object?>[],
            'next_page_token': null,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final reservations = _buildReservationsClient(httpClient: mock);
      final page = await reservations.fetchReservationsPage(
        accessTokenCredentialId: _credentialId,
        venueId: _venueId,
        windowStartUtc: DateTime.utc(2026, 5, 1),
        windowEndUtc: DateTime.utc(2026, 5, 4),
        pageSize: 100,
        useExport: false,
      );
      expect(calls, 3, reason: '2 rate-limit responses then 1 success');
      expect(page.reservations, isEmpty);
    });

    test(
      '429 exhausting retry budget surfaces typed SevenRoomsRateLimitException',
      () async {
        final mock = http_testing.MockClient((request) async {
          return http.Response(
            '{"error": "rate_limited"}',
            429,
            headers: <String, String>{
              'content-type': 'application/json',
              'retry-after': '0',
            },
          );
        });
        final reservations = _buildReservationsClient(httpClient: mock);
        expect(
          () => reservations.fetchReservationsPage(
            accessTokenCredentialId: _credentialId,
            venueId: _venueId,
            windowStartUtc: DateTime.utc(2026, 5, 1),
            windowEndUtc: DateTime.utc(2026, 5, 4),
            pageSize: 100,
            useExport: false,
          ),
          throwsA(isA<SevenRoomsRateLimitException>()),
        );
      },
    );

    test('401 on a polling GET → SevenRoomsAuthException (terminal)',
        () async {
      final mock = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'unauthorized'}),
          401,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final reservations = _buildReservationsClient(httpClient: mock);
      expect(
        () => reservations.fetchReservationsPage(
          accessTokenCredentialId: _credentialId,
          venueId: _venueId,
          windowStartUtc: DateTime.utc(2026, 5, 1),
          windowEndUtc: DateTime.utc(2026, 5, 4),
          pageSize: 100,
          useExport: false,
        ),
        throwsA(isA<SevenRoomsAuthException>()),
      );
    });

    test(
      'schema roundtrip: vendor TZ offset on arrival_time is preserved end-to-end',
      () async {
        final mock = http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'reservations': <Object?>[
                <String, Object?>{
                  'id': 'sr-resv-tz-1',
                  // -04:00 = America/Toronto EDT — must NOT be normalized.
                  'arrival_time': '2026-05-04T22:30:00.000-04:00',
                  'party_size': 2,
                  'status': 'BOOKED',
                  'last_updated_at': '2026-05-04T18:00:00.000-04:00',
                  // +09:00 = Asia/Tokyo (different offset to prove the
                  // transport does not touch the value).
                  'arrived_time': '2026-05-04T11:30:00.000+09:00',
                },
              ],
              'next_page_token': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final reservations = _buildReservationsClient(httpClient: mock);
        final page = await reservations.fetchReservationsPage(
          accessTokenCredentialId: _credentialId,
          venueId: _venueId,
          windowStartUtc: DateTime.utc(2026, 5, 1),
          windowEndUtc: DateTime.utc(2026, 5, 4),
          pageSize: 100,
          useExport: false,
        );
        final res = page.reservations.single;
        expect(res['arrival_time'], '2026-05-04T22:30:00.000-04:00',
            reason:
                'transport must pass vendor offset through unmodified per Time Guardrails');
        expect(res['last_updated_at'], '2026-05-04T18:00:00.000-04:00');
        expect(res['arrived_time'], '2026-05-04T11:30:00.000+09:00');
      },
    );

    test('non-JSON body → SevenRoomsSchemaException', () async {
      final mock = http_testing.MockClient((request) async {
        return http.Response('<html>oops</html>', 200);
      });
      final reservations = _buildReservationsClient(httpClient: mock);
      expect(
        () => reservations.fetchReservationsPage(
          accessTokenCredentialId: _credentialId,
          venueId: _venueId,
          windowStartUtc: DateTime.utc(2026, 5, 1),
          windowEndUtc: DateTime.utc(2026, 5, 4),
          pageSize: 100,
          useExport: false,
        ),
        throwsA(isA<SevenRoomsSchemaException>()),
      );
    });

    test('5xx server error → SevenRoomsServerException', () async {
      final mock = http_testing.MockClient((request) async {
        return http.Response('Bad gateway', 502);
      });
      final reservations = _buildReservationsClient(httpClient: mock);
      expect(
        () => reservations.fetchReservationsPage(
          accessTokenCredentialId: _credentialId,
          venueId: _venueId,
          windowStartUtc: DateTime.utc(2026, 5, 1),
          windowEndUtc: DateTime.utc(2026, 5, 4),
          pageSize: 100,
          useExport: false,
        ),
        throwsA(isA<SevenRoomsServerException>()),
      );
    });

    test('fetchSampleReservation returns first record from page-size=1', () async {
      late http.Request seen;
      final mock = http_testing.MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'reservations': <Object?>[
              <String, Object?>{
                'id': 'sr-resv-sample',
                'arrival_time': '2026-05-04T19:00:00.000-04:00',
                'party_size': 4,
                'status': 'BOOKED',
                'last_updated_at': '2026-05-04T17:00:00.000Z',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final reservations = _buildReservationsClient(httpClient: mock);
      final sample = await reservations.fetchSampleReservation(
        accessTokenCredentialId: _credentialId,
        venueId: _venueId,
      );
      expect(seen.url.path, kSevenRoomsReservationsPath);
      expect(seen.url.queryParameters['page_size'], '1');
      expect(seen.url.queryParameters['venue_id'], _venueId);
      expect(sample['id'], 'sr-resv-sample');
      expect(sample['arrival_time'], '2026-05-04T19:00:00.000-04:00');
    });

    test('fetchSampleReservation returns empty map when no records', () async {
      final mock = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'reservations': <Object?>[]}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final reservations = _buildReservationsClient(httpClient: mock);
      final sample = await reservations.fetchSampleReservation(
        accessTokenCredentialId: _credentialId,
        venueId: _venueId,
      );
      expect(sample, isEmpty);
    });
  });

  group('SevenRoomsWebhookProductionApiClient', () {
    test('subscribe() throws StateError — manualPaste guard', () {
      const client = SevenRoomsWebhookProductionApiClient();
      expect(
        () => client.subscribe(
          accessTokenCredentialId: _credentialId,
          webhookUrl: 'https://api.forgeflow.app/v1/webhooks/sevenrooms/conn',
          venueId: _venueId,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('SevenRoomsTransportDeps', () {
    test('shared() defaults baseUri to documented production endpoint', () {
      final deps = SevenRoomsTransportDeps.shared(
        credentialStore: _RecordingCredentialStore(),
      );
      final auth = deps.buildAuthClient();
      // Drive through resolve() via the auth flow; assert the URI host.
      expect(auth, isA<SevenRoomsAuthProductionApiClient>());
      expect(deps.core.baseUri.toString(), kSevenRoomsProdBaseUrl);
    });

    test('shared() honors environmentBaseUri override', () {
      final override = Uri.parse('https://api.staging.example/v0');
      final deps = SevenRoomsTransportDeps.shared(
        credentialStore: _RecordingCredentialStore(),
        environmentBaseUri: override,
      );
      expect(deps.core.baseUri, override);
    });
  });
}

// ─── Test doubles ──────────────────────────────────────────────────────

class _PersistedToken {
  const _PersistedToken({
    required this.clientId,
    required this.venueId,
    required this.accessToken,
    required this.lifetime,
  });
  final String clientId;
  final String venueId;
  final String accessToken;
  final Duration? lifetime;
}

class _RecordingCredentialStore implements SevenRoomsCredentialStore {
  _RecordingCredentialStore({
    // ignore: unused_element_parameter
    this.bearerToken = 'bearer-token-xyz',
    this.persistResult = 'cred-issued-1',
  });

  String bearerToken;
  String persistResult;
  final List<String> resolvedFor = <String>[];
  final List<_PersistedToken> persistedTokens = <_PersistedToken>[];

  @override
  Future<String> resolveBearerToken({required String credentialId}) async {
    resolvedFor.add(credentialId);
    return bearerToken;
  }

  @override
  Future<String> persistIssuedBearerToken({
    required String clientId,
    required String venueId,
    required String accessToken,
    required Duration? lifetime,
  }) async {
    persistedTokens.add(_PersistedToken(
      clientId: clientId,
      venueId: venueId,
      accessToken: accessToken,
      lifetime: lifetime,
    ));
    return persistResult;
  }
}

SevenRoomsAuthProductionApiClient _buildAuthClient({
  required http.Client httpClient,
  SevenRoomsCredentialStore? credentialStore,
}) {
  final deps = SevenRoomsTransportDeps.shared(
    credentialStore: credentialStore ?? _RecordingCredentialStore(),
    httpClient: httpClient,
    now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
    random: Random(7),
  );
  return deps.buildAuthClient();
}

SevenRoomsReservationsProductionApiClient _buildReservationsClient({
  required http.Client httpClient,
}) {
  final deps = SevenRoomsTransportDeps.shared(
    credentialStore: _RecordingCredentialStore(),
    httpClient: httpClient,
    now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
    random: Random(7),
  );
  return deps.buildReservationsClient(
    credentialIdForRequest: _credentialId,
  );
}
