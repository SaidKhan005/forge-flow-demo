// Phase 11A.UX.health (Slice 1) - Curated plain-English copy for the
// admin System health cards.
//
// Each health metric the proxy /health envelope can report gets two
// curated strings:
//
//   * a NAME  - the short label that heads the card. Plain English,
//                no vendor codenames (we say "AI text provider", never
//                "Anthropic"); reads as training, not as an internal
//                metric key.
//   * a MEANING - one calm sentence describing what a healthy reading
//                means. Shown on the card face only when the metric is
//                green (good); for yellow / red / no-data we show the
//                actionable "next step" remediation instead so the
//                operator always sees what to do.
//
// This file lives alongside `health_admin_screen.dart` (same
// `lib/admin/screens` directory) so the UX no-em-dash lint root keeps
// covering it. No em dashes appear in any operator-facing string here;
// the empty/missing-value sentinel `—` is never used in this file.
//
// Fallbacks (handled by the screen, documented here):
//   * For a key not in [_kHealthCopy], `healthMetricName` falls back to
//     the screen's humanised-key label and `healthMetricMeaning` falls
//     back to the metric's envelope `description`. The screen passes the
//     fallbacks in so this file owns no rendering and no envelope import.

/// Curated (name, meaning) pair for one health metric key.
class HealthMetricCopy {
  const HealthMetricCopy(this.name, this.meaning);

  /// Plain-English card title. Supersedes the humanised metric key.
  final String name;

  /// One calm sentence describing a healthy reading. Shown on the card
  /// face only when the metric is green.
  final String meaning;
}

/// Returns the curated card NAME for [key], or [fallback] when the key
/// is not curated. `fallback` is the screen's existing humanised-key
/// label so display never regresses for an un-curated key.
String healthMetricName(String key, {required String fallback}) {
  return _kHealthCopy[key]?.name ?? fallback;
}

/// Returns the curated "what a healthy reading means" sentence for
/// [key], or [fallback] when the key is not curated. `fallback` is the
/// metric's envelope `description`.
String healthMetricMeaning(String key, {required String fallback}) {
  return _kHealthCopy[key]?.meaning ?? fallback;
}

/// Curated copy, keyed by the proxy `/health` metric key. The keys here
/// mirror the tab catalogue in `health_admin_screen.dart`.
const Map<String, HealthMetricCopy> _kHealthCopy = <String, HealthMetricCopy>{
  // ── Advisor data ─────────────────────────────────────────────────
  'rollup_freshness_per_grain': HealthMetricCopy(
    'Data freshness',
    "Whether the advisor's data is current across all time periods.",
  ),
  'rollup_refresh_lag_seconds': HealthMetricCopy(
    'Refresh delay',
    "How long it has been since the advisor's data last refreshed.",
  ),
  'graph_traversal_latency_ms': HealthMetricCopy(
    'Relationship lookups (typical)',
    'How quickly the advisor looks up related items most of the time.',
  ),
  'graph_traversal_p99_latency_ms': HealthMetricCopy(
    'Relationship lookups (slowest)',
    'Lookup speed for the slowest few percent of requests.',
  ),
  'graph_traversal_timeout_rate': HealthMetricCopy(
    'Relationship lookup timeouts',
    'How often relationship lookups give up before finishing.',
  ),
  'graph_node_count': HealthMetricCopy(
    'Items in the relationship map',
    'How many items the advisor can connect together.',
  ),
  'graph_edge_count': HealthMetricCopy(
    'Connections in the relationship map',
    'How many links join items in the relationship map.',
  ),
  'graph_projection_age_seconds': HealthMetricCopy(
    'Relationship search freshness',
    'How old the relationship search snapshot is.',
  ),
  'vector_query_latency_ms': HealthMetricCopy(
    'Search speed (typical)',
    'How quickly searches come back most of the time.',
  ),
  'vector_query_p99_latency_ms': HealthMetricCopy(
    'Search speed (slowest)',
    'Search speed for the slowest few percent of requests.',
  ),
  'vector_query_timeout_rate': HealthMetricCopy(
    'Search timeouts',
    'How often searches give up before finishing.',
  ),
  'vector_recall': HealthMetricCopy(
    'Search quality',
    'How well search finds the results it should.',
  ),
  'vector_index_size_per_corpus': HealthMetricCopy(
    'Search index size',
    'How large the search index has grown.',
  ),
  'vector_index_build_age_seconds': HealthMetricCopy(
    'Search index freshness',
    'How long since the search index was last rebuilt.',
  ),

  // ── App service ──────────────────────────────────────────────────
  'circuit_breaker_anthropic_state': HealthMetricCopy(
    'AI text provider safeguard',
    'The safety switch that pauses the AI text provider when it is struggling.',
  ),
  'circuit_breaker_voyage_state': HealthMetricCopy(
    'AI search provider safeguard',
    'The safety switch that pauses the AI search provider when it is struggling.',
  ),
  'circuit_breaker_open_count_total': HealthMetricCopy(
    'Safeguard activations',
    'How many times a provider safety switch has tripped.',
  ),
  'prompt_cache_hit_rate': HealthMetricCopy(
    'Prompt reuse',
    'How often we reuse earlier prompt work to keep cost down.',
  ),
  'response_cache_hit_rate': HealthMetricCopy(
    'Saved answer reuse',
    'How often we serve a saved answer instead of paying for a new one.',
  ),
  'semantic_cache_hit_rate': HealthMetricCopy(
    'Similar answer reuse',
    'How often we reuse an answer from a similar past question.',
  ),
  'cost_per_query_class_haiku': HealthMetricCopy(
    'Fast model cost',
    'Average cost per request handled by the fast AI model.',
  ),
  'cost_per_query_class_sonnet': HealthMetricCopy(
    'Detailed model cost',
    'Average cost per request handled by the detailed AI model.',
  ),
  'cost_per_query_class_voyage': HealthMetricCopy(
    'Search model cost',
    'Average cost per search-model request.',
  ),
  'batch_api_pending_count': HealthMetricCopy(
    'Queued lower-cost work',
    'How much work is waiting in the cheaper batch lane.',
  ),
  'fallback_chain_usage_count_anthropic': HealthMetricCopy(
    'AI text provider fallback use',
    'How often we fell back to a backup path for the AI text provider.',
  ),
  'fallback_chain_usage_count_voyage': HealthMetricCopy(
    'AI search provider fallback use',
    'How often we fell back to a backup path for the AI search provider.',
  ),
  'proxy_idempotency_cache_alive': HealthMetricCopy(
    'Retry protection',
    'Whether duplicate-request protection is working.',
  ),
  'usage_caps_breach_count': HealthMetricCopy(
    'Spending limits reached',
    'How many requests were turned away for hitting a spending limit.',
  ),
  'proxy_request_p99_latency_ms': HealthMetricCopy(
    'App speed (slowest)',
    'Response time for the slowest few percent of app requests.',
  ),
  'proxy_request_5xx_rate': HealthMetricCopy(
    'Server error rate',
    'How often app requests come back as a server error.',
  ),

  // ── Behind the scenes (ecosystem / infra) ────────────────────────
  'azure_extensions_present': HealthMetricCopy(
    'Database add-ons',
    'Whether the required database add-ons are installed.',
  ),
  'pg_cron_scheduler_alive': HealthMetricCopy(
    'Scheduled jobs',
    'Whether background jobs are running on schedule.',
  ),
  'pg_cron_jobs_failed_24h': HealthMetricCopy(
    'Failed background jobs',
    'How many scheduled jobs failed in the last day.',
  ),
  'partition_count_active': HealthMetricCopy(
    'Active data partitions',
    'How many active data partitions are in use.',
  ),
  'partition_maintenance_last_run_age_seconds': HealthMetricCopy(
    'Partition upkeep',
    'How long since routine data-partition upkeep ran.',
  ),
  'partition_default_row_count': HealthMetricCopy(
    'Unsorted partition rows',
    'Rows waiting in the catch-all partition to be sorted.',
  ),
  'migration_apply_drift_count': HealthMetricCopy(
    'Database matches the app',
    'Whether the database structure matches what the app expects.',
  ),
  'audit_chain_lag_seconds': HealthMetricCopy(
    'Activity log delay',
    'How far behind the tamper-proof activity log is.',
  ),
  'audit_chain_anchor_age_seconds': HealthMetricCopy(
    'Activity log checkpoint age',
    'How long since the activity log was last checkpointed.',
  ),
  'event_outbox_undelivered_count': HealthMetricCopy(
    'Waiting notifications',
    'How many outbound notifications are waiting to send.',
  ),
  'event_outbox_lag_seconds': HealthMetricCopy(
    'Notification delay',
    'How long the oldest waiting notification has waited.',
  ),
  'event_outbox_publish_error_rate': HealthMetricCopy(
    'Notification errors',
    'How often outbound notifications fail to send.',
  ),
  'notify_queue_usage_ratio': HealthMetricCopy(
    'Notification queue load',
    'How full the notification queue is.',
  ),
  'firebase_jwks_fetch_alive': HealthMetricCopy(
    'Sign-in keys',
    'Whether sign-in security keys are reachable.',
  ),
  'service_principal_jwt_alive': HealthMetricCopy(
    'Service sign-in',
    'Whether internal service sign-in is working.',
  ),
  'cloud_run_instance_count': HealthMetricCopy(
    'Servers handling traffic',
    'How many servers are handling traffic right now.',
  ),
};
