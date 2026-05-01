// Phase 9.UX.7 - ProxyAuthIdempotencyCache unit tests.
//
// Covers behaviour the route-level tests can't easily express:
//   - 429 responses are not cached (rate-limit retries must be
//     allowed to succeed when the window passes)
//   - LRU eviction enforces the bounded-size contract so an
//     attacker spamming unique keys can't OOM the proxy
//   - Cache hits promote the entry (LRU, not pure FIFO)
//   - 5xx responses are not cached (transient failures recover)

import 'package:flutter_test/flutter_test.dart';

import '../tool/advisor_proxy/proxy_idempotency_cache.dart';

void main() {
  group('ProxyAuthIdempotencyCache', () {
    test('caches 200 and replays the cached response on key reuse', () async {
      final cache = ProxyAuthIdempotencyCache();
      var calls = 0;
      Future<CachedProxyResponse> compute() async {
        calls += 1;
        return CachedProxyResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'call': calls},
        );
      }

      final first = await cache.runOrReplay(
        route: '/v1/auth/password/reset/confirm',
        key: 'idem-1',
        compute: compute,
      );
      final second = await cache.runOrReplay(
        route: '/v1/auth/password/reset/confirm',
        key: 'idem-1',
        compute: compute,
      );

      expect(first.statusCode, equals(200));
      expect(second.statusCode, equals(200));
      expect(calls, equals(1));
      expect(second.body['call'], equals(1));
    });

    test('does NOT cache 429 — rate-limit retries must be re-evaluated',
        () async {
      final cache = ProxyAuthIdempotencyCache();
      var calls = 0;
      Future<CachedProxyResponse> compute() async {
        calls += 1;
        return CachedProxyResponse(
          statusCode: 429,
          body: <String, Object?>{'error': 'rate_limited'},
        );
      }

      await cache.runOrReplay(
        route: '/v1/auth/password/reset/request',
        key: 'idem-rate',
        compute: compute,
      );
      await cache.runOrReplay(
        route: '/v1/auth/password/reset/request',
        key: 'idem-rate',
        compute: compute,
      );

      // Both calls hit the underlying compute — second was not
      // pinned to the cached 429.
      expect(calls, equals(2));
    });

    test('does NOT cache 5xx — transient failures recover on retry',
        () async {
      final cache = ProxyAuthIdempotencyCache();
      final responses = <CachedProxyResponse>[
        CachedProxyResponse(
          statusCode: 503,
          body: const <String, Object?>{'error': 'unavailable'},
        ),
        CachedProxyResponse(
          statusCode: 200,
          body: const <String, Object?>{'ok': true},
        ),
      ];
      var index = 0;
      Future<CachedProxyResponse> compute() async => responses[index++];

      final first = await cache.runOrReplay(
        route: '/v1/auth/password/reset/request',
        key: 'idem-recover',
        compute: compute,
      );
      final second = await cache.runOrReplay(
        route: '/v1/auth/password/reset/request',
        key: 'idem-recover',
        compute: compute,
      );

      expect(first.statusCode, equals(503));
      expect(second.statusCode, equals(200));
      expect(index, equals(2));
    });

    test('caches 4xx terminal client errors so retries replay', () async {
      final cache = ProxyAuthIdempotencyCache();
      var calls = 0;
      Future<CachedProxyResponse> compute() async {
        calls += 1;
        return CachedProxyResponse(
          statusCode: 422,
          body: const <String, Object?>{'error': 'password_pwned'},
        );
      }

      await cache.runOrReplay(
        route: '/v1/auth/password/reset/confirm',
        key: 'idem-422',
        compute: compute,
      );
      final replay = await cache.runOrReplay(
        route: '/v1/auth/password/reset/confirm',
        key: 'idem-422',
        compute: compute,
      );

      expect(replay.statusCode, equals(422));
      expect(calls, equals(1));
    });

    test(
      'enforces maxEntries by evicting the oldest entry on overflow',
      () async {
        final cache = ProxyAuthIdempotencyCache(maxEntries: 2);

        Future<CachedProxyResponse> ok(int n) async => CachedProxyResponse(
              statusCode: 200,
              body: <String, Object?>{'n': n},
            );

        await cache.runOrReplay(
          route: '/r',
          key: 'k1',
          compute: () => ok(1),
        );
        await cache.runOrReplay(
          route: '/r',
          key: 'k2',
          compute: () => ok(2),
        );
        // This third entry forces k1 (oldest) to evict.
        await cache.runOrReplay(
          route: '/r',
          key: 'k3',
          compute: () => ok(3),
        );

        // k2 still cached (computes once across two calls).
        var k2Calls = 0;
        await cache.runOrReplay(
          route: '/r',
          key: 'k2',
          compute: () async {
            k2Calls += 1;
            return ok(99);
          },
        );
        expect(k2Calls, equals(0));

        // k1 was evicted — re-computed.
        var k1Calls = 0;
        await cache.runOrReplay(
          route: '/r',
          key: 'k1',
          compute: () async {
            k1Calls += 1;
            return ok(100);
          },
        );
        expect(k1Calls, equals(1));
      },
    );

    test(
      'cache hit promotes the entry (LRU survives subsequent overflow)',
      () async {
        final cache = ProxyAuthIdempotencyCache(maxEntries: 2);

        Future<CachedProxyResponse> ok(int n) async => CachedProxyResponse(
              statusCode: 200,
              body: <String, Object?>{'n': n},
            );

        await cache.runOrReplay(
          route: '/r',
          key: 'k1',
          compute: () => ok(1),
        );
        await cache.runOrReplay(
          route: '/r',
          key: 'k2',
          compute: () => ok(2),
        );

        // Hit k1 — promotes it to most-recent.
        await cache.runOrReplay(
          route: '/r',
          key: 'k1',
          compute: () => ok(99),
        );

        // Insert k3 — k2 (now oldest) should evict, not k1.
        await cache.runOrReplay(
          route: '/r',
          key: 'k3',
          compute: () => ok(3),
        );

        var k1Calls = 0;
        await cache.runOrReplay(
          route: '/r',
          key: 'k1',
          compute: () async {
            k1Calls += 1;
            return ok(100);
          },
        );
        expect(k1Calls, equals(0)); // still cached

        var k2Calls = 0;
        await cache.runOrReplay(
          route: '/r',
          key: 'k2',
          compute: () async {
            k2Calls += 1;
            return ok(200);
          },
        );
        expect(k2Calls, equals(1)); // evicted
      },
    );

    test(
      'TTL eviction: entries past expiry are not replayed',
      () async {
        DateTime fakeNow = DateTime.utc(2026, 5, 1, 12);
        final cache = ProxyAuthIdempotencyCache(
          ttl: const Duration(minutes: 5),
          now: () => fakeNow,
        );

        var calls = 0;
        Future<CachedProxyResponse> compute() async {
          calls += 1;
          return CachedProxyResponse(
            statusCode: 200,
            body: const <String, Object?>{'ok': true},
          );
        }

        await cache.runOrReplay(
          route: '/r',
          key: 'k',
          compute: compute,
        );
        // Within TTL — replay.
        fakeNow = fakeNow.add(const Duration(minutes: 4));
        await cache.runOrReplay(
          route: '/r',
          key: 'k',
          compute: compute,
        );
        expect(calls, equals(1));

        // After TTL — re-compute.
        fakeNow = fakeNow.add(const Duration(minutes: 2));
        await cache.runOrReplay(
          route: '/r',
          key: 'k',
          compute: compute,
        );
        expect(calls, equals(2));
      },
    );
  });
}
