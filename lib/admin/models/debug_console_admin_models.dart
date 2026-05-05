// Phase 11A.5 - Debug console admin value objects.
//
// The debug console reads `proxy_requests` rows projected as
// [RequestLogEntry] plus the `feature_flags` opt-in row that gates
// per-operator full-content reveal. The launch slice ships the
// per-operator request log surface; graph-debug (11A.3.x) and
// MFA-diagnostics (9.UX.1a) extensions plug into the same screen via
// stubbed tabs and do not influence the model surface.
//
// `proxy_requests` columns the launch surface needs (read-only):
//
//   * request_id            - UUID stamped by the proxy.
//   * idempotency_key       - clients send this on every non-GET.
//   * operator_id           - RLS scope.
//   * location_id           - RLS scope (nullable for global routes).
//   * usage_class           - advisor_qa / coach_qa / wf_pl / etc.
//   * status                - success / error / timeout.
//   * started_at            - UTC instant the proxy began the work.
//   * latency_ms            - proxy-side wall-clock duration.
//   * request_meta          - sanitized header/route summary always
//                             safe to render (no payload bodies).
//   * full_content          - raw prompt/response payload. ONLY
//                             populated when the operator's
//                             `debug_console_full_content_enabled`
//                             feature_flags row is on AND the actor
//                             holds `super_admin`.
//
// The opt-in is a `feature_flags` row with `flag_name =
// 'debug_console_full_content_enabled'`, scoped to the operator
// (operator_id non-null, location_id null) per the partial-unique
// index on `feature_flags`.

import 'package:flutter/foundation.dart';

/// `feature_flags.flag_name` the screen reads to decide whether to
/// render the expand-row full-content reveal. The proxy stamps the
/// row from the operator-level Feature Flags admin surface (11A.7);
/// this slice consumes it read-only.
const String kDebugConsoleFullContentFlagName =
    'debug_console_full_content_enabled';

/// Bucket the screen uses to colour status chips and filter rows.
enum RequestLogStatus { success, error, timeout, unknown }

RequestLogStatus parseRequestLogStatus(Object? raw) {
  if (raw is! String) return RequestLogStatus.unknown;
  switch (raw.toLowerCase()) {
    case 'success':
    case 'ok':
      return RequestLogStatus.success;
    case 'error':
    case 'failed':
      return RequestLogStatus.error;
    case 'timeout':
      return RequestLogStatus.timeout;
    default:
      return RequestLogStatus.unknown;
  }
}

String requestLogStatusLabel(RequestLogStatus status) {
  switch (status) {
    case RequestLogStatus.success:
      return 'success';
    case RequestLogStatus.error:
      return 'error';
    case RequestLogStatus.timeout:
      return 'timeout';
    case RequestLogStatus.unknown:
      return 'unknown';
  }
}

/// Time-window presets the filter chips offer. Custom ranges are not
/// part of the launch surface.
enum RequestLogTimeWindow { last5m, last1h, last24h, last7d }

String requestLogTimeWindowLabel(RequestLogTimeWindow window) {
  switch (window) {
    case RequestLogTimeWindow.last5m:
      return 'Last 5 min';
    case RequestLogTimeWindow.last1h:
      return 'Last hour';
    case RequestLogTimeWindow.last24h:
      return 'Last 24 h';
    case RequestLogTimeWindow.last7d:
      return 'Last 7 d';
  }
}

Duration requestLogTimeWindowSpan(RequestLogTimeWindow window) {
  switch (window) {
    case RequestLogTimeWindow.last5m:
      return const Duration(minutes: 5);
    case RequestLogTimeWindow.last1h:
      return const Duration(hours: 1);
    case RequestLogTimeWindow.last24h:
      return const Duration(hours: 24);
    case RequestLogTimeWindow.last7d:
      return const Duration(days: 7);
  }
}

/// One projected `proxy_requests` row.
@immutable
class RequestLogEntry {
  const RequestLogEntry({
    required this.requestId,
    required this.idempotencyKey,
    required this.operatorId,
    required this.locationId,
    required this.usageClass,
    required this.status,
    required this.startedAt,
    required this.latencyMs,
    required this.requestMeta,
    required this.fullContentOptInOn,
    this.fullContentPayload,
  });

  /// UUID stamped by the proxy.
  final String requestId;

  /// Per-request idempotency key supplied by the client; the proxy
  /// stores it on `proxy_requests` (UNIQUE).
  final String idempotencyKey;
  final String operatorId;
  final String? locationId;

  /// Usage class the request billed against (e.g. `advisor_qa`,
  /// `coach_qa`, `wf_pl`).
  final String usageClass;
  final RequestLogStatus status;
  final DateTime startedAt;
  final int latencyMs;

  /// Sanitized header/route summary; always safe to render.
  final Map<String, Object?> requestMeta;

  /// Snapshot of the operator's
  /// `debug_console_full_content_enabled` feature_flags row at the
  /// moment the proxy emitted the projection. The screen consults
  /// this AND the actor's role before rendering [fullContentPayload].
  final bool fullContentOptInOn;

  /// Raw prompt/response payload. Always null when the operator's
  /// opt-in is off; populated only when the proxy projected it for
  /// a `super_admin` caller.
  final Map<String, Object?>? fullContentPayload;

  factory RequestLogEntry.fromJson(Map<String, Object?> json) {
    return RequestLogEntry(
      requestId: (json['request_id'] as String?) ?? '',
      idempotencyKey: (json['idempotency_key'] as String?) ?? '',
      operatorId: (json['operator_id'] as String?) ?? '',
      locationId: json['location_id'] as String?,
      usageClass: (json['usage_class'] as String?) ?? '',
      status: parseRequestLogStatus(json['status']),
      startedAt: _parseUtc(json['started_at']) ?? DateTime.utc(1970),
      latencyMs: _parseInt(json['latency_ms']) ?? 0,
      requestMeta:
          (json['request_meta'] as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{},
      fullContentOptInOn: (json['full_content_opt_in'] as bool?) ?? false,
      fullContentPayload: (json['full_content'] as Map?)
          ?.cast<String, Object?>(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'request_id': requestId,
    'idempotency_key': idempotencyKey,
    'operator_id': operatorId,
    'location_id': locationId,
    'usage_class': usageClass,
    'status': requestLogStatusLabel(status),
    'started_at': startedAt.toUtc().toIso8601String(),
    'latency_ms': latencyMs,
    'request_meta': requestMeta,
    'full_content_opt_in': fullContentOptInOn,
    if (fullContentPayload != null) 'full_content': fullContentPayload,
  };
}

/// Filter applied to the request log list. Empty-valued fields mean
/// "no filter on this axis"; the gateway (and the in-memory matcher)
/// AND filters together.
@immutable
class RequestLogFilter {
  const RequestLogFilter({
    this.operatorId,
    this.locationId,
    this.usageClass,
    this.status,
    this.timeWindow,
    this.searchText,
  });

  final String? operatorId;
  final String? locationId;
  final String? usageClass;
  final RequestLogStatus? status;
  final RequestLogTimeWindow? timeWindow;

  /// Free-form search text that matches `request_id` OR
  /// `idempotency_key` (case-insensitive prefix match).
  final String? searchText;

  bool get isEmpty =>
      operatorId == null &&
      locationId == null &&
      usageClass == null &&
      status == null &&
      timeWindow == null &&
      (searchText == null || searchText!.isEmpty);

  RequestLogFilter copyWith({
    Object? operatorId = _unset,
    Object? locationId = _unset,
    Object? usageClass = _unset,
    Object? status = _unset,
    Object? timeWindow = _unset,
    Object? searchText = _unset,
  }) {
    return RequestLogFilter(
      operatorId: operatorId == _unset
          ? this.operatorId
          : operatorId as String?,
      locationId: locationId == _unset
          ? this.locationId
          : locationId as String?,
      usageClass: usageClass == _unset
          ? this.usageClass
          : usageClass as String?,
      status: status == _unset ? this.status : status as RequestLogStatus?,
      timeWindow: timeWindow == _unset
          ? this.timeWindow
          : timeWindow as RequestLogTimeWindow?,
      searchText: searchText == _unset
          ? this.searchText
          : searchText as String?,
    );
  }

  /// True iff [entry] satisfies every populated filter axis. Used by
  /// the in-memory gateway and by the screen for client-side
  /// re-filtering when the operator narrows a chip without forcing a
  /// fresh round-trip.
  bool matches(RequestLogEntry entry, {DateTime? now}) {
    if (operatorId != null &&
        operatorId!.isNotEmpty &&
        entry.operatorId != operatorId) {
      return false;
    }
    if (locationId != null &&
        locationId!.isNotEmpty &&
        entry.locationId != locationId) {
      return false;
    }
    if (usageClass != null &&
        usageClass!.isNotEmpty &&
        entry.usageClass != usageClass) {
      return false;
    }
    if (status != null && entry.status != status) {
      return false;
    }
    if (timeWindow != null) {
      final reference = now ?? DateTime.now().toUtc();
      final cutoff = reference.subtract(requestLogTimeWindowSpan(timeWindow!));
      if (entry.startedAt.isBefore(cutoff)) return false;
    }
    final search = searchText;
    if (search != null && search.isNotEmpty) {
      final needle = search.toLowerCase();
      final matchesId = entry.requestId.toLowerCase().contains(needle);
      final matchesKey = entry.idempotencyKey.toLowerCase().contains(needle);
      if (!matchesId && !matchesKey) return false;
    }
    return true;
  }
}

const Object _unset = Object();

/// Operator-level full-content opt-in projection. Sourced from the
/// `feature_flags` row whose `flag_name =
/// 'debug_console_full_content_enabled'` and `operator_id =
/// `<operator>`` (location_id null per the partial-unique-index shape).
@immutable
class FullContentOptIn {
  const FullContentOptIn({
    required this.operatorId,
    required this.flagName,
    required this.enabled,
    required this.updatedAt,
    this.flagId,
    this.updatedBy,
  });

  final String operatorId;
  final String flagName;
  final bool enabled;
  final DateTime updatedAt;
  final String? flagId;
  final String? updatedBy;

  factory FullContentOptIn.fromJson(Map<String, Object?> json) {
    return FullContentOptIn(
      operatorId: (json['operator_id'] as String?) ?? '',
      flagName:
          (json['flag_name'] as String?) ?? kDebugConsoleFullContentFlagName,
      enabled: (json['enabled'] as bool?) ?? false,
      updatedAt: _parseUtc(json['updated_at']) ?? DateTime.utc(1970),
      flagId: json['flag_id'] as String?,
      updatedBy: json['updated_by'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'operator_id': operatorId,
    'flag_name': flagName,
    'enabled': enabled,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    if (flagId != null) 'flag_id': flagId,
    if (updatedBy != null) 'updated_by': updatedBy,
  };
}

int? _parseInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

DateTime? _parseUtc(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final parsed = DateTime.tryParse(raw);
  return parsed?.toUtc();
}
