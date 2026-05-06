// Phase 10a.4 — admin-side gateway for `/v1/realtime/tripwire-status`.
//
// The tripwire status is a small payload (status + four metric rows)
// that the F&F admin observability surface and the operator-facing
// sync badge both consume. The proxy route is read-only and runs
// through `runAsSystem` (platform-wide aggregate, no tenant
// identifiers); the gateway here just transports the JSON envelope
// across.
//
// Deliberately a SEPARATE gateway from `ObservabilityAdminGateway`:
// the observability gateway already touches a heavy aggregate
// endpoint (cost telemetry rows etc.) that takes seconds, while the
// tripwire status is cheap (~milliseconds) and polled by the sync
// badge every ~60s. Coupling the two would either bottleneck the
// badge behind the slow path or split the screen's data model in
// two places. A separate gateway keeps the responsibilities clean.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../services/realtime/outbox_tripwire_evaluator.dart';

import 'admin_http_timeout.dart';
import 'observability_admin_gateway.dart'
    show ObservabilityAdminBearerTokenProvider;

/// Parsed tripwire envelope. Mirrors the route's wire contract; nulls
/// are tolerated in `value` because a producer projected to unknown
/// keeps the metric out of the breach list but still appears as a row
/// in the admin section.
@immutable
class RealtimeTripwireSnapshot {
  const RealtimeTripwireSnapshot({
    required this.status,
    required this.metrics,
    required this.checkedAt,
  });

  final OutboxTripwireStatus status;
  final List<RealtimeTripwireMetricRow> metrics;
  final DateTime checkedAt;

  factory RealtimeTripwireSnapshot.fromJson(Map<String, Object?> json) {
    final rawMetrics = (json['metrics'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final rows = <RealtimeTripwireMetricRow>[];
    for (final metric in OutboxTripwireMetric.values) {
      final key = outboxTripwireMetricKey(metric);
      final entry = (rawMetrics[key] as Map?)?.cast<String, Object?>();
      if (entry == null) continue;
      final thresholds = (entry['thresholds'] as Map?)?.cast<String, Object?>();
      rows.add(
        RealtimeTripwireMetricRow(
          metric: metric,
          key: key,
          label: outboxTripwireMetricLabel(metric),
          value: (entry['value'] as num?),
          status: _parseStatusOrUnknown(entry['status']),
          yellow: (thresholds?['yellow'] as num?) ??
              kOutboxTripwireDefaultThresholds[metric]!.yellow,
          red: (thresholds?['red'] as num?) ??
              kOutboxTripwireDefaultThresholds[metric]!.red,
        ),
      );
    }
    final asOfRaw = json['checked_at'] as String?;
    final asOf = (asOfRaw != null) ? DateTime.tryParse(asOfRaw) : null;
    return RealtimeTripwireSnapshot(
      status: _parseStatus(json['status']),
      metrics: List<RealtimeTripwireMetricRow>.unmodifiable(rows),
      checkedAt: (asOf ?? DateTime.now()).toUtc(),
    );
  }

  static OutboxTripwireStatus _parseStatus(Object? raw) {
    switch (raw) {
      case 'red':
        return OutboxTripwireStatus.red;
      case 'yellow':
        return OutboxTripwireStatus.yellow;
      default:
        return OutboxTripwireStatus.green;
    }
  }
}

/// Status value rendered on a row pill. Distinct from
/// [OutboxTripwireStatus] because the admin row also surfaces the
/// `unknown` placeholder a producer reports when its query failed.
enum RealtimeTripwireRowStatus { green, yellow, red, unknown }

RealtimeTripwireRowStatus _parseStatusOrUnknown(Object? raw) {
  switch (raw) {
    case 'red':
      return RealtimeTripwireRowStatus.red;
    case 'yellow':
      return RealtimeTripwireRowStatus.yellow;
    case 'green':
      return RealtimeTripwireRowStatus.green;
    default:
      return RealtimeTripwireRowStatus.unknown;
  }
}

@immutable
class RealtimeTripwireMetricRow {
  const RealtimeTripwireMetricRow({
    required this.metric,
    required this.key,
    required this.label,
    required this.value,
    required this.status,
    required this.yellow,
    required this.red,
  });

  final OutboxTripwireMetric metric;
  final String key;
  final String label;
  final num? value;
  final RealtimeTripwireRowStatus status;
  final num yellow;
  final num red;
}

class RealtimeTripwireAdminGatewayError implements Exception {
  const RealtimeTripwireAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'RealtimeTripwireAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class RealtimeTripwireAdminGateway {
  Future<RealtimeTripwireSnapshot> fetch();
}

class HttpRealtimeTripwireAdminGateway implements RealtimeTripwireAdminGateway {
  HttpRealtimeTripwireAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHealthHttpRequestTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final Uri baseUri;
  final ObservabilityAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String tripwireStatusPath = '/v1/realtime/tripwire-status';

  @override
  Future<RealtimeTripwireSnapshot> fetch() async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(tripwireStatusPath);
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
      throw RealtimeTripwireAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'tripwire status proxy timed out after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return RealtimeTripwireSnapshot.fromJson(parsed);
    }
    throw RealtimeTripwireAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: (parsed['message'] as String?) ??
          'tripwire status proxy returned an error',
    );
  }
}

/// In-memory gateway used by the demo walkthrough and widget tests.
class InMemoryRealtimeTripwireAdminGateway
    implements RealtimeTripwireAdminGateway {
  InMemoryRealtimeTripwireAdminGateway({required this.snapshot});

  RealtimeTripwireSnapshot snapshot;
  int fetchCount = 0;

  @override
  Future<RealtimeTripwireSnapshot> fetch() async {
    fetchCount += 1;
    return snapshot;
  }
}
