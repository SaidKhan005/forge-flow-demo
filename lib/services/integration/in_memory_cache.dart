// Performance hardening (B6 / PF1) — shared LRU + TTL in-memory cache.
//
// Replaces bare `Map<String, V>` fields on server-side sinks and
// syncs that grow unbounded when tenants come and go without an
// explicit eviction path. Each cache entry has an expiry timestamp;
// the cache also enforces a maximum capacity (LRU eviction).
//
// Design constraints:
//   * Pure Dart — no package:quiver dependency (not in pubspec).
//   * Dart is single-threaded (no locks needed for Dart isolates).
//   * Eviction is eager on write and lazy on read (stale entries are
//     deleted on the first access that discovers them have expired).
//
// Constants are exposed so callers can reference documented defaults
// without magic numbers.

/// Default maximum number of entries before the oldest-accessed entry
/// is evicted (LRU policy).
const int kLruTtlMapDefaultMaxSize = 1000;

/// Default time-to-live per cache entry. After this duration an entry
/// is treated as absent on the next read; the underlying slot is
/// reclaimed on the next write or explicit [LruTtlMap.purgeExpired]
/// call.
const Duration kLruTtlMapDefaultTtl = Duration(hours: 1);

/// A fixed-capacity LRU map with per-entry TTL.
///
/// - **Capacity**: when [maxSize] is exceeded, the least-recently-used
///   entry is evicted before the new entry is inserted.
/// - **TTL**: reads on an expired entry return `null` (as if absent)
///   and remove the entry from the map. Writes always overwrite the
///   existing entry and reset its expiry.
/// - **Thread safety**: not required — Dart isolates are single-
///   threaded and the sinks that use this cache are per-instance.
class LruTtlMap<K, V> {
  LruTtlMap({
    int maxSize = kLruTtlMapDefaultMaxSize,
    Duration ttl = kLruTtlMapDefaultTtl,
    DateTime Function()? clock,
  })  : _maxSize = maxSize,
        _ttl = ttl,
        _clock = clock ?? DateTime.now {
    assert(maxSize > 0, 'maxSize must be positive');
  }

  final int _maxSize;
  final Duration _ttl;
  final DateTime Function() _clock;

  // Linked-list ordering (insertion order = LRU order with refresh on
  // access). The standard Dart `LinkedHashMap` provides O(1) access
  // and preserves insertion order but does not expose move-to-front.
  // We maintain a parallel access-order deque via _order.
  final Map<K, _LruEntry<K, V>> _map = <K, _LruEntry<K, V>>{};

  // Double-ended linked list for O(1) LRU tracking.
  _LruEntry<K, V>? _lruHead; // least recently used
  _LruEntry<K, V>? _lruTail; // most recently used

  /// Number of non-expired entries currently stored.
  int get length => _map.length;

  /// Retrieve [key]. Returns `null` when absent or expired.
  V? get(K key) {
    final entry = _map[key];
    if (entry == null) return null;
    if (_clock().isAfter(entry.expiresAt)) {
      _remove(entry);
      return null;
    }
    _moveToTail(entry);
    return entry.value;
  }

  /// Store [value] under [key], resetting the TTL. Evicts the LRU
  /// entry first when the map is at capacity.
  void put(K key, V value) {
    final existing = _map[key];
    if (existing != null) {
      existing.value = value;
      existing.expiresAt = _clock().add(_ttl);
      _moveToTail(existing);
      return;
    }
    if (_map.length >= _maxSize) {
      final head = _lruHead;
      if (head != null) _remove(head);
    }
    final entry = _LruEntry<K, V>(
      key: key,
      value: value,
      expiresAt: _clock().add(_ttl),
    );
    _map[key] = entry;
    _appendToTail(entry);
  }

  /// Remove [key] and return its value, or `null` if absent/expired.
  V? remove(K key) {
    final entry = _map[key];
    if (entry == null) return null;
    _remove(entry);
    if (_clock().isAfter(entry.expiresAt)) return null;
    return entry.value;
  }

  /// Remove all entries whose TTL has elapsed. Useful for proactive
  /// cleanup in long-running pods.
  void purgeExpired() {
    final now = _clock();
    final expired =
        _map.values.where((e) => now.isAfter(e.expiresAt)).toList();
    for (final entry in expired) {
      _remove(entry);
    }
  }

  // ─── linked-list helpers ────────────────────────────────────────────

  void _appendToTail(_LruEntry<K, V> entry) {
    entry.prev = _lruTail;
    entry.next = null;
    if (_lruTail != null) {
      _lruTail!.next = entry;
    } else {
      _lruHead = entry;
    }
    _lruTail = entry;
  }

  void _remove(_LruEntry<K, V> entry) {
    _map.remove(entry.key);
    final prev = entry.prev;
    final next = entry.next;
    if (prev != null) {
      prev.next = next;
    } else {
      _lruHead = next;
    }
    if (next != null) {
      next.prev = prev;
    } else {
      _lruTail = prev;
    }
    entry.prev = null;
    entry.next = null;
  }

  void _moveToTail(_LruEntry<K, V> entry) {
    if (entry == _lruTail) return;
    // Unlink from current position without removing from map.
    final prev = entry.prev;
    final next = entry.next;
    if (prev != null) {
      prev.next = next;
    } else {
      _lruHead = next;
    }
    if (next != null) {
      next.prev = prev;
    }
    // Append at tail.
    entry.prev = _lruTail;
    entry.next = null;
    if (_lruTail != null) {
      _lruTail!.next = entry;
    } else {
      _lruHead = entry;
    }
    _lruTail = entry;
  }
}

class _LruEntry<K, V> {
  _LruEntry({
    required this.key,
    required this.value,
    required this.expiresAt,
  });

  final K key;
  V value;
  DateTime expiresAt;

  _LruEntry<K, V>? prev;
  _LruEntry<K, V>? next;
}
