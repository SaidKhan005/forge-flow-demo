// Phase 8 / Wave B `8.transport.toast-pos` — production HTTP client
// tests.
//
// Uses `package:http/testing.dart`'s `MockClient` to stub responses;
// mirrors the test style in `test/proxy/anthropic_http_complete_fn_test.dart`.
// No live HTTP, no Postgres, no Flutter binding — pure Dart-VM unit
// tests.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/toast_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/toast_pos_production_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _opId = '00000000-0000-4000-8000-000000000001';
const _locId = '00000000-0000-4000-8000-0000000000a1';
const _restaurantGuid = '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011';

/// In-memory token resolver — production wires this to the proxy
/// `vendor_credentials_repository`.
class _StubTokenResolver implements ToastAccessTokenResolver {
  _StubTokenResolver({this.tokens = const ['stub-token-0', 'stub-token-1']});

  final List<String> tokens;
  int calls = 0;
  int forceRefreshCalls = 0;

  @override
  Future<String> resolveAccessToken({
    required ToastCredentialHandle credentials,
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) forceRefreshCalls += 1;
    final t = tokens[calls.clamp(0, tokens.length - 1)];
    calls += 1;
    return t;
  }
}

http.Response _jsonResponse(int statusCode, Object? body, {Map<String, String>? headers}) {
  return http.Response(
    body is String ? body : jsonEncode(body),
    statusCode,
    headers: <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json',
      if (headers != null) ...headers,
    },
  );
}

ToastCredentialHandle _handle() => const ToastCredentialHandle(
      connectionId: '$_opId|$_locId|$_restaurantGuid',
      restaurantGuid: _restaurantGuid,
    );

/// Builds a ToastPosProductionApiClient wired with deterministic
/// helpers so tests stay reproducible.
ToastPosProductionApiClient _client(
  http.Client mock, {
  ToastAccessTokenResolver? resolver,
  Random? random,
  Future<void> Function(Duration)? sleep,
  String Function()? idempotencyKeyFactory,
}) {
  return ToastPosProductionApiClient(
    httpClient: mock,
    tokenResolver: resolver ?? _StubTokenResolver(),
    baseUri: Uri.parse('https://ws-sandbox-api.eng.toasttab.com'),
    random: random ?? Random(0),
    sleep: sleep ?? ((_) async {}),
    idempotencyKeyFactory: idempotencyKeyFactory ?? () => 'test-idem-1',
  );
}

void main() {
  group('ToastPosProductionApiClient', () {
    test('happy-path GET single page: orders + cursor parsed from body',
        () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/orders/v2/ordersBulk');
        expect(
          request.url.queryParameters['startDate'],
          isNotNull,
          reason: 'startDate query param required',
        );
        expect(
          request.headers['Authorization'],
          startsWith('Bearer '),
        );
        expect(
          request.headers['Toast-Restaurant-External-ID'],
          _restaurantGuid,
        );
        return _jsonResponse(200, <String, Object?>{
          'orders': <Map<String, Object?>>[
            <String, Object?>{
              'guid': 'p1-001',
              'modifiedDate': '2026-05-04T18:35:00.000Z',
              'openedDate': '2026-05-04T18:00:00.000Z',
              'closedDate': '2026-05-04T18:35:00.000Z',
              'numberOfGuests': 2,
              'totalAmount': 41.50,
            },
          ],
          'nextPageToken': null,
        });
      });
      final client = _client(mock);

      final page = await client.fetchOrdersPage(
        credentials: _handle(),
        windowStart: DateTime.utc(2026, 5, 4, 18, 0),
        windowEnd: DateTime.utc(2026, 5, 4, 19, 0),
      );

      expect(page.orders, hasLength(1));
      expect(page.orders.first['guid'], 'p1-001');
      expect(page.nextCursor, isNull);
      expect(
        page.lastModifiedSeen,
        DateTime.utc(2026, 5, 4, 18, 35).toUtc(),
        reason: 'lastModifiedSeen reflects max(modifiedDate) in page',
      );
    });

    test('pagination across 3 pages stitches via pageToken', () async {
      final pages = <Map<String, Object?>>[
        <String, Object?>{
          'orders': <Map<String, Object?>>[
            {
              'guid': 'p1',
              'modifiedDate': '2026-05-04T18:35:00.000Z',
              'numberOfGuests': 2,
            },
          ],
          'nextPageToken': 'cursor-page-2',
        },
        <String, Object?>{
          'orders': <Map<String, Object?>>[
            {
              'guid': 'p2',
              'modifiedDate': '2026-05-04T18:50:00.000Z',
              'numberOfGuests': 5,
            },
          ],
          'nextPageToken': 'cursor-page-3',
        },
        <String, Object?>{
          'orders': <Map<String, Object?>>[
            {
              'guid': 'p3',
              'modifiedDate': '2026-05-04T19:05:00.000Z',
              'numberOfGuests': 3,
            },
          ],
          'nextPageToken': null,
        },
      ];

      final seenCursors = <String?>[];
      final mock = MockClient((request) async {
        seenCursors.add(request.url.queryParameters['pageToken']);
        final attempt = seenCursors.length - 1;
        return _jsonResponse(200, pages[attempt]);
      });
      final client = _client(mock);

      String? cursor;
      final allOrders = <Map<String, Object?>>[];
      var iterations = 0;
      do {
        iterations += 1;
        final page = await client.fetchOrdersPage(
          credentials: _handle(),
          windowStart: DateTime.utc(2026, 5, 4, 18, 0),
          windowEnd: DateTime.utc(2026, 5, 4, 19, 0),
          resumeFromCursor: cursor,
        );
        allOrders.addAll(page.orders);
        cursor = page.nextCursor;
      } while (cursor != null && iterations < 10);

      expect(iterations, 3);
      expect(allOrders.map((o) => o['guid']), ['p1', 'p2', 'p3']);
      expect(
        seenCursors,
        [null, 'cursor-page-2', 'cursor-page-3'],
        reason: 'pageToken threaded across pages',
      );
    });

    test('429 with Retry-After backs off and retries', () async {
      var calls = 0;
      final sleeps = <Duration>[];
      final mock = MockClient((request) async {
        calls += 1;
        if (calls == 1) {
          return _jsonResponse(
            429,
            <String, Object?>{'message': 'rate limited'},
            headers: <String, String>{'retry-after': '2'},
          );
        }
        return _jsonResponse(200, <String, Object?>{
          'orders': <Map<String, Object?>>[],
          'nextPageToken': null,
        });
      });
      final client = _client(
        mock,
        sleep: (d) async {
          sleeps.add(d);
        },
      );

      final page = await client.fetchOrdersPage(
        credentials: _handle(),
        windowStart: DateTime.utc(2026, 5, 4, 18, 0),
        windowEnd: DateTime.utc(2026, 5, 4, 19, 0),
      );

      expect(page.orders, isEmpty);
      expect(calls, 2, reason: 'one retry after 429');
      expect(sleeps, hasLength(1));
      expect(
        sleeps.single.inMilliseconds,
        greaterThanOrEqualTo(2000),
        reason: 'Retry-After=2 honored (with optional jitter on top)',
      );
    });

    test('401 surfaces ToastAuthError after one reactive refresh', () async {
      final resolver = _StubTokenResolver(
        tokens: <String>['stale-token', 'fresh-token'],
      );
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        // Both attempts return 401 — the resolver's force-refresh
        // does not (in this test) recover.
        return _jsonResponse(
          401,
          <String, Object?>{'message': 'unauthorized'},
        );
      });
      final client = _client(mock, resolver: resolver);

      await expectLater(
        () => client.fetchOrdersPage(
          credentials: _handle(),
          windowStart: DateTime.utc(2026, 5, 4),
          windowEnd: DateTime.utc(2026, 5, 4, 1),
        ),
        throwsA(isA<ToastAuthError>()),
      );
      expect(
        calls,
        2,
        reason: 'one reactive refresh (forceRefresh) before surfacing',
      );
      expect(
        resolver.forceRefreshCalls,
        1,
        reason: 'resolver.forceRefresh invoked once on 401 path',
      );
    });

    test('500 retries up to the cap then surfaces TransientError',
        () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return _jsonResponse(
          500,
          <String, Object?>{'message': 'oops'},
        );
      });
      final client = _client(mock, sleep: (_) async {});

      await expectLater(
        () => client.fetchOrdersPage(
          credentials: _handle(),
          windowStart: DateTime.utc(2026, 5, 4),
          windowEnd: DateTime.utc(2026, 5, 4, 1),
        ),
        throwsA(isA<ToastTransientError>()),
      );
      // First attempt + kToastMaxRetries (5) retries = 6 total.
      expect(calls, kToastMaxRetries + 1);
    });

    test('network timeout surfaces TransientError after the cap', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        // Simulate a slow response by waiting longer than the request
        // timeout — `Future.delayed` lets the `.timeout()` fire.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return _jsonResponse(200, <String, Object?>{});
      });
      final client = ToastPosProductionApiClient(
        httpClient: mock,
        tokenResolver: _StubTokenResolver(),
        baseUri: Uri.parse('https://ws-sandbox-api.eng.toasttab.com'),
        random: Random(0),
        requestTimeout: const Duration(milliseconds: 10),
        sleep: (_) async {},
      );

      await expectLater(
        () => client.fetchOrdersPage(
          credentials: _handle(),
          windowStart: DateTime.utc(2026, 5, 4),
          windowEnd: DateTime.utc(2026, 5, 4, 1),
        ),
        throwsA(isA<ToastTransientError>()),
      );
      expect(calls, kToastMaxRetries + 1);
    });

    test('schema deserialization round-trip preserves ISO-8601 with Z',
        () async {
      const sampleBody = <String, Object?>{
        'orders': <Map<String, Object?>>[
          <String, Object?>{
            'guid': 'rt-001',
            'modifiedDate': '2026-05-04T19:55:00.000Z',
            'openedDate': '2026-05-04T18:30:00.000Z',
            'closedDate': '2026-05-04T19:55:00.000Z',
            'numberOfGuests': 4,
            'totalAmount': 87.20,
          },
        ],
        'nextPageToken': null,
      };
      final mock = MockClient((request) async {
        return _jsonResponse(200, sampleBody);
      });
      final client = _client(mock);

      final page = await client.fetchOrdersPage(
        credentials: _handle(),
        windowStart: DateTime.utc(2026, 5, 4, 18, 0),
        windowEnd: DateTime.utc(2026, 5, 4, 20, 0),
      );

      expect(page.orders.single['modifiedDate'], '2026-05-04T19:55:00.000Z');
      expect(page.orders.single['totalAmount'], 87.20);
      expect(
        page.lastModifiedSeen.isUtc,
        isTrue,
        reason: 'preserved as UTC instant — TIMESTAMPTZ-ready',
      );
      expect(
        page.lastModifiedSeen,
        DateTime.utc(2026, 5, 4, 19, 55),
      );
    });

    test('registerWebhook attaches Idempotency-Key header on POST',
        () async {
      String? observedIdemKey;
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/webhooks-config/v1/webhook');
        observedIdemKey = request.headers['Idempotency-Key'];
        return _jsonResponse(
          200,
          <String, Object?>{'guid': 'subscription-123'},
        );
      });
      final client = _client(
        mock,
        idempotencyKeyFactory: () => 'fixed-test-key-001',
      );

      final id = await client.registerWebhook(
        credentials: _handle(),
        webhookUrl: '/v1/webhooks/toast/op/loc',
      );

      expect(id, 'subscription-123');
      expect(observedIdemKey, 'fixed-test-key-001');
    });

    test('fetchOrderByGuid returns null on 404', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/orders/v2/orders/missing-guid');
        return _jsonResponse(404, <String, Object?>{});
      });
      final client = _client(mock);

      final result = await client.fetchOrderByGuid(
        credentials: _handle(),
        guid: 'missing-guid',
      );
      expect(result, isNull);
    });

    test('exchangeClientCredentials returns handle and exercises resolver',
        () async {
      final resolver = _StubTokenResolver();
      final mock = MockClient((_) async => _jsonResponse(200, <String, Object?>{}));
      final client = _client(mock, resolver: resolver);

      final handle = await client.exchangeClientCredentials(
        operatorId: _opId,
        locationId: _locId,
        restaurantGuid: _restaurantGuid,
      );
      expect(handle.restaurantGuid, _restaurantGuid);
      expect(resolver.calls, 1, reason: 'resolver called once at handle mint');
    });

    test('429 then success counts attempts correctly', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        if (calls < 3) {
          return _jsonResponse(
            429,
            <String, Object?>{'message': 'slow down'},
            headers: <String, String>{'retry-after': '0'},
          );
        }
        return _jsonResponse(200, <String, Object?>{
          'orders': <Map<String, Object?>>[],
          'nextPageToken': null,
        });
      });
      final client = _client(mock);

      final page = await client.fetchOrdersPage(
        credentials: _handle(),
        windowStart: DateTime.utc(2026, 5, 4),
        windowEnd: DateTime.utc(2026, 5, 4, 1),
      );

      expect(page.orders, isEmpty);
      expect(calls, 3, reason: '2 retries + 1 success = 3 attempts');
    });
  });
}
