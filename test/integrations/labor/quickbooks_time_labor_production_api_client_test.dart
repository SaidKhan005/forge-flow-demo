// Phase 8 / `8.transport.quickbooks-time-labor` — production HTTP
// transport tests.
//
// Coverage:
//   * Happy path: listTimesheets returns decoded records, OAuth bearer
//     header attached, page query plumbed.
//   * Pagination: walking pages 1->2 with `more=true` then `more=false`
//     surfaces correct nextPage.
//   * 429 backoff with Retry-After honored; retries until success.
//   * 429 exhausts retry budget -> QuickBooksTimeRateLimitException.
//   * 401 -> QuickBooksTimeAuthException (no retry).
//   * Schema roundtrip: vendor JSON shape decodes through
//     `mapTimesheetToCanonical` to the canonical fact.
//   * OAuth token exchange: form body + Basic auth + Idempotency-Key.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_production_api_client.dart';

const String _kAccessToken = 'qbt-bearer-001';
const String _kRefreshToken = 'qbt-refresh-001';
const String _kClientId = 'qbt-client-id';
const String _kClientSecret = 'qbt-client-secret';

QuickBooksTimeLaborProductionApiClient _build({
  required http.Client client,
  Duration Function(int)? backoff,
  int maxRetries = 3,
  String idempotencyKey = 'idem-key-fixed',
}) {
  return QuickBooksTimeLaborProductionApiClient(
    QuickBooksTimeProductionApiClientDeps(
      credentials: StaticQuickBooksTimeCredentialStore(_kAccessToken),
      oauthCredentials: const StaticQuickBooksTimeOauthClientCredentials(
        clientId: _kClientId,
        clientSecret: _kClientSecret,
      ),
      httpClient: client,
      timeout: const Duration(seconds: 5),
      maxRetries: maxRetries,
      backoffStrategy: backoff ?? (_) => Duration.zero,
      idempotencyKeyFactory: () => idempotencyKey,
    ),
  );
}

Map<String, Object?> _samplePunch({int id = 901001}) => <String, Object?>{
      'id': id,
      'user_id': 8001,
      'jobcode_id': 5001,
      'role_name': 'server',
      'start': '2026-05-04T11:00:00Z',
      'end': '2026-05-04T19:30:00Z',
      'duration': 30600,
      'last_modified': '2026-05-04T19:31:12Z',
      'type': 'regular',
      'on_the_clock': false,
    };

void main() {
  group('listTimesheets — happy path', () {
    test('attaches Bearer auth, query params, and decodes records',
        () async {
      late Uri capturedUri;
      late Map<String, String> capturedHeaders;
      final mock = http_testing.MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        final body = jsonEncode(<String, Object?>{
          'results': <String, Object?>{
            'timesheets': <String, Object?>{
              '901001': _samplePunch(id: 901001),
            },
          },
          'more': false,
        });
        return http.Response(body, 200,
            headers: const <String, String>{
              'content-type': 'application/json',
            });
      });
      final client = _build(client: mock);

      final modifiedSince = DateTime.utc(2026, 5, 1);
      final modifiedUntil = DateTime.utc(2026, 5, 4, 12);
      final page = await client.listTimesheets(
        accessToken: _kAccessToken,
        modifiedSince: modifiedSince,
        modifiedUntil: modifiedUntil,
      );

      expect(capturedUri.host, 'rest.tsheets.com');
      expect(capturedUri.path, '/api/v1/timesheets');
      expect(capturedUri.queryParameters['modified_since'],
          modifiedSince.toIso8601String());
      expect(capturedUri.queryParameters['modified_before'],
          modifiedUntil.toIso8601String());
      expect(capturedHeaders['Authorization'], 'Bearer $_kAccessToken');
      expect(capturedHeaders['Accept'], 'application/json');

      expect(page.records, hasLength(1));
      expect(page.records.first['id'], 901001);
      expect(page.nextPage, isNull);
      expect(page.lastModifiedSeen,
          DateTime.utc(2026, 5, 4, 19, 31, 12));
    });
  });

  group('Pagination', () {
    test('walks page 1 -> 2 when more=true, stops when more=false',
        () async {
      var calls = 0;
      final mock = http_testing.MockClient((request) async {
        calls += 1;
        final pageQuery = request.url.queryParameters['page'];
        if (calls == 1) {
          // First call: no explicit page parameter; server treats as
          // page 1; respond with more=true.
          expect(pageQuery, isNull);
          final body = jsonEncode(<String, Object?>{
            'results': <String, Object?>{
              'timesheets': <String, Object?>{
                '1': _samplePunch(id: 1),
                '2': _samplePunch(id: 2),
              },
            },
            'more': true,
          });
          return http.Response(body, 200);
        }
        // Second call: explicit page=2; respond with more=false.
        expect(pageQuery, '2');
        final body = jsonEncode(<String, Object?>{
          'results': <String, Object?>{
            'timesheets': <String, Object?>{
              '3': _samplePunch(id: 3),
            },
          },
          'more': false,
        });
        return http.Response(body, 200);
      });
      final client = _build(client: mock);

      final page1 = await client.listTimesheets(
        accessToken: _kAccessToken,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4, 12),
      );
      expect(page1.records, hasLength(2));
      expect(page1.nextPage, 2);

      final page2 = await client.listTimesheets(
        accessToken: _kAccessToken,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4, 12),
        page: page1.nextPage,
      );
      expect(page2.records, hasLength(1));
      expect(page2.nextPage, isNull);
      expect(calls, 2);
    });
  });

  group('Rate limiting', () {
    test('retries on 429, honors Retry-After (seconds), then succeeds',
        () async {
      var calls = 0;
      final mock = http_testing.MockClient((request) async {
        calls += 1;
        if (calls < 3) {
          return http.Response('rate limited', 429,
              headers: const <String, String>{'retry-after': '0'});
        }
        final body = jsonEncode(<String, Object?>{
          'results': <String, Object?>{
            'timesheets': <String, Object?>{
              '901001': _samplePunch(id: 901001),
            },
          },
          'more': false,
        });
        return http.Response(body, 200);
      });
      final client = _build(client: mock, maxRetries: 5);

      final page = await client.listTimesheets(
        accessToken: _kAccessToken,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4, 12),
      );

      expect(calls, 3);
      expect(page.records, hasLength(1));
    });

    test('throws QuickBooksTimeRateLimitException after exhausting retries',
        () async {
      var calls = 0;
      final mock = http_testing.MockClient((request) async {
        calls += 1;
        return http.Response('rate limited', 429,
            headers: const <String, String>{'retry-after': '0'});
      });
      // maxRetries=2 -> 1 initial + 2 retries = 3 attempts max,
      // then throw.
      final client = _build(client: mock, maxRetries: 2);

      await expectLater(
        () => client.listTimesheets(
          accessToken: _kAccessToken,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 4, 12),
        ),
        throwsA(isA<QuickBooksTimeRateLimitException>()),
      );
      // 1 initial attempt + 2 retries = 3 total HTTP calls.
      expect(calls, 3);
    });
  });

  group('Auth errors', () {
    test('401 throws QuickBooksTimeAuthException without retry',
        () async {
      var calls = 0;
      final mock = http_testing.MockClient((request) async {
        calls += 1;
        return http.Response('unauthorized', 401);
      });
      final client = _build(client: mock);

      await expectLater(
        () => client.listTimesheets(
          accessToken: 'expired-token',
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 4, 12),
        ),
        throwsA(isA<QuickBooksTimeAuthException>()),
      );
      expect(calls, 1, reason: '401 must not retry');
    });
  });

  group('Schema roundtrip', () {
    test('decoded record maps cleanly through mapTimesheetToCanonical',
        () async {
      final mock = http_testing.MockClient((request) async {
        final body = jsonEncode(<String, Object?>{
          'results': <String, Object?>{
            'timesheets': <String, Object?>{
              '901001': _samplePunch(id: 901001),
            },
          },
          'more': false,
        });
        return http.Response(body, 200);
      });
      final client = _build(client: mock);
      final page = await client.listTimesheets(
        accessToken: _kAccessToken,
        modifiedSince: DateTime.utc(2026, 5, 1),
        modifiedUntil: DateTime.utc(2026, 5, 4, 12),
      );
      expect(page.records, hasLength(1));

      // Hand the raw record to the adapter mapper through the public
      // visible-for-testing seam.
      final adapter = QuickBooksTimeLaborAdapter(
        transport: client,
        gateway: _NoopGateway(),
      );
      final fact = adapter.mapTimesheetToCanonical(
        operatorId: 'op_demo_diner',
        locationId: 'loc_yorkville',
        record: page.records.first,
      );
      expect(fact, isNotNull);
      expect(fact!.vendorEntityId, '901001');
      expect(fact.shiftStart, DateTime.utc(2026, 5, 4, 11));
      expect(fact.shiftEnd, DateTime.utc(2026, 5, 4, 19, 30));
      expect(fact.roleName, 'server');
      expect(fact.employeeId, '8001');
      expect(fact.vendorModifiedAt, DateTime.utc(2026, 5, 4, 19, 31, 12));
    });
  });

  group('OAuth exchange', () {
    test('exchangeAuthorizationCode posts to Intuit OAuth host with '
        'Basic auth + Idempotency-Key + form body', () async {
      late Uri capturedUri;
      late Map<String, String> capturedHeaders;
      late String capturedBody;
      final mock = http_testing.MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        capturedBody = request.body;
        final body = jsonEncode(<String, Object?>{
          'access_token': 'new-access-token',
          'refresh_token': 'new-refresh-token',
          'expires_in': 3600,
          'scope': 'com.intuit.quickbooks.payroll.time.access',
          'realmId': 'realm-9876543210',
        });
        return http.Response(body, 200,
            headers: const <String, String>{
              'content-type': 'application/json',
            });
      });
      final client = _build(client: mock);

      final response = await client.exchangeAuthorizationCode(
        authorizationCode: 'auth-code-001',
        redirectUri:
            'https://proxy.example/v1/oauth/callback/quickbooks_time',
      );

      expect(capturedUri.host, 'oauth.platform.intuit.com');
      expect(capturedUri.path, '/oauth2/v1/tokens/bearer');
      expect(capturedHeaders['Content-Type'],
          'application/x-www-form-urlencoded');
      final basic = base64Encode(utf8.encode('$_kClientId:$_kClientSecret'));
      expect(capturedHeaders['Authorization'], 'Basic $basic');
      expect(capturedHeaders['Idempotency-Key'], 'idem-key-fixed');
      expect(capturedBody, contains('grant_type=authorization_code'));
      expect(capturedBody, contains('code=auth-code-001'));
      expect(capturedBody, contains('redirect_uri='));

      expect(response.accessToken, 'new-access-token');
      expect(response.refreshToken, 'new-refresh-token');
      expect(response.scope,
          'com.intuit.quickbooks.payroll.time.access');
      expect(response.realmId, 'realm-9876543210');
    });

    test('refresh sends grant_type=refresh_token + refresh_token form',
        () async {
      late String capturedBody;
      final mock = http_testing.MockClient((request) async {
        capturedBody = request.body;
        final body = jsonEncode(<String, Object?>{
          'access_token': 'refreshed-access-token',
          'refresh_token': 'rotated-refresh-token',
          'expires_in': 3600,
          'scope': 'com.intuit.quickbooks.payroll.time.access',
        });
        return http.Response(body, 200);
      });
      final client = _build(client: mock);

      final response = await client.refresh(refreshToken: _kRefreshToken);
      expect(capturedBody, contains('grant_type=refresh_token'));
      expect(capturedBody, contains('refresh_token=$_kRefreshToken'));
      expect(response.accessToken, 'refreshed-access-token');
      expect(response.refreshToken, 'rotated-refresh-token');
    });
  });

  group('Other API errors', () {
    test('500 throws QuickBooksTimeApiException without retry', () async {
      var calls = 0;
      final mock = http_testing.MockClient((request) async {
        calls += 1;
        return http.Response('boom', 500);
      });
      final client = _build(client: mock);

      await expectLater(
        () => client.listTimesheets(
          accessToken: _kAccessToken,
          modifiedSince: DateTime.utc(2026, 5, 1),
          modifiedUntil: DateTime.utc(2026, 5, 4, 12),
        ),
        throwsA(isA<QuickBooksTimeApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
      expect(calls, 1);
    });
  });
}

/// Bare gateway used only to construct the adapter for the schema
/// roundtrip test. The test never invokes the framework calls that
/// would touch this gateway.
class _NoopGateway implements QuickBooksTimeGateway {
  @override
  Future<QuickBooksTimeConnectionRow> upsertConnection({
    required QuickBooksTimeConnectionRow row,
  }) async =>
      row;

  @override
  Future<QuickBooksTimeWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) async =>
      null;

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required QuickBooksTimeWatermarkRow row,
  }) async {}

  @override
  Future<bool> writePunchFact(QuickBooksTimeCanonicalPunchFact fact) async =>
      true;

  @override
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  }) async {}

  @override
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  }) async =>
      null;

  @override
  Future<String?> readIntuitRealmId({
    required String operatorId,
    required String locationId,
  }) async =>
      null;
}
