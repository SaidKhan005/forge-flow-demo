// code-health.L14 — Postgres-backed advisor response cache.
//
// CODE_HEALTH ref: "AlwaysMissAdvisorResponseCache still in production
// wiring (`main.dart:325`)" — collapsed fallback chain (LLM → secondary
// → cache → refusal). Lock 7 v1 shipped the abstract
// `AdvisorResponseCache` interface (lib/domain/services/) plus the
// `AlwaysMissAdvisorResponseCache` always-miss stub; E.2b was the
// locked slot to swap in a real implementation. This class fulfills
// that promise.
//
// The interface stays in `lib/domain/services/advisor_response_cache.dart`
// (pure abstract — no I/O); the Postgres-backed implementation lives
// here in `tool/advisor_proxy/` because:
//
//   * `lib/domain/services/` is "pure formulas, no I/O" per CLAUDE.md
//     "Service-Layer Split". A `package:postgres` dependency cannot
//     live there.
//   * Only files under `lib/infrastructure/persistence/postgres/` may
//     import the concrete `package:postgres` binding directly. This
//     file does not — it depends on the `PostgresExecutor` /
//     `TenantTransactionWrapper` seams from that directory.
//   * The proxy entrypoint already imports
//     `package:forge_and_flow/infrastructure/persistence/postgres/...`
//     for tenant-pool wiring; this file follows the same pattern.
//
// The `AlwaysMissAdvisorResponseCache` symbol stays exported from the
// abstract-class file unchanged — production wiring no longer
// references it (see main.dart) but tests still construct it as a
// known-miss fixture (see test/advisor_proxy_test.dart). Removing the
// symbol would cascade into out-of-scope test edits.
//
// Hard rules carried from CLAUDE.md and the migration:
//
//   1. Every read/write goes through `OperatorScopedRepository.withTenant`
//      (via the `TenantTransactionWrapper.runInTenantContext` it
//      delegates to) so `SET LOCAL app.operator_id / app.location_id`
//      is in place when the per-tenant RLS policy
//      `advisor_response_cache_per_tenant_location` evaluates.
//      Repository pattern is the primary defense; RLS is the backup.
//
//   2. The `prompt_hash` column is BYTEA (raw SHA-256 bytes); the
//      Dart side digests the normalized prompt and binds the bytes
//      directly via parameter binding. No hex round-trip.
//
//   3. The `response` column is JSONB; v1 stores
//      `{"answer": "<string>"}` so a future swap to a richer envelope
//      (completion + provenance + token counts) is a serializer-only
//      change, not a migration.
//
//   4. The `embedding_id` column is nullable; v1 always passes null.
//      The unique key uses `coalesce(embedding_id, 0)` so two
//      identical-prompt rows cannot collide on insert just because
//      one has an embedding probe and the other does not.
//
//   5. `put()` uses INSERT … ON CONFLICT DO UPDATE so a re-cached
//      entry refreshes `expires_at` instead of stacking duplicate
//      rows. The TTL cron sweep is the eventual cleanup; the upsert
//      handles the steady-state hot-prompt case.
//
//   6. `get()` filters on `expires_at > now()` and proactively
//      DELETEs the matched-but-stale row before returning miss, so
//      the cache stays self-healing without waiting on the cron pass.
//      The DELETE is inside the same tenant transaction so the per-
//      tenant RLS policy admits it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

/// Thrown when [PostgresAdvisorResponseCache.put] is called with a
/// non-positive TTL. The interface admits any positive [Duration]
/// down to microseconds; zero or negative values are a programming
/// error (the caller almost certainly meant `Duration.zero`-ish for
/// "do not cache" and should skip the put() call entirely instead).
class AdvisorResponseCacheTtlError implements Exception {
  AdvisorResponseCacheTtlError(this.message);
  final String message;
  @override
  String toString() => 'AdvisorResponseCacheTtlError: $message';
}

/// Postgres-backed implementation of [AdvisorResponseCache].
///
/// Reads and writes go through [TenantTransactionWrapper] so the
/// per-tenant RLS policy `advisor_response_cache_per_tenant_location`
/// admits every row. The class is constructed with the proxy's tenant
/// pool wrapper (the same one the `AdvisorConversationLogRepository`
/// and `ConnectorBackfillJobRepository` use) so cache reads share the
/// connection pool with the rest of the advisor write surface.
///
/// v1 default TTL is 24 hours (matches the migration default). Tests
/// override via the `defaultTtl` constructor argument or per-call via
/// `put(ttl: ...)`.
class PostgresAdvisorResponseCache implements AdvisorResponseCache {
  PostgresAdvisorResponseCache({
    required TenantTransactionWrapper tenantWrapper,
    Duration defaultTtl = const Duration(hours: 24),
    DateTime Function()? now,
  })  : _tenantWrapper = tenantWrapper,
        _defaultTtl = defaultTtl,
        _now = now ?? DateTime.now {
    if (_defaultTtl <= Duration.zero) {
      throw AdvisorResponseCacheTtlError(
        'defaultTtl must be positive; got $_defaultTtl',
      );
    }
  }

  final TenantTransactionWrapper _tenantWrapper;
  final Duration _defaultTtl;
  final DateTime Function() _now;

  /// SHA-256 the normalized question hash so we always bind a fixed-
  /// width 32-byte BYTEA value. The interface admits arbitrary
  /// strings as `questionHash` — callers that already digest pass a
  /// hex digest, callers that don't pass the raw question; both
  /// flows hash identically here so the column shape stays uniform.
  static Uint8List _digest(String questionHash) {
    final bytes = utf8.encode(questionHash);
    return Uint8List.fromList(sha256.convert(bytes).bytes);
  }

  @override
  Future<String?> lookup({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  }) async {
    final context = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final hash = _digest(questionHash);
    return _tenantWrapper.runInTenantContext<String?>(context, (exec) async {
      // Filter on `expires_at > now()` so a stale row never serves a
      // hit. The matching row (if any) is the unique upsert target —
      // `coalesce(embedding_id, 0) = 0` matches v1's "no embedding"
      // posture; v2 will accept an embedding_id argument and bind it.
      final rows = await exec.query(
        '''
select cache_id, response, expires_at
  from public.advisor_response_cache
 where operator_id = @operator_id
   and location_id = @location_id
   and query_class = @query_class
   and corpus_version = @corpus_version
   and prompt_hash = @prompt_hash
   and coalesce(embedding_id, 0) = 0
 limit 1
        ''',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'query_class': queryClass,
          'corpus_version': corpusVersion,
          'prompt_hash': hash,
        },
      );
      if (rows.isEmpty) {
        return null;
      }
      final row = rows.first;
      final expiresAt = row['expires_at'] as DateTime?;
      if (expiresAt == null || !expiresAt.isAfter(_now())) {
        // Stale row. Self-heal so the next hit is a fresh write
        // instead of waiting on the hourly sweep.
        final cacheId = row['cache_id'];
        await exec.execute(
          'delete from public.advisor_response_cache where cache_id = @id',
          parameters: <String, Object?>{'id': cacheId},
        );
        return null;
      }
      final response = _decodeResponse(row['response']);
      return response;
    });
  }

  /// Cache [answer] for [(operatorId, locationId, queryClass,
  /// corpusVersion, questionHash)]. Re-caching the same prompt
  /// upserts the row and refreshes `expires_at` rather than stacking
  /// a duplicate.
  ///
  /// [ttl] overrides the constructor's [_defaultTtl] when provided.
  /// Tests use a tiny ttl (e.g. 1ms) to assert the staleness branch
  /// of [lookup].
  Future<void> put({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
    required String answer,
    Duration? ttl,
  }) async {
    final effectiveTtl = ttl ?? _defaultTtl;
    if (effectiveTtl <= Duration.zero) {
      throw AdvisorResponseCacheTtlError(
        'ttl must be positive; got $effectiveTtl',
      );
    }
    final context = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final hash = _digest(questionHash);
    final responseJson = jsonEncode(<String, Object?>{'answer': answer});
    final expiresAt = _now().toUtc().add(effectiveTtl);
    await _tenantWrapper.runInTenantContext<void>(context, (exec) async {
      await exec.execute(
        '''
insert into public.advisor_response_cache (
  operator_id,
  location_id,
  query_class,
  corpus_version,
  prompt_hash,
  embedding_id,
  response,
  created_at,
  expires_at
) values (
  @operator_id,
  @location_id,
  @query_class,
  @corpus_version,
  @prompt_hash,
  null,
  @response::jsonb,
  @now,
  @expires_at
)
on conflict (operator_id, location_id, query_class, corpus_version, prompt_hash, (coalesce(embedding_id, 0)))
do update set
  response = excluded.response,
  created_at = excluded.created_at,
  expires_at = excluded.expires_at
        ''',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'query_class': queryClass,
          'corpus_version': corpusVersion,
          'prompt_hash': hash,
          'response': responseJson,
          'now': _now().toUtc(),
          'expires_at': expiresAt,
        },
      );
    });
  }

  /// JSONB columns surface as either a Dart `Map`/`List` (when the
  /// driver decoded the JSON for us) or a `String` (when the driver
  /// hands back the textual representation). Both shapes can carry
  /// the v1 envelope `{"answer": "<string>"}`; this helper extracts
  /// the answer field defensively so a corrupted row (or a v2 shape
  /// we don't yet recognize) returns a miss instead of throwing.
  static String? _decodeResponse(Object? raw) {
    Map<String, Object?>? envelope;
    if (raw is Map<String, Object?>) {
      envelope = raw;
    } else if (raw is Map) {
      envelope = raw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    } else if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          envelope = decoded;
        } else if (decoded is Map) {
          envelope = decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        }
      } catch (_) {
        return null;
      }
    }
    if (envelope == null) {
      return null;
    }
    final answer = envelope['answer'];
    return answer is String ? answer : null;
  }
}
