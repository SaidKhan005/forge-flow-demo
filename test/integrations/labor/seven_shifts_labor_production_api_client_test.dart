// Phase 8.transport.seven-shifts-labor - production HTTP transport tests.
//
// Drives [SevenShiftsApiClient] against `package:http/testing.dart`'s
// `MockClient`. Coverage:
//
//   * GET `/time_punches` happy path - bearer header, cursor pagination,
//     UTC `modified_since` window, multi-page walk.
//   * GET `/reports/hours_and_wages` with dollar precision (regular +
//     overtime, fractional cents preserved).
//   * 429 (Too Many Requests) backoff - single retry honoring
//     `Retry-After`; repeated 429s surface
//     [SevenShiftsRateLimitedException].
//   * 401 surfaces [SevenShiftsUnauthorizedException].
//   * 403/404 on the Hours & Wages report surface
//     [SevenShiftsHoursAndWagesReportGatedException] (lower plan tier).
//   * Schema roundtrip - token-exchange + sample-punch shapes.
//   * Idempotency-Key on every POST (token exchange + webhook
//     register).
//
// No live HTTP, no Postgres, no live 7shifts credentials.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_production_api_client.dart';

void main() {
  const String accessToken = 'access-token-001';
  const String companyId = 'co-7s-12345';

  SevenShiftsApiClient buildClient({
    required http.Client httpClient,
    Uri? baseUriOverride,
    int maxRetries = 1,
    DateTime Function()? now,
    SevenShiftsIdempotencyKeyGenerator? idempotencyKeyGenerator,
    int pageSize = 100,
  }) {
    return SevenShiftsApiClient(
      deps: SevenShiftsApiClientDeps(
        accessTokenProvider: () async => accessToken,
        httpClient: httpClient,
        baseUriOverride: baseUriOverride,
        maxRateLimitRetries: maxRetries,
        now: now,
        idempotencyKeyGenerator: idempotencyKeyGenerator,
        pageSize: pageSize,
      ),
    );
  }

  group('Default base URI + path resolution', () {
    test('default baseUri = https://api.7shifts.com/v2', () {
      expect(
        kSevenShiftsDefaultBaseUri.toString(),
        'https://api.7shifts.com/v2',
      );
    });

    test(
        'env override + custom path composes correctly under v2 prefix '
        'without double slashes', () async {
      late http.Request seen;
      final client = buildClient(
        baseUriOverride: Uri.parse('https://sandbox.api.7shifts.com/v2'),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{'data': <Object?>[]}),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      await client.listTimePunches(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4),
      );

      expect(
        seen.url.toString().startsWith(
          'https://sandbox.api.7shifts.com/v2/company/$companyId/time_punches',
        ),
        true,
        reason: 'sandbox override must be respected without losing v2 prefix',
      );
    });
  });

  group('GET /time_punches happy path', () {
    test(
        'sets bearer header, ISO-UTC modified_since/until, page-size limit, '
        'returns canonical-shape records + next cursor + lastModifiedSeen',
        () async {
      late http.Request seen;
      final client = buildClient(
        pageSize: 50,
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'id': 712001,
                  'user_id': 99001,
                  'role': <String, Object?>{'id': 401, 'name': 'Server'},
                  'clocked_in': '2026-05-03T18:00:00Z',
                  'clocked_out': '2026-05-03T23:30:00Z',
                  'approved': true,
                  'modified': '2026-05-03T23:35:00Z',
                },
                <String, Object?>{
                  'id': 712002,
                  'user_id': 99002,
                  'role': <String, Object?>{'id': 402, 'name': 'Bartender'},
                  'clocked_in': '2026-05-03T17:00:00Z',
                  'clocked_out': '2026-05-03T22:30:00Z',
                  'approved': true,
                  'modified': '2026-05-03T22:35:00Z',
                },
              ],
              'meta': <String, Object?>{
                'cursor': <String, Object?>{
                  'next': 'page2',
                },
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final page = await client.listTimePunches(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: DateTime.utc(2026, 5, 1, 0, 0, 0),
        modifiedUntil: DateTime.utc(2026, 5, 4, 0, 0, 0),
      );

      expect(seen.method, 'GET');
      expect(seen.headers['authorization'], 'Bearer $accessToken');
      expect(seen.headers['accept'], 'application/json');
      expect(seen.url.path, '/v2/company/$companyId/time_punches');
      expect(
        seen.url.queryParameters['modified_since'],
        '2026-05-01T00:00:00.000Z',
      );
      expect(
        seen.url.queryParameters['modified_until'],
        '2026-05-04T00:00:00.000Z',
      );
      expect(seen.url.queryParameters['limit'], '50');

      expect(page.records.length, 2);
      expect(page.records.first['id'], 712001);
      expect(page.records.first['approved'], true);
      expect(page.nextCursor, 'page2');
      // lastModifiedSeen = max of `modified` across the page.
      expect(
        page.lastModifiedSeen,
        DateTime.utc(2026, 5, 3, 23, 35, 0),
      );
    });

    test('cursor query parameter passes through on subsequent pages',
        () async {
      late http.Request seen;
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <Object?>[],
              'meta': <String, Object?>{
                'cursor': <String, Object?>{'next': null},
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      await client.listTimePunches(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4),
        cursor: 'page2',
      );

      expect(seen.url.queryParameters['cursor'], 'page2');
    });

    test('multi-page walk via meta.cursor.next terminates on null', () async {
      int callCount = 0;
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          callCount += 1;
          final cursor = request.url.queryParameters['cursor'];
          if (cursor == null) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'data': <Object?>[
                  <String, Object?>{
                    'id': 712001,
                    'user_id': 99001,
                    'clocked_in': '2026-05-03T18:00:00Z',
                    'clocked_out': '2026-05-03T23:30:00Z',
                    'approved': true,
                    'modified': '2026-05-03T23:35:00Z',
                  },
                ],
                'meta': <String, Object?>{
                  'cursor': <String, Object?>{'next': 'page2'},
                },
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'id': 712002,
                  'user_id': 99002,
                  'clocked_in': '2026-05-03T17:00:00Z',
                  'clocked_out': '2026-05-03T22:30:00Z',
                  'approved': true,
                  'modified': '2026-05-03T22:35:00Z',
                },
              ],
              'meta': <String, Object?>{
                'cursor': <String, Object?>{'next': null},
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final page1 = await client.listTimePunches(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4),
      );
      expect(page1.nextCursor, 'page2');

      final page2 = await client.listTimePunches(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4),
        cursor: page1.nextCursor,
      );
      expect(page2.nextCursor, isNull);
      expect(callCount, 2);
    });
  });

  group('GET /reports/hours_and_wages', () {
    test(
        'parses regular_pay + overtime_pay + total_pay with fractional '
        'cents preserved; emits employee+shift keyed rows', () async {
      late http.Request seen;
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'employee_id': 99001,
                  'shift_id': 887701,
                  'total_pay': 137.50,
                  'regular_pay': 110.00,
                  'overtime_pay': 27.50,
                },
                <String, Object?>{
                  // Numeric strings should also parse cleanly.
                  'employee_id': '99002',
                  'shift_id': '887702',
                  'total_pay': '96.25',
                  'regular_pay': '96.25',
                  'overtime_pay': '0',
                },
              ],
              'meta': <String, Object?>{
                'cursor': <String, Object?>{'next': null},
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final page = await client.fetchHoursAndWagesReport(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4),
        isDeliberateBackfill: false,
      );

      expect(seen.method, 'GET');
      expect(
        seen.url.path,
        '/v2/company/$companyId/reports/hours_and_wages',
      );
      expect(seen.headers['authorization'], 'Bearer $accessToken');
      expect(page.rows.length, 2);
      expect(page.rows[0].employeeId, '99001');
      expect(page.rows[0].shiftId, '887701');
      expect(page.rows[0].totalPay, 137.50);
      expect(page.rows[0].regularPay, 110.00);
      expect(page.rows[0].overtimePay, 27.50);
      expect(page.rows[1].totalPay, 96.25);
      expect(page.nextCursor, isNull);
    });

    test('403 surfaces SevenShiftsHoursAndWagesReportGatedException',
        () async {
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'message': 'Hours & Wages report is a Gourmet feature',
            }),
            403,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      expect(
        () => client.fetchHoursAndWagesReport(
          accessToken: accessToken,
          companyId: companyId,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 4),
          isDeliberateBackfill: false,
        ),
        throwsA(
          isA<SevenShiftsHoursAndWagesReportGatedException>()
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });

    test('404 surfaces SevenShiftsHoursAndWagesReportGatedException',
        () async {
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response('', 404);
        }),
      );

      expect(
        () => client.fetchHoursAndWagesReport(
          accessToken: accessToken,
          companyId: companyId,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 4),
          isDeliberateBackfill: true,
        ),
        throwsA(
          isA<SevenShiftsHoursAndWagesReportGatedException>()
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });
  });

  group('429 backoff', () {
    test(
        'single 429 followed by 200 succeeds; honors Retry-After header '
        '(zero seconds)', () async {
      int call = 0;
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          call += 1;
          if (call == 1) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'message': 'rate limit exceeded',
              }),
              429,
              headers: const <String, String>{
                'content-type': 'application/json',
                'retry-after': '0',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <Object?>[],
              'meta': <String, Object?>{
                'cursor': <String, Object?>{'next': null},
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final page = await client.listTimePunches(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4),
      );
      expect(call, 2);
      expect(page.records, isEmpty);
      expect(page.nextCursor, isNull);
    });

    test(
        'repeated 429 surfaces SevenShiftsRateLimitedException with '
        'Retry-After preserved', () async {
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{'message': 'slow down'}),
            429,
            headers: const <String, String>{
              'content-type': 'application/json',
              'retry-after': '0',
            },
          );
        }),
      );

      expect(
        () => client.listTimePunches(
          accessToken: accessToken,
          companyId: companyId,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 4),
        ),
        throwsA(
          isA<SevenShiftsRateLimitedException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                Duration.zero,
              )
              .having((e) => e.message, 'message', 'slow down'),
        ),
      );
    });
  });

  group('401 unauthorized', () {
    test('surfaces typed SevenShiftsUnauthorizedException', () async {
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'invalid_token',
              'error_description': 'token has expired',
            }),
            401,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      expect(
        () => client.listTimePunches(
          accessToken: accessToken,
          companyId: companyId,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 4),
        ),
        throwsA(
          isA<SevenShiftsUnauthorizedException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having(
                (e) => e.message,
                'message',
                'token has expired',
              ),
        ),
      );
    });
  });

  group('Schema roundtrip', () {
    test(
        'exchangeAuthorizationCode parses access_token + refresh_token + '
        'expires_at; sends Idempotency-Key on POST', () async {
      late http.Request seen;
      final client = buildClient(
        idempotencyKeyGenerator: () => 'idem-fixed-001',
        now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'at-001',
              'refresh_token': 'rt-001',
              'expires_in': 3600,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final response = await client.exchangeAuthorizationCode(
        authorizationCode: 'auth-code-001',
        redirectUri: 'https://proxy.example/v1/oauth/callback/seven_shifts',
      );

      expect(seen.method, 'POST');
      expect(seen.url.path, '/v2/oauth/token');
      expect(
        seen.headers['content-type'],
        'application/x-www-form-urlencoded',
      );
      expect(seen.headers['idempotency-key'], 'idem-fixed-001');
      // Form-encoded body shape.
      final parsed = Uri.splitQueryString(seen.body);
      expect(parsed['grant_type'], 'authorization_code');
      expect(parsed['code'], 'auth-code-001');
      expect(
        parsed['redirect_uri'],
        'https://proxy.example/v1/oauth/callback/seven_shifts',
      );

      expect(response.accessToken, 'at-001');
      expect(response.refreshToken, 'rt-001');
      expect(
        response.expiresAt,
        DateTime.utc(2026, 5, 4, 13, 0, 0),
      );
    });

    test(
        'samplePunch returns first time_punch row from the v2 list '
        'endpoint and dispatches a bearer GET',
        () async {
      late http.Request seen;
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'id': 712001,
                  'user_id': 99001,
                  'role': <String, Object?>{'id': 401, 'name': 'Server'},
                  'clocked_in': '2026-05-03T18:30:00Z',
                  'clocked_out': '2026-05-03T23:45:00Z',
                  'approved': true,
                  'modified': '2026-05-04T00:05:00Z',
                },
              ],
              'meta': <String, Object?>{
                'cursor': <String, Object?>{'next': null},
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final sample = await client.samplePunch(
        accessToken: accessToken,
        companyId: companyId,
      );

      expect(seen.method, 'GET');
      expect(seen.url.queryParameters['limit'], '1');
      expect(sample['id'], 712001);
      expect(sample['user_id'], 99001);
      expect(
        (sample['role'] as Map)['name'],
        'Server',
      );
      expect(sample['clocked_in'], '2026-05-03T18:30:00Z');
      expect(sample['approved'], true);
    });

    test('registerWebhook posts JSON body with Idempotency-Key', () async {
      late http.Request seen;
      final client = buildClient(
        idempotencyKeyGenerator: () => 'idem-webhook-001',
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{'id': 'wh-7s-501'},
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final id = await client.registerWebhook(
        accessToken: accessToken,
        companyId: companyId,
        url: 'https://proxy.example/v1/webhooks/op/loc/seven_shifts',
        events: const <String>[
          'time_punch.edited',
          'payroll_period.closed',
        ],
        signingSecret: 'whsec-test',
      );

      expect(id, 'wh-7s-501');
      expect(seen.method, 'POST');
      expect(seen.url.path, '/v2/company/$companyId/webhooks');
      expect(seen.headers['authorization'], 'Bearer $accessToken');
      expect(seen.headers['content-type'], 'application/json');
      expect(seen.headers['idempotency-key'], 'idem-webhook-001');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(
        body['url'],
        'https://proxy.example/v1/webhooks/op/loc/seven_shifts',
      );
      expect(
        (body['events'] as List).cast<String>(),
        const <String>['time_punch.edited', 'payroll_period.closed'],
      );
      expect(body['signing_secret'], 'whsec-test');
    });

    test(
        'fetchLatestPayrollPeriodClosedAt returns first closed_at as UTC',
        () async {
      late http.Request seen;
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'id': 'pp-001',
                  'closed_at': '2026-05-03T08:00:00Z',
                },
              ],
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final closedAt = await client.fetchLatestPayrollPeriodClosedAt(
        accessToken: accessToken,
        companyId: companyId,
      );

      expect(seen.url.queryParameters['status'], 'closed');
      expect(seen.url.queryParameters['limit'], '1');
      expect(closedAt, DateTime.utc(2026, 5, 3, 8, 0, 0));
      expect(closedAt!.isUtc, true);
    });

    test('fetchCompanyInfo lower-cases the plan tier on response', () async {
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{
                'id': companyId,
                'plan': 'GOURMET',
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );

      final info = await client.fetchCompanyInfo(accessToken: accessToken);
      expect(info.companyId, companyId);
      expect(info.planTier, 'gourmet');
      expect(info.supportsWebhooks, true);
    });

    test('unregisterWebhook treats 404 as no-op (already deleted)', () async {
      int call = 0;
      final client = buildClient(
        httpClient: http_testing.MockClient((request) async {
          call += 1;
          return http.Response('', 404);
        }),
      );

      // Should NOT throw.
      await client.unregisterWebhook(
        accessToken: accessToken,
        companyId: companyId,
        webhookId: 'wh-already-gone',
      );
      expect(call, 1);
    });
  });
}
