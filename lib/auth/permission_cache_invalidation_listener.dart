// Code-health PCACHE-FANOUT — cross-instance permission cache fan-out.
//
// Each Cloud Run proxy instance keeps its own in-process
// [PermissionCache] (see `lib/auth/permission_cache.dart`). Without a
// fan-out signal, when an admin role-change commits on instance A,
// other instances keep serving cached `(user, rolesVersion)` snapshots
// until the per-entry TTL (default 60s) expires. The cache key already
// includes `roles_version`, so a *fresh* request on another instance
// after a bump naturally misses; the gap is requests that re-present
// the OLD `roles_version` (e.g. a stale Firebase custom claim) plus the
// belt-and-braces case where a future write path calls `invalidateUser`
// directly and needs every instance to drop the entry.
//
// The fix mirrors the Phase 10a outbox listener pattern
// (`lib/infrastructure/persistence/postgres/outbox_notification_listener.dart`):
// a small in-process subscriber to a Postgres NOTIFY channel that
// translates each notification into `cache.invalidateUser(userId)` on
// the local instance.
//
// Channel contract (declared by convention — see
// `db/migrations/202605080500_permission_cache_invalidation_channel.sql`):
//
//   * channel name : `permission_cache_invalidate`
//   * payload      : JSON object with at least `user_id: <text>`
//                    Optional `operator_id`, `location_id` for future
//                    scoped invalidation. Today the cache invalidates
//                    by user only (`PermissionCache.invalidateUser`).
//
// Producers are added incrementally as each permission-write site
// (`lib/infrastructure/persistence/postgres/repositories/user_roles_repository.dart`,
// `users_repository.dart`, etc.) is touched in a follow-up; emitting
// `pg_notify('permission_cache_invalidate', json_build_object(...))`
// after the role/grant change commits is sufficient. The listener seam
// is wired up first so the receiver side is ready before producers
// start firing.
//
// Per the outbox contract reminder, NOTIFY is best-effort: Postgres
// drops notifications under connection failures or queue pressure. The
// per-entry TTL on [PermissionCache] is the catch-all — it bounds
// staleness to the TTL window even when a NOTIFY is dropped.

import 'dart:async';
import 'dart:convert';

import 'permission_cache.dart';

/// A single decoded `permission_cache_invalidate` notification. Today
/// only [userId] is honored; the optional scope fields are accepted
/// for forward-compatibility with future per-(operator, location)
/// invalidation.
class PermissionCacheInvalidation {
  const PermissionCacheInvalidation({
    required this.userId,
    this.operatorId,
    this.locationId,
  });

  /// `users.id` to invalidate across the local cache.
  final String userId;

  /// Optional — currently unused by the cache but parsed so producers
  /// can include it without a wire-format break.
  final String? operatorId;

  /// Optional — currently unused by the cache but parsed so producers
  /// can include it without a wire-format break.
  final String? locationId;

  static PermissionCacheInvalidation fromPayload(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw const FormatException(
        'permission_cache_invalidate payload was not a JSON object',
      );
    }
    final userId = decoded['user_id'];
    if (userId is! String || userId.isEmpty) {
      throw const FormatException(
        'permission_cache_invalidate payload missing user_id',
      );
    }
    String? readOptional(Object? value) {
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return PermissionCacheInvalidation(
      userId: userId,
      operatorId: readOptional(decoded['operator_id']),
      locationId: readOptional(decoded['location_id']),
    );
  }
}

/// Source of `permission_cache_invalidate` notifications. The
/// production binding holds a dedicated `package:postgres` connection
/// and translates payloads via [PermissionCacheInvalidation.fromPayload];
/// tests inject a fake that pushes raw payloads onto the stream.
abstract class PermissionCacheInvalidationSource {
  /// Broadcast stream of decoded notifications. Subscribers attach via
  /// [PermissionCacheInvalidationListener.start].
  Stream<PermissionCacheInvalidation> get notifications;

  /// Start LISTENing on the underlying connection. Idempotent.
  Future<void> start();

  /// Stop LISTENing and tear down resources. Not restartable.
  Future<void> stop();
}

/// Wires a [PermissionCacheInvalidationSource] up to a local
/// [PermissionCache] so each NOTIFY drops the matching `userId` from
/// the in-memory cache on this instance.
///
/// The cache's external API is unchanged — this listener only consumes
/// the existing `invalidateUser(String)` method.
class PermissionCacheInvalidationListener {
  PermissionCacheInvalidationListener({
    required PermissionCache cache,
    required PermissionCacheInvalidationSource source,
  }) : _cache = cache,
       _source = source;

  final PermissionCache _cache;
  final PermissionCacheInvalidationSource _source;

  StreamSubscription<PermissionCacheInvalidation>? _subscription;
  bool _started = false;

  /// Subscribe to [source] notifications and start invalidating the
  /// local [PermissionCache] on each event. Idempotent — repeated calls
  /// after the first are no-ops.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _source.start();
    _subscription = _source.notifications.listen(
      _handleInvalidation,
      onError: _handleError,
    );
  }

  /// Cancel the subscription and stop the underlying source. After
  /// [stop], calling [start] again is a no-op — create a new instance.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _source.stop();
  }

  void _handleInvalidation(PermissionCacheInvalidation event) {
    _cache.invalidateUser(event.userId);
  }

  void _handleError(Object error, StackTrace stack) {
    // Swallow stream errors — a transient connection blip on the
    // dedicated LISTEN connection must not propagate up to take down
    // the proxy. The cache's per-entry TTL bounds staleness while a
    // supervisor (Phase 10a-style) restarts the listener. Logging is
    // intentionally deferred to avoid echoing potentially malformed
    // payloads here; the supervisor owns observability.
  }
}
