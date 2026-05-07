// Phase 8 / `8.transport.agendrix-labor` — production HTTP transport
// tests for [AgendrixProductionApiClient].
//
// Coverage matrix (per slice prompt):
//   * Happy path: GET round-trip — URL, headers (X-Api-Key + company),
//     body decoded into AgendrixTimeEntryPage, lastModifiedSeen pulled
//     from the newest `updated_at`.
//   * Pagination: cursor threaded through; empty cursor terminates.
//   * 429 backoff: bounded exponential; respects Retry-After hint
//     while clamped at maxBackoff.
//   * 401: surfaces as AgendrixApiException(kind = unauthorized).
//   * Schema roundtrip: malformed body / non-Z timestamp / missing
//     `time_entries[]` array surface as malformedResponse.
//
// Tests use `package:http/testing.dart`'s `MockClient` to stub
// responses; no network round-trip.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/agendrix_labor_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _opId = 'op_demo_diner';
const String _locId = 'loc_toronto_yorkville';
const String _apiKey = 'sk_test_agendrix_xyz';
const String _companyId = 'co_42';

http.Response _jsonResponse(
  int statusCode,
  Object? body, {
  Map<String, String>? extraHeaders,
}) {
  return http.Response(
    body is String ? body : jsonEncode(body),
    statusCode,
    headers: <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json',
      ...?extraHeaders,
    },
  );
}

class _StubCredentialStore implements AgendrixCredentialStore {
  _StubCredentialStore();
  final String apiKey = _apiKey;
  final String companyId = _companyId;
  int reads = 0;

  @override
  Future<AgendrixCredential> readCredential({
    required String operatorId,
    required String locationId,
  }) async {
    reads += 1;
    return AgendrixCredential(apiKey: apiKey, companyId: companyId);
  }
}

class _ThrowingCredentialStore implements AgendrixCredentialStore {
  @override
  Future<AgendrixCredential> readCredential({
    required String operatorId,
    required String locationId,
  }) async {
    throw AgendrixApiException(
      kind: AgendrixApiErrorKind.unauthorized,
      message: 'no active credential',
    );
  }
}

void main() {
  group('AgendrixProductionApiClient — happy path', () {
    test('fetchTimeEntries: URL + headers + body roundtrip', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return _jsonResponse(200, <String, Object?>{
          'time_entries': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'te_1',
              'user_id': 'usr_1',
              'position': <String, Object?>{'id': 'p1', 'name': 'Server'},
              'start_time': '2026-05-02T15:00:00.000Z',
              'end_time': '2026-05-02T22:30:00.000Z',
              'updated_at': '2026-05-02T22:32:14.000Z',
            },
            <String, Object?>{
              'id': 'te_2',
              'user_id': 'usr_2',
              'position': <String, Object?>{'id': 'p2', 'name': 'Cook'},
              'start_time': '2026-05-02T16:30:00.000Z',
              'end_time': '2026-05-02T23:45:00.000Z',
              'updated_at': '2026-05-02T23:48:01.000Z',
            },
          ],
          'next_cursor': 'cursor-page-2',
        });
      });

      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );

      final page = await client.fetchTimeEntries(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 3, 4),
        cursor: null,
        isDeliberateBackfill: true,
      );

      // URL shape.
      expect(capturedUri, isNotNull);
      expect(
        capturedUri!.toString(),
        startsWith('https://api.agendrix.com/v2/companies/$_companyId/time_entries'),
      );
      expect(capturedUri!.queryParameters['limit'], '100');
      expect(
        capturedUri!.queryParameters['updated_after'],
        '2026-03-04T00:00:00.000Z',
      );
      expect(capturedUri!.queryParameters.containsKey('cursor'), isFalse);

      // Headers — API key + company id.
      expect(capturedHeaders![agendrixApiKeyHeader], _apiKey);
      expect(capturedHeaders![agendrixCompanyHeader], _companyId);
      expect(capturedHeaders![HttpHeaders.acceptHeader], 'application/json');

      // Decoded body.
      expect(page.records, hasLength(2));
      expect(page.records.first['id'], 'te_1');
      expect(page.records.last['user_id'], 'usr_2');
      expect(page.nextCursor, 'cursor-page-2');
      // lastModifiedSeen = max(updated_at) across records, parsed as UTC.
      expect(
        page.lastModifiedSeen,
        DateTime.utc(2026, 5, 2, 23, 48, 1),
      );
    });

    test('fetchSampleTimeEntry: requests limit=1, no cursor, no updated_after',
        () async {
      Uri? capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return _jsonResponse(200, <String, Object?>{
          'time_entries': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'te_sample',
              'updated_at': '2026-05-02T22:32:14.000Z',
            },
          ],
          'next_cursor': '',
        });
      });

      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );

      final page = await client.fetchSampleTimeEntry(
        operatorId: _opId,
        locationId: _locId,
      );

      expect(capturedUri!.queryParameters['limit'], '1');
      expect(capturedUri!.queryParameters.containsKey('updated_after'), isFalse);
      expect(capturedUri!.queryParameters.containsKey('cursor'), isFalse);
      expect(page.records, hasLength(1));
      expect(page.nextCursor, '');
    });
  });

  group('AgendrixProductionApiClient — pagination', () {
    test('cursor passed back into the next request; empty cursor terminates',
        () async {
      final requestedCursors = <String?>[];
      var pageIdx = 0;
      final mock = MockClient((request) async {
        requestedCursors.add(request.url.queryParameters['cursor']);
        if (pageIdx == 0) {
          pageIdx += 1;
          return _jsonResponse(200, <String, Object?>{
            'time_entries': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'te_a',
                'updated_at': '2026-05-02T22:00:00.000Z',
              },
            ],
            'next_cursor': 'cur-2',
          });
        }
        return _jsonResponse(200, <String, Object?>{
          'time_entries': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'te_b',
              'updated_at': '2026-05-02T23:00:00.000Z',
            },
          ],
          'next_cursor': '',
        });
      });

      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );

      final page1 = await client.fetchTimeEntries(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 3, 4),
        cursor: null,
        isDeliberateBackfill: false,
      );
      expect(page1.nextCursor, 'cur-2');
      expect(requestedCursors.last, isNull);

      final page2 = await client.fetchTimeEntries(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: page1.lastModifiedSeen,
        cursor: page1.nextCursor,
        isDeliberateBackfill: false,
      );
      expect(page2.nextCursor, '');
      expect(requestedCursors.last, 'cur-2');
    });
  });

  group('AgendrixProductionApiClient — 429 backoff', () {
    test('retries up to maxRetriesOn429 and surfaces success on the next 200',
        () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        if (calls <= 2) {
          return _jsonResponse(
            429,
            <String, Object?>{'error': 'rate-limited'},
            extraHeaders: <String, String>{'retry-after': '1'},
          );
        }
        return _jsonResponse(200, <String, Object?>{
          'time_entries': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'te_after_429',
              'updated_at': '2026-05-02T22:32:14.000Z',
            },
          ],
          'next_cursor': '',
        });
      });

      final sleeps = <Duration>[];
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
        sleep: (d) async => sleeps.add(d),
      );

      final page = await client.fetchTimeEntries(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 3, 4),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(calls, 3);
      expect(sleeps.length, 2);
      // Both backoff sleeps respected the Retry-After=1s hint
      // (clamped well under maxBackoff).
      for (final s in sleeps) {
        expect(s.inSeconds, 1);
      }
      expect(page.records, hasLength(1));
      expect(page.records.single['id'], 'te_after_429');
    });

    test('exhausts retries and throws rateLimitExhausted', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return _jsonResponse(
          429,
          <String, Object?>{'error': 'rate-limited'},
        );
      });

      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
        maxRetriesOn429: 2,
        sleep: (d) async {},
      );

      await expectLater(
        () => client.fetchTimeEntries(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 3, 4),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(
          isA<AgendrixApiException>().having(
            (e) => e.kind,
            'kind',
            AgendrixApiErrorKind.rateLimitExhausted,
          ),
        ),
      );
      // 1 initial attempt + 2 retries = 3 calls.
      expect(calls, 3);
    });

    test('clamps absurd Retry-After at maxBackoff', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        if (calls == 1) {
          return _jsonResponse(
            429,
            <String, Object?>{'error': 'rate-limited'},
            // 1800 seconds (30 minutes) — well above maxBackoff.
            extraHeaders: <String, String>{'retry-after': '1800'},
          );
        }
        return _jsonResponse(200, <String, Object?>{
          'time_entries': const <Map<String, Object?>>[],
          'next_cursor': '',
        });
      });

      final sleeps = <Duration>[];
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
        maxBackoff: const Duration(seconds: 5),
        sleep: (d) async => sleeps.add(d),
      );

      await client.fetchTimeEntries(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 3, 4),
        cursor: null,
        isDeliberateBackfill: false,
      );
      expect(sleeps, hasLength(1));
      expect(sleeps.single.inSeconds, lessThanOrEqualTo(5));
    });
  });

  group('AgendrixProductionApiClient — typed errors', () {
    test('401 surfaces as unauthorized', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(401, <String, Object?>{'error': 'invalid_token'});
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );
      await expectLater(
        () => client.fetchTimeEntries(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 3, 4),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(
          isA<AgendrixApiException>().having(
            (e) => e.kind,
            'kind',
            AgendrixApiErrorKind.unauthorized,
          ),
        ),
      );
    });

    test('credential store throw propagates as unauthorized', () async {
      final mock = MockClient((request) async {
        fail('HTTP must not be invoked when the credential lookup fails');
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _ThrowingCredentialStore(),
        httpClient: mock,
      );
      await expectLater(
        () => client.fetchTimeEntries(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 3, 4),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(
          isA<AgendrixApiException>().having(
            (e) => e.kind,
            'kind',
            AgendrixApiErrorKind.unauthorized,
          ),
        ),
      );
    });

    test('5xx surfaces as vendorOutage', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(503, <String, Object?>{'error': 'maint'});
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );
      await expectLater(
        () => client.fetchTimeEntries(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 3, 4),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(
          isA<AgendrixApiException>().having(
            (e) => e.kind,
            'kind',
            AgendrixApiErrorKind.vendorOutage,
          ),
        ),
      );
    });
  });

  group('AgendrixProductionApiClient — schema roundtrip', () {
    test('non-JSON body surfaces as malformedResponse', () async {
      final mock = MockClient((request) async {
        return http.Response(
          'not-json{',
          200,
          headers: <String, String>{
            HttpHeaders.contentTypeHeader: 'application/json',
          },
        );
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );
      await expectLater(
        () => client.fetchTimeEntries(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 3, 4),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(
          isA<AgendrixApiException>().having(
            (e) => e.kind,
            'kind',
            AgendrixApiErrorKind.malformedResponse,
          ),
        ),
      );
    });

    test('missing time_entries array surfaces as malformedResponse', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'data': <Map<String, Object?>>[],
        });
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );
      await expectLater(
        () => client.fetchTimeEntries(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 3, 4),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(
          isA<AgendrixApiException>().having(
            (e) => e.kind,
            'kind',
            AgendrixApiErrorKind.malformedResponse,
          ),
        ),
      );
    });

    test('non-Z updated_at preserves UTC instant (parsed as UTC)', () async {
      // DateTime.parse accepts offsets; per agendrix.asUtc the live
      // verification slice is responsible for catching the boundary.
      // The transport must NOT silently coerce naive (no-tz) strings
      // — Dart treats those as local. To assert deterministic UTC
      // behaviour we feed an explicit `+00:00` instant and verify it
      // survives round-trip as UTC.
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'time_entries': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'te_offset',
              'updated_at': '2026-05-02T22:32:14+00:00',
            },
          ],
          'next_cursor': '',
        });
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );
      final page = await client.fetchTimeEntries(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 3, 4),
        cursor: null,
        isDeliberateBackfill: false,
      );
      expect(page.lastModifiedSeen.isUtc, isTrue);
      expect(page.lastModifiedSeen, DateTime.utc(2026, 5, 2, 22, 32, 14));
    });

    test('garbage updated_at surfaces as malformedResponse', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'time_entries': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'te_garbage',
              'updated_at': 'not-a-date',
            },
          ],
          'next_cursor': '',
        });
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
      );
      await expectLater(
        () => client.fetchTimeEntries(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 3, 4),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(
          isA<AgendrixApiException>().having(
            (e) => e.kind,
            'kind',
            AgendrixApiErrorKind.malformedResponse,
          ),
        ),
      );
    });
  });

  group('AgendrixProductionApiClient — POST helper', () {
    test('postJson stamps Idempotency-Key + content-type', () async {
      Map<String, String>? capturedHeaders;
      String? capturedBody;
      final mock = MockClient((request) async {
        capturedHeaders = request.headers;
        capturedBody = request.body;
        return _jsonResponse(200, <String, Object?>{'ok': true});
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
        idempotencyKeyGenerator: () => 'idem-fixed-1',
      );
      final body = await client.postJson(
        operatorId: _opId,
        locationId: _locId,
        relativePath: 'webhooks/subscriptions',
        body: <String, Object?>{'url': 'https://example.com/hook'},
      );
      expect(capturedHeaders![agendrixIdempotencyHeader], 'idem-fixed-1');
      expect(capturedHeaders![HttpHeaders.contentTypeHeader],
          'application/json');
      expect(capturedHeaders![agendrixApiKeyHeader], _apiKey);
      expect(capturedBody, jsonEncode(<String, Object?>{
        'url': 'https://example.com/hook',
      }));
      expect(body['ok'], true);
    });

    test('caller-supplied Idempotency-Key wins', () async {
      Map<String, String>? capturedHeaders;
      final mock = MockClient((request) async {
        capturedHeaders = request.headers;
        return _jsonResponse(200, <String, Object?>{'ok': true});
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
        idempotencyKeyGenerator: () => 'should-not-be-used',
      );
      await client.postJson(
        operatorId: _opId,
        locationId: _locId,
        relativePath: 'anything',
        body: const <String, Object?>{},
        idempotencyKey: 'caller-key-7',
      );
      expect(capturedHeaders![agendrixIdempotencyHeader], 'caller-key-7');
    });
  });

  group('AgendrixProductionApiClient — base URI override', () {
    test('honors injected base URI for sandbox/test environments',
        () async {
      Uri? capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return _jsonResponse(200, <String, Object?>{
          'time_entries': const <Map<String, Object?>>[],
          'next_cursor': '',
        });
      });
      final client = AgendrixProductionApiClient(
        credentialStore: _StubCredentialStore(),
        httpClient: mock,
        baseUri: Uri.parse('https://sandbox.agendrix.example/v2/'),
      );
      await client.fetchTimeEntries(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 3, 4),
        cursor: null,
        isDeliberateBackfill: false,
      );
      expect(
        capturedUri!.toString(),
        startsWith(
          'https://sandbox.agendrix.example/v2/companies/$_companyId/time_entries',
        ),
      );
    });
  });
}
