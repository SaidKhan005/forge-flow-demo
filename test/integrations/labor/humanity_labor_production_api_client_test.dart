// Phase 8.transport.humanity-labor — production HTTP client tests.
//
// Drives [HumanityLaborProductionApiClient] against an in-memory
// [http.Client] fake. No live network, no Postgres, no plaintext
// credentials past the `exchangeUsernamePassword` call frame.
//
// Coverage proof (per the slice prompt):
//
//   * Happy path — token exchange, list shifts (single page), revoke.
//   * Pagination — two-page walk; cursor flows back to caller; final
//     page surfaces `nextCursor: null`.
//   * 429 — `Retry-After` honored; client retries and succeeds.
//   * 401 — surfaces as `HumanityAuthException`.
//   * Schema roundtrip — vendor JSON → `HumanityShiftDto.tryFromMap`
//     → canonical fields match the documented field-mapping constant
//     in the adapter.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_production_api_client.dart';
import 'package:http/http.dart' as http;

import '../../_test_helpers/mock_http_client.dart';

void main() {
  group('exchangeUsernamePassword', () {
    test('happy path → returns access_token + expiresAt + refresh_token',
        () async {
      final fake = FakeHttpClient.handler((request) async {
        expect(request.method, 'POST');
        expect(request.url.path.endsWith('/oauth2/token'), true);
        expect(request.headers['content-type'],
            'application/x-www-form-urlencoded');
        expect(request.headers.containsKey('idempotency-key'), true);
        final body = request.body;
        expect(body.contains('grant_type=password'), true);
        expect(body.contains('username=ops%40example.com'), true);
        expect(body.contains('password=hunter2%21'), true);
        return _ok(jsonEncode(<String, Object?>{
          'access_token': 'bearer-fake-001',
          'refresh_token': 'refresh-001',
          'expires_in': 3600,
        }));
      });
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      final response = await client.exchangeUsernamePassword(
        username: 'ops@example.com',
        password: 'hunter2!',
      );
      expect(response.accessToken, 'bearer-fake-001');
      expect(response.refreshToken, 'refresh-001');
      expect(response.expiresAt, isNotNull);
      expect(
        response.expiresAt!.isAfter(DateTime.now().toUtc()),
        true,
        reason: 'expires_in maps to a future UTC instant',
      );
    });

    test('schema drift → throws HumanitySchemaException when access_token '
        'missing', () async {
      final fake = FakeHttpClient.handler((_) async => _ok(jsonEncode(
            const <String, Object?>{'expires_in': 60},
          )));
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      expect(
        () => client.exchangeUsernamePassword(
          username: 'u',
          password: 'p',
        ),
        throwsA(isA<HumanitySchemaException>()),
      );
    });

    test('401 → throws HumanityAuthException', () async {
      final fake = FakeHttpClient.handler((_) async => http.Response(
            jsonEncode(<String, Object?>{'error': 'invalid_grant'}),
            401,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ));
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      expect(
        () => client.exchangeUsernamePassword(
          username: 'u',
          password: 'p',
        ),
        throwsA(isA<HumanityAuthException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });
  });

  group('listShifts (single page)', () {
    test('happy path → returns parsed records + null next cursor', () async {
      final fake = FakeHttpClient.handler((request) async {
        expect(request.method, 'GET');
        expect(request.url.path.endsWith('/shifts'), true);
        expect(
          request.headers['authorization'],
          'Bearer bearer-001',
        );
        expect(
          request.url.queryParameters['last_modified'],
          '2026-05-04T00:00:00.000Z',
        );
        return _ok(jsonEncode(<String, Object?>{
          'shifts': <Map<String, Object?>>[_sampleShift('HUM-9001')],
          'next_cursor': null,
        }));
      });
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      final page = await client.listShifts(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
        modifiedSince: DateTime.utc(2026, 5, 4),
      );
      expect(page.records, hasLength(1));
      expect(page.nextCursor, isNull);
      expect(
        page.lastModifiedSeen,
        DateTime.utc(2026, 5, 4, 11, 45, 0),
        reason: 'high watermark resolves from the highest `updated` on '
            'the page',
      );
      // Schema roundtrip — adapter DTO consumes the raw record cleanly.
      final dto = HumanityShiftDto.tryFromMap(page.records.single);
      expect(dto, isNotNull);
      expect(dto!.id, 'HUM-9001');
      expect(dto.positionName, 'Server');
      expect(dto.employeeId, 'EMP-7777');
    });
  });

  group('listShifts pagination', () {
    test('two-page walk surfaces cursor between pages then null', () async {
      var calls = 0;
      final fake = FakeHttpClient.handler((request) async {
        calls += 1;
        final cursor = request.url.queryParameters['cursor'];
        if (calls == 1) {
          expect(cursor, isNull);
          return _ok(jsonEncode(<String, Object?>{
            'shifts': <Map<String, Object?>>[_sampleShift('HUM-9001')],
            'next_cursor': 'cursor-page-2',
          }));
        }
        expect(cursor, 'cursor-page-2');
        return _ok(jsonEncode(<String, Object?>{
          'shifts': <Map<String, Object?>>[_sampleShift('HUM-9002')],
          'next_cursor': null,
        }));
      });
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      final firstPage = await client.listShifts(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
        modifiedSince: DateTime.utc(2026, 5, 4),
      );
      expect(firstPage.records.single['id'], 'HUM-9001');
      expect(firstPage.nextCursor, 'cursor-page-2');

      final secondPage = await client.listShifts(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
        modifiedSince: DateTime.utc(2026, 5, 4),
        cursor: firstPage.nextCursor,
      );
      expect(secondPage.records.single['id'], 'HUM-9002');
      expect(secondPage.nextCursor, isNull);
      expect(calls, 2);
    });

    test('legacy `next` field on `paging` envelope is honored', () async {
      final fake = FakeHttpClient.handler((_) async => _ok(jsonEncode(
            <String, Object?>{
              'shifts': <Map<String, Object?>>[_sampleShift('HUM-9001')],
              'paging': <String, Object?>{'next': 'paging-cursor-2'},
            },
          )));
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      final page = await client.listShifts(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
        modifiedSince: DateTime.utc(2026, 5, 4),
      );
      expect(page.nextCursor, 'paging-cursor-2');
    });
  });

  group('429 backoff', () {
    test('honors Retry-After then succeeds on the second attempt', () async {
      var calls = 0;
      final fake = FakeHttpClient.handler((_) async {
        calls += 1;
        if (calls == 1) {
          return http.Response(
            '{"error":"rate_limited"}',
            429,
            headers: const <String, String>{
              'content-type': 'application/json',
              'retry-after': '0',
            },
          );
        }
        return _ok(jsonEncode(<String, Object?>{
          'shifts': <Map<String, Object?>>[_sampleShift('HUM-9001')],
          'next_cursor': null,
        }));
      });
      final sleeps = <Duration>[];
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
        sleep: (d) async {
          sleeps.add(d);
        },
      );
      final page = await client.listShifts(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
        modifiedSince: DateTime.utc(2026, 5, 4),
      );
      expect(calls, 2);
      expect(sleeps, hasLength(1));
      expect(sleeps.single, Duration.zero);
      expect(page.records.single['id'], 'HUM-9001');
    });

    test('exhausts retries → throws HumanityRateLimitException', () async {
      final fake = FakeHttpClient.handler((_) async => http.Response(
            '{"error":"rate_limited"}',
            429,
            headers: const <String, String>{
              'retry-after': '0',
              'content-type': 'application/json',
            },
          ));
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
        maxRateLimitRetries: 2,
        sleep: (_) async {},
      );
      expect(
        () => client.listShifts(
          credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
          modifiedSince: DateTime.utc(2026, 5, 4),
        ),
        throwsA(isA<HumanityRateLimitException>()
            .having((e) => e.statusCode, 'statusCode', 429)),
      );
    });
  });

  group('401 on listShifts', () {
    test('surfaces HumanityAuthException without retry', () async {
      var calls = 0;
      final fake = FakeHttpClient.handler((_) async {
        calls += 1;
        return http.Response(
          '{"error":"unauthorized"}',
          401,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      });
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      await expectLater(
        () => client.listShifts(
          credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
          modifiedSince: DateTime.utc(2026, 5, 4),
        ),
        throwsA(isA<HumanityAuthException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
      expect(calls, 1, reason: '401 must not be retried');
    });
  });

  group('fetchSampleShift', () {
    test('returns the first shift on the page', () async {
      final fake = FakeHttpClient.handler((request) async {
        expect(request.url.queryParameters['limit'], '1');
        expect(request.url.queryParameters['sort'], 'updated:desc');
        return _ok(jsonEncode(<String, Object?>{
          'shifts': <Map<String, Object?>>[_sampleShift('HUM-12345')],
        }));
      });
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      final sample = await client.fetchSampleShift(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
      );
      expect(sample, isNotNull);
      expect(sample!['id'], 'HUM-12345');
    });

    test('returns null when the page is empty', () async {
      final fake = FakeHttpClient.handler((_) async => _ok(jsonEncode(
            const <String, Object?>{'shifts': <Map<String, Object?>>[]},
          )));
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      final sample = await client.fetchSampleShift(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
      );
      expect(sample, isNull);
    });
  });

  group('revokeCredential', () {
    test('best-effort POST swallows 401 silently', () async {
      var calls = 0;
      final fake = FakeHttpClient.handler((request) async {
        calls += 1;
        expect(request.method, 'POST');
        expect(request.url.path.endsWith('/oauth2/revoke'), true);
        expect(request.headers.containsKey('idempotency-key'), true);
        return http.Response(
          '{"error":"already_revoked"}',
          401,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      });
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      await client.revokeCredential(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
      );
      expect(calls, 1);
    });

    test('500 from vendor does not block disconnect', () async {
      final fake = FakeHttpClient.handler((_) async => http.Response(
            'down',
            500,
            headers: const <String, String>{
              'content-type': 'text/plain',
            },
          ));
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      await client.revokeCredential(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
      );
    });
  });

  group('schema roundtrip vs documented field-mapping constant', () {
    test('vendor JSON → DTO → fields match adapter mapping constant',
        () async {
      final fake = FakeHttpClient.handler((_) async => _ok(jsonEncode(
            <String, Object?>{
              'shifts': <Map<String, Object?>>[_sampleShift('HUM-12345')],
              'next_cursor': null,
            },
          )));
      final client = HumanityLaborProductionApiClient(
        httpClient: fake,
        baseUri: Uri.parse('https://platform.humanity.com/v1.0/'),
      );
      final page = await client.listShifts(
        credential: const VendorCredentialHandle(credentialId: 'bearer-001'),
        modifiedSince: DateTime.utc(2026, 5, 4),
      );
      final dto = HumanityShiftDto.tryFromMap(page.records.single);
      expect(dto, isNotNull);
      // Every documented mapped field round-trips cleanly.
      expect(dto!.id, 'HUM-12345');
      expect(dto.employeeId, 'EMP-7777');
      expect(dto.positionName, 'Server');
      expect(dto.inTime.toIso8601String(), '2026-05-04T16:00:00.000Z');
      expect(dto.outTime.toIso8601String(), '2026-05-04T22:30:00.000Z');
      expect(dto.updated.toIso8601String(), '2026-05-04T11:45:00.000Z');
      // Cross-check: the documented per-Humanity v1.0 field mapping
      // constant carries the exact paths the DTO consumes, so a future
      // schema bump that walked the adapter constant out of sync would
      // be caught here too.
      final shiftStartMapping = documentedPerHumanityV10FieldMapping[
          'shift_start'] as Map<String, Object?>;
      expect(shiftStartMapping['path'], 'shifts.in_time');
      final roleNameMapping = documentedPerHumanityV10FieldMapping[
          'role_name'] as Map<String, Object?>;
      expect(roleNameMapping['path'], 'positions.name');
    });
  });

  group('baseUri override via env', () {
    test('environment HUMANITY_API_BASE_URL takes precedence over default',
        () {
      final client = HumanityLaborProductionApiClient(
        httpClient: FakeHttpClient.handler((_) async => _ok('{}')),
        environment: () => const <String, String>{
          'HUMANITY_API_BASE_URL': 'https://staging.humanity.example/v1.0/',
        },
      );
      expect(
        client.baseUri.toString(),
        'https://staging.humanity.example/v1.0/',
      );
    });

    test('explicit baseUri argument overrides env', () {
      final client = HumanityLaborProductionApiClient(
        httpClient: FakeHttpClient.handler((_) async => _ok('{}')),
        baseUri: Uri.parse('https://explicit.example/v1.0/'),
        environment: () => const <String, String>{
          'HUMANITY_API_BASE_URL': 'https://staging.humanity.example/v1.0/',
        },
      );
      expect(
        client.baseUri.toString(),
        'https://explicit.example/v1.0/',
      );
    });
  });
}

// ─── Helpers ─────────────────────────────────────────────────────────

http.Response _ok(String body) => http.Response(
      body,
      200,
      headers: const <String, String>{
        'content-type': 'application/json',
      },
    );

Map<String, Object?> _sampleShift(String id) => <String, Object?>{
      'id': id,
      'employee_id': 'EMP-7777',
      'position_name': 'Server',
      'in_time': '2026-05-04T16:00:00Z',
      'out_time': '2026-05-04T22:30:00Z',
      'updated': '2026-05-04T11:45:00Z',
    };
