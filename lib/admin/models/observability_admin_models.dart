// Phase 11A.6 — Observability dashboard models.
//
// Typed parsers for the proxy `/v1/admin/observability` envelope. The
// envelope assembles cost-telemetry, latency/error/cap-event,
// Cloud-Run, graph-observability, operator-dormancy, and per-tier
// margin surfaces called out in the 11A.6 phase doc (lines 345-369).
//
// 11A.UX.health already ships the read-only `/health` envelope viewer
// at `lib/admin/screens/health_admin_screen.dart`. This surface does
// NOT duplicate `/health`. Latency / error / dependency probes the
// health envelope already exposes are linked out of the observability
// screen ("View health envelope") rather than re-parsed here. Anything
// the proxy aggregates with cost / dormancy axes (Hard Promise #9
// visibility) belongs here.
//
// The proxy producer endpoints are still in flight at the time this
// slice ships: the HTTP gateway encodes the expected paths the proxy
// will land, and the in-memory gateway carries a deterministic demo
// envelope so the click path runs without a backend.

import 'package:flutter/foundation.dart';

/// Days-silent threshold for the dormancy flag (Hard Promise #9
/// precompute-skip lever). An operator whose `last_active_at` is at
/// least this many days behind the envelope `as_of` timestamp is
/// flagged dormant and excluded from precomputed summaries.
const int kObservabilityDormancyDaysThreshold = 30;

/// Default hard cap on the number of cost-telemetry rows the screen
/// renders in a single envelope. The producer query can return a
/// large cross-product of `(operator, location, staff, workflow,
/// usage_class, query_class)` rows; the surface honors the runtime
/// acceptance contract by paginating server-side and rendering only
/// up to this many rows in a virtualized list. The proxy clamps to
/// the same value.
const int kObservabilityCostTelemetryLimit = 100;

/// Window keys used by the Top-N expensive list. Matches the phase
/// doc's `1d / 7d / 30d` rolling windows.
enum ObservabilityWindow { oneDay, sevenDays, thirtyDays }

ObservabilityWindow parseObservabilityWindow(Object? raw) {
  if (raw is! String) return ObservabilityWindow.sevenDays;
  switch (raw.toLowerCase()) {
    case '1d':
    case 'one_day':
    case 'oneday':
      return ObservabilityWindow.oneDay;
    case '7d':
    case 'seven_days':
    case 'sevendays':
      return ObservabilityWindow.sevenDays;
    case '30d':
    case 'thirty_days':
    case 'thirtydays':
      return ObservabilityWindow.thirtyDays;
    default:
      return ObservabilityWindow.sevenDays;
  }
}

String observabilityWindowKey(ObservabilityWindow window) {
  switch (window) {
    case ObservabilityWindow.oneDay:
      return '1d';
    case ObservabilityWindow.sevenDays:
      return '7d';
    case ObservabilityWindow.thirtyDays:
      return '30d';
  }
}

/// One row of the cost-telemetry breakdown, fully axed per phase doc
/// lines 356-359. All ID axes are nullable because the proxy may
/// aggregate at any subset of them — for example, a row with
/// `staff_id = null` and `workflow_id = null` represents the
/// per-(operator, location, usage_class, query_class) total. The
/// screen renders the most-specific rows first.
@immutable
class CostTelemetryEntry {
  const CostTelemetryEntry({
    required this.operatorId,
    required this.locationId,
    required this.staffId,
    required this.workflowId,
    required this.usageClass,
    required this.queryClass,
    required this.totalUsd,
    required this.requestCount,
    this.businessName,
  });

  final String operatorId;
  final String? locationId;
  final String? staffId;
  final String? workflowId;
  final String usageClass;
  final String queryClass;
  final double totalUsd;
  final int requestCount;

  /// Optional human-readable label for the operator. The proxy may
  /// inject `business_name` for the Top-N surface; the per-axis cost
  /// rows leave it null.
  final String? businessName;

  factory CostTelemetryEntry.fromJson(Map<String, Object?> json) {
    return CostTelemetryEntry(
      operatorId: (json['operator_id'] as String?) ?? '',
      locationId: json['location_id'] as String?,
      staffId: json['staff_id'] as String?,
      workflowId: json['workflow_id'] as String?,
      usageClass: (json['usage_class'] as String?) ?? '',
      queryClass: (json['query_class'] as String?) ?? '',
      totalUsd: _parseDouble(json['total_usd']) ?? 0.0,
      requestCount: _parseInt(json['request_count']) ?? 0,
      businessName: json['business_name'] as String?,
    );
  }
}

/// Cache-hit-rate envelope (Hard Promise #9 lever 3). The proxy
/// reports the rate per `query_class`; the screen renders one chip
/// per class in a wrap. Below `yellow`, the chip turns warning;
/// below `red`, it turns negative.
@immutable
class CacheHitRateEntry {
  const CacheHitRateEntry({
    required this.queryClass,
    required this.hitRate,
    this.yellowThreshold = 0.30,
    this.redThreshold = 0.10,
  });

  final String queryClass;
  final double hitRate;
  final double yellowThreshold;
  final double redThreshold;

  /// Severity mirrors the F&F health convention so widget tests can
  /// assert chip colour without reproducing the threshold logic.
  HitRateSeverity get severity {
    if (hitRate < redThreshold) return HitRateSeverity.red;
    if (hitRate < yellowThreshold) return HitRateSeverity.yellow;
    return HitRateSeverity.green;
  }

  factory CacheHitRateEntry.fromJson(Map<String, Object?> json) {
    return CacheHitRateEntry(
      queryClass: (json['query_class'] as String?) ?? '',
      hitRate: _parseDouble(json['hit_rate']) ?? 0.0,
      yellowThreshold:
          _parseDouble(json['yellow_threshold']) ?? 0.30,
      redThreshold: _parseDouble(json['red_threshold']) ?? 0.10,
    );
  }
}

enum HitRateSeverity { green, yellow, red }

/// Model-mix envelope (Hard Promise #9 lever 2). Tracks the share of
/// requests routed to Haiku vs. Sonnet per `query_class`. Per the cost
/// discipline contract a healthy mix skews toward Haiku for cheap
/// classifier work; the chip flips to warning when Sonnet share
/// exceeds the policy ceiling.
@immutable
class ModelMixEntry {
  const ModelMixEntry({
    required this.queryClass,
    required this.haikuShare,
    required this.sonnetShare,
    this.sonnetShareCeiling = 0.40,
  });

  final String queryClass;
  final double haikuShare;
  final double sonnetShare;
  final double sonnetShareCeiling;

  bool get sonnetShareExceedsCeiling => sonnetShare > sonnetShareCeiling;

  factory ModelMixEntry.fromJson(Map<String, Object?> json) {
    return ModelMixEntry(
      queryClass: (json['query_class'] as String?) ?? '',
      haikuShare: _parseDouble(json['haiku_share']) ?? 0.0,
      sonnetShare: _parseDouble(json['sonnet_share']) ?? 0.0,
      sonnetShareCeiling:
          _parseDouble(json['sonnet_share_ceiling']) ?? 0.40,
    );
  }
}

/// Batch-mode share (Hard Promise #9 lever 5). The share of async
/// workloads routed through the Anthropic Batch API. Lower = more
/// expensive; the proxy reports the rolling 24-hour share.
@immutable
class BatchModeShareEntry {
  const BatchModeShareEntry({
    required this.queryClass,
    required this.batchShare,
    this.targetShare = 0.50,
  });

  final String queryClass;
  final double batchShare;
  final double targetShare;

  factory BatchModeShareEntry.fromJson(Map<String, Object?> json) {
    return BatchModeShareEntry(
      queryClass: (json['query_class'] as String?) ?? '',
      batchShare: _parseDouble(json['batch_share']) ?? 0.0,
      targetShare: _parseDouble(json['target_share']) ?? 0.50,
    );
  }
}

/// One row of the Top-N expensive list. The proxy computes Top-N for
/// `(operator_id)`, `(operator_id, staff_id)`, and
/// `(operator_id, workflow_id)` axes per phase doc lines 364-365.
/// `axis` carries the axis label so the screen can render three
/// sub-tables under a single Top-N card.
@immutable
class TopExpensiveEntry {
  const TopExpensiveEntry({
    required this.window,
    required this.axis,
    required this.label,
    required this.totalUsd,
    required this.requestCount,
    this.operatorId,
    this.staffId,
    this.workflowId,
  });

  final ObservabilityWindow window;
  final String axis;
  final String label;
  final double totalUsd;
  final int requestCount;
  final String? operatorId;
  final String? staffId;
  final String? workflowId;

  factory TopExpensiveEntry.fromJson(Map<String, Object?> json) {
    return TopExpensiveEntry(
      window: parseObservabilityWindow(json['window']),
      axis: (json['axis'] as String?) ?? 'operator',
      label: (json['label'] as String?) ?? '',
      totalUsd: _parseDouble(json['total_usd']) ?? 0.0,
      requestCount: _parseInt(json['request_count']) ?? 0,
      operatorId: json['operator_id'] as String?,
      staffId: json['staff_id'] as String?,
      workflowId: json['workflow_id'] as String?,
    );
  }
}

/// Operator dormancy row. `lastActiveAt` is nullable: a never-active
/// operator (no row in `usage_logs` yet) or an operator the producer
/// could not resolve produces `null` rather than collapsing to the
/// envelope `as_of`. Treating a null `last_active_at` as "0 days
/// silent" would mask a never-active operator, so this surface
/// preserves the unknown state and renders it as `NEVER ACTIVE` —
/// which is at-least as dormant as the 30-day threshold for the
/// precompute-skip lever.
///
/// The proxy MAY also send a pre-computed `days_silent` integer; when
/// present it wins over the locally computed value so a producer that
/// has a richer signal (e.g., last meaningful activity vs. last login
/// ping) is authoritative.
@immutable
class OperatorDormancyEntry {
  const OperatorDormancyEntry({
    required this.operatorId,
    required this.businessName,
    required this.lastActiveAt,
    required this.asOf,
    this.daysSilentOverride,
    this.subscriptionTier,
  });

  final String operatorId;
  final String businessName;

  /// Nullable when the producer reports no `last_active_at` for the
  /// operator. Never collapsed to `asOf`.
  final DateTime? lastActiveAt;
  final DateTime asOf;

  /// Producer-supplied `days_silent` integer. When non-null this
  /// wins over the locally derived [_computedDaysSilent] so a richer
  /// upstream signal stays authoritative.
  final int? daysSilentOverride;
  final String? subscriptionTier;

  /// True when the producer never reported a `last_active_at` for
  /// this operator. Renders as `NEVER ACTIVE · DORMANT` and is
  /// always considered dormant for the precompute-skip lever.
  bool get neverActive =>
      lastActiveAt == null && daysSilentOverride == null;

  /// Days silent: prefers a producer-supplied override; otherwise
  /// derives from `asOf - lastActiveAt`. Returns null when neither
  /// is available.
  int? get daysSilent {
    if (daysSilentOverride != null) {
      return daysSilentOverride! < 0 ? 0 : daysSilentOverride;
    }
    final lastActive = lastActiveAt;
    if (lastActive == null) return null;
    final diff = asOf.difference(lastActive).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// Operator is dormant when known-silent for at least
  /// [kObservabilityDormancyDaysThreshold] days OR never active.
  bool get isDormant {
    if (neverActive) return true;
    final silent = daysSilent;
    if (silent == null) return false;
    return silent >= kObservabilityDormancyDaysThreshold;
  }

  factory OperatorDormancyEntry.fromJson(
    Map<String, Object?> json,
    DateTime asOf,
  ) {
    return OperatorDormancyEntry(
      operatorId: (json['operator_id'] as String?) ?? '',
      businessName: (json['business_name'] as String?) ?? '(unnamed)',
      // Preserve null — DO NOT default to asOf, which would mask a
      // never-active operator as "0 days silent".
      lastActiveAt: _parseUtc(json['last_active_at']),
      asOf: asOf,
      daysSilentOverride: _parseInt(json['days_silent']),
      subscriptionTier: json['subscription_tier'] as String?,
    );
  }
}

/// Per-tier margin estimate. `revenueUsd` comes from
/// `subscription_tier` × seats; `costUsd` is the rolling cost from
/// `usage_logs`; `marginUsd = revenue - cost`. A negative margin is
/// the surface the F&F admin watches before launch.
@immutable
class MarginEstimateEntry {
  const MarginEstimateEntry({
    required this.operatorId,
    required this.businessName,
    required this.subscriptionTier,
    required this.revenueUsd,
    required this.costUsd,
  });

  final String operatorId;
  final String businessName;
  final String subscriptionTier;
  final double revenueUsd;
  final double costUsd;

  double get marginUsd => revenueUsd - costUsd;
  double get marginRatio =>
      revenueUsd <= 0 ? 0 : (revenueUsd - costUsd) / revenueUsd;
  bool get isUnderwater => marginUsd < 0;

  factory MarginEstimateEntry.fromJson(Map<String, Object?> json) {
    return MarginEstimateEntry(
      operatorId: (json['operator_id'] as String?) ?? '',
      businessName: (json['business_name'] as String?) ?? '(unnamed)',
      subscriptionTier: (json['subscription_tier'] as String?) ?? '',
      revenueUsd: _parseDouble(json['revenue_usd']) ?? 0.0,
      costUsd: _parseDouble(json['cost_usd']) ?? 0.0,
    );
  }
}

/// One cap-breach event. The proxy emits a row whenever a request is
/// refused because `usage_caps` was reached; the stream feeds the
/// "Cap events" tab so the F&F admin can spot a runaway operator.
@immutable
class CapEvent {
  const CapEvent({
    required this.eventId,
    required this.occurredAt,
    required this.operatorId,
    required this.businessName,
    required this.usageClass,
    required this.queryClass,
    required this.capUsd,
    required this.attemptedUsd,
    this.locationId,
    this.staffId,
    this.workflowId,
  });

  final String eventId;
  final DateTime occurredAt;
  final String operatorId;
  final String businessName;
  final String usageClass;
  final String queryClass;
  final double capUsd;
  final double attemptedUsd;
  final String? locationId;
  final String? staffId;
  final String? workflowId;

  factory CapEvent.fromJson(Map<String, Object?> json) {
    return CapEvent(
      eventId: (json['event_id'] as String?) ?? '',
      occurredAt: _parseUtc(json['occurred_at']) ?? DateTime.now().toUtc(),
      operatorId: (json['operator_id'] as String?) ?? '',
      businessName: (json['business_name'] as String?) ?? '(unnamed)',
      usageClass: (json['usage_class'] as String?) ?? '',
      queryClass: (json['query_class'] as String?) ?? '',
      capUsd: _parseDouble(json['cap_usd']) ?? 0.0,
      attemptedUsd: _parseDouble(json['attempted_usd']) ?? 0.0,
      locationId: json['location_id'] as String?,
      staffId: json['staff_id'] as String?,
      workflowId: json['workflow_id'] as String?,
    );
  }
}

/// Graph observability counts and freshness, per phase doc lines
/// 351-353. Counts are operator-scoped totals across the canonical
/// graph tables; `inferredApproved` is the subset of approved edges
/// whose `confidence_label = INFERRED` (the human-graded queue
/// follow-up signal).
@immutable
class GraphObservability {
  const GraphObservability({
    required this.approvedNodeCount,
    required this.approvedEdgeCount,
    required this.inferredApprovedCount,
    required this.rejectedCandidateCount,
    required this.isolatedNodeCount,
    required this.projectionAgeSeconds,
    required this.traversalP95Ms,
  });

  final int approvedNodeCount;
  final int approvedEdgeCount;
  final int inferredApprovedCount;
  final int rejectedCandidateCount;
  final int isolatedNodeCount;
  final int projectionAgeSeconds;
  final int traversalP95Ms;

  factory GraphObservability.fromJson(Map<String, Object?> json) {
    return GraphObservability(
      approvedNodeCount: _parseInt(json['approved_node_count']) ?? 0,
      approvedEdgeCount: _parseInt(json['approved_edge_count']) ?? 0,
      inferredApprovedCount:
          _parseInt(json['inferred_approved_count']) ?? 0,
      rejectedCandidateCount:
          _parseInt(json['rejected_candidate_count']) ?? 0,
      isolatedNodeCount: _parseInt(json['isolated_node_count']) ?? 0,
      projectionAgeSeconds:
          _parseInt(json['projection_age_seconds']) ?? 0,
      traversalP95Ms: _parseInt(json['traversal_p95_ms']) ?? 0,
    );
  }
}

/// Per-route latency / error rate trend point. The proxy returns one
/// entry per route with rolling p50/p95/p99 latency and the 5xx rate
/// over the same window. The health envelope already exposes the
/// platform-wide proxy_request_p99 / proxy_request_5xx_rate metrics;
/// this surface drills into per-route detail without re-parsing those.
@immutable
class RouteLatencyEntry {
  const RouteLatencyEntry({
    required this.route,
    required this.p50Ms,
    required this.p95Ms,
    required this.p99Ms,
    required this.errorRate,
    required this.requestCount,
  });

  final String route;
  final int p50Ms;
  final int p95Ms;
  final int p99Ms;
  final double errorRate;
  final int requestCount;

  factory RouteLatencyEntry.fromJson(Map<String, Object?> json) {
    return RouteLatencyEntry(
      route: (json['route'] as String?) ?? '',
      p50Ms: _parseInt(json['p50_ms']) ?? 0,
      p95Ms: _parseInt(json['p95_ms']) ?? 0,
      p99Ms: _parseInt(json['p99_ms']) ?? 0,
      errorRate: _parseDouble(json['error_rate']) ?? 0.0,
      requestCount: _parseInt(json['request_count']) ?? 0,
    );
  }
}

/// Cloud Run instance shape. `instanceCount` is the active count;
/// `revisionId` lets the F&F admin confirm which revision is serving
/// traffic without bouncing to the GCP console for every check.
@immutable
class CloudRunInstanceMetric {
  const CloudRunInstanceMetric({
    required this.serviceName,
    required this.instanceCount,
    required this.revisionId,
    required this.minInstances,
    required this.maxInstances,
  });

  final String serviceName;
  final int instanceCount;
  final String revisionId;
  final int minInstances;
  final int maxInstances;

  factory CloudRunInstanceMetric.fromJson(Map<String, Object?> json) {
    return CloudRunInstanceMetric(
      serviceName: (json['service_name'] as String?) ?? '',
      instanceCount: _parseInt(json['instance_count']) ?? 0,
      revisionId: (json['revision_id'] as String?) ?? '',
      minInstances: _parseInt(json['min_instances']) ?? 0,
      maxInstances: _parseInt(json['max_instances']) ?? 0,
    );
  }
}

/// Whole observability envelope. Every list is non-null; an empty list
/// is the proxy's signal that no rows are populated yet (typical for
/// the first launch run). The screen renders an empty-state caption
/// per section instead of a generic skeleton.
///
/// Cost telemetry is the only large list — its server-side bound is
/// surfaced via [costTelemetryTotalCount] and [costTelemetryTruncated]
/// so the UI can render a "showing N of M (truncated — refine
/// filter)" hint and a virtualized list. Every other list is small by
/// construction (per-query_class hit rates, per-tier margins,
/// dormancy is one row per operator, etc.).
@immutable
class ObservabilityEnvelope {
  const ObservabilityEnvelope({
    required this.asOf,
    required this.contract,
    required this.schemaVersion,
    required this.costTelemetry,
    required this.costTelemetryTotalCount,
    required this.costTelemetryTruncated,
    required this.cacheHitRates,
    required this.modelMix,
    required this.batchModeShare,
    required this.topExpensive,
    required this.dormancy,
    required this.margins,
    required this.capEvents,
    required this.graph,
    required this.routeLatency,
    required this.cloudRun,
    this.costTelemetryQueryClassFilter,
  });

  final DateTime asOf;
  final String contract;
  final int schemaVersion;
  final List<CostTelemetryEntry> costTelemetry;

  /// Total number of cost-telemetry rows that match the request
  /// scope, before the server-side limit. When equal to
  /// `costTelemetry.length` the result is exhaustive; when greater,
  /// [costTelemetryTruncated] is true and the screen renders the
  /// "refine filter" hint.
  final int costTelemetryTotalCount;

  /// True when the proxy clamped [costTelemetry] to its hard cap.
  /// The UI cannot deepen the result without a narrower filter.
  final bool costTelemetryTruncated;

  /// `query_class` filter the proxy applied (empty / null when no
  /// filter was requested). The screen echoes it so the operator can
  /// tell which slice of the cost table they are looking at.
  final String? costTelemetryQueryClassFilter;

  final List<CacheHitRateEntry> cacheHitRates;
  final List<ModelMixEntry> modelMix;
  final List<BatchModeShareEntry> batchModeShare;
  final List<TopExpensiveEntry> topExpensive;
  final List<OperatorDormancyEntry> dormancy;
  final List<MarginEstimateEntry> margins;
  final List<CapEvent> capEvents;
  final GraphObservability graph;
  final List<RouteLatencyEntry> routeLatency;
  final List<CloudRunInstanceMetric> cloudRun;

  Iterable<TopExpensiveEntry> topExpensiveForWindow(
    ObservabilityWindow window,
  ) =>
      topExpensive.where((e) => e.window == window);

  Iterable<OperatorDormancyEntry> get dormantOperators =>
      dormancy.where((d) => d.isDormant);

  Iterable<MarginEstimateEntry> get underwaterOperators =>
      margins.where((m) => m.isUnderwater);

  factory ObservabilityEnvelope.fromJson(Map<String, Object?> json) {
    final asOf = _parseUtc(json['as_of']) ?? DateTime.now().toUtc();
    final costTelemetry = <CostTelemetryEntry>[
      for (final entry in (json['cost_telemetry'] as List?) ?? const [])
        if (entry is Map)
          CostTelemetryEntry.fromJson(entry.cast<String, Object?>()),
    ];
    final costTelemetryMeta =
        (json['cost_telemetry_meta'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final declaredTotal = _parseInt(costTelemetryMeta['total_count']);
    final declaredTruncated = costTelemetryMeta['truncated'] is bool
        ? costTelemetryMeta['truncated'] as bool
        : null;
    return ObservabilityEnvelope(
      asOf: asOf,
      contract: (json['contract'] as String?) ?? 'admin_observability.v1',
      schemaVersion: _parseInt(json['schema_version']) ?? 1,
      costTelemetry: costTelemetry,
      // When the proxy supplies an explicit total, trust it; otherwise
      // assume the response is exhaustive.
      costTelemetryTotalCount: declaredTotal ?? costTelemetry.length,
      // When the proxy supplies an explicit `truncated`, trust it;
      // otherwise infer truncation by comparing list length to the
      // hard cap.
      costTelemetryTruncated: declaredTruncated ??
          (costTelemetry.length >= kObservabilityCostTelemetryLimit),
      costTelemetryQueryClassFilter:
          costTelemetryMeta['query_class_filter'] as String?,
      cacheHitRates: <CacheHitRateEntry>[
        for (final entry in (json['cache_hit_rates'] as List?) ?? const [])
          if (entry is Map)
            CacheHitRateEntry.fromJson(entry.cast<String, Object?>()),
      ],
      modelMix: <ModelMixEntry>[
        for (final entry in (json['model_mix'] as List?) ?? const [])
          if (entry is Map)
            ModelMixEntry.fromJson(entry.cast<String, Object?>()),
      ],
      batchModeShare: <BatchModeShareEntry>[
        for (final entry in (json['batch_mode_share'] as List?) ?? const [])
          if (entry is Map)
            BatchModeShareEntry.fromJson(entry.cast<String, Object?>()),
      ],
      topExpensive: <TopExpensiveEntry>[
        for (final entry in (json['top_expensive'] as List?) ?? const [])
          if (entry is Map)
            TopExpensiveEntry.fromJson(entry.cast<String, Object?>()),
      ],
      dormancy: <OperatorDormancyEntry>[
        for (final entry in (json['dormancy'] as List?) ?? const [])
          if (entry is Map)
            OperatorDormancyEntry.fromJson(
              entry.cast<String, Object?>(),
              asOf,
            ),
      ],
      margins: <MarginEstimateEntry>[
        for (final entry in (json['margins'] as List?) ?? const [])
          if (entry is Map)
            MarginEstimateEntry.fromJson(entry.cast<String, Object?>()),
      ],
      capEvents: <CapEvent>[
        for (final entry in (json['cap_events'] as List?) ?? const [])
          if (entry is Map) CapEvent.fromJson(entry.cast<String, Object?>()),
      ],
      graph: GraphObservability.fromJson(
        ((json['graph'] as Map?) ?? const <String, Object?>{})
            .cast<String, Object?>(),
      ),
      routeLatency: <RouteLatencyEntry>[
        for (final entry in (json['route_latency'] as List?) ?? const [])
          if (entry is Map)
            RouteLatencyEntry.fromJson(entry.cast<String, Object?>()),
      ],
      cloudRun: <CloudRunInstanceMetric>[
        for (final entry in (json['cloud_run'] as List?) ?? const [])
          if (entry is Map)
            CloudRunInstanceMetric.fromJson(entry.cast<String, Object?>()),
      ],
    );
  }
}

int? _parseInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

double? _parseDouble(Object? raw) {
  if (raw is double) return raw;
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw);
  return null;
}

DateTime? _parseUtc(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final parsed = DateTime.tryParse(raw);
  return parsed?.toUtc();
}
