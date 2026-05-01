// Phase 9.UX.7 - in-memory Idempotency-Key cache for auth-route writes.
//
// The auth password routes (change / reset request / reset confirm)
// promise idempotency per the Phase 11A.10 proxy contract: every
// write is idempotent, retries return the prior result. The advisor
// LLM path uses `proxy_requests` keyed by Idempotency-Key. The auth
// routes are non-LLM and don't carry usage telemetry, so they get
// this lighter-weight cache scoped per route.
//
// Scope:
//   - In-memory, per-proxy-instance. The proxy is single-node by
//     deployment posture; horizontally-scaling later means this
//     cache promotes to a shared store (Postgres/Redis), not that
//     idempotency is dropped.
//   - Concurrency: a second concurrent request with the same key
//     awaits the in-flight result instead of running the work
//     twice. This matches the "exactly once effect" promise even
//     when a flaky client retries before the first response lands.
//   - TTL: cached entries expire after [ttl]; long enough that a
//     reasonable retry window (proxy timeout + client retry) hits
//     the replay path, short enough that the cache does not leak
//     unbounded memory under load.
//   - Bounded: the reset routes are unauthenticated and accept
//     caller-controlled keys, so an attacker can spam unique keys.
//     [maxEntries] caps the store and evicts LRU on overflow so a
//     unique-key flood degrades to a missed-dedupe penalty for the
//     evicted client instead of an OOM for the proxy.

import 'dart:async';
import 'dart:collection';

class CachedProxyResponse {
  CachedProxyResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

class _CacheEntry {
  _CacheEntry({required this.response, required this.expiresAt});

  final CachedProxyResponse response;
  final DateTime expiresAt;
}

class ProxyAuthIdempotencyCache {
  ProxyAuthIdempotencyCache({
    this.ttl = const Duration(hours: 1),
    this.maxEntries = 10000,
    DateTime Function()? now,
  })  : assert(maxEntries > 0, 'maxEntries must be positive'),
        _now = now ?? DateTime.now;

  final Duration ttl;

  /// Hard cap on cached entries. The reset routes are public, so an
  /// attacker can otherwise grow the map unboundedly within the TTL
  /// window by sending many distinct keys.
  final int maxEntries;

  final DateTime Function() _now;

  /// LinkedHashMap preserves insertion order, which we use as a
  /// FIFO eviction order. We re-insert on cache hit to promote the
  /// entry, giving an LRU eviction policy on overflow.
  final LinkedHashMap<String, _CacheEntry> _store =
      LinkedHashMap<String, _CacheEntry>();
  final Map<String, Future<CachedProxyResponse>> _inflight =
      <String, Future<CachedProxyResponse>>{};

  /// Composite-key delimiter. Using ` ` keeps the source file
  /// text-friendly (so `rg`/IDE tooling does not treat it as binary)
  /// while still being a byte that cannot appear inside a route path
  /// or a base64/hex idempotency key.
  static const String _keyDelimiter = ' ';

  /// Runs [compute] and caches its result under [(route, key)], or
  /// replays the cached response when the same key arrives a
  /// second time. Concurrent calls with the same key wait on the
  /// first one rather than racing.
  Future<CachedProxyResponse> runOrReplay({
    required String route,
    required String key,
    required Future<CachedProxyResponse> Function() compute,
  }) {
    _gc();
    final composite = '$route$_keyDelimiter$key';
    final cached = _store.remove(composite);
    if (cached != null) {
      // Re-insert at the tail so frequently-replayed entries survive
      // longer under LRU eviction than untouched ones.
      _store[composite] = cached;
      return Future<CachedProxyResponse>.value(cached.response);
    }
    final inflight = _inflight[composite];
    if (inflight != null) return inflight;

    final future = _runAndCache(composite, compute);
    _inflight[composite] = future;
    return future;
  }

  Future<CachedProxyResponse> _runAndCache(
    String composite,
    Future<CachedProxyResponse> Function() compute,
  ) async {
    try {
      final result = await compute();
      // Standard Idempotency-Key semantic: cache 2xx (success) and
      // terminal 4xx (operator must change input before the next
      // submit anyway, so a replay costs nothing).
      // Do NOT cache 5xx — those are transient server-side failures
      // (e.g., Postgres lookup blip) and the operator's same-key
      // retry must be allowed to succeed when infrastructure
      // recovers, not be locked to the cached 503.
      // Do NOT cache 429 either — rate-limit responses inherently
      // mean "the same request will succeed if retried later", so
      // pinning the key to a 429 for the full TTL would defeat the
      // wait-then-retry semantic the response is asking for.
      if (_shouldCache(result.statusCode)) {
        _store[composite] = _CacheEntry(
          response: result,
          expiresAt: _now().add(ttl),
        );
        _evictOverflow();
      }
      return result;
    } finally {
      _inflight.remove(composite);
    }
  }

  static bool _shouldCache(int statusCode) {
    if (statusCode == 429) return false;
    return statusCode >= 200 && statusCode < 500;
  }

  void _gc() {
    final cutoff = _now();
    _store.removeWhere((_, entry) => entry.expiresAt.isBefore(cutoff));
  }

  void _evictOverflow() {
    while (_store.length > maxEntries) {
      // LinkedHashMap.keys.first is the oldest insertion (or oldest
      // promoted hit) — drop it.
      _store.remove(_store.keys.first);
    }
  }
}
