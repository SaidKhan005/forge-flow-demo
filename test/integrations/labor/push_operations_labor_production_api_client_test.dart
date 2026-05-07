// Phase 8.S / `8.transport.push-operations-labor` — production HTTP
// transport tests.
//
// Coverage:
//   1. Happy path: sample fetch + paged fetch hit the documented
//      production base URI with `Authorization: Bearer <token>` and
//      `page+limit` query params.
//   2. Pagination: short page closes the cursor; full page emits
//      `page:<n+1>` so the adapter loop advances.
//   3. 429 with `Retry-After` integer seconds is honored; budget exhaust
//      throws `PushOperationsThrottledException`.
//   4. 401 throws `PushOperationsUnauthorizedException`.
//   5. Schema roundtrip: vendor `shifts[].id` / `start_at` / `end_at` /
//      `updated_at` survive the transport unmodified through to the
//      adapter's canonical-fact projection.
//   6. Auth missing throws `PushOperationsAuthMissingException`.
//
// All tests use `package:http/testing.dart`'s `MockClient` — no real
// network I/O.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/integrations/labor/push_operations_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_labor_production_api_client.dart';

const String _opId = 'op_demo_diner';
const String _locId = 'loc_toronto_yorkville';
const String _bearer = 'partner-bearer-abcdef';

http.Response _jsonResponse(int statusCode, Object? body, {Map<String, String>? headers}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json',
      ...?headers,
    },
  );
}

PushOperationsBearerResolver _staticBearer({String token = _bearer}) {
  return ({required String operatorId, required String locationId}) async => token;
}

PushOperationsBearerResolver _missingBearer() {
  return ({required String operatorId, required String locationId}) async => null;
}

Map<String, Object?> _shift({
  required int id,
  required String startAt,
  required String endAt,
  required String updatedAt,
  String position = 'Server',
  int employeeId = 5512,
}) {
  return <String, Object?>{
    'id': id,
    'employee_id': employeeId,
    'position_name': position,
    'start_at': startAt,
    'end_at': endAt,
    'updated_at': updatedAt,
  };
}

void main() {
  group('PushOperationsLaborProductionApiClient — happy path', () {
    test('fetchSampleShift hits documented base URI with bearer + page=1 + limit=1',
        () async {
      late http.Request seen;
      final mock = MockClient((request) async {
        seen = request;
        return _jsonResponse(200, <String, Object?>{
          'shifts': <Object?>[
            _shift(
              id: 800101,
              startAt: '2026-05-02T16:00:00.000Z',
              endAt: '2026-05-02T23:30:00.000Z',
              updatedAt: '2026-05-02T15:45:00.000Z',
            ),
          ],
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
      );

      final page = await client.fetchSampleShift(
        operatorId: _opId,
        locationId: _locId,
      );

      expect(seen.method, 'GET');
      expect(seen.url.scheme, 'https');
      expect(seen.url.host, 'app-elb.pushoperations.com');
      expect(seen.url.path, '/api/v1/shifts');
      expect(seen.url.queryParameters['page'], '1');
      expect(seen.url.queryParameters['limit'], '1');
      // Sample fetch does not pass updated_after — vendor returns most-
      // recent rows first, the adapter only needs one.
      expect(seen.url.queryParameters.containsKey('updated_after'), isFalse);
      expect(seen.headers['authorization'], 'Bearer $_bearer');
      expect(seen.headers['accept'], 'application/json');
      expect(page.records, hasLength(1));
      expect(page.records.single['id'], 800101);
      expect(page.nextCursor, pushOperationsInitialCursorToken);
    });

    test('fetchShifts threads sinceModified into updated_after and pages by cursor',
        () async {
      final calls = <Uri>[];
      final mock = MockClient((request) async {
        calls.add(request.url);
        return _jsonResponse(200, <String, Object?>{
          'shifts': const <Object?>[],
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
      );

      await client.fetchShifts(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 5, 1, 0, 0, 0),
        cursor: 'page:7',
        isDeliberateBackfill: false,
      );

      final url = calls.single;
      expect(url.path, '/api/v1/shifts');
      expect(url.queryParameters['page'], '7');
      expect(url.queryParameters['limit'], pushOperationsMaxPageSize.toString());
      expect(url.queryParameters['updated_after'], '2026-05-01T00:00:00.000Z');
    });
  });

  group('PushOperationsLaborProductionApiClient — pagination shape', () {
    test('full page emits page:N+1 cursor', () async {
      final fullPage = List<Map<String, Object?>>.generate(
        pushOperationsMaxPageSize,
        (i) => _shift(
          id: 900000 + i,
          startAt: '2026-05-02T16:00:00.000Z',
          endAt: '2026-05-02T23:30:00.000Z',
          updatedAt: '2026-05-02T15:45:00.000Z',
        ),
      );
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{'shifts': fullPage});
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
      );

      final page = await client.fetchShifts(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 5, 1),
        cursor: null,
        isDeliberateBackfill: true,
      );

      expect(page.records, hasLength(pushOperationsMaxPageSize));
      expect(page.nextCursor, 'page:2');
    });

    test('short page closes the cursor (matches documented end-of-listing)',
        () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'shifts': <Object?>[
            _shift(
              id: 800101,
              startAt: '2026-05-02T16:00:00.000Z',
              endAt: '2026-05-02T23:30:00.000Z',
              updatedAt: '2026-05-02T15:45:00.000Z',
            ),
          ],
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
      );

      final page = await client.fetchShifts(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 5, 1),
        cursor: 'page:3',
        isDeliberateBackfill: false,
      );

      expect(page.records, hasLength(1));
      expect(page.nextCursor, pushOperationsInitialCursorToken);
    });
  });

  group('PushOperationsLaborProductionApiClient — 429 backoff', () {
    test('honors Retry-After header and retries until 200', () async {
      var hit = 0;
      final sleeps = <Duration>[];
      final mock = MockClient((request) async {
        hit += 1;
        if (hit < 3) {
          return _jsonResponse(429, <String, Object?>{}, headers: <String, String>{
            'retry-after': '2',
          });
        }
        return _jsonResponse(200, <String, Object?>{
          'shifts': const <Object?>[],
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
        sleep: (d) async => sleeps.add(d),
      );

      final page = await client.fetchShifts(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 5, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(hit, 3);
      expect(sleeps, hasLength(2));
      expect(sleeps.every((d) => d == const Duration(seconds: 2)), isTrue);
      expect(page.records, isEmpty);
    });

    test('exhausts retry budget and throws PushOperationsThrottledException',
        () async {
      final mock = MockClient((request) async {
        return _jsonResponse(429, <String, Object?>{}, headers: <String, String>{
          'retry-after': '1',
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
        sleep: (_) async {},
        max429Retries: 2,
      );

      await expectLater(
        client.fetchShifts(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 5, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<PushOperationsThrottledException>()),
      );
    });

    test('falls back to exponential backoff when Retry-After is absent',
        () async {
      var hit = 0;
      final sleeps = <Duration>[];
      final mock = MockClient((request) async {
        hit += 1;
        if (hit < 3) {
          return _jsonResponse(429, <String, Object?>{});
        }
        return _jsonResponse(200, <String, Object?>{
          'shifts': const <Object?>[],
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
        sleep: (d) async => sleeps.add(d),
      );

      await client.fetchShifts(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 5, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(hit, 3);
      expect(sleeps, hasLength(2));
      // Exponential: attempt 0 -> 1s, attempt 1 -> 2s.
      expect(sleeps[0], const Duration(seconds: 1));
      expect(sleeps[1], const Duration(seconds: 2));
    });
  });

  group('PushOperationsLaborProductionApiClient — auth failures', () {
    test('401 throws PushOperationsUnauthorizedException', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(401, <String, Object?>{
          'error': 'invalid_token',
          'message': 'bearer token is revoked',
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
      );

      await expectLater(
        client.fetchShifts(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 5, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<PushOperationsUnauthorizedException>()),
      );
    });

    test('missing bearer throws PushOperationsAuthMissingException', () async {
      final mock = MockClient((_) async {
        fail('HTTP client must not be called when no bearer is available');
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _missingBearer(),
        httpClient: mock,
      );

      await expectLater(
        client.fetchShifts(
          operatorId: _opId,
          locationId: _locId,
          sinceModified: DateTime.utc(2026, 5, 1),
          cursor: null,
          isDeliberateBackfill: false,
        ),
        throwsA(isA<PushOperationsAuthMissingException>()),
      );
    });
  });

  group('PushOperationsLaborProductionApiClient — schema roundtrip', () {
    test(
        'vendor shifts[] survives transport and feeds the adapter canonical projection',
        () async {
      final vendorRow = _shift(
        id: 800101,
        startAt: '2026-05-02T16:00:00.000Z',
        endAt: '2026-05-02T23:30:00.000Z',
        updatedAt: '2026-05-02T15:45:00.000Z',
        position: 'Server',
        employeeId: 5512,
      );
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'shifts': <Object?>[vendorRow],
        });
      });

      final api = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
      );

      final page = await api.fetchShifts(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 5, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(page.records.single, vendorRow);
      expect(
        page.lastModifiedSeen.toIso8601String(),
        '2026-05-02T15:45:00.000Z',
      );

      // The adapter's `_mapShiftToCanonical` projection must consume
      // the same shape verbatim. Build a minimal adapter, run the
      // public passthrough, and verify the canonical fields survive.
      final adapter = PushOperationsLaborAdapter(
        apiClient: _SchemaRoundtripFakeClient(api: api),
        canonicalSink: _NoopSink(),
      );
      final canonical = adapter.mapShiftToCanonical(page.records.single);
      expect(canonical['vendor_id'], pushOperationsVendorId);
      expect(canonical['vendor_entity_id'], '800101');
      expect(canonical['employee_id'], '5512');
      expect(canonical['role_name'], 'Server');
      expect(
        (canonical['shift_start']! as DateTime).toIso8601String(),
        '2026-05-02T16:00:00.000Z',
      );
      expect(
        (canonical['shift_end']! as DateTime).toIso8601String(),
        '2026-05-02T23:30:00.000Z',
      );
      expect(
        (canonical['vendor_modified_at']! as DateTime).toIso8601String(),
        '2026-05-02T15:45:00.000Z',
      );
    });

    test('non-2xx other than 401/429 throws PushOperationsHttpException',
        () async {
      final mock = MockClient((request) async {
        return _jsonResponse(500, <String, Object?>{'error': 'oops'});
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
      );

      await expectLater(
        client.fetchSampleShift(operatorId: _opId, locationId: _locId),
        throwsA(isA<PushOperationsHttpException>()),
      );
    });

    test('malformed body throws PushOperationsSchemaException', () async {
      final mock = MockClient((request) async {
        return http.Response(
          'this is not json',
          200,
          headers: <String, String>{
            HttpHeaders.contentTypeHeader: 'application/json',
          },
        );
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        httpClient: mock,
      );

      await expectLater(
        client.fetchSampleShift(operatorId: _opId, locationId: _locId),
        throwsA(isA<PushOperationsSchemaException>()),
      );
    });
  });

  group('PushOperationsLaborProductionApiClient — base URI override', () {
    test('respects an env-supplied baseUri for sandbox / region failover',
        () async {
      late http.Request seen;
      final mock = MockClient((request) async {
        seen = request;
        return _jsonResponse(200, <String, Object?>{
          'shifts': const <Object?>[],
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        baseUri: Uri.parse('https://sandbox.pushoperations.example/api/v1/'),
        httpClient: mock,
      );

      await client.fetchShifts(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 5, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(seen.url.host, 'sandbox.pushoperations.example');
      expect(seen.url.path, '/api/v1/shifts');
    });

    test('normalizes a baseUri without a trailing slash', () async {
      late http.Request seen;
      final mock = MockClient((request) async {
        seen = request;
        return _jsonResponse(200, <String, Object?>{
          'shifts': const <Object?>[],
        });
      });

      final client = PushOperationsLaborProductionApiClient(
        bearerResolver: _staticBearer(),
        baseUri: Uri.parse('https://sandbox.pushoperations.example/api/v1'),
        httpClient: mock,
      );

      await client.fetchShifts(
        operatorId: _opId,
        locationId: _locId,
        sinceModified: DateTime.utc(2026, 5, 1),
        cursor: null,
        isDeliberateBackfill: false,
      );

      expect(seen.url.path, '/api/v1/shifts');
    });
  });
}

/// Fake that delegates back to the real production client so the
/// schema-roundtrip test can exercise the full transport while still
/// driving the adapter from a single arrange phase.
class _SchemaRoundtripFakeClient implements PushOperationsApiClient {
  _SchemaRoundtripFakeClient({required this.api});
  final PushOperationsLaborProductionApiClient api;

  @override
  Future<PushOperationsShiftPage> fetchSampleShift({
    required String operatorId,
    required String locationId,
  }) =>
      api.fetchSampleShift(operatorId: operatorId, locationId: locationId);

  @override
  Future<PushOperationsShiftPage> fetchShifts({
    required String operatorId,
    required String locationId,
    required DateTime sinceModified,
    required String? cursor,
    required bool isDeliberateBackfill,
  }) =>
      api.fetchShifts(
        operatorId: operatorId,
        locationId: locationId,
        sinceModified: sinceModified,
        cursor: cursor,
        isDeliberateBackfill: isDeliberateBackfill,
      );
}

class _NoopSink implements PushOperationsCanonicalSink {
  @override
  Future<bool> upsertShift({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async =>
      true;

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {}

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {}

  @override
  Future<({bool credentialsWiped, bool webhookUnregistered, bool watermarkPreserved})>
      wipeCredentialsPreserveWatermark({
    required String operatorId,
    required String locationId,
  }) async =>
          (credentialsWiped: true, webhookUnregistered: true, watermarkPreserved: true);
}
