// Phase 11A.6 - Observability admin gateway.
//
// The admin Flutter client never holds a Postgres connection or
// Cloud Run admin credentials directly - every read flows through the
// F&F admin proxy. This gateway returns the cost-telemetry,
// dormancy, margin, cap-event, graph, latency, and Cloud Run surfaces
// the 11A.6 dashboard renders.
//
// Two implementations ship in this slice:
//
//   * [HttpObservabilityAdminGateway] - production. GET against the
//     proxy with the signed-in admin's bearer token. The aggregate
//     endpoint is documented in the phase doc as
//     `/v1/admin/observability`; if the proxy has not yet landed it,
//     production wires the in-memory gateway as a fallback so the
//     route paints something instead of throwing.
//
//   * [InMemoryObservabilityAdminGateway] - demo + widget tests.
//     Returns a deterministic envelope keyed by the demo identities
//     used elsewhere in the admin shell so the click path runs
//     end-to-end without a backend.
//
// The /health envelope is owned by the F.1 health gateway and is not
// duplicated here. The observability screen links out to the health
// surface for dependency probes and tier-1 metric tiles.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/observability_admin_models.dart';
import 'admin_http_timeout.dart';

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token stream;
/// tests pin a synthetic value.
typedef ObservabilityAdminBearerTokenProvider = Future<String> Function();

class ObservabilityAdminGatewayError implements Exception {
  const ObservabilityAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'ObservabilityAdminGatewayError($statusCode/$errorCode): $message';
}

/// Bounded request shape for the observability fetch. Cost telemetry
/// is the only large surface, so the gateway exposes a server-side
/// [costTelemetryLimit] (clamped to
/// [kObservabilityCostTelemetryLimit] by the proxy) and an optional
/// [queryClassFilter] so the operator can scope the cost table to a
/// single `query_class`. The other surfaces are small by construction.
@immutable
class ObservabilityFetchRequest {
  const ObservabilityFetchRequest({
    this.costTelemetryLimit = kObservabilityCostTelemetryLimit,
    this.queryClassFilter,
    this.operatorId,
    this.locationId,
    this.locationIds = const <String>{},
  });

  final int costTelemetryLimit;
  final String? queryClassFilter;
  final String? operatorId;
  final String? locationId;
  final Set<String> locationIds;

  Map<String, String> toQueryParameters() {
    return <String, String>{
      'cost_telemetry_limit':
          '${costTelemetryLimit.clamp(1, kObservabilityCostTelemetryLimit)}',
      if (queryClassFilter != null && queryClassFilter!.isNotEmpty)
        'query_class': queryClassFilter!,
      if (operatorId != null && operatorId!.isNotEmpty)
        'operator_id': operatorId!,
      if (locationId != null && locationId!.isNotEmpty)
        'location_id': locationId!,
      if (locationIds.isNotEmpty) 'location_ids': locationIds.join(','),
    };
  }
}

abstract class ObservabilityAdminGateway {
  Future<ObservabilityEnvelope> fetch([ObservabilityFetchRequest request]);
}

/// Production gateway: hits the proxy aggregate endpoint and parses
/// the envelope. The endpoint is read-only, so no idempotency key is
/// attached. Long-running diagnostic runs use the same timeout as the
/// `/health` gateway because the producer queries can scan
/// `usage_logs` rolling windows that are not always cheap.
class HttpObservabilityAdminGateway implements ObservabilityAdminGateway {
  HttpObservabilityAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHealthHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri baseUri;
  final ObservabilityAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  /// Aggregate observability envelope path. The proxy assembles the
  /// cost-telemetry, dormancy, margin, cap-event, graph, latency, and
  /// Cloud Run rows under this single path so the UI does not fan
  /// out one request per surface.
  static const String observabilityPath = '/v1/admin/observability';

  @override
  Future<ObservabilityEnvelope> fetch([
    ObservabilityFetchRequest request = const ObservabilityFetchRequest(),
  ]) async {
    final token = await bearerTokenProvider();
    final clampedLimit = request.costTelemetryLimit.clamp(
      1,
      kObservabilityCostTelemetryLimit,
    );
    final query = request.toQueryParameters()
      ..['cost_telemetry_limit'] = '$clampedLimit';
    final uri = baseUri
        .resolve(observabilityPath)
        .replace(queryParameters: query);
    final httpRequest = http.Request('GET', uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        httpRequest,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw ObservabilityAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin observability proxy timed out after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        parsed = decoded.cast<String, Object?>();
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return ObservabilityEnvelope.fromJson(parsed);
    }
    throw ObservabilityAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ??
          'admin observability proxy returned an error',
    );
  }
}

/// In-memory gateway used by the demo walkthrough and widget tests.
/// Construct with a raw envelope JSON map; the gateway parses it on
/// every `fetch` so widget tests can swap the seed between calls.
///
/// Honors the request: applies [ObservabilityFetchRequest.queryClassFilter]
/// to the seeded `cost_telemetry` rows and clamps the result to
/// [ObservabilityFetchRequest.costTelemetryLimit] (also clamped to
/// [kObservabilityCostTelemetryLimit] by the proxy contract). The
/// resulting envelope's `cost_telemetry_meta.total_count` and
/// `cost_telemetry_meta.truncated` reflect the in-memory pre-clamp
/// length so screen tests can assert the truncation hint without
/// hitting a live proxy.
class InMemoryObservabilityAdminGateway implements ObservabilityAdminGateway {
  InMemoryObservabilityAdminGateway({
    required Map<String, Object?> envelope,
    Exception? errorOnFetch,
  }) : _envelope = envelope,
       _errorOnFetch = errorOnFetch;

  Map<String, Object?> _envelope;
  Exception? _errorOnFetch;

  /// Replace the seeded envelope for the next [fetch] call. Used by
  /// the screen widget test to assert manual refresh consumes the new
  /// envelope.
  void setEnvelope(Map<String, Object?> envelope, {Exception? errorOnFetch}) {
    _envelope = envelope;
    _errorOnFetch = errorOnFetch;
  }

  @override
  Future<ObservabilityEnvelope> fetch([
    ObservabilityFetchRequest request = const ObservabilityFetchRequest(),
  ]) async {
    final err = _errorOnFetch;
    if (err != null) throw err;
    final clampedLimit = request.costTelemetryLimit.clamp(
      1,
      kObservabilityCostTelemetryLimit,
    );
    final base = Map<String, Object?>.from(_envelope);
    final rawRows =
        (base['cost_telemetry'] as List?)?.cast<Map<String, Object?>>() ??
        const <Map<String, Object?>>[];
    Iterable<Map<String, Object?>> filtered = rawRows;
    final filter = request.queryClassFilter;
    if (filter != null && filter.isNotEmpty) {
      filtered = filtered.where((row) => row['query_class'] == filter);
    }
    filtered = filtered.where((row) => _matchesScope(row, request));
    final preClamp = filtered.toList(growable: false);
    final clamped = preClamp.length > clampedLimit
        ? preClamp.sublist(0, clampedLimit)
        : preClamp;
    base['cost_telemetry'] = clamped;
    for (final key in const <String>[
      'top_expensive',
      'dormancy',
      'margins',
      'cap_events',
    ]) {
      base[key] = _filteredScopeRows(base[key], request);
    }
    base['cost_telemetry_meta'] = <String, Object?>{
      'total_count': preClamp.length,
      'truncated': preClamp.length > clampedLimit,
      if (filter != null && filter.isNotEmpty) 'query_class_filter': filter,
    };
    return ObservabilityEnvelope.fromJson(base);
  }
}

List<Map<String, Object?>> _filteredScopeRows(
  Object? raw,
  ObservabilityFetchRequest request,
) {
  final rows =
      (raw as List?)?.whereType<Map<Object?, Object?>>().map(
        (row) => row.cast<String, Object?>(),
      ) ??
      const Iterable<Map<String, Object?>>.empty();
  return rows.where((row) => _matchesScope(row, request)).toList();
}

bool _matchesScope(
  Map<String, Object?> row,
  ObservabilityFetchRequest request,
) {
  final operatorId = request.operatorId;
  if (operatorId == null || operatorId.isEmpty) return true;
  if (row['operator_id'] != operatorId) return false;
  final rowLocationId = row['location_id'] as String?;
  final requestedLocationId = request.locationId;
  if (requestedLocationId != null && requestedLocationId.isNotEmpty) {
    return rowLocationId == requestedLocationId;
  }
  if (request.locationIds.isEmpty) return true;
  if (rowLocationId == null || rowLocationId.isEmpty) return true;
  return request.locationIds.contains(rowLocationId);
}

/// Seed envelope used by the 11A.6 walkthrough when no production
/// gateway is mounted. Mirrors the demo operators from the rest of
/// the admin shell so the click path is consistent across tabs:
///
///   * `Demo Diner Co.` (launch tier) - active operator with a
///     non-trivial cost row, healthy margin, and a recent cap event.
///   * `Sunset Cafe Group` (pilot tier) - dormant 32+ days so the
///     30-day flag trips, modest cost, underwater margin row.
const Map<String, Object?> kObservabilityAdminDemoEnvelope = <String, Object?>{
  'as_of': '2026-05-03T12:00:00.000Z',
  'contract': 'admin_observability.v1',
  'schema_version': 1,
  'cost_telemetry': <Map<String, Object?>>[
    <String, Object?>{
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'location_id': '00000000-0000-4000-8000-0000000000a1',
      'staff_id': null,
      'workflow_id': null,
      'usage_class': 'advisor_qa',
      'query_class': 'advisor_qa',
      'total_usd': 18.42,
      'request_count': 1245,
    },
    <String, Object?>{
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'location_id': '00000000-0000-4000-8000-0000000000a1',
      'staff_id': '00000000-0000-4000-8000-0000000000s1',
      'workflow_id': null,
      'usage_class': 'advisor_qa',
      'query_class': 'coach_qa',
      'total_usd': 4.18,
      'request_count': 287,
    },
    <String, Object?>{
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'location_id': '00000000-0000-4000-8000-0000000000a1',
      'staff_id': null,
      'workflow_id': '00000000-0000-4000-8000-0000000000w1',
      'usage_class': 'workflow',
      'query_class': 'wf_pl',
      'total_usd': 6.91,
      'request_count': 142,
    },
    <String, Object?>{
      'operator_id': '00000000-0000-4000-8000-000000000002',
      'location_id': '00000000-0000-4000-8000-0000000000b1',
      'staff_id': null,
      'workflow_id': null,
      'usage_class': 'advisor_qa',
      'query_class': 'advisor_qa',
      'total_usd': 0.42,
      'request_count': 31,
    },
  ],
  'cache_hit_rates': <Map<String, Object?>>[
    <String, Object?>{
      'query_class': 'advisor_qa',
      'hit_rate': 0.61,
      'yellow_threshold': 0.30,
      'red_threshold': 0.10,
    },
    <String, Object?>{
      'query_class': 'coach_qa',
      'hit_rate': 0.48,
      'yellow_threshold': 0.30,
      'red_threshold': 0.10,
    },
    <String, Object?>{
      'query_class': 'wf_pl',
      'hit_rate': 0.22,
      'yellow_threshold': 0.30,
      'red_threshold': 0.10,
    },
  ],
  'model_mix': <Map<String, Object?>>[
    <String, Object?>{
      'query_class': 'advisor_qa',
      'haiku_share': 0.78,
      'sonnet_share': 0.22,
      'sonnet_share_ceiling': 0.40,
    },
    <String, Object?>{
      'query_class': 'coach_qa',
      'haiku_share': 0.55,
      'sonnet_share': 0.45,
      'sonnet_share_ceiling': 0.40,
    },
    <String, Object?>{
      'query_class': 'wf_pl',
      'haiku_share': 0.10,
      'sonnet_share': 0.90,
      'sonnet_share_ceiling': 0.95,
    },
  ],
  'batch_mode_share': <Map<String, Object?>>[
    <String, Object?>{
      'query_class': 'wf_pl',
      'batch_share': 0.62,
      'target_share': 0.50,
    },
    <String, Object?>{
      'query_class': 'wf_schedule',
      'batch_share': 0.34,
      'target_share': 0.50,
    },
  ],
  'top_expensive': <Map<String, Object?>>[
    <String, Object?>{
      'window': '1d',
      'axis': 'operator',
      'label': 'Demo Diner Co.',
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'total_usd': 4.84,
      'request_count': 312,
    },
    <String, Object?>{
      'window': '1d',
      'axis': 'operator',
      'label': 'Sunset Cafe Group',
      'operator_id': '00000000-0000-4000-8000-000000000002',
      'total_usd': 0.18,
      'request_count': 21,
    },
    <String, Object?>{
      'window': '7d',
      'axis': 'operator',
      'label': 'Demo Diner Co.',
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'total_usd': 29.51,
      'request_count': 1674,
    },
    <String, Object?>{
      'window': '7d',
      'axis': 'workflow',
      'label': 'wf_pl (Demo Diner Co.)',
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'workflow_id': '00000000-0000-4000-8000-0000000000w1',
      'total_usd': 6.91,
      'request_count': 142,
    },
    <String, Object?>{
      'window': '30d',
      'axis': 'operator',
      'label': 'Demo Diner Co.',
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'total_usd': 121.07,
      'request_count': 7204,
    },
    <String, Object?>{
      'window': '30d',
      'axis': 'staff',
      'label': 'Owner @ Demo Diner Co.',
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'staff_id': '00000000-0000-4000-8000-0000000000s1',
      'total_usd': 18.74,
      'request_count': 902,
    },
  ],
  'dormancy': <Map<String, Object?>>[
    <String, Object?>{
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'business_name': 'Demo Diner Co.',
      'last_active_at': '2026-05-03T08:00:00.000Z',
      'subscription_tier': 'launch',
    },
    <String, Object?>{
      'operator_id': '00000000-0000-4000-8000-000000000002',
      'business_name': 'Sunset Cafe Group',
      'last_active_at': '2026-04-01T09:30:00.000Z',
      'subscription_tier': 'pilot',
    },
  ],
  'margins': <Map<String, Object?>>[
    <String, Object?>{
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'business_name': 'Demo Diner Co.',
      'subscription_tier': 'launch',
      'revenue_usd': 199.0,
      'cost_usd': 29.51,
    },
    <String, Object?>{
      'operator_id': '00000000-0000-4000-8000-000000000002',
      'business_name': 'Sunset Cafe Group',
      'subscription_tier': 'pilot',
      'revenue_usd': 0.0,
      'cost_usd': 0.42,
    },
  ],
  'cap_events': <Map<String, Object?>>[
    <String, Object?>{
      'event_id': '00000000-0000-4000-8000-0000000000e1',
      'occurred_at': '2026-05-03T11:42:11.000Z',
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'business_name': 'Demo Diner Co.',
      'usage_class': 'advisor_qa',
      'query_class': 'advisor_qa',
      'cap_usd': 50.0,
      'attempted_usd': 50.12,
      'location_id': '00000000-0000-4000-8000-0000000000a1',
    },
    <String, Object?>{
      'event_id': '00000000-0000-4000-8000-0000000000e2',
      'occurred_at': '2026-05-02T14:08:53.000Z',
      'operator_id': '00000000-0000-4000-8000-000000000001',
      'business_name': 'Demo Diner Co.',
      'usage_class': 'workflow',
      'query_class': 'wf_pl',
      'cap_usd': 8.0,
      'attempted_usd': 8.04,
      'workflow_id': '00000000-0000-4000-8000-0000000000w1',
    },
  ],
  'graph': <String, Object?>{
    'approved_node_count': 1245,
    'approved_edge_count': 4218,
    'inferred_approved_count': 312,
    'rejected_candidate_count': 87,
    'isolated_node_count': 4,
    'projection_age_seconds': 1820,
    'traversal_p95_ms': 92,
  },
  'route_latency': <Map<String, Object?>>[
    <String, Object?>{
      'route': '/v1/advisor/answer',
      'p50_ms': 412,
      'p95_ms': 1180,
      'p99_ms': 2104,
      'error_rate': 0.0008,
      'request_count': 8421,
    },
    <String, Object?>{
      'route': '/v1/coach/answer',
      'p50_ms': 318,
      'p95_ms': 894,
      'p99_ms': 1402,
      'error_rate': 0.0011,
      'request_count': 1284,
    },
    <String, Object?>{
      'route': '/v1/workflows/run',
      'p50_ms': 612,
      'p95_ms': 1860,
      'p99_ms': 3120,
      'error_rate': 0.0042,
      'request_count': 318,
    },
  ],
  'cloud_run': <Map<String, Object?>>[
    <String, Object?>{
      'service_name': 'advisor-proxy',
      'instance_count': 2,
      'revision_id': 'advisor-proxy-00037-n1k',
      'min_instances': 1,
      'max_instances': 8,
    },
    <String, Object?>{
      'service_name': 'admin-proxy',
      'instance_count': 1,
      'revision_id': 'admin-proxy-00012-cv9',
      'min_instances': 1,
      'max_instances': 4,
    },
  ],
};
