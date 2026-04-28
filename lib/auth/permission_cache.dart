// Phase 9.6 - Permission cache.
//
// In-process LRU cache keyed by `(userId, rolesVersion)` with a
// short TTL (default 60s). The cache hits when the same user comes
// back inside the TTL with the same roles_version; misses fall
// through to a resolver lookup which the caller wires.
//
// Cache invalidation is implicit: when an admin role-change bumps
// `users.roles_version`, the next request from that user has a
// new key and never reads the old entry. The TTL is a safety net
// for: (a) edits the proxy missed (e.g. roles_version not yet
// propagated), and (b) memory pressure (LRU bounds the cache size).
//
// Memorystore / shared cache is deferred until ~50k MAU per the
// plan. For a single proxy instance the in-process LRU is plenty.

import 'permission_effect.dart';

/// One cached permission snapshot for a single (userId, rolesVersion)
/// pair. The snapshot is the full resolved map at evaluation time —
/// callers ask for keys via [snapshot] and never re-resolve until
/// the entry expires or roles_version bumps.
class PermissionSnapshot {
  PermissionSnapshot({
    required this.userId,
    required this.rolesVersion,
    required this.operatorId,
    required this.locationId,
    required this.evaluatedAt,
    required this.entries,
  });

  final String userId;
  final int rolesVersion;
  final String operatorId;
  final String locationId;
  final DateTime evaluatedAt;
  final Map<String, PermissionEffect> entries;

  /// Returns the resolved effect for [permissionKey], defaulting to
  /// [PermissionEffect.deny] when the key is not present (no allow
  /// rule matched).
  PermissionEffect effectFor(String permissionKey) {
    return entries[permissionKey] ?? PermissionEffect.deny;
  }

  bool isExpiredAt(DateTime now, Duration ttl) {
    return now.difference(evaluatedAt) >= ttl;
  }
}

class PermissionCache {
  PermissionCache({
    int maxEntries = 1000,
    Duration ttl = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _maxEntries = maxEntries,
       _ttl = ttl,
       _now = now ?? DateTime.now;

  final int _maxEntries;
  final Duration _ttl;
  final DateTime Function() _now;

  // LinkedHashMap preserves insertion order; we keep the most
  // recently used entry at the back via remove + put on hit.
  final Map<_CacheKey, PermissionSnapshot> _entries =
      <_CacheKey, PermissionSnapshot>{};

  int hitCount = 0;
  int missCount = 0;
  int evictionCount = 0;

  /// Returns the cached snapshot for [userId] + [rolesVersion] +
  /// [operatorId] + [locationId] iff one is fresh; null otherwise.
  ///
  /// A roles_version mismatch counts as a miss — the entry stays
  /// in the cache temporarily and gets bumped out by LRU pressure
  /// (or replaced by a put with the new version).
  PermissionSnapshot? read({
    required String userId,
    required int rolesVersion,
    required String operatorId,
    required String locationId,
  }) {
    final key = _CacheKey(
      userId: userId,
      rolesVersion: rolesVersion,
      operatorId: operatorId,
      locationId: locationId,
    );
    final existing = _entries.remove(key);
    if (existing == null) {
      missCount += 1;
      return null;
    }
    if (existing.isExpiredAt(_now(), _ttl)) {
      missCount += 1;
      return null;
    }
    _entries[key] = existing; // bump to MRU position
    hitCount += 1;
    return existing;
  }

  /// Stores [snapshot]. Drops the LRU entry if the cache is full.
  void put(PermissionSnapshot snapshot) {
    final key = _CacheKey(
      userId: snapshot.userId,
      rolesVersion: snapshot.rolesVersion,
      operatorId: snapshot.operatorId,
      locationId: snapshot.locationId,
    );
    _entries.remove(key);
    if (_entries.length >= _maxEntries) {
      final firstKey = _entries.keys.first;
      _entries.remove(firstKey);
      evictionCount += 1;
    }
    _entries[key] = snapshot;
  }

  /// Drops every cached snapshot for [userId]. Called by the proxy
  /// after an admin role change, so the user's next request never
  /// reads a stale snapshot even if the bump-and-read path races.
  void invalidateUser(String userId) {
    _entries.removeWhere((key, _) => key.userId == userId);
  }

  /// Drops everything. Used in tests + on roles catalog reseed.
  void clear() {
    _entries.clear();
  }

  int get length => _entries.length;
}

class _CacheKey {
  const _CacheKey({
    required this.userId,
    required this.rolesVersion,
    required this.operatorId,
    required this.locationId,
  });

  final String userId;
  final int rolesVersion;
  final String operatorId;
  final String locationId;

  @override
  bool operator ==(Object other) {
    return other is _CacheKey &&
        other.userId == userId &&
        other.rolesVersion == rolesVersion &&
        other.operatorId == operatorId &&
        other.locationId == locationId;
  }

  @override
  int get hashCode =>
      Object.hash(userId, rolesVersion, operatorId, locationId);
}
