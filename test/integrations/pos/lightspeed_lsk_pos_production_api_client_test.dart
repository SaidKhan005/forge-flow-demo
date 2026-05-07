// Phase 8 / Wave D — production HTTP transport tests.
//
// Drives every concrete in
// `lib/integrations/pos/lightspeed_lsk_pos_production_api_client.dart`
// against a fake `http.Client`. Live verification (real Lightspeed
// sandbox / prod) is the `8.LSK.live.sandbox` slice's job.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_pos_production_api_client.dart';

import 'fixtures/lightspeed_lsk_orders_fixture.dart';

void main() {
  group('LightspeedLskProductionOrdersClient', () {
    test('happy path: GET /f/v2/business-location/{id}/sales returns mapped page',
        () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'sales': lightspeedLskFiveRecordBatch(),
            'nextPageToken': null,
          }),
        ),
      ]);
      final orders = LightspeedLskProductionOrdersClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        httpClient: fakeClient,
        sleeper: _instantSleep,
      );

      final page = await orders.fetchSalesPage(
        accessTokenCredentialId: 'cred-1',
        businessId: 'biz-7c2f',
        windowStartUtc: DateTime.utc(2026, 5, 4, 0, 0, 0),
        windowEndUtc: DateTime.utc(2026, 5, 5, 0, 0, 0),
        pageSize: 50,
      );

      expect(page.sales.length, 5);
      expect(page.sales.first['accountFiscId'], 'A65315.17');
      expect(page.nextPageToken, isNull);
      expect(fakeClient.requests, hasLength(1));
      final request = fakeClient.requests.single;
      expect(request.method, 'GET');
      expect(
        request.url.path,
        contains('/f/v2/business-location/biz-7c2f/sales'),
      );
      expect(request.url.queryParameters['pageSize'], '50');
      expect(
        request.url.queryParameters['fromDate'],
        '2026-05-04T00:00:00.000Z',
      );
      expect(
        request.url.queryParameters['toDate'],
        '2026-05-05T00:00:00.000Z',
      );
      expect(
        request.headers['authorization'],
        'Bearer access-token-bytes',
      );
    });

    test('pagination: client passes nextPageToken on subsequent calls',
        () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'sales': lightspeedLskFiveRecordBatch().take(3).toList(),
            'nextPageToken': 'page-2-token',
          }),
        ),
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'sales': lightspeedLskFiveRecordBatch().skip(3).toList(),
            'nextPageToken': null,
          }),
        ),
      ]);
      final orders = LightspeedLskProductionOrdersClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        httpClient: fakeClient,
        sleeper: _instantSleep,
      );

      final page1 = await orders.fetchSalesPage(
        accessTokenCredentialId: 'cred-1',
        businessId: 'biz-1',
        windowStartUtc: DateTime.utc(2026, 5, 4),
        windowEndUtc: DateTime.utc(2026, 5, 5),
        pageSize: 50,
      );
      expect(page1.nextPageToken, 'page-2-token');

      final page2 = await orders.fetchSalesPage(
        accessTokenCredentialId: 'cred-1',
        businessId: 'biz-1',
        windowStartUtc: DateTime.utc(2026, 5, 4),
        windowEndUtc: DateTime.utc(2026, 5, 5),
        pageSize: 50,
        cursorToken: page1.nextPageToken,
      );
      expect(page2.nextPageToken, isNull);
      expect(fakeClient.requests, hasLength(2));
      expect(
        fakeClient.requests[0].url.queryParameters.containsKey('pageToken'),
        isFalse,
      );
      expect(
        fakeClient.requests[1].url.queryParameters['pageToken'],
        'page-2-token',
      );
    });

    test('429 backoff: honors Retry-After then succeeds', () async {
      final waits = <Duration>[];
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 429,
          body: '{"error":"rate_limited"}',
          headers: <String, String>{'retry-after': '2'},
        ),
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'sales': <Map<String, Object?>>[],
            'nextPageToken': null,
          }),
        ),
      ]);
      final orders = LightspeedLskProductionOrdersClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        httpClient: fakeClient,
        sleeper: (delay) async {
          waits.add(delay);
        },
        maxBackoff: const Duration(seconds: 30),
      );

      final page = await orders.fetchSalesPage(
        accessTokenCredentialId: 'cred-1',
        businessId: 'biz-1',
        windowStartUtc: DateTime.utc(2026, 5, 4),
        windowEndUtc: DateTime.utc(2026, 5, 5),
        pageSize: 50,
      );
      expect(page.sales, isEmpty);
      expect(fakeClient.requests, hasLength(2));
      expect(waits.length, 1);
      expect(waits.single, const Duration(seconds: 2));
    });

    test('401 surfaces typed exception immediately (no retry)', () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 401,
          body: '{"error":"invalid_token"}',
        ),
      ]);
      final orders = LightspeedLskProductionOrdersClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        httpClient: fakeClient,
        sleeper: _instantSleep,
      );

      try {
        await orders.fetchSalesPage(
          accessTokenCredentialId: 'cred-1',
          businessId: 'biz-1',
          windowStartUtc: DateTime.utc(2026, 5, 4),
          windowEndUtc: DateTime.utc(2026, 5, 5),
          pageSize: 50,
        );
        fail('expected LightspeedLskTransportException');
      } on LightspeedLskTransportException catch (e) {
        expect(e.statusCode, 401);
        expect(e.isUnauthorized, isTrue);
        expect(e.vendorErrorCode, 'invalid_token');
      }
      expect(fakeClient.requests, hasLength(1));
    });

    test('500 retries until budget exhausted', () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(statusCode: 500, body: '{"error":"server_error"}'),
        _FakeHttpResponse(statusCode: 502, body: ''),
        _FakeHttpResponse(statusCode: 503, body: ''),
        _FakeHttpResponse(statusCode: 504, body: ''),
        _FakeHttpResponse(statusCode: 500, body: '{"error":"persistent"}'),
      ]);
      final orders = LightspeedLskProductionOrdersClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        httpClient: fakeClient,
        sleeper: _instantSleep,
        maxRetries: 4,
      );

      try {
        await orders.fetchSalesPage(
          accessTokenCredentialId: 'cred-1',
          businessId: 'biz-1',
          windowStartUtc: DateTime.utc(2026, 5, 4),
          windowEndUtc: DateTime.utc(2026, 5, 5),
          pageSize: 50,
        );
        fail('expected LightspeedLskTransportException');
      } on LightspeedLskTransportException catch (e) {
        expect(e.statusCode, 500);
        expect(e.isTransient, isTrue);
      }
      // 1 first attempt + 4 retries.
      expect(fakeClient.requests, hasLength(5));
    });

    test('timeout surfaces typed exception', () async {
      final fakeClient = _FakeHttpClient.alwaysTimesOut();
      final orders = LightspeedLskProductionOrdersClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        httpClient: fakeClient,
        sleeper: _instantSleep,
        timeout: const Duration(milliseconds: 25),
        maxRetries: 1,
      );

      try {
        await orders.fetchSalesPage(
          accessTokenCredentialId: 'cred-1',
          businessId: 'biz-1',
          windowStartUtc: DateTime.utc(2026, 5, 4),
          windowEndUtc: DateTime.utc(2026, 5, 5),
          pageSize: 50,
        );
        fail('expected timeout exception');
      } on LightspeedLskTransportException catch (e) {
        expect(e.statusCode, isNull);
        expect(e.isTransient, isTrue);
        expect(e.message, contains('timed out'));
      }
    });

    test('schema roundtrip: sample order parses through adapter mapping',
        () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'sales': <Map<String, Object?>>[lightspeedLskSampleOrder()],
            'nextPageToken': null,
          }),
        ),
      ]);
      final orders = LightspeedLskProductionOrdersClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        httpClient: fakeClient,
        sleeper: _instantSleep,
      );

      final sample = await orders.fetchSampleOrder(
        accessTokenCredentialId: 'cred-1',
        businessId: 'biz-1',
      );
      expect(sample[LightspeedLskSaleFields.entityId], 'A65315.17');
      expect(sample[LightspeedLskSaleFields.openedAt],
          '2026-05-04T18:45:00.000Z');
      expect(sample[LightspeedLskSaleFields.closedAt],
          '2026-05-04T19:42:00.000Z');
      expect(sample[LightspeedLskSaleFields.covers], 3.0);
      final payments = sample[LightspeedLskSaleFields.paymentsArray] as List;
      expect(payments, hasLength(1));
      expect(
        (payments.first as Map)[LightspeedLskSaleFields.paymentNetAmountWithTax],
        '142.55',
      );
    });

    test('respects custom baseUri (sandbox override)', () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'sales': <Map<String, Object?>>[],
            'nextPageToken': null,
          }),
        ),
      ]);
      final orders = LightspeedLskProductionOrdersClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        httpClient: fakeClient,
        sleeper: _instantSleep,
        baseUri: kLightspeedLskSandboxBaseUri,
      );

      await orders.fetchSalesPage(
        accessTokenCredentialId: 'cred-1',
        businessId: 'biz-1',
        windowStartUtc: DateTime.utc(2026, 5, 4),
        windowEndUtc: DateTime.utc(2026, 5, 5),
        pageSize: 50,
      );
      expect(fakeClient.requests.single.url.host,
          kLightspeedLskSandboxBaseUri.host);
    });
  });

  group('LightspeedLskProductionOAuthClient', () {
    test('completeAuthorization exchanges code for tokens, persists, returns ids',
        () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'access_token': 'access-1',
            'refresh_token': 'refresh-1',
            'expires_in': 1800,
            'scope': 'orders-api financial-api offline_access',
            'business_id': 'lsk-biz-7c2f',
          }),
        ),
      ]);
      final persistCalls = <Map<String, Object?>>[];
      final oauth = LightspeedLskProductionOAuthClient(
        clientCredentials: LightspeedLskOAuthClientCredentials(
          clientId: 'ff-client-id',
          clientSecret: 'ff-client-secret',
          redirectUri: _redirectUri,
        ),
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{},
        ),
        idempotencyKeyGenerator: () => 'idem-1',
        authorizationCodeFor: (state) async => 'auth-code-$state',
        persistTokens: ({
          required accessToken,
          required refreshToken,
          required expiresAtUtc,
          required scopes,
        }) async {
          persistCalls.add(<String, Object?>{
            'access': accessToken,
            'refresh': refreshToken,
            'expires': expiresAtUtc.toIso8601String(),
            'scopes': scopes,
          });
          return (
            accessTokenCredentialId: 'cred-access-1',
            refreshTokenCredentialId: 'cred-refresh-1',
          );
        },
        httpClient: fakeClient,
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final result = await oauth.completeAuthorization(oauthState: 's-1');
      expect(result.accessTokenCredentialId, 'cred-access-1');
      expect(result.refreshTokenCredentialId, 'cred-refresh-1');
      expect(result.businessId, 'lsk-biz-7c2f');
      expect(result.scopes, <String>[
        'orders-api',
        'financial-api',
        'offline_access',
      ]);
      expect(
        result.tokenExpiresAtUtc,
        DateTime.utc(2026, 5, 4, 12, 30, 0),
      );

      expect(fakeClient.requests, hasLength(1));
      final req = fakeClient.requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, endsWith('/oauth/token'));
      expect(
        req.headers['content-type'],
        'application/x-www-form-urlencoded',
      );
      expect(req.headers['idempotency-key'], 'idem-1');
      expect(req.body, contains('grant_type=authorization_code'));
      expect(req.body, contains('code=auth-code-s-1'));
      expect(req.body, contains('client_id=ff-client-id'));

      expect(persistCalls, hasLength(1));
      expect(persistCalls.single['access'], 'access-1');
      expect(persistCalls.single['refresh'], 'refresh-1');
    });

    test('refresh: posts grant_type=refresh_token using stored refresh token',
        () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'access_token': 'access-2',
            'refresh_token': 'refresh-2',
            'expires_in': 3600,
            'scope': 'orders-api',
          }),
        ),
      ]);
      final oauth = LightspeedLskProductionOAuthClient(
        clientCredentials: LightspeedLskOAuthClientCredentials(
          clientId: 'ff-client-id',
          clientSecret: 'ff-client-secret',
          redirectUri: _redirectUri,
        ),
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-refresh-old': 'refresh-token-bytes'},
        ),
        idempotencyKeyGenerator: () => 'idem-r',
        authorizationCodeFor: (state) async => fail('not invoked on refresh'),
        persistTokens: ({
          required accessToken,
          required refreshToken,
          required expiresAtUtc,
          required scopes,
        }) async =>
            (
              accessTokenCredentialId: 'cred-access-new',
              refreshTokenCredentialId: 'cred-refresh-new',
            ),
        httpClient: fakeClient,
        clock: () => DateTime.utc(2026, 5, 4, 13, 0, 0),
      );

      final result = await oauth.refresh(
        refreshTokenCredentialId: 'cred-refresh-old',
      );
      expect(result.accessTokenCredentialId, 'cred-access-new');
      expect(result.tokenExpiresAtUtc, DateTime.utc(2026, 5, 4, 14, 0, 0));
      final req = fakeClient.requests.single;
      expect(req.body, contains('grant_type=refresh_token'));
      expect(req.body, contains('refresh_token=refresh-token-bytes'));
    });

    test('revoke: posts to /oauth/revoke and tolerates empty body', () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(statusCode: 200, body: ''),
      ]);
      final oauth = LightspeedLskProductionOAuthClient(
        clientCredentials: LightspeedLskOAuthClientCredentials(
          clientId: 'ff-client-id',
          clientSecret: 'ff-client-secret',
          redirectUri: _redirectUri,
        ),
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-access-1': 'access-token-bytes'},
        ),
        idempotencyKeyGenerator: () => 'idem-revoke',
        authorizationCodeFor: (state) async =>
            fail('not invoked on revoke'),
        persistTokens: ({
          required accessToken,
          required refreshToken,
          required expiresAtUtc,
          required scopes,
        }) async =>
            fail('not invoked on revoke'),
        httpClient: fakeClient,
      );

      await oauth.revoke(accessTokenCredentialId: 'cred-access-1');
      final req = fakeClient.requests.single;
      expect(req.url.path, endsWith('/oauth/revoke'));
      expect(req.body, contains('token=access-token-bytes'));
    });

    test('error response: typed exception with status + vendor code',
        () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 400,
          body: '{"error":"invalid_grant"}',
        ),
      ]);
      final oauth = LightspeedLskProductionOAuthClient(
        clientCredentials: LightspeedLskOAuthClientCredentials(
          clientId: 'ff-client-id',
          clientSecret: 'ff-client-secret',
          redirectUri: _redirectUri,
        ),
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{},
        ),
        idempotencyKeyGenerator: () => 'idem-x',
        authorizationCodeFor: (state) async => 'code',
        persistTokens: ({
          required accessToken,
          required refreshToken,
          required expiresAtUtc,
          required scopes,
        }) async =>
            fail('not invoked on error'),
        httpClient: fakeClient,
      );

      try {
        await oauth.completeAuthorization(oauthState: 's');
        fail('expected exception');
      } on LightspeedLskTransportException catch (e) {
        expect(e.statusCode, 400);
        expect(e.vendorErrorCode, 'invalid_grant');
      }
    });
  });

  group('LightspeedLskProductionWebhookClient', () {
    test('subscribe: PUTs registration body, returns subscription + secret id',
        () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'subscriptionId': 'sub-99',
            'signingSecret': 'whsec-bytes',
          }),
        ),
      ]);
      final persistCalls = <Map<String, Object?>>[];
      final webhook = LightspeedLskProductionWebhookClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        idempotencyKeyGenerator: () => 'idem-w',
        persistSigningSecret: ({
          required subscriptionId,
          required signingSecret,
        }) async {
          persistCalls.add(<String, Object?>{
            'subscription': subscriptionId,
            'secret': signingSecret,
          });
          return 'cred-signing-1';
        },
        httpClient: fakeClient,
        sleeper: _instantSleep,
      );

      final sub = await webhook.subscribe(
        accessTokenCredentialId: 'cred-1',
        webhookUrl: 'https://api.forgeflow.app/v1/webhooks/lightspeed_lsk/c-1',
        endpointId: 'forge-flow-lsk',
      );
      expect(sub.subscriptionId, 'sub-99');
      expect(sub.signingSecretCredentialId, 'cred-signing-1');
      expect(persistCalls, hasLength(1));
      expect(persistCalls.single['secret'], 'whsec-bytes');

      final req = fakeClient.requests.single;
      expect(req.method, 'PUT');
      expect(req.url.path, endsWith('/o/wh/1/webhook'));
      expect(req.headers['authorization'], 'Bearer access-token-bytes');
      expect(req.headers['content-type'], 'application/json');
      expect(req.headers['idempotency-key'], 'idem-w');
      final decoded = jsonDecode(req.body) as Map<String, Object?>;
      expect(decoded['endpointId'], 'forge-flow-lsk');
      expect(decoded['url'],
          'https://api.forgeflow.app/v1/webhooks/lightspeed_lsk/c-1');
    });

    test('unregister: DELETE to /o/wh/1/webhook/{id}', () async {
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(statusCode: 204, body: ''),
      ]);
      final webhook = LightspeedLskProductionWebhookClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'access-token-bytes'},
        ),
        idempotencyKeyGenerator: () => 'idem-d',
        persistSigningSecret: ({
          required subscriptionId,
          required signingSecret,
        }) async =>
            fail('not invoked on unregister'),
        httpClient: fakeClient,
        sleeper: _instantSleep,
      );

      await webhook.unregister(
        accessTokenCredentialId: 'cred-1',
        subscriptionId: 'sub-99',
      );
      final req = fakeClient.requests.single;
      expect(req.method, 'DELETE');
      expect(req.url.path, endsWith('/o/wh/1/webhook/sub-99'));
      expect(req.headers['idempotency-key'], 'idem-d');
    });

    test('429 backoff on subscribe', () async {
      final waits = <Duration>[];
      final fakeClient = _FakeHttpClient(<_FakeHttpResponse>[
        _FakeHttpResponse(
          statusCode: 429,
          body: '',
          headers: <String, String>{'retry-after': '1'},
        ),
        _FakeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'subscriptionId': 'sub-1',
            'signingSecret': 'whsec',
          }),
        ),
      ]);
      final webhook = LightspeedLskProductionWebhookClient(
        tokenResolver: InMemoryLightspeedLskAccessTokenResolver(
          <String, String>{'cred-1': 'tok'},
        ),
        idempotencyKeyGenerator: () => 'idem',
        persistSigningSecret: ({
          required subscriptionId,
          required signingSecret,
        }) async =>
            'cred-secret',
        httpClient: fakeClient,
        sleeper: (delay) async {
          waits.add(delay);
        },
      );

      final sub = await webhook.subscribe(
        accessTokenCredentialId: 'cred-1',
        webhookUrl: 'https://example.test/wh',
        endpointId: 'fflsk',
      );
      expect(sub.subscriptionId, 'sub-1');
      expect(waits, hasLength(1));
      expect(waits.single, const Duration(seconds: 1));
      expect(fakeClient.requests, hasLength(2));
    });
  });

  group('LightspeedLskTransportException', () {
    test('isUnauthorized true for 401/403 only', () {
      expect(
        LightspeedLskTransportException(message: '', statusCode: 401)
            .isUnauthorized,
        isTrue,
      );
      expect(
        LightspeedLskTransportException(message: '', statusCode: 403)
            .isUnauthorized,
        isTrue,
      );
      expect(
        LightspeedLskTransportException(message: '', statusCode: 500)
            .isUnauthorized,
        isFalse,
      );
    });

    test('isTransient true for 429, 5xx, network/timeout', () {
      expect(
        LightspeedLskTransportException(message: '', statusCode: 429)
            .isTransient,
        isTrue,
      );
      expect(
        LightspeedLskTransportException(message: '', statusCode: 503)
            .isTransient,
        isTrue,
      );
      expect(
        LightspeedLskTransportException.timeout(const Duration(seconds: 1))
            .isTransient,
        isTrue,
      );
      expect(
        LightspeedLskTransportException(message: '', statusCode: 400)
            .isTransient,
        isFalse,
      );
    });
  });
}

final Uri _redirectUri = Uri.parse(
  'https://api.forgeflow.app/v1/integrations/lightspeed_lsk/oauth/callback',
);

Future<void> _instantSleep(Duration delay) async {}

// ─── Fake http.Client ─────────────────────────────────────────────────

class _FakeHttpResponse {
  _FakeHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

class _CapturedRequest {
  _CapturedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;
}

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(List<_FakeHttpResponse> queue)
      : _queue = List<_FakeHttpResponse>.of(queue),
        _alwaysTimeout = false;

  _FakeHttpClient.alwaysTimesOut()
      : _queue = <_FakeHttpResponse>[],
        _alwaysTimeout = true;

  final List<_FakeHttpResponse> _queue;
  final bool _alwaysTimeout;
  final List<_CapturedRequest> requests = <_CapturedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    String body = '';
    if (request is http.Request) {
      body = request.body;
    }
    requests.add(_CapturedRequest(
      method: request.method,
      url: request.url,
      headers: Map<String, String>.from(request.headers),
      body: body,
    ));
    if (_alwaysTimeout) {
      // Never completes — caller's `.timeout(...)` raises a
      // TimeoutException.
      return Completer<http.StreamedResponse>().future;
    }
    if (_queue.isEmpty) {
      throw StateError('FakeHttpClient: no canned response remaining');
    }
    final canned = _queue.removeAt(0);
    final stream = Stream<List<int>>.fromIterable(<List<int>>[
      utf8.encode(canned.body),
    ]);
    return http.StreamedResponse(
      stream,
      canned.statusCode,
      headers: canned.headers,
    );
  }
}
