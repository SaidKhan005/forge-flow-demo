// Wave W2.D — Operator Web Connector Backfill Jobs gateway.
//
// Reads the `connector_backfill_jobs` projection through the
// operator-scoped proxy route shipped by
// `tool/advisor_proxy/connector_backfill_jobs_routes.dart`.
//
// Web-safe: pure-Dart, no `dart:io`. Mirrors the existing operator-web
// gateway shape (live HTTP impl + demo impl + provider sentinel) so
// the auth source mixes in the gateway and the screen consumes it via
// `is`-typecheck without coupling to a concrete impl.
//
// UX writing standard (per `memory/project_ux_writing_standard.md`):
// the screen renders plain-English progress per Doc 1's empty/loading/
// stale rules; the gateway returns the raw status so the screen can
// translate without re-parsing strings.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One backfill job row, projected from the proxy's
/// `/v1/operator/connector-backfill-jobs` response. Field names mirror
/// the wire shape so the screen + gateway never disagree.
class OperatorWebConnectorBackfillJob {
  const OperatorWebConnectorBackfillJob({
    required this.jobId,
    required this.connectionId,
    required this.vendorId,
    required this.category,
    required this.status,
    required this.windowStart,
    required this.windowEnd,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.cursorToken,
    this.lastModifiedSeen,
    this.workerId,
    this.claimedAt,
    this.completedAt,
    this.lastError,
  });

  /// Stable job UUID. Used as the React-key analogue when the screen
  /// rebuilds the progress widget.
  final String jobId;

  /// `connector_connection.connection_id` the job belongs to. Used to
  /// match the row up to the rendered vendor card.
  final String connectionId;

  /// Adapter id, e.g. `toast`, `seven_shifts`.
  final String vendorId;

  /// One of `pos`, `labor`, `reservation`.
  final String category;

  /// Wire status. One of `pending`, `running`, `succeeded`, `failed`,
  /// `dead_lettered`. The proxy currently emits the first four; the
  /// screen renders `dead_lettered` honestly when a future wire bump
  /// adds it (the value comes from `connector_backfill_jobs.status`).
  final String status;

  /// Start of the bounded 60-day backfill window in UTC.
  final DateTime windowStart;

  /// End of the bounded 60-day backfill window in UTC.
  final DateTime windowEnd;

  /// Cursor watermark — the resume token the worker advances after
  /// each successful page. Null until the worker has made its first
  /// pass. The screen renders this as the most-recent business-date
  /// processed when it parses as ISO-8601.
  final String? cursorToken;

  /// Most recent `last_modified_seen` cursor in UTC. Worker sets this
  /// alongside `cursor_token` so the screen can render a real
  /// timestamp without parsing the opaque cursor.
  final DateTime? lastModifiedSeen;

  /// Number of times this job has been claimed (incremented on every
  /// claim). Surfaces "retried 3 times" in the failure body.
  final int attemptCount;

  /// Worker id that last claimed the job. Null until first claim.
  final String? workerId;

  /// UTC timestamp the worker last claimed the job. Null until first
  /// claim.
  final DateTime? claimedAt;

  /// UTC timestamp the worker reported the terminal state. Null while
  /// the job is still pending or running.
  final DateTime? completedAt;

  /// Honest error message persisted on the last failed attempt. Null
  /// when the most recent attempt did not fail.
  final String? lastError;

  /// UTC timestamp the row was inserted by the post-commit projector.
  final DateTime createdAt;

  /// UTC timestamp of the row's most recent server-side update.
  final DateTime updatedAt;
}

/// Wire response for one read. The screen treats [jobs] as
/// already-deduped per `connection_id` (proxy emits the latest job per
/// connection) so it can build a `Map<String, …>` keyed on
/// `connectionId`.
class OperatorWebConnectorBackfillJobsBundle {
  const OperatorWebConnectorBackfillJobsBundle({
    required this.operatorId,
    required this.locationId,
    required this.jobs,
  });

  final String operatorId;
  final String locationId;

  /// Latest job per connection. Order is the proxy's
  /// `updated_at desc`, but the screen keys by `connectionId` so order
  /// is informational only.
  final List<OperatorWebConnectorBackfillJob> jobs;
}

/// Narrow gateway interface the Vendor Connections backfill widget
/// reads against. Demo + live impls share the same shape.
abstract class OperatorWebConnectorBackfillJobsGateway {
  /// Loads the latest backfill job per connection for the caller's
  /// (operator_id, location_id). [connectionId] narrows the result to
  /// a single connection when non-null.
  Future<OperatorWebConnectorBackfillJobsBundle> loadJobs({
    String? connectionId,
  });
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply an [OperatorWebConnectorBackfillJobsGateway]. Demo
/// sources omit the mixin and the screen renders an honest empty
/// state instead of falling back to a fixture (so the demo
/// walkthrough does not lie about progress).
abstract class OperatorWebConnectorBackfillJobsGatewayProvider {
  OperatorWebConnectorBackfillJobsGateway? get connectorBackfillJobsGateway;
}

/// Thrown when the proxy returns a non-2xx, the response body is
/// malformed, or the network call fails. Carries the proxy's error
/// code + message verbatim so the screen can surface honest copy.
class OperatorWebConnectorBackfillJobsError implements Exception {
  const OperatorWebConnectorBackfillJobsError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'OperatorWebConnectorBackfillJobsError(code: $code, status: $statusCode, '
      'message: $message)';
}

/// Live `package:http` implementation. Reads the Firebase ID token off
/// the supplied provider on every call so refreshed tokens land on the
/// next request; reuses the operator-web proxy path constant.
class OperatorWebConnectorBackfillJobsGatewayLive
    implements OperatorWebConnectorBackfillJobsGateway {
  OperatorWebConnectorBackfillJobsGatewayLive({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  }) : _idTokenProvider = idTokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  /// Wire path the live route is mounted at. Mirrored by the proxy
  /// route file `connector_backfill_jobs_routes.dart`.
  static const String path = '/v1/operator/connector-backfill-jobs';

  @override
  Future<OperatorWebConnectorBackfillJobsBundle> loadJobs({
    String? connectionId,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebConnectorBackfillJobsError(
        code: 'no_id_token',
        message:
            'Backfill progress gateway has no live Firebase ID token to '
            'attach to the request.',
      );
    }
    final params = <String, String>{};
    if (connectionId != null && connectionId.trim().isNotEmpty) {
      params['connection_id'] = connectionId.trim();
    }
    final url = proxyBaseUri.resolve(path).replace(
      queryParameters: params.isEmpty ? null : params,
    );
    final request = http.Request('GET', url)
      ..headers.addAll(<String, String>{
        'accept': 'application/json',
        'authorization': 'Bearer ${token.trim()}',
      });
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const OperatorWebConnectorBackfillJobsError(
        code: 'transport_timeout',
        message:
            'Backfill progress request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw OperatorWebConnectorBackfillJobsError(
        code: 'transport_error',
        message:
            'Backfill progress request failed before reaching the proxy '
            '($error).',
      );
    }
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    Object? decoded;
    if (raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = const <String, Object?>{};
      }
    }
    final body = decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw OperatorWebConnectorBackfillJobsError(
        code: _readNonBlankString(body['error']) ?? 'backfill_jobs_failed',
        message:
            _readNonBlankString(body['message']) ??
            'proxy returned status ${streamed.statusCode}',
        statusCode: streamed.statusCode,
      );
    }
    return _bundleFromJson(body);
  }

  static OperatorWebConnectorBackfillJobsBundle _bundleFromJson(
    Map<String, Object?> body,
  ) {
    final operatorId = _readNonBlankString(body['operator_id']) ?? '';
    final locationId = _readNonBlankString(body['location_id']) ?? '';
    final raw = body['jobs'];
    final jobs = <OperatorWebConnectorBackfillJob>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map<Object?, Object?>) {
          final job = _jobFromJson(Map<String, Object?>.from(entry));
          if (job != null) jobs.add(job);
        }
      }
    }
    return OperatorWebConnectorBackfillJobsBundle(
      operatorId: operatorId,
      locationId: locationId,
      jobs: List<OperatorWebConnectorBackfillJob>.unmodifiable(jobs),
    );
  }

  static OperatorWebConnectorBackfillJob? _jobFromJson(
    Map<String, Object?> json,
  ) {
    final jobId = _readNonBlankString(json['job_id']);
    final connectionId = _readNonBlankString(json['connection_id']);
    final vendorId = _readNonBlankString(json['vendor_id']);
    final category = _readNonBlankString(json['category']);
    final status = _readNonBlankString(json['status']);
    final windowStart = _readDate(json['window_start']);
    final windowEnd = _readDate(json['window_end']);
    final createdAt = _readDate(json['created_at']);
    final updatedAt = _readDate(json['updated_at']);
    if (jobId == null ||
        connectionId == null ||
        vendorId == null ||
        category == null ||
        status == null ||
        windowStart == null ||
        windowEnd == null ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }
    final attemptRaw = json['attempt_count'];
    final attemptCount = attemptRaw is int
        ? attemptRaw
        : (attemptRaw is num ? attemptRaw.toInt() : 0);
    return OperatorWebConnectorBackfillJob(
      jobId: jobId,
      connectionId: connectionId,
      vendorId: vendorId,
      category: category,
      status: status,
      windowStart: windowStart,
      windowEnd: windowEnd,
      cursorToken: _readNonBlankString(json['cursor_token']),
      lastModifiedSeen: _readDate(json['last_modified_seen']),
      attemptCount: attemptCount,
      workerId: _readNonBlankString(json['worker_id']),
      claimedAt: _readDate(json['claimed_at']),
      completedAt: _readDate(json['completed_at']),
      lastError: _readNonBlankString(json['last_error']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _readDate(Object? value) {
    if (value is DateTime) return value.toUtc();
    final raw = _readNonBlankString(value);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}

/// In-memory demo + test gateway. The demo auth source can mix this in
/// to render a fixture progress trail without hitting the proxy; tests
/// instantiate it directly with the same fixture shape.
class OperatorWebConnectorBackfillJobsGatewayInMemory
    implements OperatorWebConnectorBackfillJobsGateway {
  OperatorWebConnectorBackfillJobsGatewayInMemory({
    required this.operatorId,
    required this.locationId,
    List<OperatorWebConnectorBackfillJob>? jobs,
  }) : _jobs = List<OperatorWebConnectorBackfillJob>.unmodifiable(
         jobs ?? const <OperatorWebConnectorBackfillJob>[],
       );

  final String operatorId;
  final String locationId;
  final List<OperatorWebConnectorBackfillJob> _jobs;

  @override
  Future<OperatorWebConnectorBackfillJobsBundle> loadJobs({
    String? connectionId,
  }) async {
    final filtered = connectionId == null
        ? _jobs
        : _jobs
              .where((job) => job.connectionId == connectionId)
              .toList(growable: false);
    return OperatorWebConnectorBackfillJobsBundle(
      operatorId: operatorId,
      locationId: locationId,
      jobs: List<OperatorWebConnectorBackfillJob>.unmodifiable(filtered),
    );
  }
}
