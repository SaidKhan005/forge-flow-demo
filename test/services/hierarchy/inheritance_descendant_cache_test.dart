// Slice L_A2 — InheritanceDescendantCache tests.
//
// Pins the cache semantics around the L_A1 primitive
// [OrgUnitsRepository.getDescendantLocations]:
//
//   * Default OFF posture (so other repo tests stay deterministic).
//   * Cache HIT skips the underlying repository round-trip; MISS hits
//     it exactly once and stores the result.
//   * TTL: a read past `expiresAt` re-loads from the repository.
//   * Cross-tenant isolation: same scope id under two operators is
//     two distinct cache entries; a hit for operator A cannot ever
//     satisfy operator B.
//   * Explicit invalidation: per-scope and per-operator (drop-all)
//     paths both work.
//   * Empty-scope edge case: an operator with zero descendant rows
//     under a scope IS cached (empty list is a real read shape).
//   * Loader exceptions do NOT poison the cache: the next call
//     re-attempts the loader.
//   * LRU eviction when at capacity.
//   * Stats projection reports the right hit/miss/invalidation/
//     eviction counters.
//   * Constructor guards: positive ttl + positive maxEntries.
//   * Null scope is a distinct cache key from a real scope id.
//
// The cache wraps a real `OrgUnitsRepository` over a `_RecordingPool`
// (mirrors `inheritance_tree_repository_test.dart`) so the tests
// exercise the full Dart code path — no fakes-around-fakes.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/org_units_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/hierarchy/inheritance_descendant_cache.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const String _userA = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

void main() {
  group('InheritanceDescendantCache — defaults + constructor guards', () {
    test('is OFF by default — passthrough on every call, no cache state',
        () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-1',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.east',
            'name': 'Store One',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      // Default: enabled defaults to false.
      final cache = InheritanceDescendantCache(repository: repo);
      expect(cache.isEnabled, isFalse);

      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );

      // Two pass-through calls = two transactions on the pool.
      expect(pool.transactions, hasLength(2));
      final stats = cache.statsSnapshot();
      expect(stats.hits, equals(0));
      expect(stats.misses, equals(2));
      expect(stats.size, equals(0));
    });

    test('rejects non-positive maxEntries', () {
      final pool = _RecordingPool();
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      expect(
        () => InheritanceDescendantCache(
          repository: repo,
          enabled: true,
          maxEntries: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => InheritanceDescendantCache(
          repository: repo,
          enabled: true,
          maxEntries: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects non-positive ttl', () {
      final pool = _RecordingPool();
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      expect(
        () => InheritanceDescendantCache(
          repository: repo,
          enabled: true,
          ttl: Duration.zero,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => InheritanceDescendantCache(
          repository: repo,
          enabled: true,
          ttl: const Duration(seconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('InheritanceDescendantCache — HIT vs MISS', () {
    test('MISS hits repo; second call HITs cache, no second round-trip',
        () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-1',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.east',
            'name': 'Store One',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );

      final first = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
        userId: _userA,
      );
      final second = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
        userId: _userA,
      );

      expect(first, hasLength(1));
      expect(second, hasLength(1));
      expect(second.first.locationId, equals('loc-1'));
      // Only one transaction = only one round-trip.
      expect(pool.transactions, hasLength(1));
      final stats = cache.statsSnapshot();
      expect(stats.hits, equals(1));
      expect(stats.misses, equals(1));
      expect(stats.size, equals(1));
    });

    test('locationId / userId variation does NOT split cache entries (RLS '
        'tenant-context fields are not part of the key)', () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-1',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.east',
            'name': 'Store One',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );

      // Same operatorId + scopeOrgUnitId, different locationId/userId →
      // single cache slot. Two HITs on the cache, one DB round-trip.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
        userId: _userA,
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        scopeOrgUnitId: 'ou-x',
        userId: 'dddddddd-dddd-dddd-dddd-dddddddddddd',
      );

      expect(pool.transactions, hasLength(1));
      final stats = cache.statsSnapshot();
      expect(stats.hits, equals(1));
      expect(stats.misses, equals(1));
    });
  });

  group('InheritanceDescendantCache — TTL', () {
    test('expired entry triggers a fresh repository read', () async {
      final clock = _MutableClock(DateTime.utc(2026, 5, 13, 10, 0, 0));
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-1',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.east',
            'name': 'Store One',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
        ttl: const Duration(seconds: 60),
        clock: clock.now,
      );

      // Initial MISS at T=0 — entry expires at T=60.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );

      // T=30: hit, no second tx.
      clock.advance(const Duration(seconds: 30));
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      expect(pool.transactions, hasLength(1));

      // T=61: past TTL, re-load.
      clock.advance(const Duration(seconds: 31));
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      expect(pool.transactions, hasLength(2));

      final stats = cache.statsSnapshot();
      expect(stats.hits, equals(1));
      expect(stats.misses, equals(2));
    });
  });

  group('InheritanceDescendantCache — cross-tenant isolation (HP #4)', () {
    test('same scopeOrgUnitId under operator A and operator B are distinct '
        'cache slots; HIT for A never returns B\'s data', () async {
      final pool = _RecordingPool();
      // Toggle the response per-transaction so we can prove the cache
      // never crosses operators.
      pool.descendantLocationsByCallIndex = <List<PostgresRow>>[
        // call 0: operator A, scope ou-x → returns loc-A
        const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-A',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.east',
            'name': 'A Store',
          },
        ],
        // call 1: operator B, scope ou-x → returns loc-B
        const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-B',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'mega.south',
            'name': 'B Store',
          },
        ],
      ];
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );

      final aFirst = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      final bFirst = await cache.getDescendantLocationsCached(
        operatorId: _opB,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );

      expect(aFirst.single.locationId, equals('loc-A'));
      expect(bFirst.single.locationId, equals('loc-B'));

      // Second read for each operator: both HIT, no third round-trip.
      final aSecond = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      final bSecond = await cache.getDescendantLocationsCached(
        operatorId: _opB,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      expect(aSecond.single.locationId, equals('loc-A'));
      expect(bSecond.single.locationId, equals('loc-B'));
      expect(pool.transactions, hasLength(2));

      final stats = cache.statsSnapshot();
      expect(stats.hits, equals(2));
      expect(stats.misses, equals(2));
      expect(stats.size, equals(2));
    });
  });

  group('InheritanceDescendantCache — invalidation', () {
    test('invalidate(operator, scope) drops only that entry; next read MISSes',
        () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-1',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.east',
            'name': 'Store One',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );

      // Seed: warm two scopes for the same operator.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-y',
      );
      expect(pool.transactions, hasLength(2));

      // Invalidate only the ou-x entry.
      cache.invalidate(operatorId: _opA, scopeOrgUnitId: 'ou-x');

      // ou-x re-reads (3rd tx); ou-y still hits.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-y',
      );
      expect(pool.transactions, hasLength(3));

      final stats = cache.statsSnapshot();
      expect(stats.invalidations, equals(1));
      // 2 misses initial + 1 miss post-invalidate, 1 hit on ou-y.
      expect(stats.misses, equals(3));
      expect(stats.hits, equals(1));
    });

    test('invalidate(operator) with null scope drops every entry for that '
        'operator but leaves other operators untouched', () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-x',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.x',
            'name': 'Store X',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );

      // Two scopes for A, one for B.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-y',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opB,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      expect(cache.statsSnapshot().size, equals(3));

      cache.invalidate(operatorId: _opA);

      final stats = cache.statsSnapshot();
      // 2 entries dropped (both _opA scopes); _opB's entry remains.
      expect(stats.invalidations, equals(2));
      expect(stats.size, equals(1));

      // _opB's entry still HITs.
      await cache.getDescendantLocationsCached(
        operatorId: _opB,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      // _opA's must MISS.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      // Initial 3 + 1 post-invalidate-A = 4 transactions.
      expect(pool.transactions, hasLength(4));
    });

    test('clear() drops every entry and bumps invalidations counter',
        () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-x',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.x',
            'name': 'Store X',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opB,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      expect(cache.statsSnapshot().size, equals(2));
      cache.clear();
      expect(cache.statsSnapshot().size, equals(0));
      expect(cache.statsSnapshot().invalidations, equals(2));
    });

    test('invalidating an absent key is a no-op (no counter bump)', () async {
      final pool = _RecordingPool();
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );
      cache.invalidate(operatorId: _opA, scopeOrgUnitId: 'ou-x');
      expect(cache.statsSnapshot().invalidations, equals(0));
    });
  });

  group('InheritanceDescendantCache — edge cases', () {
    test('empty descendant list IS cached (operator has zero locations '
        'under the scope is a real read shape, not a missing row)',
        () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );
      final first = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-empty',
      );
      final second = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-empty',
      );
      expect(first, isEmpty);
      expect(second, isEmpty);
      // Only one round-trip — second call HITs.
      expect(pool.transactions, hasLength(1));
      expect(cache.statsSnapshot().hits, equals(1));
    });

    test('null scope is a distinct key from a real scope id', () async {
      final pool = _RecordingPool();
      pool.descendantLocationsByCallIndex = <List<PostgresRow>>[
        // call 0: scope null → returns loc-root
        const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-root',
            'parent_org_unit_id': 'ou-root',
            'org_unit_path': 'demo',
            'name': 'Root Store',
          },
        ],
        // call 1: scope ou-x → returns loc-x
        const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-x',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.east',
            'name': 'East Store',
          },
        ],
      ];
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );

      final nullScope = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
      );
      final realScope = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );

      // Both MISS — two distinct keys, two transactions.
      expect(pool.transactions, hasLength(2));
      expect(nullScope.single.locationId, equals('loc-root'));
      expect(realScope.single.locationId, equals('loc-x'));

      // Re-read each — both HIT.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      expect(pool.transactions, hasLength(2));
      final stats = cache.statsSnapshot();
      expect(stats.size, equals(2));
      expect(stats.hits, equals(2));
    });

    test('loader exception does NOT poison the cache — next call retries',
        () async {
      // First call throws inside the SELECT; second call returns
      // normally. The pool fans out per-transaction so we can switch
      // behavior between calls without mutating shared state.
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-x',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.east',
            'name': 'Store X',
          },
        ],
      );
      pool.throwOnDescendantQueryByCallIndex = <bool>[true, false];
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
      );

      await expectLater(
        cache.getDescendantLocationsCached(
          operatorId: _opA,
          locationId: _locA,
          scopeOrgUnitId: 'ou-x',
        ),
        throwsA(isA<StateError>()),
      );
      // Cache is empty after the failed loader: nothing stored.
      expect(cache.statsSnapshot().size, equals(0));

      // Retry — succeeds, MISS path lights up, entry stored.
      final ok = await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );
      expect(ok, hasLength(1));
      expect(cache.statsSnapshot().size, equals(1));
    });
  });

  group('InheritanceDescendantCache — LRU eviction', () {
    test('exceeding maxEntries evicts the oldest entry first; recent HITs '
        'survive', () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-x',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.x',
            'name': 'Store X',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
        maxEntries: 2,
      );

      // Fill: scope-1, scope-2.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-1',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-2',
      );
      expect(cache.statsSnapshot().size, equals(2));
      expect(cache.statsSnapshot().evictions, equals(0));

      // Insert scope-3 → evicts scope-1 (oldest).
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-3',
      );
      expect(cache.statsSnapshot().size, equals(2));
      expect(cache.statsSnapshot().evictions, equals(1));

      // scope-1 now MISSes (was evicted); scope-2 still HITs.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-2',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-1',
      );
      // Transactions: scope-1 (1) + scope-2 (1) + scope-3 (1) +
      // scope-1 re-read (1) = 4. scope-2 second call was a HIT.
      expect(pool.transactions, hasLength(4));
      expect(cache.statsSnapshot().hits, equals(1));
    });

    test('LRU bump: a hit moves the entry to the tail so a later insert '
        'evicts the OTHER entry instead', () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-x',
            'parent_org_unit_id': 'ou-x',
            'org_unit_path': 'demo.x',
            'name': 'Store X',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));
      final cache = InheritanceDescendantCache(
        repository: repo,
        enabled: true,
        maxEntries: 2,
      );

      // Fill: scope-1, scope-2.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-1',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-2',
      );

      // HIT scope-1 → moves to tail; scope-2 becomes oldest.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-1',
      );
      expect(cache.statsSnapshot().hits, equals(1));

      // Insert scope-3 → evicts scope-2 (now the oldest), not scope-1.
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-3',
      );

      // scope-1 still HITs; scope-2 MISSes (evicted).
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-1',
      );
      await cache.getDescendantLocationsCached(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'scope-2',
      );

      // Transactions: scope-1, scope-2, scope-3, scope-2 re-read = 4.
      expect(pool.transactions, hasLength(4));
      // scope-1 was HIT twice (3rd and 6th calls).
      expect(cache.statsSnapshot().hits, equals(2));
    });
  });

  group('InheritanceDescendantCacheKey value semantics', () {
    test('equality is by (operatorId, scopeOrgUnitId) tuple', () {
      const a = InheritanceDescendantCacheKey(
        operatorId: 'op-a',
        scopeOrgUnitId: 'scope-x',
      );
      const b = InheritanceDescendantCacheKey(
        operatorId: 'op-a',
        scopeOrgUnitId: 'scope-x',
      );
      const c = InheritanceDescendantCacheKey(
        operatorId: 'op-b',
        scopeOrgUnitId: 'scope-x',
      );
      const d = InheritanceDescendantCacheKey(
        operatorId: 'op-a',
        scopeOrgUnitId: null,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });
  });
}

// ── Test doubles ────────────────────────────────────────────────────

class _MutableClock {
  _MutableClock(this._now);
  DateTime _now;
  DateTime now() => _now;
  void advance(Duration d) {
    _now = _now.add(d);
  }
}

// ── Recording pool / transaction (mirrors inheritance_tree_repository_test) ──

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    this.descendantLocationsReturning,
    List<List<PostgresRow>>? descendantLocationsByCallIndex,
    this.throwOnDescendantQuery = false,
    this.txIndex = 0,
  }) : _byCall = descendantLocationsByCallIndex;

  final List<PostgresRow>? descendantLocationsReturning;
  final List<List<PostgresRow>>? _byCall;
  final bool throwOnDescendantQuery;
  final int txIndex;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    final lowered = sql.toLowerCase();
    if (lowered.contains('from locations') ||
        lowered.contains('from public.locations') ||
        (lowered.contains('from locations l') &&
            lowered.contains('l.org_unit_path'))) {
      if (throwOnDescendantQuery) {
        throw StateError('simulated DB outage');
      }
      if (_byCall != null && txIndex < _byCall.length) {
        return _byCall[txIndex];
      }
      return descendantLocationsReturning ?? const <PostgresRow>[];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
  }
}

class _RecordingPool implements PostgresPool {
  _RecordingPool({
    this.descendantLocationsReturning,
  });

  final List<PostgresRow>? descendantLocationsReturning;
  List<List<PostgresRow>>? descendantLocationsByCallIndex;
  List<bool>? throwOnDescendantQueryByCallIndex;

  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final idx = transactions.length;
    final shouldThrow = throwOnDescendantQueryByCallIndex != null &&
            idx < throwOnDescendantQueryByCallIndex!.length
        ? throwOnDescendantQueryByCallIndex![idx]
        : false;
    final tx = _RecordingTransaction(
      descendantLocationsReturning: descendantLocationsReturning,
      descendantLocationsByCallIndex: descendantLocationsByCallIndex,
      throwOnDescendantQuery: shouldThrow,
      txIndex: idx,
    );
    transactions.add(tx);
    return tx;
  }
}
