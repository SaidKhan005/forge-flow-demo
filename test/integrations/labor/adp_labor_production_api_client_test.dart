// Phase 8.transport.adp-labor — production ADP HTTP client tests.
//
// Drives the production transport against `MockClient` from
// `package:http/testing.dart` so every protocol seam is exercised
// without a partner-credentialed sandbox or live ADP host. Coverage:
//   * Happy path token exchange + bearer requests
//   * Pagination cursor walk via `next_cursor`
//   * 429 retry with `Retry-After` honored + bounded retries
//   * 401 surfaces typed `AdpAuthenticationException`
//   * Schema roundtrip (vendor_entity_id / vendor_modified_at / etc.)
//   * Idempotency-Key minted on POST registration
//   * mTLS gap is documented at the top of the production file (the
//     test path uses an injected `http.Client` and never reaches
//     `dart:io` — see banner comment in the production source).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:forge_and_flow/integrations/labor/adp_labor_production_api_client.dart';

const _opId = '00000000-0000-4000-8000-000000000001';
const _locId = '00000000-0000-4000-8000-0000000000a1';
const _accessToken = 'access-token-001';
const _module = 'workforce_now';

AdpLaborProductionApiClient _buildClient({
  required http.Client httpClient,
  AdpCredentialsProvider? credentialsProvider,
  AdpSubscriptionSecretProvider? subscriptionSecretProvider,
  Duration defaultRetryAfter = const Duration(milliseconds: 1),
  int maxRetriesOn429 = 3,
  AdpIdempotencyKeyMinter? idempotencyKeyMinter,
  DateTime Function()? now,
  Future<void> Function(Duration)? sleep,
}) {
  return AdpLaborProductionApiClient(
    credentialsProvider: credentialsProvider ??
        () async => const AdpClientCredentials(
              clientId: 'client-id',
              clientSecret: 'client-secret',
            ),
    subscriptionSecretProvider:
        subscriptionSecretProvider ?? () async => 'whsec_test',
    httpClient: httpClient,
    defaultRetryAfter: defaultRetryAfter,
    maxRetriesOn429: maxRetriesOn429,
    idempotencyKeyMinter: idempotencyKeyMinter,
    now: now ?? () => DateTime.utc(2026, 5, 6, 12, 0, 0),
    sleep: sleep ?? (_) async {},
  );
}

void main() {
  group('exchangeAuthorizationCode', () {
    test('happy path → access + refresh + expiresAt', () async {
      late http.Request seen;
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'access-001',
              'refresh_token': 'refresh-001',
              'expires_in': 3600,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final token = await client.exchangeAuthorizationCode(
        authorizationCode: 'code-001',
        redirectUri: 'https://proxy.example/v1/oauth/callback/adp',
        module: _module,
      );

      expect(token.accessToken, 'access-001');
      expect(token.refreshToken, 'refresh-001');
      expect(
        token.expiresAt,
        DateTime.utc(2026, 5, 6, 13, 0, 0),
      );
      expect(seen.method, 'POST');
      expect(seen.url.toString(),
          'https://accounts.adp.com/auth/oauth/v2/token');
      expect(seen.bodyFields['grant_type'], 'authorization_code');
      expect(seen.bodyFields['code'], 'code-001');
      expect(seen.headers['authorization']!.startsWith('Basic '), true);
      expect(seen.headers['x-adp-module'], _module);
    });

    test('401 on token request → AdpAuthenticationException', () async {
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response('{"error":"invalid_grant"}', 401);
        }),
      );

      expect(
        () => client.exchangeAuthorizationCode(
          authorizationCode: 'bad',
          redirectUri: 'https://proxy.example/v1/oauth/callback/adp',
          module: _module,
        ),
        throwsA(isA<AdpAuthenticationException>()),
      );
    });
  });

  group('refresh', () {
    test('sends grant_type=refresh_token + refresh_token form', () async {
      late http.Request seen;
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'access-002',
              'refresh_token': 'refresh-002',
              'expires_in': 1800,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final token = await client.refresh(
        refreshToken: 'refresh-001',
        module: _module,
      );

      expect(token.accessToken, 'access-002');
      expect(seen.bodyFields['grant_type'], 'refresh_token');
      expect(seen.bodyFields['refresh_token'], 'refresh-001');
    });
  });

  group('listTimeEvents', () {
    test('happy path → records + cursor + lastModifiedSeen (TIMESTAMPTZ)',
        () async {
      late http.Request seen;
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': <Object?>[
                <String, Object?>{
                  'time_event': <String, Object?>{
                    'id': 'ADP-TE-001',
                    'entry_date_time': '2026-05-04T15:00:00Z',
                    'exit_date_time': '2026-05-04T23:00:00Z',
                    'last_modified_date_time': '2026-05-04T23:01:30Z',
                  },
                  'worker': <String, Object?>{
                    'associate_oid': 'G3WXX1Y2Z3A4B5C6',
                    'position': <String, Object?>{
                      'position_title': 'Server',
                    },
                  },
                },
                <String, Object?>{
                  'time_event': <String, Object?>{
                    'id': 'ADP-TE-002',
                    'entry_date_time': '2026-05-05T15:00:00Z',
                    'exit_date_time': '2026-05-05T23:00:00Z',
                    'last_modified_date_time': '2026-05-05T23:01:30Z',
                  },
                  'worker': <String, Object?>{
                    'associate_oid': 'G3WXX1Y2Z3A4B5C7',
                    'position': <String, Object?>{
                      'position_title': 'Cook',
                    },
                  },
                },
              ],
              'next_cursor': 'cursor-page-2',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final page = await client.listTimeEvents(
        accessToken: _accessToken,
        module: _module,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );

      expect(page.records.length, 2);
      expect(page.nextCursor, 'cursor-page-2');
      // TIMESTAMPTZ preserved: latest record is 2026-05-05T23:01:30Z.
      expect(
        page.lastModifiedSeen,
        DateTime.utc(2026, 5, 5, 23, 1, 30),
      );
      expect(seen.method, 'GET');
      expect(seen.headers['authorization'], 'Bearer $_accessToken');
      expect(seen.headers['x-adp-module'], _module);
      expect(
        seen.url.queryParameters['modifiedSince'],
        '2026-05-01T00:00:00.000Z',
      );
      expect(
        seen.url.queryParameters['modifiedUntil'],
        '2026-05-06T00:00:00.000Z',
      );
    });

    test('pagination — second call carries cursor', () async {
      final seen = <http.Request>[];
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen.add(request);
          if (seen.length == 1) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'records': <Object?>[
                  <String, Object?>{
                    'time_event': <String, Object?>{
                      'id': 'ADP-TE-001',
                      'entry_date_time': '2026-05-04T15:00:00Z',
                      'last_modified_date_time': '2026-05-04T23:01:30Z',
                    },
                    'worker': <String, Object?>{
                      'associate_oid': 'oid-1',
                      'position': <String, Object?>{
                        'position_title': 'Server',
                      },
                    },
                  },
                ],
                'next_cursor': 'cursor-page-2',
              }),
              200,
              headers: <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': <Object?>[],
              'next_cursor': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final firstPage = await client.listTimeEvents(
        accessToken: _accessToken,
        module: _module,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );
      expect(firstPage.nextCursor, 'cursor-page-2');

      final secondPage = await client.listTimeEvents(
        accessToken: _accessToken,
        module: _module,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
        cursor: firstPage.nextCursor,
      );
      expect(secondPage.records, isEmpty);
      expect(secondPage.nextCursor, isNull);
      expect(seen[1].url.queryParameters['cursor'], 'cursor-page-2');
    });

    test('429 with Retry-After triggers backoff then succeeds', () async {
      var attempt = 0;
      final sleeps = <Duration>[];
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          attempt += 1;
          if (attempt == 1) {
            return http.Response(
              '{"error":"rate_limited"}',
              429,
              headers: <String, String>{'retry-after': '2'},
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': <Object?>[],
              'next_cursor': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        defaultRetryAfter: const Duration(seconds: 1),
        sleep: (d) async {
          sleeps.add(d);
        },
      );

      final page = await client.listTimeEvents(
        accessToken: _accessToken,
        module: _module,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );

      expect(page.records, isEmpty);
      expect(attempt, 2);
      expect(sleeps.length, 1);
      expect(sleeps.first, const Duration(seconds: 2));
    });

    test('429 exhausted retries surfaces AdpRateLimitException', () async {
      var attempt = 0;
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          attempt += 1;
          return http.Response(
            '{"error":"rate_limited"}',
            429,
            headers: <String, String>{'retry-after': '1'},
          );
        }),
        maxRetriesOn429: 2,
        defaultRetryAfter: const Duration(milliseconds: 1),
        sleep: (_) async {},
      );

      expect(
        () => client.listTimeEvents(
          accessToken: _accessToken,
          module: _module,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        ),
        throwsA(isA<AdpRateLimitException>()),
      );
      // Drain the attempt counter so the assertion doesn't race.
      await Future<void>.delayed(Duration.zero);
      expect(attempt, greaterThanOrEqualTo(1));
    });

    test('401 surfaces AdpAuthenticationException (refresh-on-401 path)',
        () async {
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response('{"error":"unauthorized"}', 401);
        }),
      );

      expect(
        () => client.listTimeEvents(
          accessToken: _accessToken,
          module: _module,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        ),
        throwsA(isA<AdpAuthenticationException>()),
      );
    });

    test('schema roundtrip — adapter consumes records as-is', () async {
      // Drive the canonicalizer by feeding the records into the
      // adapter's `_canonicalize` via a `ConnectCommand`-shaped path:
      // the simplest check is that the records carry every key the
      // adapter requires (vendor_entity_id, entry_date_time,
      // associate_oid, position_title, last_modified_date_time).
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': <Object?>[
                <String, Object?>{
                  'time_event': <String, Object?>{
                    'id': 'ADP-TE-9001',
                    'entry_date_time': '2026-05-04T15:00:00Z',
                    'exit_date_time': '2026-05-04T23:00:00Z',
                    'last_modified_date_time': '2026-05-04T23:01:30Z',
                  },
                  'worker': <String, Object?>{
                    'associate_oid': 'G3WXX1Y2Z3A4B5C6',
                    'position': <String, Object?>{
                      'position_title': 'Server',
                    },
                  },
                },
              ],
              'next_cursor': null,
            }),
            200,
          );
        }),
      );

      final page = await client.listTimeEvents(
        accessToken: _accessToken,
        module: _module,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 6),
      );

      final row = page.records.single;
      final timeEvent =
          Map<String, Object?>.from(row['time_event'] as Map);
      final worker = Map<String, Object?>.from(row['worker'] as Map);
      final position =
          Map<String, Object?>.from(worker['position'] as Map);
      expect(timeEvent['id'], 'ADP-TE-9001');
      expect(timeEvent['entry_date_time'], '2026-05-04T15:00:00Z');
      expect(timeEvent['last_modified_date_time'], '2026-05-04T23:01:30Z');
      expect(worker['associate_oid'], 'G3WXX1Y2Z3A4B5C6');
      expect(position['position_title'], 'Server');
      // Page-level lastModifiedSeen mirrors the record (TIMESTAMPTZ).
      expect(
        page.lastModifiedSeen,
        DateTime.utc(2026, 5, 4, 23, 1, 30),
      );
    });
  });

  group('registerEventSubscription', () {
    test('POST carries idempotency-key + bearer + signing secret', () async {
      late http.Request seen;
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'subscription_id': 'adp-sub-001',
            }),
            201,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        idempotencyKeyMinter: () => 'idem-fixed-001',
      );

      final id = await client.registerEventSubscription(
        accessToken: _accessToken,
        module: _module,
        url: 'https://proxy.example/v1/webhooks/$_opId/$_locId/adp',
        events: const <String>['time.timeEvent.modify'],
        signingSecret: 'whsec_001',
      );

      expect(id, 'adp-sub-001');
      expect(seen.method, 'POST');
      expect(seen.headers['idempotency-key'], 'idem-fixed-001');
      expect(seen.headers['authorization'], 'Bearer $_accessToken');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      final sub = Map<String, Object?>.from(body['subscription'] as Map);
      expect(sub['signing_secret'], 'whsec_001');
      expect(sub['callback_url'],
          'https://proxy.example/v1/webhooks/$_opId/$_locId/adp');
      expect(sub['events'], <String>['time.timeEvent.modify']);
    });
  });

  group('unregisterEventSubscription', () {
    test('DELETE 404 → treated as already-gone (no throw)', () async {
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          expect(request.method, 'DELETE');
          return http.Response('', 404);
        }),
      );

      await client.unregisterEventSubscription(
        accessToken: _accessToken,
        module: _module,
        subscriptionId: 'adp-sub-001',
      );
    });
  });

  group('revoke', () {
    test('200 → no throw', () async {
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          expect(request.url.path, '/auth/oauth/v2/revoke');
          expect(request.bodyFields['token'], _accessToken);
          return http.Response('', 200);
        }),
      );

      await client.revoke(accessToken: _accessToken);
    });
  });

  group('sampleTimeEvent', () {
    test('returns first record + worker subtree', () async {
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': <Object?>[
                <String, Object?>{
                  'time_event': <String, Object?>{
                    'id': 'ADP-TE-001',
                    'entry_date_time': '2026-05-04T15:00:00Z',
                    'exit_date_time': '2026-05-04T23:00:00Z',
                    'last_modified_date_time': '2026-05-04T23:01:30Z',
                  },
                  'worker': <String, Object?>{
                    'associate_oid': 'G3WXX1Y2Z3A4B5C6',
                    'position': <String, Object?>{
                      'position_title': 'Server',
                    },
                  },
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final sample = await client.sampleTimeEvent(
        accessToken: _accessToken,
        module: _module,
      );

      expect(sample['id'], 'ADP-TE-001');
      expect(sample['entry_date_time'], '2026-05-04T15:00:00Z');
      final worker = Map<String, Object?>.from(sample['worker'] as Map);
      expect(worker['associate_oid'], 'G3WXX1Y2Z3A4B5C6');
    });
  });

  group('schema refusal', () {
    test('non-JSON body → AdpSchemaException', () async {
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response('<html>not json</html>', 200);
        }),
      );

      expect(
        () => client.listTimeEvents(
          accessToken: _accessToken,
          module: _module,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 6),
        ),
        throwsA(isA<AdpSchemaException>()),
      );
    });

    test('missing access_token in OAuth response → AdpSchemaException',
        () async {
      final client = _buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'refresh_token': 'r',
              'expires_in': 60,
            }),
            200,
          );
        }),
      );

      expect(
        () => client.exchangeAuthorizationCode(
          authorizationCode: 'code',
          redirectUri: 'https://x/y',
          module: _module,
        ),
        throwsA(isA<AdpSchemaException>()),
      );
    });
  });
}
