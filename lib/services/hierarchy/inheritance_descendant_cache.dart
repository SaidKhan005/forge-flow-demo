// Slice L_A2 — Descendant-set cache for the Inheritance Tree.
//
// Performance projection on top of L_A1's
// [OrgUnitsRepository.getDescendantLocations]. The underlying query
// is already O(log N) via the GIST index on `locations.org_unit_path`
// added in `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql`,
// so the cache is a latency optimisation — not a structural prereq.
// Future consumers (B6 benchmark inheritance, B8 audit-log hierarchy
// filter) call this primitive instead of the repository directly so
// "every location under this scope" becomes a single in-process map
// lookup on the common hit path.
//
// Storage shape — Option α (app-level memoization) per operator's
// 2026-05-13 L_A1 merge note: "anchor on existing GIST shape, frame
// caching as performance projection (not structural prereq)."
//
//   * Per-pod in-process cache keyed by (operator_id, scopeOrgUnitId?).
//   * Bounded TTL (default 60s) so stale reads after a hierarchy edit
//     self-heal even without explicit invalidation.
//   * Explicit [invalidate] seam for callers that mutate the hierarchy
//     and need the next read to see fresh data (B6/B8 write paths will
//     wire this).
//   * Bounded capacity (LRU) so a runaway tenant cannot grow the cache
//     without limit.
//   * Successful results only — empty descendant lists are cached
//     because an operator may legitimately have a scope with zero
//     locations; that is a real read shape, not a missing row.
//   * Loader exceptions are NEVER cached. A DB outage during cache
//     miss bubbles up to the caller and the next call re-attempts.
//
// HP #4 (per-operator isolation): the cache key is a record of
// `(operatorId, scopeOrgUnitId)`. There is no path by which a hit for
// operator A under scope S can ever satisfy a lookup from operator B
// under the same scope id. Cross-tenant isolation is asserted by tests.
//
// Determinism: a constructor-injected clock and an `enabled` flag let
// tests run with the cache OFF by default (so other repository tests
// stay deterministic), and let cache-specific tests advance time
// without real waits.
//
// Side-effect surface: zero. No I/O, no Flutter, no `package:postgres`.
// The lib/infrastructure layer owns the SQL; this service is pure
// Dart memoization sitting in front of it.

import '../../infrastructure/persistence/postgres/repositories/org_units_repository.dart';

/// Default time-to-live per cache entry. After this duration a read
/// treats the entry as absent and re-loads from the repository. Sized
/// to be short enough that an undirected hierarchy edit propagates
/// before the next benchmark/audit roll-up, and long enough that a
/// burst of consecutive reads from the same surface (e.g. a paginated
/// audit-log scroll) collapses to one DB round-trip.
const Duration kInheritanceDescendantCacheDefaultTtl = Duration(seconds: 60);

/// Default per-pod maximum number of cached scopes before the
/// least-recently-used entry is evicted. Sized so each cached scope
/// costs at most a few KB of heap and a single pod holding the V1
/// operator population fits comfortably.
const int kInheritanceDescendantCacheDefaultMaxEntries = 512;

/// Cache key. Two scopes from different operators with the same
/// `scopeOrgUnitId` are distinct entries — this is the per-operator
/// isolation guarantee.
class InheritanceDescendantCacheKey {
  const InheritanceDescendantCacheKey({
    required this.operatorId,
    required this.scopeOrgUnitId,
  });

  final String operatorId;

  /// Null when the caller wants every location under the operator's
  /// business root (matches the no-scope branch of
  /// [OrgUnitsRepository.getDescendantLocations]).
  final String? scopeOrgUnitId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is InheritanceDescendantCacheKey &&
            other.operatorId == operatorId &&
            other.scopeOrgUnitId == scopeOrgUnitId);
  }

  @override
  int get hashCode => Object.hash(operatorId, scopeOrgUnitId);

  @override
  String toString() {
    final scope = scopeOrgUnitId ?? '<business-root>';
    return 'InheritanceDescendantCacheKey($operatorId, scope=$scope)';
  }
}

/// Snapshot of cache statistics. Useful for the proxy's /health
/// observability surface (a future slice may project this onto a
/// gauge — out of scope for L_A2).
class InheritanceDescendantCacheStats {
  const InheritanceDescendantCacheStats({
    required this.hits,
    required this.misses,
    required this.invalidations,
    required this.evictions,
    required this.size,
  });

  final int hits;
  final int misses;
  final int invalidations;
  final int evictions;
  final int size;

  @override
  String toString() {
    return 'InheritanceDescendantCacheStats(hits=$hits, misses=$misses, '
        'invalidations=$invalidations, evictions=$evictions, size=$size)';
  }
}

/// In-process descendant-set cache. Wraps [OrgUnitsRepository] and
/// exposes a [getDescendantLocations] method whose signature mirrors
/// the repository's so consumers can swap one for the other.
class InheritanceDescendantCache {
  InheritanceDescendantCache({
    required OrgUnitsRepository repository,
    bool enabled = false,
    Duration ttl = kInheritanceDescendantCacheDefaultTtl,
    int maxEntries = kInheritanceDescendantCacheDefaultMaxEntries,
    DateTime Function()? clock,
  })  : _repository = repository,
        _enabled = enabled,
        _ttl = ttl,
        _maxEntries = maxEntries,
        _clock = clock ?? DateTime.now {
    if (maxEntries <= 0) {
      throw ArgumentError.value(
        maxEntries,
        'maxEntries',
        'must be positive — a non-positive cap would evict every entry on '
            'insert and defeat the cache entirely',
      );
    }
    if (ttl.isNegative || ttl == Duration.zero) {
      throw ArgumentError.value(
        ttl,
        'ttl',
        'must be a positive duration — a zero or negative TTL would expire '
            'every entry the moment it is written',
      );
    }
  }

  final OrgUnitsRepository _repository;
  final bool _enabled;
  final Duration _ttl;
  final int _maxEntries;
  final DateTime Function() _clock;

  // Insertion-order map doubles as LRU order: a hit re-inserts the
  // entry at the tail so it survives eviction. Dart's `Map` literal /
  // factory preserves insertion order per the language spec since
  // 2.7, and `LinkedHashMap` is the default; the explicit
  // `LinkedHashMap` import is unnecessary.
  final Map<InheritanceDescendantCacheKey, _CacheEntry> _entries =
      <InheritanceDescendantCacheKey, _CacheEntry>{};

  int _hits = 0;
  int _misses = 0;
  int _invalidations = 0;
  int _evictions = 0;

  /// Cache-aware variant of
  /// [OrgUnitsRepository.getDescendantLocations]. Falls through to the
  /// repository on miss / expiry / disabled. Successful results are
  /// stored under (operator_id, scope_org_unit_id); exceptions
  /// propagate without poisoning the cache.
  ///
  /// The [locationId] + optional [userId] arguments are threaded
  /// through to the repository for tenant-transaction SET LOCAL
  /// (RLS primary defense). They are NOT part of the cache key — a
  /// hit for operator A's scope S serves any caller who can already
  /// see operator A, because the cache value is per-tenant data the
  /// caller already had read permission to retrieve.
  Future<List<InheritanceTreeLocationRef>> getDescendantLocationsCached({
    required String operatorId,
    required String locationId,
    String? scopeOrgUnitId,
    String? userId,
  }) async {
    if (!_enabled) {
      _misses += 1;
      return _repository.getDescendantLocations(
        operatorId: operatorId,
        locationId: locationId,
        scopeOrgUnitId: scopeOrgUnitId,
        userId: userId,
      );
    }
    final key = InheritanceDescendantCacheKey(
      operatorId: operatorId,
      scopeOrgUnitId: scopeOrgUnitId,
    );
    final now = _clock();
    final existing = _entries[key];
    if (existing != null && now.isBefore(existing.expiresAt)) {
      // LRU bump: re-insert at tail so this entry survives eviction.
      _entries
        ..remove(key)
        ..[key] = existing;
      _hits += 1;
      return existing.value;
    }
    if (existing != null) {
      // Expired — drop before reloading so a load failure doesn't
      // leave a stale entry behind.
      _entries.remove(key);
    }
    final fresh = await _repository.getDescendantLocations(
      operatorId: operatorId,
      locationId: locationId,
      scopeOrgUnitId: scopeOrgUnitId,
      userId: userId,
    );
    _misses += 1;
    final immutable = List<InheritanceTreeLocationRef>.unmodifiable(fresh);
    _store(key, immutable);
    return immutable;
  }

  /// Invalidate cached entries for [operatorId]. When [scopeOrgUnitId]
  /// is supplied, only the exact `(operator, scope)` entry is dropped;
  /// when null, every entry for the operator is dropped.
  ///
  /// Callers MUST invoke this after any write that changes the
  /// descendant set of a scope — for V1 this means moves/suspends/
  /// deletes on `org_units` or `locations`. B6/B8 wire the call sites
  /// when they ship; L_A2 provides the seam.
  ///
  /// Honest seam note: because the cache is per-pod, this only
  /// invalidates the LOCAL pod. Other pods in the proxy fleet will
  /// continue serving stale reads until their entries expire via TTL.
  /// V1 single-pod posture makes this acceptable; multi-pod posture
  /// requires either a shorter TTL or a cross-pod fanout (deferred).
  void invalidate({required String operatorId, String? scopeOrgUnitId}) {
    if (scopeOrgUnitId != null) {
      final removed = _entries.remove(
        InheritanceDescendantCacheKey(
          operatorId: operatorId,
          scopeOrgUnitId: scopeOrgUnitId,
        ),
      );
      if (removed != null) _invalidations += 1;
      return;
    }
    final toRemove = <InheritanceDescendantCacheKey>[];
    for (final entry in _entries.entries) {
      if (entry.key.operatorId == operatorId) {
        toRemove.add(entry.key);
      }
    }
    for (final key in toRemove) {
      _entries.remove(key);
    }
    _invalidations += toRemove.length;
  }

  /// Drop every entry. Useful for tests + admin debug paths.
  void clear() {
    final count = _entries.length;
    _entries.clear();
    _invalidations += count;
  }

  /// Cache observability snapshot.
  InheritanceDescendantCacheStats statsSnapshot() {
    return InheritanceDescendantCacheStats(
      hits: _hits,
      misses: _misses,
      invalidations: _invalidations,
      evictions: _evictions,
      size: _entries.length,
    );
  }

  /// Whether the cache is currently serving hits. Tests inspect this
  /// to assert default-off posture.
  bool get isEnabled => _enabled;

  void _store(
    InheritanceDescendantCacheKey key,
    List<InheritanceTreeLocationRef> value,
  ) {
    // Eager LRU eviction: when at capacity, drop the oldest (head of
    // the insertion-order map) before inserting the new entry. The
    // freshly-inserted entry lands at the tail.
    while (_entries.length >= _maxEntries) {
      final firstKey = _entries.keys.first;
      _entries.remove(firstKey);
      _evictions += 1;
    }
    _entries[key] = _CacheEntry(
      value: value,
      expiresAt: _clock().add(_ttl),
    );
  }
}

class _CacheEntry {
  _CacheEntry({
    required this.value,
    required this.expiresAt,
  });

  final List<InheritanceTreeLocationRef> value;
  final DateTime expiresAt;
}
