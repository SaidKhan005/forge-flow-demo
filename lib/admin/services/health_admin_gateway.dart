// Phase 11A.UX.health (F.1) — Gateway for the proxy /health envelope.
//
// The proxy `/health` route is public unauthenticated per
// `docs/contracts/proxy_health_contract.md`, so the HTTP gateway does
// NOT attach a bearer token. A 200 response yields the full envelope.
// A 503 response also yields a parseable envelope (the proxy returns
// the same shape on dependency failure with `status: unavailable`),
// and the gateway promotes the 503 to
// `HealthEnvelope.dependenciesUnavailable: true` so the screen can
// render its top-of-page red banner regardless of which dependency
// tipped the response.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/health_admin_models.dart';

class HealthAdminGatewayError implements Exception {
  const HealthAdminGatewayError({
    required this.statusCode,
    required this.message,
  });

  final int statusCode;
  final String message;

  @override
  String toString() => 'HealthAdminGatewayError($statusCode): $message';
}

abstract class HealthAdminGateway {
  Future<HealthEnvelope> fetch();
}

/// Production gateway: hits `GET <proxy>/health` and surfaces the
/// envelope to the screen. Treats HTTP 200 and HTTP 503 as success
/// because the proxy returns the envelope JSON in both cases (the
/// 503 simply indicates a failed dependency probe). Any other status
/// throws.
class HttpHealthAdminGateway implements HealthAdminGateway {
  HttpHealthAdminGateway({required this.baseUri, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  /// Proxy base URI (e.g. `https://advisor-proxy.forgeflow.app`).
  final Uri baseUri;
  final http.Client _httpClient;

  static const String healthPath = '/health';

  @override
  Future<HealthEnvelope> fetch() async {
    final uri = baseUri.resolve(healthPath);
    final request = http.Request('GET', uri)
      ..headers['accept'] = 'application/json';
    final response = await http.Response.fromStream(
      await _httpClient.send(request),
    );
    final raw = utf8.decode(response.bodyBytes);

    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        parsed = decoded.cast<String, Object?>();
      }
    }

    final status = response.statusCode;
    if (status == 200) {
      return HealthEnvelope.fromJson(parsed);
    }
    if (status == 503) {
      // The proxy returned the same envelope shape with
      // `status: unavailable`; the screen renders the red banner.
      return HealthEnvelope.fromJson(parsed, dependenciesUnavailable: true);
    }
    throw HealthAdminGatewayError(
      statusCode: status,
      message: 'proxy /health returned HTTP $status',
    );
  }
}

/// In-memory gateway used by widget tests + the kDemoMode walkthrough.
/// Constructed from a raw envelope JSON map (matching the proxy
/// contract) and an optional `dependenciesUnavailable` flag so the
/// 503 banner path can be exercised end-to-end without hitting a
/// proxy.
class InMemoryHealthAdminGateway implements HealthAdminGateway {
  InMemoryHealthAdminGateway({
    required Map<String, Object?> envelope,
    bool dependenciesUnavailable = false,
    Exception? errorOnFetch,
  }) : _envelope = envelope,
       _dependenciesUnavailable = dependenciesUnavailable,
       _errorOnFetch = errorOnFetch;

  Map<String, Object?> _envelope;
  bool _dependenciesUnavailable;
  Exception? _errorOnFetch;

  /// Replace the seeded envelope for the next [fetch] call. Used by
  /// the screen widget test to assert auto-refresh consumes the new
  /// envelope.
  void setEnvelope(
    Map<String, Object?> envelope, {
    bool? dependenciesUnavailable,
    Exception? errorOnFetch,
  }) {
    _envelope = envelope;
    if (dependenciesUnavailable != null) {
      _dependenciesUnavailable = dependenciesUnavailable;
    }
    _errorOnFetch = errorOnFetch;
  }

  @override
  Future<HealthEnvelope> fetch() async {
    final err = _errorOnFetch;
    if (err != null) throw err;
    return HealthEnvelope.fromJson(
      _envelope,
      dependenciesUnavailable: _dependenciesUnavailable,
    );
  }
}

/// Seed envelope used by the F.1 walkthrough when no production
/// gateway is mounted. Mirrors the proxy contract shape with a mix of
/// green / yellow / red statuses across tiers so the operator can
/// click through every tab and see the tier-coloring rules in
/// action without a backend.
const Map<String, Object?> kHealthAdminDemoEnvelope = <String, Object?>{
  'status': 'degraded',
  'severity': 'yellow',
  'contract': 'proxy_health.v1',
  'schema_version': 1,
  'checked_at': '2026-05-01T12:00:00.000Z',
  'envelope_variant': 'full_v1',
  'dependencies': <String, Object?>{
    'postgres': <String, Object?>{
      'status': 'green',
      'check': 'select_1',
      'legacy_key': 'postgres_select_1',
    },
    'age': <String, Object?>{
      'status': 'green',
      'check': 'cypher_match',
      'legacy_key': 'age_cypher_match',
    },
    'pgvector': <String, Object?>{
      'status': 'green',
      'check': 'similarity',
      'legacy_key': 'pgvector_similarity',
    },
  },
  'surfaces': <String, Object?>{
    'graph': <String, Object?>{
      'status': 'green',
      'metrics': <String>['graph_node_count', 'graph_edge_count'],
      'owner': 'B44',
    },
    'vector': <String, Object?>{
      'status': 'green',
      'metrics': <String>['vector_query_latency_ms', 'vector_recall'],
      'owner': 'B47',
    },
    'event_outbox': <String, Object?>{
      'status': 'green',
      'metrics': <String>['event_outbox_undelivered_count'],
      'owner': 'Phase 10a',
    },
    'audit_chain': <String, Object?>{
      'status': 'green',
      'metrics': <String>['audit_chain_lag_seconds'],
      'owner': 'B37/B43',
    },
  },
  'metrics': <String, Object?>{
    // ── Tier 1 — infrastructure / dependencies ──────────────────
    'audit_chain_lag_seconds': <String, Object?>{
      'status': 'green',
      'value': 12,
      'unit': 'seconds',
      'description':
          'Lag between current audit chain head and latest durable audit anchor.',
      'source': 'audit_chain_anchors',
      'owner': 'B37/B43',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 1800, 'red': 21600},
      'metadata': <String, Object?>{'tier': 1},
    },
    'migration_apply_drift_count': <String, Object?>{
      'status': 'green',
      'value': 0,
      'unit': 'count',
      'description': 'Migration files not yet recorded as applied.',
      'source': 'proxy_migrations_applied',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'red': 1},
      'metadata': <String, Object?>{'tier': 1},
    },
    'azure_extensions_present': <String, Object?>{
      'status': 'green',
      'value': 6,
      'unit': 'count',
      'description':
          'Required Azure extensions installed in the active business '
          'database (AGE, pgvector, pg_diskann, pg_partman, '
          'pg_stat_statements, pgcrypto). pg_cron is tracked separately '
          'from Azure''s maintenance database.',
      'source': 'pg_extension',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 1},
    },
    'pg_cron_scheduler_alive': <String, Object?>{
      'status': 'green',
      'value': true,
      'unit': 'boolean',
      'description':
          'pg_cron scheduler reported a successful run inside the last 5 minutes.',
      'source': 'cron.job_run_details',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 1},
    },
    'circuit_breaker_anthropic_state': <String, Object?>{
      'status': 'yellow',
      'value': 'half_open',
      'unit': 'state',
      'description':
          'Lock 7 circuit breaker state for the Anthropic provider '
          '(closed/half_open/open).',
      'source': 'in_memory_breaker',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 1, 'provider': 'anthropic'},
    },
    'circuit_breaker_voyage_state': <String, Object?>{
      'status': 'green',
      'value': 'closed',
      'unit': 'state',
      'description':
          'Lock 7 circuit breaker state for the Voyage provider '
          '(closed/half_open/open).',
      'source': 'in_memory_breaker',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 1, 'provider': 'voyage'},
    },
    'service_principal_jwt_alive': <String, Object?>{
      'status': 'green',
      'value': true,
      'unit': 'boolean',
      'description':
          'service-principal HMAC signer secret loaded and a recent sp: '
          'token verified successfully.',
      'source': 'service_principals_signer_status',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 1},
    },
    'firebase_jwks_fetch_alive': <String, Object?>{
      'status': 'green',
      'value': true,
      'unit': 'boolean',
      'description': 'Firebase JWKS fetch succeeded inside cache TTL window.',
      'source': 'firebase_jwks_cache_status',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 1},
    },
    'proxy_idempotency_cache_alive': <String, Object?>{
      'status': 'green',
      'value': true,
      'unit': 'boolean',
      'description':
          'proxy_requests idempotency table reachable and accepting reads.',
      'source': 'proxy_requests',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 1},
    },
    // ── Tier 2 — production hardening ──────────────────────────
    'graph_node_count': <String, Object?>{
      'status': 'green',
      'value': 1245,
      'unit': 'count',
      'description': 'Canonical graph node count for operations health.',
      'source': 'public.graph_health_metrics()',
      'owner': 'B44',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 2},
    },
    'graph_edge_count': <String, Object?>{
      'status': 'green',
      'value': 4218,
      'unit': 'count',
      'description': 'Canonical active graph edge count for operations health.',
      'source': 'public.graph_health_metrics()',
      'owner': 'B44',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 3000000, 'red': 4000000},
      'metadata': <String, Object?>{'tier': 2},
    },
    'graph_traversal_latency_ms': <String, Object?>{
      'status': 'green',
      'value': 92,
      'unit': 'milliseconds',
      'description': 'Graph traversal p95 latency from the latest benchmark.',
      'source': 'graph_benchmark_runs',
      'owner': 'B44',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 250, 'red': 500},
      'metadata': <String, Object?>{'tier': 2, 'percentile': 'p95'},
    },
    'graph_traversal_p99_latency_ms': <String, Object?>{
      'status': 'green',
      'value': 184,
      'unit': 'milliseconds',
      'description': 'Graph traversal p99 latency from the latest benchmark.',
      'source': 'graph_benchmark_runs',
      'owner': 'B44',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 750, 'red': 1500},
      'metadata': <String, Object?>{'tier': 2},
    },
    'vector_query_latency_ms': <String, Object?>{
      'status': 'green',
      'value': 38,
      'unit': 'milliseconds',
      'description': 'Filtered vector search p50 latency.',
      'source': 'vector_benchmark_runs',
      'owner': 'B47',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 200, 'red': 400},
      'metadata': <String, Object?>{'tier': 2, 'percentile': 'p50'},
    },
    'vector_query_p99_latency_ms': <String, Object?>{
      'status': 'green',
      'value': 124,
      'unit': 'milliseconds',
      'description': 'Filtered vector search p99 latency.',
      'source': 'vector_benchmark_runs',
      'owner': 'B47',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 600, 'red': 1200},
      'metadata': <String, Object?>{'tier': 2},
    },
    'vector_recall': <String, Object?>{
      'status': 'green',
      'value': 0.94,
      'unit': 'ratio',
      'description': 'Filtered vector search recall@10.',
      'source': 'vector_benchmark_runs',
      'owner': 'B47',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 0.85, 'red': 0.70},
      'metadata': <String, Object?>{'tier': 2},
    },
    'vector_index_size_per_corpus': <String, Object?>{
      'status': 'green',
      'value': 24180,
      'unit': 'count',
      'description': 'Per-corpus vector index size.',
      'source': 'vector_index_health',
      'owner': 'B47',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 5000000, 'red': 8000000},
      'metadata': <String, Object?>{'tier': 2},
    },
    'rollup_freshness_per_grain': <String, Object?>{
      'status': 'yellow',
      'value': 4218,
      'unit': 'seconds',
      'description': 'Rollup freshness lag grouped by grain.',
      'source': 'aggregation_state',
      'owner': 'B45',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 3600, 'red': 21600},
      'metadata': <String, Object?>{'tier': 2},
    },
    'rollup_refresh_lag_seconds': <String, Object?>{
      'status': 'green',
      'value': 240,
      'unit': 'seconds',
      'description': 'Time since the most recent rollup refresh job ran.',
      'source': 'aggregation_state',
      'owner': 'B45',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 3600, 'red': 14400},
      'metadata': <String, Object?>{'tier': 2},
    },
    'event_outbox_undelivered_count': <String, Object?>{
      'status': 'green',
      'value': 7,
      'unit': 'count',
      'description': 'Undelivered event_outbox rows awaiting bridge delivery.',
      'source': 'event_outbox',
      'owner': 'Phase 10a',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 10000, 'red': 100000},
      'metadata': <String, Object?>{'tier': 2},
    },
    'event_outbox_lag_seconds': <String, Object?>{
      'status': 'green',
      'value': 4,
      'unit': 'seconds',
      'description': 'Age of the oldest undelivered event_outbox row.',
      'source': 'event_outbox',
      'owner': 'Phase 10a',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 60, 'red': 300},
      'metadata': <String, Object?>{'tier': 2},
    },
    'partition_count_active': <String, Object?>{
      'status': 'green',
      'value': 18,
      'unit': 'count',
      'description': 'Active child partitions registered with pg_partman.',
      'source': 'partman.part_config',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 2},
    },
    'partition_maintenance_last_run_age_seconds': <String, Object?>{
      'status': 'green',
      'value': 1820,
      'unit': 'seconds',
      'description': 'Age of the last successful pg_partman run_maintenance().',
      'source': 'cron.job_run_details',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 7200, 'red': 14400},
      'metadata': <String, Object?>{'tier': 2},
    },
    'pg_cron_jobs_failed_24h': <String, Object?>{
      'status': 'green',
      'value': 0,
      'unit': 'count',
      'description': 'pg_cron job runs failed in the last 24 hours.',
      'source': 'cron.job_run_details',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 1, 'red': 5},
      'metadata': <String, Object?>{'tier': 2},
    },
    'usage_caps_breach_count': <String, Object?>{
      'status': 'green',
      'value': 0,
      'unit': 'count',
      'description': 'Requests refused because usage caps were reached.',
      'source': 'proxy usage accounting',
      'owner': 'B33',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 1, 'red': 100},
      'metadata': <String, Object?>{'tier': 2},
    },
    // ── Tier 3 — ops observability ─────────────────────────────
    'prompt_cache_hit_rate': <String, Object?>{
      'status': 'green',
      'value': 0.62,
      'unit': 'ratio',
      'description':
          'Anthropic prompt cache hit rate (Hard Promise #9 lever 1).',
      'source': 'cache_metrics',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 0.30, 'red': 0.10},
      'metadata': <String, Object?>{'tier': 3},
    },
    'response_cache_hit_rate': <String, Object?>{
      'status': 'green',
      'value': 0.41,
      'unit': 'ratio',
      'description':
          'Memorystore response cache hit rate (Hard Promise #9 lever 3).',
      'source': 'cache_metrics',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 0.30, 'red': 0.10},
      'metadata': <String, Object?>{'tier': 3},
    },
    'semantic_cache_hit_rate': <String, Object?>{
      'status': 'green',
      'value': 0.36,
      'unit': 'ratio',
      'description': 'Semantic cache hit rate (Hard Promise #9 lever 3).',
      'source': 'cache_metrics',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 0.30, 'red': 0.10},
      'metadata': <String, Object?>{'tier': 3},
    },
    'cost_per_query_class_haiku': <String, Object?>{
      'status': 'green',
      'value': 0.0008,
      'unit': 'usd',
      'description': 'Rolling 1-hour mean cost per Haiku-routed request (USD).',
      'source': 'usage_logs',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 3},
    },
    'cost_per_query_class_sonnet': <String, Object?>{
      'status': 'green',
      'value': 0.012,
      'unit': 'usd',
      'description':
          'Rolling 1-hour mean cost per Sonnet-routed request (USD).',
      'source': 'usage_logs',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 3},
    },
    'batch_api_pending_count': <String, Object?>{
      'status': 'green',
      'value': 8,
      'unit': 'count',
      'description': 'Workflow runs in AWAITING_BATCH (Lock 8).',
      'source': 'workflow_runs',
      'owner': 'Phase 12.0',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 100, 'red': 1000},
      'metadata': <String, Object?>{'tier': 3},
    },
    'fallback_chain_usage_count_anthropic': <String, Object?>{
      'status': 'green',
      'value': 12,
      'unit': 'count',
      'description':
          'Requests in last 5 minutes that traversed the Anthropic '
          'fallback chain.',
      'source': 'usage_logs',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 3},
    },
    'fallback_chain_usage_count_voyage': <String, Object?>{
      'status': 'green',
      'value': 0,
      'unit': 'count',
      'description':
          'Requests in last 5 minutes that traversed the Voyage '
          'fallback chain.',
      'source': 'usage_logs',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 3},
    },
    'cloud_run_instance_count': <String, Object?>{
      'status': 'green',
      'value': 2,
      'unit': 'count',
      'description': 'Active Cloud Run instance count for the proxy.',
      'source': 'cloud_run.instance_metrics',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'metadata': <String, Object?>{'tier': 3},
    },
    'proxy_request_p99_latency_ms': <String, Object?>{
      'status': 'green',
      'value': 740,
      'unit': 'milliseconds',
      'description': 'Rolling 5-minute proxy request p99 latency.',
      'source': 'proxy_request_metrics',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 2000, 'red': 5000},
      'metadata': <String, Object?>{'tier': 3},
    },
    'proxy_request_5xx_rate': <String, Object?>{
      'status': 'green',
      'value': 0.001,
      'unit': 'ratio',
      'description': 'Rolling 5-minute proxy 5xx response rate.',
      'source': 'proxy_request_metrics',
      'owner': 'B42',
      'observed_at': '2026-05-01T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 0.01, 'red': 0.05},
      'metadata': <String, Object?>{'tier': 3},
    },
  },
  'warnings': <Object?>[],
};
