// Phase 11A.5 - Debug console admin gateway.
//
// Translates the screen's read intents into proxy
// `/v1/admin/debug/*` HTTP calls. The admin Flutter client never
// holds a Postgres connection string and never reaches the database
// directly - every read flows through the F&F admin proxy. Writes are
// out of scope for this surface (it is read-only debugging).
//
// Two implementations ship in this slice:
//
//   * [HttpDebugConsoleAdminGateway] - production. GET against the
//     proxy with the signed-in admin's bearer token. Filters are
//     query-string encoded; the request log list endpoint paginates
//     by `started_at` desc but the launch surface fetches a bounded
//     window (default 100 rows) per call.
//
//   * [InMemoryDebugConsoleAdminGateway] - demo + widget tests. Seed
//     a deterministic mix of operators / locations / usage classes /
//     statuses / opt-ins so the screen can be driven end-to-end
//     without a backend.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/debug_console_admin_models.dart';
import 'admin_http_timeout.dart';

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token stream;
/// tests pin a synthetic value.
typedef DebugConsoleAdminBearerTokenProvider = Future<String> Function();

/// Top-level error type for debug-console gateway calls.
class DebugConsoleAdminGatewayError implements Exception {
  const DebugConsoleAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'DebugConsoleAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class DebugConsoleAdminGateway {
  /// Fetch the latest request-log rows that satisfy [filter]. The
  /// proxy enforces RLS so the caller's role gate is the boundary;
  /// `super_admin` and `ff_support` both admit on this read path.
  Future<List<RequestLogEntry>> listRequests(
    RequestLogFilter filter, {
    int limit = kDebugConsoleListLimit,
  });

  /// Single-row lookup by `request_id`. Returns null when the proxy
  /// answers 404; throws on any other non-2xx response.
  Future<RequestLogEntry?> getByRequestId(String requestId);

  /// Single-row lookup by `idempotency_key`.
  Future<RequestLogEntry?> getByIdempotencyKey(String idempotencyKey);

  /// Returns the most recent N rows ordered by [RequestLogEntry.startedAt]
  /// descending. The screen polls this on a slow tick when the
  /// live-tail toggle is on.
  Future<List<RequestLogEntry>> tailRecent({
    int limit = kDebugConsoleTailLimit,
  });

  /// Operator-level full-content opt-in projections. The admin shell
  /// renders one entry per operator the caller is allowed to
  /// administer (RLS on `feature_flags` keeps the list tenant-scoped).
  Future<List<FullContentOptIn>> listFullContentOptIns();
}

/// Default bounded page size for the request-log list.
const int kDebugConsoleListLimit = 100;

/// Default page size for live-tail polling.
const int kDebugConsoleTailLimit = 25;

/// Default poll cadence the screen uses while live-tail is on.
const Duration kDebugConsoleTailPollInterval = Duration(seconds: 5);

class HttpDebugConsoleAdminGateway implements DebugConsoleAdminGateway {
  HttpDebugConsoleAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`). The
  /// gateway resolves `/v1/admin/debug/*` against this.
  final Uri baseUri;
  final DebugConsoleAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String requestsPath = '/v1/admin/debug/requests';
  static const String requestByIdPath = '/v1/admin/debug/requests/by-id';
  static const String requestByKeyPath = '/v1/admin/debug/requests/by-key';
  static const String tailPath = '/v1/admin/debug/requests/tail';
  static const String optInsPath = '/v1/admin/debug/full-content-opt-ins';

  @override
  Future<List<RequestLogEntry>> listRequests(
    RequestLogFilter filter, {
    int limit = kDebugConsoleListLimit,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (filter.operatorId != null && filter.operatorId!.isNotEmpty) {
      query['operator_id'] = filter.operatorId!;
    }
    if (filter.locationId != null && filter.locationId!.isNotEmpty) {
      query['location_id'] = filter.locationId!;
    } else if (filter.locationIds != null && filter.locationIds!.length == 1) {
      query['location_id'] = filter.locationIds!.single;
    } else if (filter.locationIds != null && filter.locationIds!.isNotEmpty) {
      query['location_ids'] = filter.locationIds!.join(',');
    }
    if (filter.usageClass != null && filter.usageClass!.isNotEmpty) {
      query['usage_class'] = filter.usageClass!;
    }
    if (filter.status != null) {
      query['status'] = requestLogStatusLabel(filter.status!);
    }
    if (filter.timeWindow != null) {
      query['time_window_seconds'] =
          '${requestLogTimeWindowSpan(filter.timeWindow!).inSeconds}';
    }
    if (filter.searchText != null && filter.searchText!.isNotEmpty) {
      query['q'] = filter.searchText!;
    }
    final body = await _send(
      method: 'GET',
      path: requestsPath,
      queryParameters: query,
    );
    final list = (body['requests'] as List?) ?? const [];
    return <RequestLogEntry>[
      for (final entry in list)
        RequestLogEntry.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<RequestLogEntry?> getByRequestId(String requestId) async {
    return _fetchSingle(requestByIdPath, <String, String>{
      'request_id': requestId,
    });
  }

  @override
  Future<RequestLogEntry?> getByIdempotencyKey(String idempotencyKey) async {
    return _fetchSingle(requestByKeyPath, <String, String>{
      'idempotency_key': idempotencyKey,
    });
  }

  @override
  Future<List<RequestLogEntry>> tailRecent({
    int limit = kDebugConsoleTailLimit,
  }) async {
    final body = await _send(
      method: 'GET',
      path: tailPath,
      queryParameters: <String, String>{'limit': '$limit'},
    );
    final list = (body['requests'] as List?) ?? const [];
    return <RequestLogEntry>[
      for (final entry in list)
        RequestLogEntry.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<List<FullContentOptIn>> listFullContentOptIns() async {
    final body = await _send(method: 'GET', path: optInsPath);
    final list = (body['opt_ins'] as List?) ?? const [];
    return <FullContentOptIn>[
      for (final entry in list)
        FullContentOptIn.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  Future<RequestLogEntry?> _fetchSingle(
    String path,
    Map<String, String> queryParameters,
  ) async {
    try {
      final body = await _send(
        method: 'GET',
        path: path,
        queryParameters: queryParameters,
      );
      final raw = body['request'];
      if (raw is Map) {
        return RequestLogEntry.fromJson(raw.cast<String, Object?>());
      }
      return null;
    } on DebugConsoleAdminGatewayError catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
  }) async {
    final token = await bearerTokenProvider();
    Uri uri = baseUri.resolve(path);
    if (queryParameters != null && queryParameters.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{
          ...uri.queryParameters,
          ...queryParameters,
        },
      );
    }
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw DebugConsoleAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin debug-console proxy timed out after '
            '${_timeout.inSeconds}s',
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
      return parsed;
    }
    throw DebugConsoleAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ??
          'admin debug-console proxy returned an error',
    );
  }
}

/// In-memory gateway used by the demo walkthrough and widget tests.
/// Persists nothing across runs - every construction starts from
/// [seed] / [optInSeed]. Filtering mirrors [RequestLogFilter.matches]
/// so the demo behaves identically to the proxy.
class InMemoryDebugConsoleAdminGateway implements DebugConsoleAdminGateway {
  InMemoryDebugConsoleAdminGateway({
    Iterable<RequestLogEntry> seed = const <RequestLogEntry>[],
    Iterable<FullContentOptIn> optInSeed = const <FullContentOptIn>[],
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc()),
       _entries = <RequestLogEntry>[...seed],
       _optIns = <String, FullContentOptIn>{
         for (final row in optInSeed) row.operatorId: row,
       };

  final DateTime Function() _now;
  final List<RequestLogEntry> _entries;
  final Map<String, FullContentOptIn> _optIns;

  /// Add an entry - used by the demo walkthrough to push a synthetic
  /// new row while the live-tail toggle is on.
  void appendEntry(RequestLogEntry entry) {
    _entries.add(entry);
  }

  /// Replace the seeded entries (used by widget tests).
  void replaceEntries(Iterable<RequestLogEntry> entries) {
    _entries
      ..clear()
      ..addAll(entries);
  }

  /// Replace the opt-in projections (used by widget tests).
  void replaceOptIns(Iterable<FullContentOptIn> optIns) {
    _optIns
      ..clear()
      ..addEntries(optIns.map((o) => MapEntry(o.operatorId, o)));
  }

  @override
  Future<List<RequestLogEntry>> listRequests(
    RequestLogFilter filter, {
    int limit = kDebugConsoleListLimit,
  }) async {
    final reference = _now();
    final matched = <RequestLogEntry>[
      for (final entry in _entries)
        if (filter.matches(entry, now: reference)) entry,
    ];
    matched.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final clamped = matched.length > limit
        ? matched.sublist(0, limit)
        : matched;
    return List<RequestLogEntry>.unmodifiable(clamped);
  }

  @override
  Future<RequestLogEntry?> getByRequestId(String requestId) async {
    for (final entry in _entries) {
      if (entry.requestId == requestId) return entry;
    }
    return null;
  }

  @override
  Future<RequestLogEntry?> getByIdempotencyKey(String idempotencyKey) async {
    for (final entry in _entries) {
      if (entry.idempotencyKey == idempotencyKey) return entry;
    }
    return null;
  }

  @override
  Future<List<RequestLogEntry>> tailRecent({
    int limit = kDebugConsoleTailLimit,
  }) async {
    final sorted = <RequestLogEntry>[..._entries]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final clamped = sorted.length > limit ? sorted.sublist(0, limit) : sorted;
    return List<RequestLogEntry>.unmodifiable(clamped);
  }

  @override
  Future<List<FullContentOptIn>> listFullContentOptIns() async {
    final list = _optIns.values.toList()
      ..sort((a, b) => a.operatorId.compareTo(b.operatorId));
    return List<FullContentOptIn>.unmodifiable(list);
  }
}

/// Default in-memory seed used by the kDemoMode walkthrough. Three
/// operators × mixed usage_class × mixed status × opt-in / opt-out so
/// the screen renders every filter axis without a backend.
List<RequestLogEntry> kDebugConsoleDemoEntries = <RequestLogEntry>[
  RequestLogEntry(
    requestId: 'req-00000000-0000-4000-8000-000000000a01',
    idempotencyKey: 'idem-advisor-001',
    operatorId: '00000000-0000-4000-8000-000000000001',
    locationId: '00000000-0000-4000-8000-0000000000a1',
    usageClass: 'advisor_qa',
    status: RequestLogStatus.success,
    startedAt: DateTime.utc(2026, 5, 3, 11, 58, 12),
    latencyMs: 412,
    requestMeta: const <String, Object?>{
      'route': '/v1/advisor/answer',
      'method': 'POST',
      'model': 'claude-sonnet-4-6',
      'cache_hit': true,
    },
    fullContentOptInOn: true,
    fullContentPayload: const <String, Object?>{
      'prompt_summary':
          'Advisor question about labor target deviations on Toronto Yorkville.',
      'response_summary':
          'Recommendation to investigate Saturday daypart staffing.',
    },
  ),
  RequestLogEntry(
    requestId: 'req-00000000-0000-4000-8000-000000000a02',
    idempotencyKey: 'idem-coach-014',
    operatorId: '00000000-0000-4000-8000-000000000001',
    locationId: '00000000-0000-4000-8000-0000000000a1',
    usageClass: 'coach_qa',
    status: RequestLogStatus.error,
    startedAt: DateTime.utc(2026, 5, 3, 11, 56, 4),
    latencyMs: 1284,
    requestMeta: const <String, Object?>{
      'route': '/v1/coach/answer',
      'method': 'POST',
      'error': 'usage_caps_breach',
    },
    fullContentOptInOn: true,
  ),
  RequestLogEntry(
    requestId: 'req-00000000-0000-4000-8000-000000000a03',
    idempotencyKey: 'idem-wf-pl-007',
    operatorId: '00000000-0000-4000-8000-000000000001',
    locationId: '00000000-0000-4000-8000-0000000000a2',
    usageClass: 'wf_pl',
    status: RequestLogStatus.success,
    startedAt: DateTime.utc(2026, 5, 3, 11, 50, 33),
    latencyMs: 8420,
    requestMeta: const <String, Object?>{
      'route': '/v1/workflows/pl_runs',
      'method': 'POST',
      'rows_returned': 28,
    },
    fullContentOptInOn: true,
  ),
  RequestLogEntry(
    requestId: 'req-00000000-0000-4000-8000-000000000b01',
    idempotencyKey: 'idem-advisor-219',
    operatorId: '00000000-0000-4000-8000-000000000002',
    locationId: '00000000-0000-4000-8000-0000000000b1',
    usageClass: 'advisor_qa',
    status: RequestLogStatus.timeout,
    startedAt: DateTime.utc(2026, 5, 3, 11, 45, 59),
    latencyMs: 30000,
    requestMeta: const <String, Object?>{
      'route': '/v1/advisor/answer',
      'method': 'POST',
      'circuit_breaker': 'half_open',
    },
    fullContentOptInOn: false,
  ),
  RequestLogEntry(
    requestId: 'req-00000000-0000-4000-8000-000000000b02',
    idempotencyKey: 'idem-wf-schedule-141',
    operatorId: '00000000-0000-4000-8000-000000000002',
    locationId: '00000000-0000-4000-8000-0000000000b1',
    usageClass: 'wf_schedule',
    status: RequestLogStatus.success,
    startedAt: DateTime.utc(2026, 5, 3, 11, 32, 17),
    latencyMs: 524,
    requestMeta: const <String, Object?>{
      'route': '/v1/workflows/schedule_runs',
      'method': 'POST',
      'rows_returned': 5,
    },
    fullContentOptInOn: false,
  ),
];

/// Default in-memory opt-in seed. Demo Diner Co. has the launch
/// debug-console full-content opt-in turned on; Sunset Cafe Group
/// keeps it off so the walkthrough can demonstrate the meta-only
/// path.
List<FullContentOptIn> kDebugConsoleDemoOptIns = <FullContentOptIn>[
  FullContentOptIn(
    operatorId: '00000000-0000-4000-8000-000000000001',
    flagName: kDebugConsoleFullContentFlagName,
    enabled: true,
    updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
    flagId: '00000000-0000-4000-8000-0000000000f5',
    updatedBy: 'demo-super-admin',
  ),
  FullContentOptIn(
    operatorId: '00000000-0000-4000-8000-000000000002',
    flagName: kDebugConsoleFullContentFlagName,
    enabled: false,
    updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
    flagId: '00000000-0000-4000-8000-0000000000f6',
    updatedBy: 'demo-super-admin',
  ),
];
