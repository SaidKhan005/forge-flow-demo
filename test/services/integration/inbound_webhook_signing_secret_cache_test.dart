// P0 fix (2026-05-09 webhook-signature triage Section 5.F.1) —
// SigningSecretCache unit tests.
//
// Drives the in-memory implementation through:
//
//   * Cache hit returns memoized value without invoking loader.
//   * Cache miss invokes loader, populates entry.
//   * TTL expiry triggers re-fetch.
//   * Loader exception bubbles AND does NOT poison the cache.
//   * Per-operator entry cap evicts oldest.
//   * `invalidate(...)` clears the keyed entry only.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_signing_secret_cache.dart';

void main() {
  group('InMemorySigningSecretCache', () {
    test('cache hit returns memoized value without invoking loader',
        () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(clock: clock.now);
      var loaderCalls = 0;
      Future<String?> loader() async {
        loaderCalls += 1;
        return 'secret-1';
      }

      final first = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: loader,
      );
      final second = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: loader,
      );

      expect(first, 'secret-1');
      expect(second, 'secret-1');
      expect(loaderCalls, 1, reason: 'second call must hit cache');
    });

    test('cache miss invokes loader and populates entry', () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(clock: clock.now);

      final result = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: () async => 'fresh',
      );

      expect(result, 'fresh');
      expect(cache.debugSizeForOperator('op-1'), 1);
    });

    test('null loader return is NEVER cached (re-fetches every time)',
        () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(clock: clock.now);
      var loaderCalls = 0;
      Future<String?> nullLoader() async {
        loaderCalls += 1;
        return null;
      }

      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: nullLoader,
      );
      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: nullLoader,
      );

      expect(loaderCalls, 2,
          reason: 'null returns must NOT poison the cache; the just-'
              'provisioned-secret path must light up immediately on '
              'the next dispatch');
      expect(cache.debugSizeForOperator('op-1'), 0);
    });

    test('TTL expiry triggers re-fetch', () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(
        clock: clock.now,
        ttl: const Duration(seconds: 30),
      );
      var loaderCalls = 0;
      Future<String?> loader() async {
        loaderCalls += 1;
        return 'secret-$loaderCalls';
      }

      final first = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: loader,
      );
      // Advance past TTL.
      clock.advance(const Duration(seconds: 31));
      final second = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: loader,
      );

      expect(first, 'secret-1');
      expect(second, 'secret-2');
      expect(loaderCalls, 2);
    });

    test('TTL boundary — exactly TTL old is evicted', () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(
        clock: clock.now,
        ttl: const Duration(seconds: 60),
      );
      var loaderCalls = 0;
      Future<String?> loader() async {
        loaderCalls += 1;
        return 'secret-$loaderCalls';
      }

      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: loader,
      );
      clock.advance(const Duration(seconds: 60));
      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: loader,
      );

      expect(loaderCalls, 2,
          reason:
              'an entry that has aged exactly the TTL is treated as '
              'expired (>=, not >) so the upper bound on staleness is '
              'tight');
    });

    test('loader exception bubbles AND does NOT poison the cache',
        () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(clock: clock.now);

      // First attempt throws.
      await expectLater(
        () => cache.getOrFetch(
          operatorId: 'op-1',
          locationId: 'loc-1',
          vendorId: 'vendor-x',
          loader: () async => throw const _LoaderFailure(),
        ),
        throwsA(isA<_LoaderFailure>()),
      );
      // No entry was stored.
      expect(cache.debugSizeForOperator('op-1'), 0);

      // Second attempt succeeds — the cache is fresh, not poisoned.
      final fresh = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: () async => 'recovered',
      );
      expect(fresh, 'recovered');
      expect(cache.debugSizeForOperator('op-1'), 1);
    });

    test('per-operator entry cap evicts oldest', () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(
        clock: clock.now,
        perOperatorCap: 3,
      );

      // Fill four distinct (location, vendor) tuples so the oldest is
      // pushed out.
      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-A',
        vendorId: 'vendor-1',
        loader: () async => 'A',
      );
      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-B',
        vendorId: 'vendor-1',
        loader: () async => 'B',
      );
      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-C',
        vendorId: 'vendor-1',
        loader: () async => 'C',
      );
      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-D',
        vendorId: 'vendor-1',
        loader: () async => 'D',
      );

      expect(cache.debugSizeForOperator('op-1'), 3);

      // The oldest (loc-A) should have been evicted — verify by
      // checking that re-fetching it invokes the loader.
      var aLoaderCalls = 0;
      final reFetched = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-A',
        vendorId: 'vendor-1',
        loader: () async {
          aLoaderCalls += 1;
          return 'A-fresh';
        },
      );
      expect(aLoaderCalls, 1,
          reason: 'evicted entry must trigger a fresh loader call');
      expect(reFetched, 'A-fresh');
    });

    test('invalidate clears the keyed entry only', () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(clock: clock.now);

      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: () async => 'X',
      );
      await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-y',
        loader: () async => 'Y',
      );
      expect(cache.debugSizeForOperator('op-1'), 2);

      cache.invalidate(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
      );
      expect(cache.debugSizeForOperator('op-1'), 1,
          reason: 'only the keyed entry is invalidated');

      // The other entry is still warm — loader must NOT fire.
      var loaderCalls = 0;
      final hit = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-y',
        loader: () async {
          loaderCalls += 1;
          return 'Y-fresh';
        },
      );
      expect(hit, 'Y');
      expect(loaderCalls, 0);

      // The invalidated entry now triggers a loader call.
      var xLoaderCalls = 0;
      final reFetched = await cache.getOrFetch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'vendor-x',
        loader: () async {
          xLoaderCalls += 1;
          return 'X-fresh';
        },
      );
      expect(xLoaderCalls, 1);
      expect(reFetched, 'X-fresh');
    });

    test(
        'per-operator isolation: tenant A does NOT see tenant B entries',
        () async {
      final clock = _FixedClock(DateTime.utc(2026, 5, 9, 12));
      final cache = InMemorySigningSecretCache(clock: clock.now);

      await cache.getOrFetch(
        operatorId: 'op-A',
        locationId: 'loc-shared',
        vendorId: 'vendor-shared',
        loader: () async => 'A-secret',
      );

      var bLoaderCalls = 0;
      final fromB = await cache.getOrFetch(
        operatorId: 'op-B',
        locationId: 'loc-shared',
        vendorId: 'vendor-shared',
        loader: () async {
          bLoaderCalls += 1;
          return 'B-secret';
        },
      );

      expect(fromB, 'B-secret');
      expect(bLoaderCalls, 1,
          reason: 'tenant B must trigger its own loader; tenant A '
              'cache key must not be reused for tenant B');
      expect(cache.debugSizeForOperator('op-A'), 1);
      expect(cache.debugSizeForOperator('op-B'), 1);
    });
  });
}

class _FixedClock {
  _FixedClock(this._current);

  DateTime _current;

  DateTime now() => _current;

  void advance(Duration d) {
    _current = _current.add(d);
  }
}

class _LoaderFailure implements Exception {
  const _LoaderFailure();
}
