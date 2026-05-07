// Phase 8 / Wave B — `8.transport.oracle-micros-simphony` test suite.
//
// Verifies the production HTTP client against the documented Simphony
// Cloud API contract from `docs/integrations/oracle_micros_simphony/
// api_consumed.md` and `oauth_shape.md`. Uses `package:http/testing.dart`'s
// `MockClient` to stub responses; no live HTTP. Mirrors the test style
// in `test/proxy/anthropic_http_complete_fn_test.dart`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/oracle_micros_simphony_checks_fixture.dart';

const String _opId = 'op_demo_diner';
const String _locId = 'loc_toronto_yorkville';

class _FakeTokenStore implements SimphonyTokenStore {
  _FakeTokenStore({
    SimphonyAccessToken? initial,
    SimphonyAccessToken? refreshed,
  })  : _initial = initial ??
            SimphonyAccessToken(
              accessToken: 'access-token-1',
              expiresAt: DateTime.utc(2099, 1, 1),
            ),
        _refreshed = refreshed ??
            SimphonyAccessToken(
              accessToken: 'access-token-2',
              expiresAt: DateTime.utc(2099, 1, 1),
            );

  final SimphonyAccessToken _initial;
  final SimphonyAccessToken _refreshed;

  int fetchCalls = 0;
  int refreshCalls = 0;

  @override
  Future<SimphonyAccessToken> fetchAccessToken({
    required String operatorId,
    required String locationId,
    required SimphonyVendorCredentialHandle credential,
  }) async {
    fetchCalls += 1;
    return _initial;
  }

  @override
  Future<SimphonyAccessToken> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required SimphonyVendorCredentialHandle credential,
  }) async {
    refreshCalls += 1;
    return _refreshed;
  }
}

http.Response _jsonResponse(int statusCode, Object? body,
    {Map<String, String>? headers}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json',
      ...?headers,
    },
  );
}

OracleMicrosSimphonyProductionApiClient _build({
  required http.Client httpClient,
  SimphonyTokenStore? tokenStore,
  Future<void> Function(Duration)? delay,
  int maxRetries = 3,
}) {
  return OracleMicrosSimphonyProductionApiClient(
    httpClient: httpClient,
    tokenStore: tokenStore ?? _FakeTokenStore(),
    credential: const SimphonyVendorCredentialHandle(credentialId: 'cred-1'),
    baseUri: Uri.parse('https://api.example/sim/api/v2/'),
    delay: delay ?? (_) async {},
    maxRetries: maxRetries,
    initialBackoff: const Duration(milliseconds: 1),
    maxBackoff: const Duration(milliseconds: 10),
    idempotencyKeyFn: ({
      required String operatorId,
      required String locationId,
      required String purpose,
    }) =>
        'idem:$purpose:$operatorId:$locationId',
  );
}

void main() {
  group('OracleMicrosSimphonyProductionApiClient — happy GET / POST', () {
    test('fetchGuestChecks returns parsed page from a 200 response', () async {
      late http.BaseRequest captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[sampleSimphonyGuestCheck],
          'nextCursor': '',
          'lastModifiedUTC': '2026-05-02T23:32:14.000Z',
        });
      });

      final client = _build(httpClient: mock);
      final page = await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 4, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(page.records, hasLength(1));
      expect(page.records.single['header'],
          sampleSimphonyGuestCheck['header']);
      expect(page.nextCursor, '');
      expect(page.lastModifiedSeen, DateTime.utc(2026, 5, 2, 23, 32, 14));

      // Outbound shape: posData/getGuestChecks under the documented v2 base,
      // bearer header, idempotency key, accept JSON.
      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          startsWith('https://api.example/sim/api/v2/posData/getGuestChecks'));
      expect(captured.headers[HttpHeaders.authorizationHeader],
          'Bearer access-token-1');
      expect(captured.headers['Idempotency-Key'], isNotNull);
      expect(captured.headers[HttpHeaders.acceptHeader], 'application/json');
    });

    test('fetchSampleGuestCheck returns the first row only and forces empty '
        'next cursor', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[
            sampleSimphonyGuestCheck,
            secondSimphonyGuestCheck,
          ],
          'nextCursor': 'should-be-ignored',
          'lastModifiedUTC': '2026-05-02T23:48:01.000Z',
        });
      });

      final client = _build(httpClient: mock);
      final page = await client.fetchSampleGuestCheck(
        operatorId: _opId,
        locationId: _locId,
      );

      expect(page.records, hasLength(1));
      expect(page.records.single, sampleSimphonyGuestCheck);
      expect(page.nextCursor, '');
    });
  });

  group('OracleMicrosSimphonyProductionApiClient — pagination', () {
    test('subsequent call carries cursor token in the request body', () async {
      var call = 0;
      late http.BaseRequest secondCapture;
      final mock = MockClient((request) async {
        call += 1;
        if (call == 1) {
          return _jsonResponse(200, <String, Object?>{
            'items': <Map<String, Object?>>[sampleSimphonyGuestCheck],
            'nextCursor': 'cursor-page-2',
            'lastModifiedUTC': '2026-05-02T23:32:14.000Z',
          });
        }
        secondCapture = request;
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[secondSimphonyGuestCheck],
          'nextCursor': '',
          'lastModifiedUTC': '2026-05-02T23:48:01.000Z',
        });
      });

      final client = _build(httpClient: mock);
      final pageOne = await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 4, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );
      expect(pageOne.nextCursor, 'cursor-page-2');

      final pageTwo = await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: pageOne.lastModifiedSeen,
        cursor: pageOne.nextCursor,
        isDeliberateBackfill: false,
      );
      expect(pageTwo.nextCursor, '');

      // The second outbound request body carries the cursor.
      final body = jsonDecode((secondCapture as http.Request).body)
          as Map<String, Object?>;
      expect(body['cursor'], 'cursor-page-2');
    });
  });

  group('OracleMicrosSimphonyProductionApiClient — 401 token refresh', () {
    test('signals refresh on 401 and retries once with the new bearer',
        () async {
      var call = 0;
      late http.BaseRequest secondCapture;
      final mock = MockClient((request) async {
        call += 1;
        if (call == 1) {
          return http.Response('unauthorized', 401);
        }
        secondCapture = request;
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[sampleSimphonyGuestCheck],
          'nextCursor': '',
          'lastModifiedUTC': '2026-05-02T23:32:14.000Z',
        });
      });

      final tokenStore = _FakeTokenStore();
      final client = _build(httpClient: mock, tokenStore: tokenStore);

      await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 4, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(tokenStore.fetchCalls, 1);
      expect(tokenStore.refreshCalls, 1);
      expect(secondCapture.headers[HttpHeaders.authorizationHeader],
          'Bearer access-token-2');
    });

    test('second 401 in a row throws SimphonyAuthError without re-refreshing',
        () async {
      final mock = MockClient((request) async {
        return http.Response('still unauthorized', 401);
      });
      final tokenStore = _FakeTokenStore();
      final client = _build(httpClient: mock, tokenStore: tokenStore);

      await expectLater(
        client.fetchGuestChecks(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 4, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<SimphonyAuthError>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.body, 'body', contains('still unauthorized'))),
      );
      expect(tokenStore.refreshCalls, 1);
    });
  });

  group('OracleMicrosSimphonyProductionApiClient — 429 backoff', () {
    test('honors Retry-After integer-seconds and retries up to maxRetries',
        () async {
      final delays = <Duration>[];
      var call = 0;
      final mock = MockClient((request) async {
        call += 1;
        if (call <= 2) {
          return http.Response(
            'rate limited',
            429,
            headers: <String, String>{'retry-after': '2'},
          );
        }
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[sampleSimphonyGuestCheck],
          'nextCursor': '',
          'lastModifiedUTC': '2026-05-02T23:32:14.000Z',
        });
      });

      final client = _build(
        httpClient: mock,
        delay: (d) async {
          delays.add(d);
        },
      );

      final page = await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 4, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(page.records, hasLength(1));
      expect(call, 3);
      // Two 429s -> two delays; both honored vendor's `Retry-After: 2`.
      expect(delays, <Duration>[
        const Duration(seconds: 2),
        const Duration(seconds: 2),
      ]);
    });

    test('exhausting retries on sustained 429 throws SimphonyRateLimitError',
        () async {
      final mock = MockClient((request) async {
        return http.Response(
          'too many',
          429,
          headers: <String, String>{'retry-after': '3'},
        );
      });
      final client = _build(httpClient: mock, maxRetries: 2);

      await expectLater(
        client.fetchGuestChecks(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 4, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<SimphonyRateLimitError>()
            .having((e) => e.lastRetryAfter, 'lastRetryAfter',
                const Duration(seconds: 3))
            .having((e) => e.body, 'body', contains('too many'))),
      );
    });

    test('falls back to exponential back-off when Retry-After is absent',
        () async {
      final delays = <Duration>[];
      var call = 0;
      final mock = MockClient((request) async {
        call += 1;
        if (call <= 1) {
          return http.Response('rate limited', 429);
        }
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[sampleSimphonyGuestCheck],
          'nextCursor': '',
          'lastModifiedUTC': '2026-05-02T23:32:14.000Z',
        });
      });
      final client = _build(
        httpClient: mock,
        delay: (d) async {
          delays.add(d);
        },
      );

      await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 4, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      // Exactly one back-off (one 429); first attempt @ initialBackoff.
      expect(delays, hasLength(1));
      expect(delays.single, const Duration(milliseconds: 1));
    });
  });

  group('OracleMicrosSimphonyProductionApiClient — 5xx retry', () {
    test('retries 500 up to maxRetries and succeeds on the third attempt',
        () async {
      var call = 0;
      final mock = MockClient((request) async {
        call += 1;
        if (call <= 2) {
          return http.Response('upstream blip', 500);
        }
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[sampleSimphonyGuestCheck],
          'nextCursor': '',
          'lastModifiedUTC': '2026-05-02T23:32:14.000Z',
        });
      });
      final client = _build(httpClient: mock);

      final page = await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 4, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );
      expect(page.records, hasLength(1));
      expect(call, 3);
    });

    test('exhausting retries on sustained 503 throws SimphonyServerError',
        () async {
      final mock = MockClient((request) async {
        return http.Response('still down', 503);
      });
      final client = _build(httpClient: mock, maxRetries: 2);

      await expectLater(
        client.fetchGuestChecks(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 4, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<SimphonyServerError>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.body, 'body', contains('still down'))),
      );
    });

    test('400 and other client errors throw SimphonyClientError without retry',
        () async {
      var call = 0;
      final mock = MockClient((request) async {
        call += 1;
        return http.Response('bad request', 400);
      });
      final client = _build(httpClient: mock);

      await expectLater(
        client.fetchGuestChecks(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 4, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<SimphonyClientError>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.body, 'body', contains('bad request'))),
      );
      expect(call, 1);
    });
  });

  group('OracleMicrosSimphonyProductionApiClient — schema roundtrip', () {
    test('preserves TIMESTAMPTZ instants and integer guestCount end-to-end',
        () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[sampleSimphonyGuestCheck],
          'nextCursor': '',
          'lastModifiedUTC': '2026-05-02T23:32:14.000Z',
        });
      });
      final client = _build(httpClient: mock);

      final page = await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 4, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      // The adapter feeds the raw `record` map into
      // `_mapGuestCheckToCanonical`. Verify the preserved shape so the
      // adapter's downstream mapping (covers / opened_at / closed_at /
      // actual_sales / vendor_modified_at) reads valid values.
      final record = page.records.single;
      final header = record['header'] as Map<String, Object?>;
      expect(header['guestCount'], 5);
      expect(header['chkNum'], 412901);
      expect(header['subTtlCents'], 12485);
      expect(header['opnUTC'], '2026-05-02T22:45:00.000Z');
      expect(header['cmplOrClsdUTC'], '2026-05-02T23:32:14.000Z');
      expect(header['lastUpdatedUTC'], '2026-05-02T23:32:14.000Z');

      // Page-level watermark is UTC-normalized.
      expect(page.lastModifiedSeen.isUtc, isTrue);
      expect(page.lastModifiedSeen, DateTime.utc(2026, 5, 2, 23, 32, 14));
    });

    test('falls back to max lastUpdatedUTC across rows when envelope omits '
        'lastModifiedUTC', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'items': <Map<String, Object?>>[
            sampleSimphonyGuestCheck,
            secondSimphonyGuestCheck,
          ],
          'nextCursor': '',
          // No lastModifiedUTC — the parser scans rows.
        });
      });
      final client = _build(httpClient: mock);

      final page = await client.fetchGuestChecks(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 4, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      // Latest of the two rows' lastUpdatedUTC instants.
      expect(page.lastModifiedSeen, DateTime.utc(2026, 5, 2, 23, 48, 1));
    });

    test('malformed body (missing items array) throws '
        'SimphonyMalformedResponseError', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          // No items.
          'nextCursor': '',
        });
      });
      final client = _build(httpClient: mock);

      await expectLater(
        client.fetchGuestChecks(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 4, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<SimphonyMalformedResponseError>()),
      );
    });

    test('non-JSON body throws SimphonyMalformedResponseError', () async {
      final mock = MockClient((request) async {
        return http.Response(
          '<html>not json</html>',
          200,
          headers: <String, String>{
            HttpHeaders.contentTypeHeader: 'text/html',
          },
        );
      });
      final client = _build(httpClient: mock);

      await expectLater(
        client.fetchGuestChecks(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 4, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<SimphonyMalformedResponseError>()),
      );
    });
  });

  group('OracleMicrosSimphonyProductionApiClient — request timeout', () {
    test('fires when the upstream response is delayed past the timeout',
        () async {
      final mock = MockClient((request) async {
        return Future<http.Response>.delayed(
          const Duration(seconds: 2),
          () => _jsonResponse(200, <String, Object?>{
            'items': <Map<String, Object?>>[],
            'nextCursor': '',
            'lastModifiedUTC': '2026-05-02T23:32:14.000Z',
          }),
        );
      });
      final client = OracleMicrosSimphonyProductionApiClient(
        httpClient: mock,
        tokenStore: _FakeTokenStore(),
        credential: const SimphonyVendorCredentialHandle(credentialId: 'cred-1'),
        baseUri: Uri.parse('https://api.example/sim/api/v2/'),
        timeout: const Duration(milliseconds: 50),
        maxRetries: 0,
        delay: (_) async {},
      );

      await expectLater(
        client.fetchGuestChecks(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 4, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
