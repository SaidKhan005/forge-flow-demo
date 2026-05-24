// Forge & Flow advisor proxy — Health infrastructure + Migration registry writer
// (part of advisor_proxy.dart).
//
// chore(advisor-proxy): pure size refactor. This part file holds the health
// check infrastructure (ProxyHealthCheckStore, ProxyRuntimeGauges,
// ProxyHealthStatus, ProxyHealthMetric, ProxyHealthSurface,
// ScaffoldFailingProxyHealthCheckStore, ProxySchemaContractException,
// AdminProxySchemaContractVerifier, ProxyHealthRegistryContext,
// ProxyHealthFeatureFlags, ProxyHealthRegistryResult,
// RegistryProxyHealthCheckStore, ProxyHealthDependencyProbe) and the
// migration apply registry writer (ProxyMigrationApplyRegistryWriter).
// Mechanically lifted from advisor_proxy.dart so the monolith stays under the
// kAdvisorProxyMaxLines bleed-stop ceiling enforced by
// tool/advisor_proxy_size_lint.dart. As a Dart `part` it shares the
// library's imports and private scope verbatim — routing, shapes, status
// codes, RLS, auth, and SQL are all unchanged. No symbol was renamed.

part of 'advisor_proxy.dart';

abstract class ProxyHealthCheckStore {
  Future<ProxyHealthStatus> check();
}

/// In-process runtime gauges the proxy `/health` envelope surfaces
/// alongside the dependency-probe + producer-registry envelope.
///
/// These are CHEAP O(1) snapshots collected at request time:
///   - Postgres pool saturation (open / idle / waiter / max)
///   - Pub/Sub subscriber ring-buffer key count
///
/// A1 §2.4 instrumentation items #3 and #4 — surface S2 (pool waiter
/// exhaustion) + S3 (`_ringBuffers` unbounded key growth) so operators
/// can see the early signal before a Cloud Run pod crashes.
///
/// Production wiring sets this in `main.dart` immediately after
/// constructing the Postgres pool + pubsub subscriber. The /health
/// route reads `current` if it has been wired; when null (tests / dev
/// scaffolds), the envelope omits the `runtime_gauges` field so
/// existing test assertions stay green.
class ProxyRuntimeGauges {
  ProxyRuntimeGauges({this.postgresPoolGauge, this.ringBufferKeyCountGauge});

  /// Returns a snapshot of the Postgres pool, or null when the pool
  /// runs without connection reuse (close-on-commit mode).
  final PostgresPoolGaugeSnapshot? Function()? postgresPoolGauge;

  /// Returns the live ring-buffer `(operator_id, topic)` key count
  /// for the pubsub subscriber, or null when no subscriber is wired.
  final int? Function()? ringBufferKeyCountGauge;

  /// Snapshot every gauge into a JSON-shaped map. Each gauge is
  /// independently null-tolerant so a missing collector never tips
  /// the rest of the envelope to error. Empty when no collectors are
  /// wired (so callers can omit the field entirely).
  Map<String, Object?> snapshotJson() {
    final result = <String, Object?>{};
    final pgCollector = postgresPoolGauge;
    if (pgCollector != null) {
      try {
        final snapshot = pgCollector();
        if (snapshot != null) {
          result['postgres_pool'] = snapshot.toJson();
        }
      } on Exception catch (_) {
        // Collectors must not destabilize /health. Pool collectors can
        // surface a variety of Exception subtypes (postgres PgException,
        // StateError-like wrapped failures from a closed pool, etc.);
        // collapse them all into a uniform `error` field. Narrowed to
        // `Exception` so genuine `Error`s (assertion failures, OOM, type
        // errors) keep propagating instead of being silently masked.
        result['postgres_pool'] = <String, Object?>{
          'error': 'pool_gauge_collector_failed',
        };
      }
    }
    final ringCollector = ringBufferKeyCountGauge;
    if (ringCollector != null) {
      try {
        final value = ringCollector();
        if (value != null) {
          result['pubsub_subscriber'] = <String, Object?>{
            'ring_buffer_keys': value,
          };
        }
      } on Exception catch (_) {
        // Pubsub subscriber collectors are arbitrary closures wired by
        // the production entrypoint; any Exception subtype they raise
        // (StateError-like wraps from a closed subscriber, etc.) lands
        // here. Narrowed to `Exception` so genuine `Error`s continue to
        // propagate instead of being silently masked.
        result['pubsub_subscriber'] = <String, Object?>{
          'error': 'ring_buffer_gauge_collector_failed',
        };
      }
    }
    return result;
  }
}

/// Process-wide runtime gauge holder. Set once by the production
/// entrypoint (`tool/advisor_proxy/main.dart`) once the Postgres pool
/// and pubsub subscriber are constructed. Tests and dev scaffolds
/// leave this null; the /health route then omits the
/// `runtime_gauges` envelope field, preserving existing assertions.
ProxyRuntimeGauges? proxyRuntimeGauges;

class ProxyHealthStatus {
  const ProxyHealthStatus({
    required this.postgresOk,
    required this.ageOk,
    required this.pgvectorOk,
    this.metrics = const <String, ProxyHealthMetric>{},
    this.surfaces = const <String, ProxyHealthSurface>{},
    this.useFullEnvelope = true,
  });

  final bool postgresOk;
  final bool ageOk;
  final bool pgvectorOk;
  final Map<String, ProxyHealthMetric> metrics;
  final Map<String, ProxyHealthSurface> surfaces;

  /// When `false` (feature flag `health_envelope_full_v1` disabled),
  /// the response renders only the original B42 reserved 11 metrics
  /// + 6 surfaces — used as a rollback path if the expanded envelope
  /// regresses.
  final bool useFullEnvelope;

  bool get ok => postgresOk && ageOk && pgvectorOk;

  Map<String, Object?> toJson({required DateTime checkedAt}) {
    final reservedMetrics = useFullEnvelope
        ? proxyHealthReservedMetrics
        : _legacyReservedProxyHealthMetrics;
    final reservedSurfaces = useFullEnvelope
        ? proxyHealthReservedSurfaces
        : _legacyReservedProxyHealthSurfaces;

    final metricEnvelope = <String, ProxyHealthMetric>{
      ...reservedMetrics,
      ...<String, ProxyHealthMetric>{
        for (final entry in metrics.entries)
          entry.key: _enrichMetricWithReservedTier(
            entry.value,
            reservedMetrics[entry.key],
          ),
      },
    };
    // Surface envelope: start from reserved templates, then apply caller
    // overrides, then derive each surface's status from the rolled-up
    // status of its constituent metrics so the surfaces never drift
    // from the metrics.
    final mergedSurfaces = <String, ProxyHealthSurface>{
      ...reservedSurfaces,
      ...surfaces,
    };
    final surfaceEnvelope = <String, ProxyHealthSurface>{
      for (final entry in mergedSurfaces.entries)
        entry.key: entry.value.copyWith(
          status: _rollUpSurfaceStatus(entry.value, metricEnvelope),
        ),
    };

    final hasMetricProblem =
        _hasYellowOrRedMetric(metricEnvelope) ||
        _hasYellowOrRedSurface(surfaceEnvelope);
    final status = !ok
        ? 'unavailable'
        : hasMetricProblem
        ? 'degraded'
        : 'ok';
    final severity = _tieredOverallSeverity(
      dependenciesOk: ok,
      metrics: metricEnvelope,
    );

    final warnings = <Map<String, Object?>>[];
    for (final entry in metricEnvelope.entries) {
      final warning = entry.value.metadata['warning'];
      if (warning is String) {
        warnings.add(<String, Object?>{
          'metric': entry.key,
          'warning': warning,
          if (entry.value.metadata['budget_ms'] != null)
            'budget_ms': entry.value.metadata['budget_ms'],
        });
      }
    }

    return <String, Object?>{
      'status': status,
      'severity': severity,
      'contract': 'proxy_health.v1',
      'schema_version': 1,
      'checked_at': checkedAt.toUtc().toIso8601String(),
      'envelope_variant': useFullEnvelope ? 'full_v1' : 'legacy_b42',
      'dependencies': <String, Object?>{
        'postgres': _dependencyJson(
          ok: postgresOk,
          check: 'select_1',
          legacyKey: 'postgres_select_1',
        ),
        'age': _dependencyJson(
          ok: ageOk,
          check: 'cypher_match',
          legacyKey: 'age_cypher_match',
        ),
        'pgvector': _dependencyJson(
          ok: pgvectorOk,
          check: 'similarity',
          legacyKey: 'pgvector_similarity',
        ),
      },
      'surfaces': <String, Object?>{
        for (final entry in surfaceEnvelope.entries)
          entry.key: entry.value.toJson(),
      },
      'metrics': <String, Object?>{
        for (final entry in metricEnvelope.entries)
          entry.key: entry.value.toJson(),
      },
      'warnings': warnings,
      // Compatibility aliases for the first deep-health implementation.
      'postgres_select_1': postgresOk ? 'ok' : 'failed',
      'age_cypher_match': ageOk ? 'ok' : 'failed',
      'pgvector_similarity': pgvectorOk ? 'ok' : 'failed',
    };
  }
}

class ProxyHealthMetric {
  const ProxyHealthMetric({
    required this.status,
    required this.value,
    required this.unit,
    required this.description,
    required this.owner,
    this.source,
    this.observedAt,
    this.thresholds = const <String, Object?>{},
    this.metadata = const <String, Object?>{},
  });

  final String status;
  final Object? value;
  final String unit;
  final String description;
  final String owner;
  final String? source;
  final DateTime? observedAt;
  final Map<String, Object?> thresholds;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'value': value,
    'unit': unit,
    'description': description,
    'source': source,
    'owner': owner,
    'observed_at': observedAt?.toUtc().toIso8601String(),
    'thresholds': thresholds,
    'metadata': metadata,
  };
}

class ProxyHealthSurface {
  const ProxyHealthSurface({
    required this.status,
    required this.metrics,
    required this.owner,
  });

  final String status;
  final List<String> metrics;
  final String owner;

  ProxyHealthSurface copyWith({String? status}) => ProxyHealthSurface(
    status: status ?? this.status,
    metrics: metrics,
    owner: owner,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'metrics': metrics,
    'owner': owner,
  };
}

Map<String, Object?> _dependencyJson({
  required bool ok,
  required String check,
  required String legacyKey,
}) => <String, Object?>{
  'status': ok ? 'green' : 'red',
  'check': check,
  'legacy_key': legacyKey,
};

bool _hasYellowOrRedMetric(Map<String, ProxyHealthMetric> metrics) => metrics
    .values
    .any((metric) => metric.status == 'yellow' || metric.status == 'red');

bool _hasYellowOrRedSurface(Map<String, ProxyHealthSurface> surfaces) =>
    surfaces.values.any(
      (surface) => surface.status == 'yellow' || surface.status == 'red',
    );

/// Tier-aware overall severity computation per the B42 contract:
/// - Red:    any dependency probe is bad, OR any Tier-1 metric is non-green
/// - Yellow: any Tier-2 metric is non-green
/// - Green:  otherwise
///
/// Tier-3 metrics never bump severity. They drive Status: degraded only
/// when populated red/yellow (so the ops console can still see them) but
/// the [severity] flag stays green so operators are not paged for cost-
/// observability noise.
String _tieredOverallSeverity({
  required bool dependenciesOk,
  required Map<String, ProxyHealthMetric> metrics,
}) {
  if (!dependenciesOk) {
    return 'red';
  }
  for (final metric in metrics.values) {
    final tier = _metricTier(metric);
    if (tier == 1 && (metric.status == 'red' || metric.status == 'yellow')) {
      return 'red';
    }
  }
  for (final metric in metrics.values) {
    final tier = _metricTier(metric);
    if (tier == 2 && (metric.status == 'red' || metric.status == 'yellow')) {
      return 'yellow';
    }
  }
  return 'green';
}

int _metricTier(ProxyHealthMetric metric) {
  final raw = metric.metadata['tier'];
  if (raw is int) return raw;
  if (raw is String) return int.tryParse(raw) ?? 3;
  return 3;
}

/// When a caller passes a metric override for a reserved key without a
/// `tier` metadata entry, fold the reserved metric's tier in so severity
/// computation does not silently downgrade a Tier-1/Tier-2 producer to
/// Tier-3.
ProxyHealthMetric _enrichMetricWithReservedTier(
  ProxyHealthMetric metric,
  ProxyHealthMetric? reserved,
) {
  if (reserved == null) return metric;
  if (metric.metadata.containsKey('tier')) return metric;
  final reservedTier = reserved.metadata['tier'];
  if (reservedTier == null) return metric;
  return ProxyHealthMetric(
    status: metric.status,
    value: metric.value,
    unit: metric.unit,
    description: metric.description,
    source: metric.source,
    owner: metric.owner,
    observedAt: metric.observedAt,
    thresholds: metric.thresholds,
    metadata: <String, Object?>{...metric.metadata, 'tier': reservedTier},
  );
}

String _rollUpSurfaceStatus(
  ProxyHealthSurface surface,
  Map<String, ProxyHealthMetric> metrics,
) {
  var hasRed = false;
  var hasYellow = false;
  var hasUnknown = false;
  var hasGreen = false;
  for (final key in surface.metrics) {
    final metric = metrics[key];
    if (metric == null) continue;
    switch (metric.status) {
      case 'red':
        hasRed = true;
        break;
      case 'yellow':
        hasYellow = true;
        break;
      case 'green':
        hasGreen = true;
        break;
      case 'unknown':
      default:
        hasUnknown = true;
        break;
    }
  }
  if (hasRed) return 'red';
  if (hasYellow) return 'yellow';
  if (hasGreen && !hasUnknown) return 'green';
  if (hasGreen) return 'green'; // some unknown but no red/yellow → green wins.
  return 'unknown';
}

/// The original B42 reserved-11 metric set. Used when the
/// `health_envelope_full_v1` feature flag is OFF as the rollback path.
const Map<String, ProxyHealthMetric>
_legacyReservedProxyHealthMetrics = <String, ProxyHealthMetric>{
  'audit_chain_lag_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description:
        'Lag between current audit chain head and latest durable audit anchor.',
    source: 'audit_chain_anchors',
    owner: 'B37/B43',
    metadata: <String, Object?>{'tier': 1},
  ),
  'event_outbox_undelivered_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Undelivered event_outbox rows awaiting bridge delivery.',
    source: 'event_outbox',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 10000, 'red': 100000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'event_outbox_lag_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Age of the oldest undelivered event_outbox row.',
    source: 'event_outbox',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 60, 'red': 300},
    metadata: <String, Object?>{'tier': 2},
  ),
  'usage_caps_breach_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Requests refused because usage caps were reached.',
    source: 'proxy usage accounting',
    owner: 'B33',
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_node_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Canonical graph node count for operations health.',
    source: 'public.graph_health_metrics()',
    owner: 'B44',
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_edge_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Canonical active graph edge count for operations health.',
    source: 'public.graph_health_metrics()',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 3000000, 'red': 4000000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_traversal_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description: 'Graph traversal latency from the graph benchmark slice.',
    source: 'graph benchmark',
    owner: 'B44',
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_index_size_per_corpus': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Per-corpus vector index size.',
    source: 'vector index health helper',
    owner: 'B47',
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_query_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description: 'Filtered vector search latency summary.',
    source: 'filtered-search benchmark',
    owner: 'B47',
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_recall': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Filtered vector search benchmark recall.',
    source: 'filtered-search benchmark',
    owner: 'B47',
    metadata: <String, Object?>{'tier': 2},
  ),
  'rollup_freshness_per_grain': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Rollup freshness lag grouped by grain.',
    source: 'RollupFreshnessReporter.snapshot()',
    owner: 'B45',
    metadata: <String, Object?>{'tier': 2},
  ),
};

const Map<String, ProxyHealthSurface> _legacyReservedProxyHealthSurfaces =
    <String, ProxyHealthSurface>{
      'audit_chain': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>['audit_chain_lag_seconds'],
        owner: 'B37/B43',
      ),
      'event_outbox': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'event_outbox_undelivered_count',
          'event_outbox_lag_seconds',
        ],
        owner: 'Phase 10a',
      ),
      'usage_caps': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>['usage_caps_breach_count'],
        owner: 'B33',
      ),
      'graph': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'graph_node_count',
          'graph_edge_count',
          'graph_traversal_latency_ms',
        ],
        owner: 'B44',
      ),
      'vector': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'vector_index_size_per_corpus',
          'vector_query_latency_ms',
          'vector_recall',
        ],
        owner: 'B47',
      ),
      'rollups': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>['rollup_freshness_per_grain'],
        owner: 'B45',
      ),
    };

/// Full B42 producer catalog — 58 reserved metric slots covering every
/// signal the producer registry knows how to fill. Slots without a live
/// producer simply render with `status: 'unknown'`, `value: null`.
const Map<String, ProxyHealthMetric>
proxyHealthReservedMetrics = <String, ProxyHealthMetric>{
  // ── Tier 1 — foundation/auth/audit ─────────────────────────────
  'audit_chain_lag_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description:
        'Lag between current audit chain head and latest durable audit anchor.',
    source: 'audit_chain_anchors',
    owner: 'B37/B43',
    thresholds: <String, Object?>{'yellow': 1800, 'red': 21600},
    metadata: <String, Object?>{'tier': 1},
  ),
  'audit_chain_anchor_age_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Age of the most recent Azure Blob immutable audit anchor.',
    source: 'audit_chain_anchors',
    owner: 'B37/B43',
    thresholds: <String, Object?>{'yellow': 86400, 'red': 172800},
    metadata: <String, Object?>{'tier': 1},
  ),
  'migration_apply_drift_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Migration files in db/migrations not yet recorded as applied '
        'in proxy_migrations_applied.',
    source: 'proxy_migrations_applied',
    owner: 'B42',
    thresholds: <String, Object?>{'red': 1},
    metadata: <String, Object?>{'tier': 1},
  ),
  'firebase_jwks_fetch_alive': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'boolean',
    description: 'Firebase JWKS fetch succeeded inside cache TTL window.',
    source: 'firebase_jwks_cache_status',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 1},
  ),
  'service_principal_jwt_alive': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'boolean',
    description:
        'service-principal HMAC signer secret loaded and a recent sp: '
        'token verified successfully.',
    source: 'service_principals_signer_status',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 1},
  ),
  'circuit_breaker_anthropic_state': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'state',
    description:
        'Lock 7 circuit breaker state for the Anthropic provider '
        '(closed/half_open/open).',
    source: 'circuit_breaker_state',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 1},
  ),
  'circuit_breaker_voyage_state': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'state',
    description:
        'Lock 7 circuit breaker state for the Voyage provider '
        '(closed/half_open/open).',
    source: 'circuit_breaker_state',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 1},
  ),
  'azure_extensions_present': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Required Azure extensions installed in the active business '
        'database (AGE, pgvector, pg_diskann, pg_partman, '
        'pg_stat_statements, pgcrypto). pg_cron is tracked separately '
        'from Azure'
        's maintenance database.',
    source: 'pg_extension',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 1},
  ),
  'pg_cron_scheduler_alive': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'boolean',
    description:
        'pg_cron scheduler reported a successful run inside the last '
        '5 minutes.',
    source: 'cron.job_run_details',
    owner: 'B42',
    thresholds: <String, Object?>{'red_seconds_since_last_run': 300},
    metadata: <String, Object?>{'tier': 1},
  ),
  'proxy_idempotency_cache_alive': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'boolean',
    description:
        'proxy_requests idempotency table reachable and accepting reads.',
    source: 'proxy_requests',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 1},
  ),
  // ── Tier 2 — production hardening ──────────────────────────────
  'event_outbox_undelivered_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Undelivered event_outbox rows awaiting bridge delivery.',
    source: 'event_outbox',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 10000, 'red': 100000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'event_outbox_lag_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Age of the oldest undelivered event_outbox row.',
    source: 'event_outbox',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 60, 'red': 300},
    metadata: <String, Object?>{'tier': 2},
  ),
  'event_outbox_publish_error_rate': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description:
        'Rolling 5-minute event_outbox publish error rate (Decision 33).',
    source: 'event_outbox_publish_metrics',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
    metadata: <String, Object?>{'tier': 2},
  ),
  'event_outbox_dlq_depth': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Dead-lettered event_outbox rows awaiting operator review.',
    source: 'event_outbox_dead_letter',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 1, 'red': 100},
    metadata: <String, Object?>{'tier': 2},
  ),
  'event_outbox_retention_backlog': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Delivered event_outbox rows older than the 7-day retention window '
        'that are still in the live table.',
    source: 'event_outbox',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 100, 'red': 10000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'event_outbox_retention_lag_hours': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'hours',
    description:
        'Hours since the most recent event_outbox retention sweep completed.',
    source: 'event_outbox_retention_sweep_log',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 36, 'red': 168},
    metadata: <String, Object?>{'tier': 2},
  ),
  'notify_queue_usage_ratio': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'pg_notification_queue_usage() (Decision 33).',
    source: 'pg_notification_queue_usage',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 0.10, 'red': 0.25},
    metadata: <String, Object?>{'tier': 2},
  ),
  // Phase 10a.4 — bridge-side post-pickup lag. Same Q22 thresholds as
  // event_outbox_lag_seconds; SQL semantic differs (max(picked_up_at)
  // vs min(created_at)) so the two metrics catch different stalls.
  'event_outbox_bridge_lag_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description:
        'Seconds since the most recent event_outbox pickup that has not '
        'yet committed delivered_at (Decision 33).',
    source: 'event_outbox',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 60, 'red': 300},
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_node_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Canonical graph node count for operations health.',
    source: 'public.graph_health_metrics()',
    owner: 'B44',
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_edge_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Canonical active graph edge count for operations health '
        '(Decision 30: yellow 3M, red 4M).',
    source: 'public.graph_health_metrics()',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 3000000, 'red': 4000000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_traversal_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description:
        'Graph traversal p95 latency from the latest benchmark. '
        'Lock 3 isolated-p95 gate: yellow 250ms, red 500ms.',
    source: 'graph_benchmark_runs',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 250, 'red': 500},
    metadata: <String, Object?>{'tier': 2, 'percentile': 'p95'},
  ),
  'graph_traversal_p99_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description: 'Graph traversal p99 latency from the latest benchmark.',
    source: 'graph_benchmark_runs',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 750, 'red': 1500},
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_traversal_timeout_rate': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Rolling 5-minute graph traversal timeout rate.',
    source: 'graph_traversal_metrics',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_high_degree_node_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Vertices with degree above the high-degree band.',
    source: 'public.graph_health_metrics()',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 100, 'red': 1000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_failed_traversals_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Graph traversal failure count over the last 5 minutes.',
    source: 'graph_traversal_metrics',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 1, 'red': 100},
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_projection_age_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Age of the most recent AGE projection rebuild.',
    source: 'graph_projection_runs',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 86400, 'red': 604800},
    metadata: <String, Object?>{'tier': 2},
  ),
  'graph_growth_projection_90d_edges': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        '90-day projected edge count (Decision 30: red ≥ 5M triggers '
        'projection rollover planning).',
    source: 'graph_growth_projection',
    owner: 'B44',
    thresholds: <String, Object?>{'red': 5000000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_index_size_per_corpus': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Per-corpus vector index size.',
    source: 'vector_index_health',
    owner: 'B47',
    thresholds: <String, Object?>{'yellow': 5000000, 'red': 8000000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_query_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description: 'Filtered vector search p50 latency.',
    source: 'vector_benchmark_runs',
    owner: 'B47',
    thresholds: <String, Object?>{'yellow': 200, 'red': 400},
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_recall': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Filtered vector search recall@10.',
    source: 'vector_benchmark_runs',
    owner: 'B47',
    thresholds: <String, Object?>{'yellow': 0.85, 'red': 0.70},
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_query_p99_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description: 'Filtered vector search p99 latency.',
    source: 'vector_benchmark_runs',
    owner: 'B47',
    thresholds: <String, Object?>{'yellow': 600, 'red': 1200},
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_query_timeout_rate': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Rolling 5-minute filtered vector search timeout rate.',
    source: 'vector_query_metrics',
    owner: 'B47',
    thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_active_count_per_corpus': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Active vector count per corpus (Decision 31: yellow 5M, red 8M).',
    source: 'vector_index_health',
    owner: 'B47',
    thresholds: <String, Object?>{'yellow': 5000000, 'red': 8000000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_index_build_age_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Age of the most recent vector index build.',
    source: 'vector_index_health',
    owner: 'B47',
    thresholds: <String, Object?>{'yellow': 604800, 'red': 2592000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'vector_growth_projection_90d_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        '90-day projected vector count per corpus (Decision 31: red '
        '≥ 10M = DiskANN cutover trigger).',
    source: 'vector_growth_projection',
    owner: 'B47',
    thresholds: <String, Object?>{'red': 10000000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'rollup_freshness_per_grain': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Rollup freshness lag grouped by grain.',
    source: 'aggregation_state',
    owner: 'B45',
    thresholds: <String, Object?>{'yellow': 3600, 'red': 21600},
    metadata: <String, Object?>{'tier': 2},
  ),
  'rollup_refresh_lag_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Time since the most recent rollup refresh job ran.',
    source: 'aggregation_state',
    owner: 'B45',
    thresholds: <String, Object?>{'yellow': 3600, 'red': 14400},
    metadata: <String, Object?>{'tier': 2},
  ),
  'rollup_failed_refreshes_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'pg_cron rollup refreshes that failed in last 24h.',
    source: 'cron.job_run_details',
    owner: 'B45',
    thresholds: <String, Object?>{'yellow': 1, 'red': 5},
    metadata: <String, Object?>{'tier': 2},
  ),
  'rollup_concurrent_refresh_status': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'boolean',
    description:
        'Whether a REFRESH MATERIALIZED VIEW CONCURRENTLY is currently '
        'running.',
    source: 'pg_stat_activity',
    owner: 'B45',
    metadata: <String, Object?>{'tier': 2},
  ),
  'partition_maintenance_last_run_age_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description:
        'Age of the last successful pg_partman run_maintenance() (Lock 2).',
    source: 'cron.job_run_details',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 7200, 'red': 14400},
    metadata: <String, Object?>{'tier': 2},
  ),
  'partition_default_row_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Rows landed in the pg_partman default partition for usage_logs '
        '(Lock 2).',
    source: 'usage_logs_default',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 1, 'red': 1000},
    metadata: <String, Object?>{'tier': 2},
  ),
  'partition_count_active': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Active child partitions registered with pg_partman (Lock 2).',
    source: 'partman.part_config',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 2},
  ),
  'pg_cron_jobs_failed_24h': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'pg_cron job runs failed in the last 24 hours.',
    source: 'cron.job_run_details',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 1, 'red': 5},
    metadata: <String, Object?>{'tier': 2},
  ),
  'usage_caps_breach_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Requests refused because usage caps were reached.',
    source: 'proxy usage accounting',
    owner: 'B33',
    thresholds: <String, Object?>{'yellow': 1, 'red': 100},
    metadata: <String, Object?>{'tier': 2},
  ),
  // ── Tier 3 — ops observability ─────────────────────────────────
  'circuit_breaker_open_count_total': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Number of breakers currently in open or half_open state.',
    source: 'circuit_breaker_state',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 3},
  ),
  'fallback_chain_usage_count_anthropic': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Requests in last 5 minutes that traversed the Anthropic '
        'fallback chain.',
    source: 'usage_logs',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 3},
  ),
  'fallback_chain_usage_count_voyage': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Requests in last 5 minutes that traversed the Voyage '
        'fallback chain.',
    source: 'usage_logs',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 3},
  ),
  'provider_5xx_rate_anthropic': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Rolling 5-minute Anthropic 5xx rate.',
    source: 'provider_request_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 0.05, 'red': 0.25},
    metadata: <String, Object?>{'tier': 3},
  ),
  'provider_5xx_rate_voyage': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Rolling 5-minute Voyage 5xx rate.',
    source: 'provider_request_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 0.05, 'red': 0.25},
    metadata: <String, Object?>{'tier': 3},
  ),
  'provider_429_rate_anthropic': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Rolling 5-minute Anthropic 429 rate.',
    source: 'provider_request_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 0.05, 'red': 0.25},
    metadata: <String, Object?>{'tier': 3},
  ),
  'provider_429_rate_voyage': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Rolling 5-minute Voyage 429 rate.',
    source: 'provider_request_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 0.05, 'red': 0.25},
    metadata: <String, Object?>{'tier': 3},
  ),
  'proxy_request_p99_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description: 'Rolling 5-minute proxy request p99 latency.',
    source: 'proxy_request_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 2000, 'red': 5000},
    metadata: <String, Object?>{'tier': 3},
  ),
  'proxy_request_5xx_rate': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Rolling 5-minute proxy 5xx response rate.',
    source: 'proxy_request_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
    metadata: <String, Object?>{'tier': 3},
  ),
  'prompt_cache_hit_rate': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Anthropic prompt cache hit rate (Hard Promise #9 lever 1).',
    source: 'cache_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 0.30, 'red': 0.10},
    metadata: <String, Object?>{'tier': 3},
  ),
  'response_cache_hit_rate': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description:
        'Memorystore response cache hit rate (Hard Promise #9 lever 3).',
    source: 'cache_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 0.30, 'red': 0.10},
    metadata: <String, Object?>{'tier': 3},
  ),
  'semantic_cache_hit_rate': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Semantic cache hit rate (Hard Promise #9 lever 3).',
    source: 'cache_metrics',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow': 0.30, 'red': 0.10},
    metadata: <String, Object?>{'tier': 3},
  ),
  'cost_per_query_class_haiku': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'usd',
    description: 'Rolling 1-hour mean cost per Haiku-routed request (USD).',
    source: 'usage_logs',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow_factor': 2.0, 'red_factor': 5.0},
    metadata: <String, Object?>{'tier': 3},
  ),
  'cost_per_query_class_sonnet': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'usd',
    description: 'Rolling 1-hour mean cost per Sonnet-routed request (USD).',
    source: 'usage_logs',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow_factor': 2.0, 'red_factor': 5.0},
    metadata: <String, Object?>{'tier': 3},
  ),
  'cost_per_query_class_voyage': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'usd',
    description: 'Rolling 1-hour mean cost per Voyage embedding request (USD).',
    source: 'usage_logs',
    owner: 'B42',
    thresholds: <String, Object?>{'yellow_factor': 2.0, 'red_factor': 5.0},
    metadata: <String, Object?>{'tier': 3},
  ),
  'batch_api_pending_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Workflow runs in AWAITING_BATCH (Lock 8). Yellow at 100, '
        'red at 1,000.',
    source: 'workflow_runs',
    owner: 'Phase 12.0',
    thresholds: <String, Object?>{'yellow': 100, 'red': 1000},
    metadata: <String, Object?>{'tier': 3},
  ),
  'cloud_run_instance_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Active Cloud Run instance count for the proxy.',
    source: 'cloud_run.instance_metrics',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 3},
  ),
  // Slice A11.1.b — surface the per-instance SessionRecordIncompleteGauge
  // into the deep-health envelope. Multi-instance Cloud Run rolls up per-
  // pod gauge state at the observability sink because each pod emits its
  // own /health JSON. Authority: docs/archive/_audits/post_codex_wave/
  // wave_completion_deep_audit_2026_05_13.md finding #2 + R3 §2 stretch
  // goal (consumer side, A11.1.b).
  'session_record_incomplete_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description:
        'Total per-instance increments of '
        'proxy.session_record.incomplete{route, missing_field} since '
        'process start. Observability-only: a session-finalizing 2xx '
        'whose body fails SessionRecord.assertComplete bumps the matching '
        '(route, missing_field) bucket. Metadata carries the full '
        '(route -> missing_field -> count) slice so a downstream observability '
        'sink can roll up across multi-instance Cloud Run pods.',
    source: 'session_record_incomplete_gauge',
    owner: 'B42',
    metadata: <String, Object?>{'tier': 2},
  ),
};

const Map<String, ProxyHealthSurface> proxyHealthReservedSurfaces =
    <String, ProxyHealthSurface>{
      'audit_chain': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'audit_chain_lag_seconds',
          'audit_chain_anchor_age_seconds',
          'migration_apply_drift_count',
        ],
        owner: 'B37/B43',
      ),
      'event_outbox': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'event_outbox_undelivered_count',
          'event_outbox_lag_seconds',
          'event_outbox_publish_error_rate',
          'event_outbox_dlq_depth',
          'notify_queue_usage_ratio',
          // Phase 10a.4 — bridge-side post-pickup lag (sister metric to
          // event_outbox_lag_seconds; both bound to the same Q22 lock).
          'event_outbox_bridge_lag_seconds',
        ],
        owner: 'Phase 10a',
      ),
      'usage_caps': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>['usage_caps_breach_count'],
        owner: 'B33',
      ),
      'graph': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'graph_node_count',
          'graph_edge_count',
          'graph_traversal_latency_ms',
          'graph_traversal_p99_latency_ms',
          'graph_traversal_timeout_rate',
          'graph_high_degree_node_count',
          'graph_failed_traversals_count',
          'graph_projection_age_seconds',
          'graph_growth_projection_90d_edges',
        ],
        owner: 'B44',
      ),
      'vector': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'vector_index_size_per_corpus',
          'vector_query_latency_ms',
          'vector_recall',
          'vector_query_p99_latency_ms',
          'vector_query_timeout_rate',
          'vector_active_count_per_corpus',
          'vector_index_build_age_seconds',
          'vector_growth_projection_90d_count',
        ],
        owner: 'B47',
      ),
      'rollups': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'rollup_freshness_per_grain',
          'rollup_refresh_lag_seconds',
          'rollup_failed_refreshes_count',
          'rollup_concurrent_refresh_status',
        ],
        owner: 'B45',
      ),
      'circuit_breakers': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'circuit_breaker_anthropic_state',
          'circuit_breaker_voyage_state',
          'circuit_breaker_open_count_total',
          'fallback_chain_usage_count_anthropic',
          'fallback_chain_usage_count_voyage',
          'provider_5xx_rate_anthropic',
          'provider_5xx_rate_voyage',
          'provider_429_rate_anthropic',
          'provider_429_rate_voyage',
        ],
        owner: 'B42',
      ),
      'infra': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'azure_extensions_present',
          'pg_cron_scheduler_alive',
          'proxy_idempotency_cache_alive',
          'partition_maintenance_last_run_age_seconds',
          'partition_default_row_count',
          'partition_count_active',
          'pg_cron_jobs_failed_24h',
          'cloud_run_instance_count',
          // Slice A11.1.b — session-record gauge consumer (per-instance
          // observability buffer surfaced into /health).
          'session_record_incomplete_count',
        ],
        owner: 'B42',
      ),
      'auth': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'firebase_jwks_fetch_alive',
          'service_principal_jwt_alive',
        ],
        owner: 'B42',
      ),
      'proxy_traffic': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'proxy_request_p99_latency_ms',
          'proxy_request_5xx_rate',
        ],
        owner: 'B42',
      ),
      'cost': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'prompt_cache_hit_rate',
          'response_cache_hit_rate',
          'semantic_cache_hit_rate',
          'cost_per_query_class_haiku',
          'cost_per_query_class_sonnet',
          'cost_per_query_class_voyage',
          'batch_api_pending_count',
        ],
        owner: 'B42',
      ),
    };

class ScaffoldFailingProxyHealthCheckStore implements ProxyHealthCheckStore {
  const ScaffoldFailingProxyHealthCheckStore();

  @override
  Future<ProxyHealthStatus> check() async {
    throw StateError(
      '11a.11d scaffold: real Postgres health checks are not wired.',
    );
  }
}

/// Read-only function shape for the deep-health producer registry. The
/// runtime injects a Postgres-backed runner; tests inject a fake.
typedef ProxyHealthQueryRunnerFn =
    Future<List<Map<String, Object?>>> Function(
      String sql, {
      Map<String, Object?> parameters,
    });

class ProxySchemaContractException implements Exception {
  ProxySchemaContractException(Iterable<String> missingObjects)
    : missingObjects = List<String>.unmodifiable(missingObjects);

  final List<String> missingObjects;

  @override
  String toString() =>
      'admin proxy schema contract missing: ${missingObjects.join(', ')}';
}

/// Verifies that the live database contains the schema objects required
/// by the non-demo admin console. This deliberately does not apply
/// migrations; deploy/runbook tooling owns migration execution. The proxy
/// only fails closed before binding when code and schema are out of step.
class AdminProxySchemaContractVerifier {
  AdminProxySchemaContractVerifier({required this.runnerFn});

  final ProxyHealthQueryRunnerFn runnerFn;

  static const List<String> requiredTables = <String>[
    'public.operators',
    'public.feature_flags',
    'public.users',
    'public.corpus_versions',
    'public.corpus_version_chunks',
    'public.admin_idempotency_cache',
    'public.provider_credentials',
    'public.graphify_review_audit',
    'public.corpus_invalidation_events',
    'public.admin_request_idempotency',
  ];

  static const List<String> requiredColumns = <String>[
    'public.operators.suspended_at',
    'public.feature_flags.kind',
    'public.feature_flags.description',
    'public.feature_flags.updated_by',
    'public.users.firebase_uid',
  ];

  static const List<String> requiredFeatureFlags = <String>[
    'kms_real_provider_azure_db_enabled',
    'kms_real_provider_voyage_enabled',
    'kms_real_provider_gemini_enabled',
    'kms_real_provider_anthropic_enabled',
  ];

  static const String _schemaContractSql = '''
with required_tables(object_name) as (
  values
    ('public.operators'),
    ('public.feature_flags'),
    ('public.users'),
    ('public.corpus_versions'),
    ('public.corpus_version_chunks'),
    ('public.admin_idempotency_cache'),
    ('public.provider_credentials'),
    ('public.graphify_review_audit'),
    ('public.corpus_invalidation_events'),
    ('public.admin_request_idempotency')
),
required_columns(object_name) as (
  values
    ('public.operators.suspended_at'),
    ('public.feature_flags.kind'),
    ('public.feature_flags.description'),
    ('public.feature_flags.updated_by'),
    ('public.users.firebase_uid')
),
required_feature_flags(flag_name) as (
  values
    ('kms_real_provider_azure_db_enabled'),
    ('kms_real_provider_voyage_enabled'),
    ('kms_real_provider_gemini_enabled'),
    ('kms_real_provider_anthropic_enabled')
)
select 'table:' || object_name as object_name
from required_tables
where to_regclass(object_name) is null
union all
select 'column:' || object_name as object_name
from required_columns
where not exists (
  select 1
  from information_schema.columns c
  where c.table_schema = split_part(object_name, '.', 1)
    and c.table_name = split_part(object_name, '.', 2)
    and c.column_name = split_part(object_name, '.', 3)
)
union all
select 'row:public.feature_flags.' || flag_name as object_name
from required_feature_flags
where to_regclass('public.feature_flags') is not null
  and not exists (
    select 1
    from public.feature_flags f
    where f.flag_name = flag_name
      and f.operator_id = public.feature_flag_system_wide_operator_id()
      and f.location_id is null
  )
order by object_name
''';

  Future<void> verify({Duration budget = const Duration(seconds: 10)}) async {
    final rows = await runnerFn(_schemaContractSql).timeout(budget);
    final missing = rows
        .map((row) => row['object_name']?.toString())
        .whereType<String>()
        .toList(growable: false);
    if (missing.isNotEmpty) {
      throw ProxySchemaContractException(missing);
    }
  }
}

/// Producer functions in `tool/advisor_proxy/health_producers/` use this
/// inputs envelope. Defined here to avoid pulling the family files into
/// the main proxy file. The shape mirrors
/// `health_producers/health_producer.dart::ProxyHealthProducerContext`.
class ProxyHealthRegistryContext {
  const ProxyHealthRegistryContext({
    required this.runnerFn,
    required this.now,
    this.budget = const Duration(milliseconds: 250),
    this.inMemoryBreakerStates,
    this.sessionRecordIncompleteSnapshot,
  });

  final ProxyHealthQueryRunnerFn runnerFn;
  final DateTime now;
  final Duration budget;

  /// Block 2 (Lock 7 v1) — optional accessor into the per-instance
  /// circuit breakers held by `routeRequest`. When non-null, breaker
  /// producers use this snapshot instead of querying the
  /// `circuit_breaker_state` DB table.
  final Map<String, CircuitState> Function()? inMemoryBreakerStates;

  /// Slice A11.1.b — optional accessor into the per-instance
  /// [SessionRecordIncompleteGauge] held by `routeRequest`. Mirrors the
  /// `inMemoryBreakerStates` side-channel pattern: producers reach into
  /// process-local observability state without that state needing a
  /// Postgres-backed source. The shape matches
  /// [SessionRecordIncompleteGauge.snapshot] (route -> missing_field ->
  /// count); the producer projects it into the deep-health envelope as
  /// `session_record_incomplete_count`. Per-pod identity is conveyed by
  /// the envelope-level pod label produced separately by Cloud Run; this
  /// accessor exposes only the gauge state.
  /// Authority: docs/archive/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md
  /// finding #2 + docs/archive/_execution/lane_a_code_health/03_execution_slices.md
  /// Slice A11.1 (consumer side, A11.1.b).
  final Map<String, Map<String, int>> Function()?
  sessionRecordIncompleteSnapshot;
}

typedef ProxyHealthRegistryProducer =
    Future<ProxyHealthMetric> Function(ProxyHealthRegistryContext context);

/// Deep-health feature flags. `health_envelope_full_v1` defaults to true
/// (Block 3, task 6); flipping to false reverts the route to the legacy
/// 11-metric envelope as a rollback path.
class ProxyHealthFeatureFlags {
  const ProxyHealthFeatureFlags({this.healthEnvelopeFullV1 = true});

  final bool healthEnvelopeFullV1;
}

/// Result envelope for the dependency-probe + producer registry. Used
/// internally by [RegistryProxyHealthCheckStore] before being projected
/// into [ProxyHealthStatus].
class ProxyHealthRegistryResult {
  const ProxyHealthRegistryResult({
    required this.postgresOk,
    required this.ageOk,
    required this.pgvectorOk,
    required this.metrics,
  });

  final bool postgresOk;
  final bool ageOk;
  final bool pgvectorOk;
  final Map<String, ProxyHealthMetric> metrics;
}

/// Drives deep health from a producer catalog + dependency probes.
///
/// Producers receive a [ProxyHealthRegistryContext]; each producer is
/// budget-bounded without abandoning already-started database work, and
/// the registry also guards custom producers with the same budget helper.
/// A failing producer or timeout never crashes the route; the projection
/// downgrades to `status: 'unknown'`.
class RegistryProxyHealthCheckStore implements ProxyHealthCheckStore {
  RegistryProxyHealthCheckStore({
    required this.runnerFn,
    required this.dependencyProbe,
    required this.producers,
    this.featureFlags = const ProxyHealthFeatureFlags(),
    this.now,
    this.producerBudget = const Duration(milliseconds: 250),
    this.outerProducerBudget = const Duration(milliseconds: 750),
    this.producerRouteBudget = const Duration(seconds: 3),
    this.producerConcurrency = 4,
    this.inMemoryBreakerStates,
    this.sessionRecordIncompleteSnapshot,
  }) : assert(producerConcurrency > 0);

  final ProxyHealthQueryRunnerFn runnerFn;
  final Future<ProxyHealthDependencyProbe> Function(
    ProxyHealthQueryRunnerFn runnerFn,
    DateTime now,
  )
  dependencyProbe;
  final Map<String, ProxyHealthRegistryProducer> producers;
  final ProxyHealthFeatureFlags featureFlags;
  final DateTime Function()? now;
  final Duration producerBudget;
  final Duration outerProducerBudget;
  final Duration producerRouteBudget;
  final int producerConcurrency;
  final Map<String, CircuitState> Function()? inMemoryBreakerStates;

  /// Slice A11.1.b — optional accessor for the in-process
  /// [SessionRecordIncompleteGauge] snapshot. When wired, the deep-health
  /// producer surfaces `session_record_incomplete_count` so multi-instance
  /// Cloud Run can roll up per-pod gauge state. When null, the producer
  /// renders `status: 'unknown'` (back-compat with tests + scaffolds that
  /// don't plumb the gauge through every health-check call site).
  final Map<String, Map<String, int>> Function()?
  sessionRecordIncompleteSnapshot;

  @override
  Future<ProxyHealthStatus> check() async {
    final clock = now ?? DateTime.now;
    final asOf = clock();
    final probe = await dependencyProbe(runnerFn, asOf);

    final allowedKeys = featureFlags.healthEnvelopeFullV1
        ? proxyHealthReservedMetrics.keys.toSet()
        : _legacyReservedProxyHealthMetrics.keys.toSet();

    final selected = <String, ProxyHealthRegistryProducer>{
      for (final entry in producers.entries)
        if (allowedKeys.contains(entry.key)) entry.key: entry.value,
    };

    final selectedEntries = selected.entries.toList(growable: false);
    final results = probe.postgresOk
        ? await _runSelectedWithRouteBudget(selectedEntries, asOf)
        : const <MapEntry<String, ProxyHealthMetric>>[];
    final metrics = <String, ProxyHealthMetric>{
      for (final entry in results) entry.key: entry.value,
    };

    return ProxyHealthStatus(
      postgresOk: probe.postgresOk,
      ageOk: probe.ageOk,
      pgvectorOk: probe.pgvectorOk,
      metrics: metrics,
      useFullEnvelope: featureFlags.healthEnvelopeFullV1,
    );
  }

  Future<List<MapEntry<String, ProxyHealthMetric>>> _runSelectedWithRouteBudget(
    List<MapEntry<String, ProxyHealthRegistryProducer>> selected,
    DateTime asOf,
  ) async {
    if (selected.isEmpty) return const <MapEntry<String, ProxyHealthMetric>>[];
    try {
      return await _runSelected(selected, asOf).timeout(producerRouteBudget);
    } on TimeoutException {
      return <MapEntry<String, ProxyHealthMetric>>[
        for (final entry in selected)
          MapEntry(
            entry.key,
            _unknownProducerMetric(
              key: entry.key,
              observedAt: asOf,
              warning: 'registry_route_budget_exceeded',
              budget: producerRouteBudget,
            ),
          ),
      ];
    }
  }

  Future<List<MapEntry<String, ProxyHealthMetric>>> _runSelected(
    List<MapEntry<String, ProxyHealthRegistryProducer>> selected,
    DateTime asOf,
  ) async {
    if (selected.isEmpty) return const <MapEntry<String, ProxyHealthMetric>>[];

    final context = ProxyHealthRegistryContext(
      runnerFn: runnerFn,
      now: asOf,
      budget: producerBudget,
      inMemoryBreakerStates: inMemoryBreakerStates,
      sessionRecordIncompleteSnapshot: sessionRecordIncompleteSnapshot,
    );
    final results = <MapEntry<String, ProxyHealthMetric>>[];
    var nextIndex = 0;
    final workerCount = producerConcurrency < selected.length
        ? producerConcurrency
        : selected.length;

    Future<void> runWorker() async {
      while (true) {
        final index = nextIndex;
        nextIndex += 1;
        if (index >= selected.length) return;
        final entry = selected[index];
        results.add(await _runOne(entry.key, entry.value, context));
      }
    }

    await Future.wait(<Future<void>>[
      for (var i = 0; i < workerCount; i += 1) runWorker(),
    ]);
    return results;
  }

  Future<MapEntry<String, ProxyHealthMetric>> _runOne(
    String key,
    ProxyHealthRegistryProducer producer,
    ProxyHealthRegistryContext context,
  ) async {
    try {
      final metric = await awaitHealthOperationWithBudget(
        producer(context),
        budget: outerProducerBudget,
      );
      return MapEntry(key, metric);
    } on Exception catch (_) {
      // Producers are arbitrary `ProxyHealthRegistryProducer` closures
      // wired by the registry; the budget helper raises `TimeoutException`
      // and any producer-side `Exception` subtype propagates through
      // (postgres PgException, network IOException, parse FormatException,
      // etc.). Collapse them all into the `unknown` placeholder metric so
      // one bad producer cannot wedge the registry pass. Narrowed to
      // `Exception` so genuine `Error`s (assertion failures, OOM, type
      // errors) keep propagating instead of being silently masked.
      return MapEntry(
        key,
        _unknownProducerMetric(
          key: key,
          observedAt: context.now,
          warning: 'registry_outer_failure',
        ),
      );
    }
  }

  ProxyHealthMetric _unknownProducerMetric({
    required String key,
    required DateTime observedAt,
    required String warning,
    Duration? budget,
  }) {
    final reserved =
        proxyHealthReservedMetrics[key] ??
        _legacyReservedProxyHealthMetrics[key];
    return ProxyHealthMetric(
      status: 'unknown',
      value: null,
      unit: reserved?.unit ?? 'unknown',
      description:
          reserved?.description ?? 'Producer failed in registry runner.',
      source: reserved?.source,
      owner: reserved?.owner ?? 'B42',
      observedAt: observedAt,
      thresholds: reserved?.thresholds ?? const <String, Object?>{},
      metadata: <String, Object?>{
        ...?reserved?.metadata,
        'warning': warning,
        if (budget != null) 'budget_ms': budget.inMilliseconds,
      },
    );
  }
}

/// Result of a single dependency probe pass.
class ProxyHealthDependencyProbe {
  const ProxyHealthDependencyProbe({
    required this.postgresOk,
    required this.ageOk,
    required this.pgvectorOk,
  });

  final bool postgresOk;
  final bool ageOk;
  final bool pgvectorOk;
}

/// Default dependency probe — three small queries, each independently
/// budget-bounded.
///
/// Liveness is decoupled from data presence: AGE and pgvector probes
/// check that the *extension* is loaded and round-trip a tiny syntactic
/// value through it (cypher() returns a constant; `'[1,2,3]'::vector`
/// constructs a vector). An empty graph or empty embeddings table must
/// not flip these probes to false because that would tie HTTP 503 to
/// data presence rather than dependency liveness, which the contract
/// forbids.
///
/// Errors and timeouts project to `false` so a flaky extension never
/// crashes the deep-health route.
Future<ProxyHealthDependencyProbe> defaultProxyHealthDependencyProbe(
  ProxyHealthQueryRunnerFn runnerFn,
  DateTime now, {
  Duration budget = const Duration(milliseconds: 250),
}) async {
  Future<bool> probe(String sql) async {
    try {
      final rows = await awaitHealthOperationWithBudget(
        runnerFn(sql),
        budget: budget,
      );
      return rows.isNotEmpty;
    } on Exception catch (_) {
      // Dependency liveness must project to `false` (not crash) for
      // every flake mode: `TimeoutException` from the budget helper,
      // `PgException` from the postgres driver, `IOException` from the
      // network layer, etc. Collapse them all into a missing-liveness
      // signal. Narrowed to `Exception` so genuine `Error`s (assertion
      // failures, OOM, type errors) keep propagating instead of being
      // silently masked behind a green deep-health envelope.
      return false;
    }
  }

  final results = await Future.wait(<Future<bool>>[
    // Postgres liveness: server can answer `select 1`.
    probe('select 1 as ok'),
    // AGE liveness: extension is loaded. The contract is "AGE is
    // installed and reachable", not "the graph contains data".
    probe("select 1 as ok from pg_extension where extname = 'age'"),
    // pgvector liveness: extension is loaded AND the `vector` type
    // round-trips a literal value. Independent of any embedding row
    // existing in the database.
    probe(
      "select 1 as ok from pg_extension where extname = 'vector' "
      "and ('[1,2,3]'::vector) is not null",
    ),
  ]);

  return ProxyHealthDependencyProbe(
    postgresOk: results[0],
    ageOk: results[1],
    pgvectorOk: results[2],
  );
}

/// HARD-A — production-grade dependency probe.
///
/// `defaultProxyHealthDependencyProbe` (above) only verifies extension
/// presence. The hardening contract requires the AGE check to actually
/// invoke cypher `MATCH (n) RETURN 1 LIMIT 1` and the pgvector check
/// to compute a real distance, so a regression in either path surfaces
/// as `red` instead of green.
///
/// Each check passes when the SQL call returns without throwing. Row
/// count is not the success criterion — `MATCH (n)` against an empty
/// graph correctly returns zero rows, and an empty graph must not
/// flip the dependency to `red` (that would tie HTTP 503 to data
/// presence rather than dependency liveness).
///
/// Errors and timeouts project to `false` so a flaky extension never
/// crashes the deep-health route.
Future<ProxyHealthDependencyProbe> strictProxyHealthDependencyProbe(
  ProxyHealthQueryRunnerFn runnerFn,
  DateTime now, {
  Duration budget = const Duration(milliseconds: 250),
  String ageGraphName = 'forgeflow',
}) async {
  Future<bool> probe(String sql) async {
    try {
      await awaitHealthOperationWithBudget(runnerFn(sql), budget: budget);
      return true;
    } on Exception catch (_) {
      // HARD-A dependency liveness mirrors the default probe: project
      // every Exception subtype (`TimeoutException` from the budget
      // helper, `PgException` from the cypher/vector round-trips, etc.)
      // to `false` so a flaky extension can never crash the deep-health
      // route. Narrowed to `Exception` so genuine `Error`s (assertion
      // failures, OOM, type errors) keep propagating instead of being
      // silently masked behind a green health envelope.
      return false;
    }
  }

  // AGE cypher must be a SINGLE statement so it survives the proxy's
  // prepared-query runner (`package:postgres` `Sql.named(...)` rejects
  // multi-command strings). Fully qualify both the function
  // (`ag_catalog.cypher`) and the result type (`ag_catalog.agtype`)
  // instead of prefixing a `SET search_path` — same effect, one
  // statement. AGE returns zero rows on an empty graph, which still
  // succeeds because the probe's success criterion is "no throw".
  const String ageCypherProbeSql =
      "select * from ag_catalog.cypher('forgeflow', "
      "\$\$ MATCH (n) RETURN 1 LIMIT 1 \$\$) as (v ag_catalog.agtype)";

  final results = await Future.wait(<Future<bool>>[
    // Postgres: `select 1` round-trips through the driver.
    probe('select 1 as ok'),
    // AGE: real cypher MATCH against the canonical graph. Empty graph
    // returns zero rows but does not raise — still green.
    probe(ageCypherProbeSql),
    // pgvector: actual distance operator (`<->`) so a regressed
    // operator surfaces, not just extension presence.
    probe("select '[1,0,0]'::vector <-> '[0,1,0]'::vector as distance"),
  ]);

  return ProxyHealthDependencyProbe(
    postgresOk: results[0],
    ageOk: results[1],
    pgvectorOk: results[2],
  );
}

/// Cross-DB pg_cron via FDW bootstrap.
///
/// Azure Database for PostgreSQL Flexible Server installs `pg_cron` into a
/// single dedicated database (`postgres`). To schedule jobs against the
/// `forgeflow` business database from that scheduler, we expose the
/// business database through a `postgres_fdw` foreign server and a
/// foreign-table mapping. The proxy boots this once at startup if the
/// mapping is missing — idempotent, no-op when already configured.
Future<void> ensureProxyHealthCronFdwBootstrap({
  required ProxyHealthQueryRunnerFn runnerFn,
  String foreignServerName = 'forgeflow_app',
  String foreignDatabase = 'forgeflow',
  Duration budget = const Duration(seconds: 5),
}) async {
  Future<List<Map<String, Object?>>> run(String sql) =>
      runnerFn(sql).timeout(budget);

  // 1. Ensure postgres_fdw is loaded.
  await run('create extension if not exists postgres_fdw');

  // 2. Ensure the foreign server points at the business database. The
  //    server-name lookup is parameterized through a where-clause to
  //    avoid creating duplicates.
  final servers = await run(
    "select srvname from pg_foreign_server where srvname = '$foreignServerName'",
  );
  if (servers.isEmpty) {
    await run(
      "create server $foreignServerName foreign data wrapper postgres_fdw "
      "options (host 'localhost', dbname '$foreignDatabase')",
    );
  }

  // 3. Ensure user mapping for the cron-runner role.
  final mappings = await run(
    "select usename from pg_user_mappings "
    "where srvname = '$foreignServerName' and usename = current_user",
  );
  if (mappings.isEmpty) {
    await run(
      "create user mapping for current_user server $foreignServerName "
      "options (user current_user)",
    );
  }
}

/// Records on-disk migration filenames into `proxy_migrations_applied`
/// at proxy startup so the Tier-1 `migration_apply_drift_count`
/// producer has a registry to compare against. Idempotent — uses
/// `on conflict do nothing` against the unique filename index.
///
/// Returns the count of newly inserted rows; existing rows are not
/// re-touched. The proxy startup logs the count by name only.
class ProxyMigrationApplyRegistryWriter {
  ProxyMigrationApplyRegistryWriter({required this.runnerFn});

  final ProxyHealthQueryRunnerFn runnerFn;

  Future<int> recordAppliedMigrations(
    Iterable<String> migrationFilenames, {
    Duration budget = const Duration(seconds: 10),
  }) async {
    var inserted = 0;
    for (final filename in migrationFilenames) {
      // Defensive: refuse anything but a basename — the registry is
      // a public-schema artefact and must never store a filesystem
      // path.
      if (filename.contains('/') ||
          filename.contains('\\') ||
          filename.contains('..')) {
        throw ArgumentError.value(
          filename,
          'migrationFilenames',
          'must be a basename (no path separators)',
        );
      }
      final rows = await runnerFn(
        'insert into public.proxy_migrations_applied '
        '(migration_filename, observed_by) '
        "values (@filename, 'proxy_startup') "
        'on conflict (migration_filename) do nothing '
        'returning id',
        parameters: <String, Object?>{'filename': filename},
      ).timeout(budget);
      if (rows.isNotEmpty) inserted++;
    }
    return inserted;
  }

  /// Reads the drift function with the supplied expected list and
  /// returns the count + missing filenames. Used by tests and by the
  /// `migration_apply_drift_count` producer for cross-checks.
  Future<({int driftCount, List<String> missing})> computeDrift(
    List<String> expectedFilenames,
  ) async {
    final rows = await runnerFn(
      'select drift_count, missing_migrations '
      'from public.proxy_migration_apply_drift(@expected::text[])',
      parameters: <String, Object?>{'expected': expectedFilenames},
    );
    if (rows.isEmpty) {
      return (driftCount: 0, missing: const <String>[]);
    }
    final row = rows.first;
    final driftCount = (row['drift_count'] as num?)?.toInt() ?? 0;
    final missing = row['missing_migrations'];
    final missingList = missing is List
        ? List<String>.from(missing.map((e) => e.toString()))
        : <String>[];
    return (driftCount: driftCount, missing: missingList);
  }
}
