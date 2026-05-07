// Phase 8 / `8.transport.aloha-ncr-voyix-pos` — Production transport
// tests for the Aloha (NCR Voyix) POS adapter.
//
// Coverage:
//   1. exchangeClientCredentials happy path — POSTs to the OAuth token
//      endpoint with Basic auth + nep-application-key + nep-organization
//      headers, parses access_token, returns a credential handle.
//   2. fetchSampleCheck happy path — GETs the sample-check endpoint
//      with Bearer + nep-* headers + Aloha-Site-Id, parses JSON object.
//   3. fetchChecksPage happy path — GETs the search endpoint with
//      modifiedAtMin/Max + cursor; parses the `checks` array, picks
//      the latest `modifiedAt` as `lastModifiedSeen`.
//   4. fetchCheckById happy path — GETs the by-id endpoint, parses JSON.
//   5. fetchCheckById 404 → returns null (not an error).
//   6. registerWebhook happy path — POSTs subscription, returns id.
//   7. unregisterWebhook idempotent — 404 treated as already-gone.
//   8. 401 → AlohaNcrVoyixAuthException.
//   9. 429 with Retry-After → retries; eventual success returns body.
//  10. 429 exhausted → AlohaNcrVoyixRateLimitException with retryAfter.
//  11. 500 → AlohaNcrVoyixVendorException with bodyExcerpt + status.
//  12. Network error → AlohaNcrVoyixTransportException.
//  13. Schema roundtrip — fixture ↔ JSON ↔ fixture preserves every
//      documented field (covers, opened_at, closed_at, modifiedAt,
//      checkId, totalAmount, siteId).
//  14. baseUriOverride from credential store wins over the constructor
//      default (on-prem relay deployment model).
//
// Limitations documented for `*.live.sandbox` follow-up:
//   * The exact NCR Voyix Aloha REST URL paths used here mirror the
//     documented portal shape; the live verification slice will diff
//     observed responses against `documentedPerAlohaNcrVoyixV1` and
//     pin any drift as a bounded fix.
//   * The `Aloha-Site-Id` / `nep-organization` header names track the
//     publicly-documented NCR Voyix conventions; if NCR Voyix renames
//     them between now and the live slice, only the production client
//     needs the header rename — the abstract surface is unchanged.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'fixtures/aloha_ncr_voyix_orders_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _siteId = 'site-aloha-001';

const AlohaNcrVoyixCredentialHandle _handle = AlohaNcrVoyixCredentialHandle(
  connectionId: 'conn-aloha-1',
  siteId: _siteId,
);

const AlohaNcrVoyixOauthClientCredentials _oauth =
    AlohaNcrVoyixOauthClientCredentials(
  clientId: 'cid-test',
  clientSecret: 'csec-test',
  applicationKey: 'app-key-test',
  organizationId: 'org-test',
  scope: 'aloha:read',
);

const AlohaNcrVoyixResolvedCredentials _resolved =
    AlohaNcrVoyixResolvedCredentials(
  accessToken: 'access-token-test',
  applicationKey: 'app-key-test',
  organizationId: 'org-test',
  siteId: _siteId,
);

Future<AlohaNcrVoyixResolvedCredentials> _staticStore(
    AlohaNcrVoyixCredentialHandle h) async => _resolved;

void main() {
  group('AlohaNcrVoyixPosProductionApiClient', () {
    test('1. exchangeClientCredentials posts to the token endpoint with '
        'Basic auth + nep-* headers and returns a handle', () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'access_token': 'minted-access-token',
            'token_type': 'Bearer',
            'expires_in': 3600,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );

      final result = await client.exchangeClientCredentials(
        operatorId: _opId,
        locationId: _locId,
        siteId: _siteId,
      );

      expect(result.siteId, _siteId);
      expect(captured.method, 'POST');
      expect(captured.url.path, kAlohaOauthTokenPath);
      expect(captured.headers['authorization'],
          startsWith('Basic '));
      expect(captured.headers['nep-application-key'], 'app-key-test');
      expect(captured.headers['nep-organization'], 'org-test');
      expect(captured.headers['content-type'],
          contains('application/x-www-form-urlencoded'));
      expect(captured.body, contains('grant_type=client_credentials'));
      expect(captured.body, contains('scope=aloha%3Aread'));
    });

    test('2. fetchSampleCheck issues GET with Bearer + nep-* + site-id headers',
        () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(alohaNcrVoyixSampleCheck),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );

      final sample = await client.fetchSampleCheck(credentials: _handle);

      expect(captured.method, 'GET');
      expect(captured.url.path, kAlohaSampleCheckPath);
      expect(captured.headers['authorization'], 'Bearer access-token-test');
      expect(captured.headers['nep-application-key'], 'app-key-test');
      expect(captured.headers['nep-organization'], 'org-test');
      expect(captured.headers['aloha-site-id'], _siteId);
      expect(sample['checkId'], alohaNcrVoyixSampleCheck['checkId']);
      expect(sample['numberOfGuests'], alohaNcrVoyixSampleCheck['numberOfGuests']);
    });

    test('3. fetchChecksPage parses checks + nextCursor + lastModifiedSeen',
        () async {
      late http.Request captured;
      final checks = alohaNcrVoyixBackfillPage1Checks();
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'checks': checks,
            'nextCursor': 'cursor-page-2',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );

      final start = DateTime.utc(2026, 5, 1);
      final end = DateTime.utc(2026, 5, 5);
      final page = await client.fetchChecksPage(
        credentials: _handle,
        windowStart: start,
        windowEnd: end,
        resumeFromCursor: 'cursor-page-1',
      );

      expect(captured.method, 'GET');
      expect(captured.url.path, kAlohaCheckSearchPath);
      expect(captured.url.queryParameters['modifiedAtMin'],
          start.toIso8601String());
      expect(captured.url.queryParameters['modifiedAtMax'],
          end.toIso8601String());
      expect(captured.url.queryParameters['siteId'], _siteId);
      expect(captured.url.queryParameters['cursor'], 'cursor-page-1');

      expect(page.checks.length, checks.length);
      expect(page.nextCursor, 'cursor-page-2');
      // Latest `modifiedAt` from page-1 fixture is 2026-05-04T19:05:00Z.
      expect(page.lastModifiedSeen.toUtc(),
          DateTime.parse('2026-05-04T19:05:00.000Z').toUtc());
    });

    test('4. fetchCheckById GETs the by-id endpoint and parses the body',
        () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(alohaNcrVoyixSampleCheck),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );

      final result = await client.fetchCheckById(
        credentials: _handle,
        checkId: 'chk-2026-05-04-001',
      );

      expect(captured.method, 'GET');
      expect(captured.url.path,
          '$kAlohaCheckByIdPathPrefix${'chk-2026-05-04-001'}');
      expect(result, isNotNull);
      expect(result!['checkId'], 'chk-2026-05-04-001');
    });

    test('5. fetchCheckById returns null on 404 (not an error)', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response('not found', 404);
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );
      final result = await client.fetchCheckById(
        credentials: _handle,
        checkId: 'missing',
      );
      expect(result, isNull);
    });

    test('6. registerWebhook posts subscription body and returns id',
        () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'subscriptionId': 'sub-aloha-99',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );

      final id = await client.registerWebhook(
        credentials: _handle,
        webhookUrl: '/v1/webhooks/aloha_ncr_voyix/op/loc',
      );

      expect(id, 'sub-aloha-99');
      expect(captured.method, 'POST');
      expect(captured.url.path, kAlohaWebhookSubscriptionsPath);
      final decoded = jsonDecode(captured.body) as Map<String, Object?>;
      expect(decoded['url'], '/v1/webhooks/aloha_ncr_voyix/op/loc');
      expect(decoded['siteId'], _siteId);
      final events = decoded['events'] as List;
      expect(events, contains('aloha.check.modified'));
    });

    test('7. unregisterWebhook treats 404 as already-gone and returns true',
        () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response('', 404);
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );
      final ok = await client.unregisterWebhook(
        credentials: _handle,
        subscriptionId: 'sub-gone',
      );
      expect(ok, true);
    });

    test('8. 401 surfaces AlohaNcrVoyixAuthException', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'invalid_token'}),
          401,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );

      await expectLater(
        client.fetchSampleCheck(credentials: _handle),
        throwsA(isA<AlohaNcrVoyixAuthException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('9. 429 with Retry-After honors backoff and eventually succeeds',
        () async {
      var calls = 0;
      final mock = http_testing.MockClient((http.Request request) async {
        calls += 1;
        if (calls < 3) {
          return http.Response(
            'rate limited',
            429,
            headers: <String, String>{
              'retry-after': '0',
              'content-type': 'text/plain',
            },
          );
        }
        return http.Response(
          jsonEncode(alohaNcrVoyixSampleCheck),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final sleeps = <Duration>[];
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
        sleep: (d) async {
          sleeps.add(d);
        },
      );

      final result = await client.fetchSampleCheck(credentials: _handle);
      expect(result['checkId'], alohaNcrVoyixSampleCheck['checkId']);
      expect(calls, 3);
      expect(sleeps.length, 2);
      expect(sleeps.first, Duration.zero,
          reason: 'Retry-After: 0 maps to zero-second sleep');
    });

    test('10. 429 exhausted retries surface AlohaNcrVoyixRateLimitException',
        () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          'rate limited',
          429,
          headers: <String, String>{'retry-after': '7'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
        maxRateLimitRetries: 1,
        sleep: (_) async {},
      );

      await expectLater(
        client.fetchSampleCheck(credentials: _handle),
        throwsA(isA<AlohaNcrVoyixRateLimitException>()
            .having((e) => e.retryAfter, 'retryAfter',
                const Duration(seconds: 7))),
      );
    });

    test('11. 500 surfaces AlohaNcrVoyixVendorException with body excerpt',
        () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response('internal error detail', 500);
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );

      await expectLater(
        client.fetchSampleCheck(credentials: _handle),
        throwsA(isA<AlohaNcrVoyixVendorException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.bodyExcerpt, 'bodyExcerpt',
                contains('internal error detail'))),
      );
    });

    test('12. Network error surfaces AlohaNcrVoyixTransportException',
        () async {
      final mock = http_testing.MockClient((http.Request request) async {
        throw http.ClientException('socket closed');
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );
      await expectLater(
        client.fetchSampleCheck(credentials: _handle),
        throwsA(isA<AlohaNcrVoyixTransportException>()),
      );
    });

    test('13. schema roundtrip — fixture survives JSON encode/decode/parse',
        () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'checks': <Map<String, Object?>>[alohaNcrVoyixSampleCheck],
            'nextCursor': null,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: _staticStore,
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://api.test.local'),
      );

      final page = await client.fetchChecksPage(
        credentials: _handle,
        windowStart: DateTime.utc(2026, 5, 1),
        windowEnd: DateTime.utc(2026, 5, 5),
      );
      final roundTripped = page.checks.single;
      expect(roundTripped['checkId'], alohaNcrVoyixSampleCheck['checkId']);
      expect(roundTripped['siteId'], alohaNcrVoyixSampleCheck['siteId']);
      expect(roundTripped['modifiedAt'],
          alohaNcrVoyixSampleCheck['modifiedAt']);
      expect(roundTripped['openedAt'], alohaNcrVoyixSampleCheck['openedAt']);
      expect(roundTripped['closedAt'], alohaNcrVoyixSampleCheck['closedAt']);
      expect(roundTripped['numberOfGuests'],
          alohaNcrVoyixSampleCheck['numberOfGuests']);
      expect(roundTripped['totalAmount'],
          alohaNcrVoyixSampleCheck['totalAmount']);
      // TIMESTAMPTZ: lastModifiedSeen is UTC.
      expect(page.lastModifiedSeen.isUtc, true);
    });

    test('14. baseUriOverride from credential store wins over default',
        () async {
      late Uri capturedUri;
      final mock = http_testing.MockClient((http.Request request) async {
        capturedUri = request.url;
        return http.Response(
          jsonEncode(alohaNcrVoyixSampleCheck),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: (_) async => const AlohaNcrVoyixResolvedCredentials(
          accessToken: 'a',
          applicationKey: 'k',
          organizationId: 'o',
          siteId: _siteId,
          baseUriOverride: null,
        ),
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://cloud.api.test.local'),
      );
      // Override at the credential store level.
      final clientRelay = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: (_) async => AlohaNcrVoyixResolvedCredentials(
          accessToken: 'a',
          applicationKey: 'k',
          organizationId: 'o',
          siteId: _siteId,
          baseUriOverride: Uri.parse('http://aloha-agent.local:8443'),
        ),
        oauthCredentials: _oauth,
        httpClient: mock,
        baseUri: Uri.parse('https://cloud.api.test.local'),
      );

      await client.fetchSampleCheck(credentials: _handle);
      expect(capturedUri.host, 'cloud.api.test.local');

      await clientRelay.fetchSampleCheck(credentials: _handle);
      expect(capturedUri.host, 'aloha-agent.local');
      expect(capturedUri.port, 8443);
    });
  });
}
