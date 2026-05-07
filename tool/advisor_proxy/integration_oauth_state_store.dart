// Phase 8 — Operator-facing OAuth CSRF state store.
//
// Backs the new `/v1/integrations/oauth/<vendor>/begin` and
// `/v1/integrations/oauth/<vendor>/callback` routes (see
// `integration_oauth_routes.dart`).
//
// Lifecycle:
//
//   1. The begin route mints a state token (UUIDv4 prefix +
//      `crypto.Random.secure()` bytes hex-encoded), stores a row with
//      a 10-minute TTL via [issue], and hands the operator's browser
//      the vendor authorize URL with the token embedded as
//      `&state=...`.
//
//   2. The vendor consent flow bounces the operator's browser to
//      `<callback>?code=...&state=...`. The callback route calls
//      [consume] inside a tenant-scoped transaction, which:
//        * looks up the token row,
//        * validates `expires_at > now()` (else `expired`),
//        * validates `consumed_at is null` (else `already_consumed`),
//        * validates the inbound (operator_id, location_id, vendor_id)
//          tuple matches the row (else `tuple_mismatch`),
//        * stamps `consumed_at = now()`,
//        * returns the row contents to the route so the per-vendor
//          token exchanger can swap the code for a token bundle.
//
//   3. Expired rows linger until [pruneExpired] is invoked. V1 ships
//      this as an opportunistic call from the begin path; a cron
//      sweep is a Production1 follow-up.
//
// Hard Promise alignment:
//
//   * HP #4 (per-operator isolation). Every read + write rides the
//     tenant-scoped pool via `TenantTransactionWrapper.runInTenantContext`
//     so the SET LOCAL chain pins the per-tenant RLS policy. The
//     [consume] path also re-checks the (operator, location, vendor)
//     tuple in application code as defense in depth.
//
//   * HP #7 (server-side secrets). The state token is the only
//     piece that ever crosses the wire to the operator's browser.
//     The PKCE verifier (when used) stays in the database and is
//     only ever read server-side.
//
// V1 lean cuts (locked 2026-05-03 / project_v1_lean_cut_2_2026_05_03):
//
//   * No advisory lock on the consume path. Postgres' UPDATE ... WHERE
//     consumed_at IS NULL ... RETURNING * is atomic; a duplicate
//     callback returns zero rows on the second consume and the route
//     surfaces `already_consumed`.
//
//   * No metric emission for the prune sweep. The new
//     `connector_oauth_state` table is small enough that grep over
//     `proxy.oauth_state.expired` is the V1 visibility surface.

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

/// A row in `public.connector_oauth_state` after the state token has
/// been validated by [IntegrationOAuthStateStore.consume].
class IntegrationOAuthStateRecord {
  const IntegrationOAuthStateRecord({
    required this.stateToken,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.redirectUri,
    required this.createdAt,
    required this.expiresAt,
    required this.consumedAt,
    this.pkceVerifier,
    this.actorUserId,
    this.module,
  });

  final String stateToken;
  final String operatorId;
  final String locationId;
  final String vendorId;
  final String redirectUri;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime consumedAt;
  final String? pkceVerifier;
  final String? actorUserId;
  final String? module;
}

/// Reasons [IntegrationOAuthStateStore.consume] can refuse a state
/// token. The route maps each to a 400 Bad Request with the reason
/// in the redirect target's `?reason=...` query string.
enum IntegrationOAuthStateConsumeFailureReason {
  notFound,
  expired,
  alreadyConsumed,
  tupleMismatch,
}

/// Thrown by [IntegrationOAuthStateStore.consume] when the state
/// token is rejected. The route catches this, surfaces a structured
/// error response, and never proceeds to the vendor token exchange.
class IntegrationOAuthStateConsumeFailure implements Exception {
  const IntegrationOAuthStateConsumeFailure(this.reason);

  final IntegrationOAuthStateConsumeFailureReason reason;

  @override
  String toString() =>
      'IntegrationOAuthStateConsumeFailure(reason=${reason.name})';
}

/// Production-or-test seam. Production wires a Postgres-backed impl
/// via [PostgresIntegrationOAuthStateStore]; tests pass an in-memory
/// fake.
abstract class IntegrationOAuthStateStore {
  /// Persist a freshly minted state token and return when the row is
  /// committed. The route calls this BEFORE redirecting the browser
  /// to the vendor's authorize URL.
  Future<void> issue({
    required String stateToken,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String redirectUri,
    required Duration ttl,
    String? pkceVerifier,
    String? actorUserId,
    String? module,
  });

  /// Validate and consume a state token returned by the vendor
  /// callback. Throws [IntegrationOAuthStateConsumeFailure] on every
  /// failure path. On success returns the validated row so the route
  /// can pass `(operator, location, vendor)` through to the per-vendor
  /// token-exchange step.
  Future<IntegrationOAuthStateRecord> consume({
    required String stateToken,
    required String operatorId,
    required String locationId,
    required String vendorId,
  });

  /// Best-effort prune of expired rows for the given operator/location.
  /// V1 calls this opportunistically from the begin path; a future
  /// cron sweep can call [pruneExpiredAcrossTenants] via the admin
  /// pool when traffic justifies it. Returns the number of deleted
  /// rows.
  Future<int> pruneExpired({
    required String operatorId,
    required String locationId,
  });
}

/// Postgres-backed [IntegrationOAuthStateStore]. All reads + writes
/// run through the tenant-scoped wrapper so the per-tenant RLS
/// policy on `public.connector_oauth_state` admits every row.
class PostgresIntegrationOAuthStateStore implements IntegrationOAuthStateStore {
  PostgresIntegrationOAuthStateStore({
    required TenantTransactionWrapper tenantWrapper,
    DateTime Function()? now,
  })  : _tenantWrapper = tenantWrapper,
        _now = now ?? DateTime.now;

  final TenantTransactionWrapper _tenantWrapper;
  final DateTime Function() _now;

  @override
  Future<void> issue({
    required String stateToken,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String redirectUri,
    required Duration ttl,
    String? pkceVerifier,
    String? actorUserId,
    String? module,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _validateUuidOrNull(actorUserId),
    );
    final expiresAt = _now().toUtc().add(ttl);
    await _tenantWrapper.runInTenantContext<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_oauth_state ('
        'state_token, operator_id, location_id, vendor_id, '
        'redirect_uri, pkce_verifier, actor_user_id, module, '
        'expires_at'
        ') values ('
        '@state_token, @operator_id::uuid, @location_id::uuid, '
        '@vendor_id, @redirect_uri, @pkce_verifier, '
        '@actor_user_id, @module, @expires_at::timestamptz'
        ')',
        parameters: <String, Object?>{
          'state_token': stateToken,
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'redirect_uri': redirectUri,
          'pkce_verifier': pkceVerifier,
          'actor_user_id': actorUserId,
          'module': module,
          'expires_at': expiresAt.toIso8601String(),
        },
      );
    });
  }

  @override
  Future<IntegrationOAuthStateRecord> consume({
    required String stateToken,
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return _tenantWrapper.runInTenantContext<IntegrationOAuthStateRecord>(
      ctx,
      (exec) async {
        final lookup = await exec.query(
          'select state_token, operator_id::text as operator_id, '
          'location_id::text as location_id, vendor_id, redirect_uri, '
          'pkce_verifier, actor_user_id, module, '
          'created_at, expires_at, consumed_at '
          'from public.connector_oauth_state '
          'where state_token = @state_token '
          'limit 1',
          parameters: <String, Object?>{
            'state_token': stateToken,
          },
        );
        if (lookup.isEmpty) {
          throw const IntegrationOAuthStateConsumeFailure(
            IntegrationOAuthStateConsumeFailureReason.notFound,
          );
        }
        final row = lookup.single;
        // Tuple mismatch BEFORE any state mutation. RLS already
        // narrowed the visible rows to the actor's (operator, location);
        // the vendor_id check defends against a token replayed across
        // a different vendor consent flow within the same tenant.
        if ((row['operator_id'] as String).toLowerCase() !=
                operatorId.toLowerCase() ||
            (row['location_id'] as String).toLowerCase() !=
                locationId.toLowerCase() ||
            (row['vendor_id'] as String) != vendorId) {
          throw const IntegrationOAuthStateConsumeFailure(
            IntegrationOAuthStateConsumeFailureReason.tupleMismatch,
          );
        }
        final consumedAt = row['consumed_at'];
        if (consumedAt != null) {
          throw const IntegrationOAuthStateConsumeFailure(
            IntegrationOAuthStateConsumeFailureReason.alreadyConsumed,
          );
        }
        final expiresAt = _coerceTimestamp(row['expires_at']);
        if (expiresAt == null || !expiresAt.isAfter(_now().toUtc())) {
          throw const IntegrationOAuthStateConsumeFailure(
            IntegrationOAuthStateConsumeFailureReason.expired,
          );
        }
        // Single-statement UPDATE so the consume is atomic against
        // a duplicate callback racing the same token. The WHERE
        // clause re-checks `consumed_at IS NULL` so a second writer
        // gets zero rows back even if its read sniffed the row
        // before our UPDATE landed.
        final updated = await exec.query(
          'update public.connector_oauth_state '
          '   set consumed_at = now() '
          ' where state_token = @state_token '
          '   and consumed_at is null '
          '   and expires_at > now() '
          'returning consumed_at',
          parameters: <String, Object?>{
            'state_token': stateToken,
          },
        );
        if (updated.isEmpty) {
          // Lost the race against another callback consuming the
          // same token. Surface as already_consumed so the operator
          // sees a consistent error message rather than the more
          // generic `notFound`.
          throw const IntegrationOAuthStateConsumeFailure(
            IntegrationOAuthStateConsumeFailureReason.alreadyConsumed,
          );
        }
        final consumedAtNow = _coerceTimestamp(updated.single['consumed_at']) ??
            _now().toUtc();
        return IntegrationOAuthStateRecord(
          stateToken: row['state_token'] as String,
          operatorId: row['operator_id'] as String,
          locationId: row['location_id'] as String,
          vendorId: row['vendor_id'] as String,
          redirectUri: row['redirect_uri'] as String,
          createdAt: _coerceTimestamp(row['created_at']) ?? _now().toUtc(),
          expiresAt: expiresAt,
          consumedAt: consumedAtNow,
          pkceVerifier: row['pkce_verifier'] as String?,
          actorUserId: row['actor_user_id'] as String?,
          module: row['module'] as String?,
        );
      },
    );
  }

  @override
  Future<int> pruneExpired({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return _tenantWrapper.runInTenantContext<int>(ctx, (exec) async {
      final deleted = await exec.query(
        'delete from public.connector_oauth_state '
        ' where operator_id = @operator_id::uuid '
        '   and location_id = @location_id::uuid '
        '   and expires_at <= now() '
        'returning state_token',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return deleted.length;
    });
  }

  /// `userId` carries through `TenantContext.userId`, which in turn
  /// rejects non-UUID values (defense in depth around the SET LOCAL
  /// payload). The route may carry an opaque actor id like
  /// `sp:integration_admin`; in that case we skip injecting it onto
  /// the tenant context but still persist it onto the row body.
  String? _validateUuidOrNull(String? value) {
    if (value == null) return null;
    if (RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(value)) {
      return value;
    }
    return null;
  }

  static DateTime? _coerceTimestamp(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String && value.isNotEmpty) {
      return DateTime.parse(value).toUtc();
    }
    return null;
  }
}

/// In-memory fake for tests. Behaves the same as the Postgres-backed
/// store down to the failure-reason taxonomy, so route tests can drive
/// the full consume + prune flow without binding a real pool.
class InMemoryIntegrationOAuthStateStore implements IntegrationOAuthStateStore {
  InMemoryIntegrationOAuthStateStore({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, _MemRow> _rows = <String, _MemRow>{};

  @override
  Future<void> issue({
    required String stateToken,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String redirectUri,
    required Duration ttl,
    String? pkceVerifier,
    String? actorUserId,
    String? module,
  }) async {
    if (_rows.containsKey(stateToken)) {
      throw StateError(
        'state_token collision in in-memory store '
        '(stateToken=$stateToken)',
      );
    }
    final createdAt = _now().toUtc();
    _rows[stateToken] = _MemRow(
      stateToken: stateToken,
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      redirectUri: redirectUri,
      pkceVerifier: pkceVerifier,
      actorUserId: actorUserId,
      module: module,
      createdAt: createdAt,
      expiresAt: createdAt.add(ttl),
    );
  }

  @override
  Future<IntegrationOAuthStateRecord> consume({
    required String stateToken,
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    final row = _rows[stateToken];
    if (row == null) {
      throw const IntegrationOAuthStateConsumeFailure(
        IntegrationOAuthStateConsumeFailureReason.notFound,
      );
    }
    if (row.operatorId.toLowerCase() != operatorId.toLowerCase() ||
        row.locationId.toLowerCase() != locationId.toLowerCase() ||
        row.vendorId != vendorId) {
      throw const IntegrationOAuthStateConsumeFailure(
        IntegrationOAuthStateConsumeFailureReason.tupleMismatch,
      );
    }
    if (row.consumedAt != null) {
      throw const IntegrationOAuthStateConsumeFailure(
        IntegrationOAuthStateConsumeFailureReason.alreadyConsumed,
      );
    }
    if (!row.expiresAt.isAfter(_now().toUtc())) {
      throw const IntegrationOAuthStateConsumeFailure(
        IntegrationOAuthStateConsumeFailureReason.expired,
      );
    }
    final consumedAt = _now().toUtc();
    final consumed = row.copyWith(consumedAt: consumedAt);
    _rows[stateToken] = consumed;
    return IntegrationOAuthStateRecord(
      stateToken: consumed.stateToken,
      operatorId: consumed.operatorId,
      locationId: consumed.locationId,
      vendorId: consumed.vendorId,
      redirectUri: consumed.redirectUri,
      createdAt: consumed.createdAt,
      expiresAt: consumed.expiresAt,
      consumedAt: consumedAt,
      pkceVerifier: consumed.pkceVerifier,
      actorUserId: consumed.actorUserId,
      module: consumed.module,
    );
  }

  @override
  Future<int> pruneExpired({
    required String operatorId,
    required String locationId,
  }) async {
    final now = _now().toUtc();
    final toDelete = <String>[];
    _rows.forEach((token, row) {
      if (row.operatorId.toLowerCase() == operatorId.toLowerCase() &&
          row.locationId.toLowerCase() == locationId.toLowerCase() &&
          !row.expiresAt.isAfter(now)) {
        toDelete.add(token);
      }
    });
    for (final token in toDelete) {
      _rows.remove(token);
    }
    return toDelete.length;
  }

  /// Test-only: peek a row by token. Returns null when the token is
  /// not present.
  IntegrationOAuthStateRecord? peek(String stateToken) {
    final row = _rows[stateToken];
    if (row == null) return null;
    return IntegrationOAuthStateRecord(
      stateToken: row.stateToken,
      operatorId: row.operatorId,
      locationId: row.locationId,
      vendorId: row.vendorId,
      redirectUri: row.redirectUri,
      createdAt: row.createdAt,
      expiresAt: row.expiresAt,
      consumedAt: row.consumedAt ?? row.createdAt,
      pkceVerifier: row.pkceVerifier,
      actorUserId: row.actorUserId,
      module: row.module,
    );
  }

  /// Test-only: count the rows in the store. Useful for asserting
  /// that prune actually removed something.
  int get length => _rows.length;
}

class _MemRow {
  _MemRow({
    required this.stateToken,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.redirectUri,
    required this.createdAt,
    required this.expiresAt,
    this.pkceVerifier,
    this.actorUserId,
    this.module,
    this.consumedAt,
  });

  final String stateToken;
  final String operatorId;
  final String locationId;
  final String vendorId;
  final String redirectUri;
  final String? pkceVerifier;
  final String? actorUserId;
  final String? module;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? consumedAt;

  _MemRow copyWith({DateTime? consumedAt}) {
    return _MemRow(
      stateToken: stateToken,
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      redirectUri: redirectUri,
      pkceVerifier: pkceVerifier,
      actorUserId: actorUserId,
      module: module,
      createdAt: createdAt,
      expiresAt: expiresAt,
      consumedAt: consumedAt ?? this.consumedAt,
    );
  }
}
