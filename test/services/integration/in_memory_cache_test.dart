// Performance hardening (B6 / PF1) — LRU + TTL cache tests.
//
// Tests verify:
//   1. Basic get/put operations.
//   2. LRU eviction when at capacity.
//   3. TTL expiration (lazy deletion on get, eager on put).
//   4. Length tracking.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/in_memory_cache.dart';

void main() {
  group('LruTtlMap', () {
    test('stores and retrieves values', () {
      final cache = LruTtlMap<String, int>();
      cache.put('a', 1);
      cache.put('b', 2);

      expect(cache.get('a'), equals(1));
      expect(cache.get('b'), equals(2));
    });

    test('returns null for missing keys', () {
      final cache = LruTtlMap<String, int>();
      expect(cache.get('missing'), isNull);
    });

    test('overwrites existing keys', () {
      final cache = LruTtlMap<String, int>();
      cache.put('a', 1);
      cache.put('a', 2);

      expect(cache.get('a'), equals(2));
      expect(cache.length, equals(1));
    });

    test('evicts LRU entry when at capacity', () {
      final cache = LruTtlMap<String, int>(maxSize: 3);
      cache.put('a', 1);
      cache.put('b', 2);
      cache.put('c', 3);

      expect(cache.length, equals(3));

      // Insert new entry; 'a' (oldest) should be evicted.
      cache.put('d', 4);

      expect(cache.length, equals(3));
      expect(cache.get('a'), isNull);
      expect(cache.get('b'), equals(2));
      expect(cache.get('c'), equals(3));
      expect(cache.get('d'), equals(4));
    });

    test('moves accessed entry to tail (most recently used)', () {
      final cache = LruTtlMap<String, int>(maxSize: 3);
      cache.put('a', 1);
      cache.put('b', 2);
      cache.put('c', 3);

      // Access 'a', making it most recently used.
      cache.get('a');

      // Insert new entry; 'b' (now oldest) should be evicted.
      cache.put('d', 4);

      expect(cache.get('a'), equals(1));
      expect(cache.get('b'), isNull);
      expect(cache.get('c'), equals(3));
      expect(cache.get('d'), equals(4));
    });

    test('expires entries based on TTL', () {
      final now = DateTime(2026, 5, 8, 12, 0, 0);
      var clock = now;

      final cache = LruTtlMap<String, int>(
        ttl: const Duration(minutes: 1),
        clock: () => clock,
      );

      cache.put('a', 1);
      cache.put('b', 2);

      // Both entries are fresh; should be retrievable.
      expect(cache.get('a'), equals(1));
      expect(cache.get('b'), equals(2));

      // Advance clock past TTL.
      clock = now.add(const Duration(minutes: 2));

      // Entries should be considered expired.
      expect(cache.get('a'), isNull);
      expect(cache.get('b'), isNull);
      expect(cache.length, equals(0));
    });

    test('resets TTL when overwriting an entry', () {
      final now = DateTime(2026, 5, 8, 12, 0, 0);
      var clock = now;

      final cache = LruTtlMap<String, int>(
        ttl: const Duration(minutes: 1),
        clock: () => clock,
      );

      cache.put('a', 1);

      // Advance clock partway.
      clock = now.add(const Duration(seconds: 45));

      // Overwrite entry; TTL resets.
      cache.put('a', 10);

      // Original TTL would have expired, but overwrite reset it.
      clock = now.add(const Duration(minutes: 1, seconds: 30));
      expect(cache.get('a'), equals(10));

      // Now TTL expires for the new entry.
      clock = now.add(const Duration(minutes: 2, seconds: 30));
      expect(cache.get('a'), isNull);
    });

    test('remove deletes and returns value if not expired', () {
      final now = DateTime(2026, 5, 8, 12, 0, 0);
      final clock = now;

      final cache = LruTtlMap<String, int>(
        ttl: const Duration(minutes: 1),
        clock: () => clock,
      );

      cache.put('a', 42);

      // Before expiry, remove should succeed.
      expect(cache.remove('a'), equals(42));
      expect(cache.length, equals(0));

      // Second remove should return null.
      expect(cache.remove('a'), isNull);
    });

    test('remove returns null if expired', () {
      final now = DateTime(2026, 5, 8, 12, 0, 0);
      var clock = now;

      final cache = LruTtlMap<String, int>(
        ttl: const Duration(minutes: 1),
        clock: () => clock,
      );

      cache.put('a', 42);

      // Advance past expiry.
      clock = now.add(const Duration(minutes: 2));

      // Expired entry should return null.
      expect(cache.remove('a'), isNull);
      expect(cache.length, equals(0));
    });

    test('purgeExpired removes all expired entries', () {
      final now = DateTime(2026, 5, 8, 12, 0, 0);
      var clock = now;

      final cache = LruTtlMap<String, int>(
        ttl: const Duration(minutes: 1),
        clock: () => clock,
      );

      cache.put('a', 1);
      cache.put('b', 2);
      cache.put('c', 3);

      expect(cache.length, equals(3));

      // Advance past expiry.
      clock = now.add(const Duration(minutes: 2));

      // Purge should remove all expired entries.
      cache.purgeExpired();
      expect(cache.length, equals(0));
    });

    test('purgeExpired leaves non-expired entries', () {
      final now = DateTime(2026, 5, 8, 12, 0, 0);
      var clock = now;

      final cache = LruTtlMap<String, int>(
        ttl: const Duration(minutes: 1),
        clock: () => clock,
      );

      cache.put('a', 1);
      cache.put('b', 2);

      // Advance partway.
      clock = now.add(const Duration(seconds: 30));

      // Add another entry.
      cache.put('c', 3);

      // Advance so 'a' and 'b' are expired but 'c' is not.
      clock = now.add(const Duration(minutes: 1, seconds: 30));

      cache.purgeExpired();

      expect(cache.get('a'), isNull);
      expect(cache.get('b'), isNull);
      expect(cache.get('c'), equals(3));
      expect(cache.length, equals(1));
    });

    test('handles generic types (string values)', () {
      final cache = LruTtlMap<String, String>();
      cache.put('key1', 'value1');
      cache.put('key2', 'value2');

      expect(cache.get('key1'), equals('value1'));
      expect(cache.get('key2'), equals('value2'));
    });

    test('handles generic types (complex objects)', () {
      final cache = LruTtlMap<String, Map<String, dynamic>>();
      final obj = {'id': 123, 'name': 'test'};
      cache.put('key', obj);

      expect(cache.get('key'), equals(obj));
    });
  });
}
