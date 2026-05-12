// Phase 11A.7 - Feature flags admin gateway.
//
// Translates the screen's commands into proxy
// `/v1/admin/feature-flags/*` HTTP calls. The admin Flutter client
// never holds a Postgres connection string and never reaches the
// database directly - every read/write flows through the F&F admin
// proxy.
//
// Two implementations ship in this slice:
//
//   * [HttpFeatureFlagsAdminGateway] - production. GET/POST against
//     the proxy with the signed-in admin's bearer token. The toggle
//     POST carries an `Idempotency-Key` header so retries collapse to
//     one ledger row + one audit row.
//
//   * [InMemoryFeatureFlagsAdminGateway] - demo + widget tests.
//     Mutates an in-memory list so the screen runs end-to-end in
//     `kDemoMode` without a backend. Validation rules mirror the
//     proxy: unknown flag_id → 404, idempotency-key reuse → cached
//     result.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/feature_flags_admin_models.dart';
import 'admin_http_timeout.dart';

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token stream;
/// tests pin a synthetic value.
typedef FeatureFlagsAdminBearerTokenProvider = Future<String> Function();

/// Top-level error type for gateway calls. Carries an HTTP-style
/// status code + machine-readable error code so the screen can branch
/// on `permission_denied` / `unknown_flag` / `validation_failed`
/// without parsing `message`.
class FeatureFlagsAdminGatewayError implements Exception {
  const FeatureFlagsAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'FeatureFlagsAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class FeatureFlagsAdminGateway {
  /// Lists every `feature_flags` row across all scopes, ordered for
  /// the admin grid (destructive flags first, then alphabetical).
  Future<List<FeatureFlagAdminRow>> listFlags({FeatureFlagScopeFilter? scope});

  /// Toggle one flag. Returns the post-toggle row (so the screen can
  /// re-render with the latest `updated_by` / `updated_at` without a
  /// separate refresh round-trip).
  Future<FeatureFlagAdminRow> toggleFlag(FeatureFlagToggleCommand command);
}

class FeatureFlagScopeFilter {
  const FeatureFlagScopeFilter({
    required this.operatorId,
    this.locationId,
    this.locationIds = const <String>{},
  });

  final String operatorId;
  final String? locationId;
  final Set<String> locationIds;

  Map<String, String> toQueryParameters() {
    return <String, String>{
      'operator_id': operatorId,
      if (locationId != null && locationId!.isNotEmpty)
        'location_id': locationId!,
      if (locationIds.isNotEmpty) 'location_ids': locationIds.join(','),
    };
  }

  bool includes(FeatureFlagAdminRow row) {
    final rowOperatorId = row.operatorId;
    final rowLocationId = row.locationId;
    if (rowOperatorId == null && rowLocationId == null) return true;
    if (rowOperatorId != operatorId) return false;
    if (rowLocationId == null) return true;
    if (locationId != null && rowLocationId == locationId) return true;
    return locationIds.contains(rowLocationId);
  }
}

class HttpFeatureFlagsAdminGateway implements FeatureFlagsAdminGateway {
  HttpFeatureFlagsAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`). The
  /// gateway resolves `/v1/admin/feature-flags/*` against this.
  final Uri baseUri;
  final FeatureFlagsAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String listPath = '/v1/admin/feature-flags';
  static const String togglePath = '/v1/admin/feature-flags/toggle';

  @override
  Future<List<FeatureFlagAdminRow>> listFlags({
    FeatureFlagScopeFilter? scope,
  }) async {
    final body = await _send(
      method: 'GET',
      path: listPath,
      queryParameters: scope?.toQueryParameters(),
    );
    final list = (body['flags'] as List?) ?? const [];
    return <FeatureFlagAdminRow>[
      for (final entry in list)
        FeatureFlagAdminRow.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<FeatureFlagAdminRow> toggleFlag(
    FeatureFlagToggleCommand command,
  ) async {
    final body = await _send(
      method: 'POST',
      path: togglePath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return FeatureFlagAdminRow.fromJson(
      (body['flag'] as Map).cast<String, Object?>(),
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path).replace(queryParameters: queryParameters);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw FeatureFlagsAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin feature flags proxy timed out after '
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
    throw FeatureFlagsAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ??
          'admin feature flags proxy returned an error',
    );
  }
}

/// In-memory gateway used by the demo walkthrough and widget tests.
/// Persists nothing across runs - every construction starts from
/// [seed]. Validation rules mirror the proxy:
///
///   * Unknown `flag_id` → 404 `unknown_flag`.
///   * Idempotency-key reuse → returns the prior result without
///     re-toggling (proxy stores keys in `proxy_requests` UNIQUE).
class InMemoryFeatureFlagsAdminGateway implements FeatureFlagsAdminGateway {
  InMemoryFeatureFlagsAdminGateway({
    Iterable<FeatureFlagAdminRow> seed = const <FeatureFlagAdminRow>[],
    DateTime Function()? now,
    String? actorUserId,
  }) : _now = now ?? DateTime.now,
       _actorUserId = actorUserId,
       _flags = <String, FeatureFlagAdminRow>{
         for (final row in seed) row.flagId: row,
       };

  final DateTime Function() _now;
  final String? _actorUserId;
  final Map<String, FeatureFlagAdminRow> _flags;
  final Map<String, FeatureFlagAdminRow> _idempotentResults =
      <String, FeatureFlagAdminRow>{};

  @override
  Future<List<FeatureFlagAdminRow>> listFlags({
    FeatureFlagScopeFilter? scope,
  }) async {
    final list = _flags.values.toList()
      ..removeWhere((row) => scope != null && !scope.includes(row))
      ..sort((a, b) {
        // Destructive flags first so kill switches surface at the top
        // of the operator's view.
        if (a.isDestructive != b.isDestructive) {
          return a.isDestructive ? -1 : 1;
        }
        return a.flagName.toLowerCase().compareTo(b.flagName.toLowerCase());
      });
    return List<FeatureFlagAdminRow>.unmodifiable(list);
  }

  @override
  Future<FeatureFlagAdminRow> toggleFlag(
    FeatureFlagToggleCommand command,
  ) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached != null) return cached;
    final prior = _flags[command.flagId];
    if (prior == null) {
      throw const FeatureFlagsAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_flag',
        message: 'feature flag not found',
      );
    }
    final ts = _now().toUtc();
    final updated = FeatureFlagAdminRow(
      flagId: prior.flagId,
      flagName: prior.flagName,
      operatorId: prior.operatorId,
      locationId: prior.locationId,
      enabled: command.enabled,
      kind: prior.kind,
      description: prior.description,
      updatedBy: _actorUserId ?? prior.updatedBy,
      createdAt: prior.createdAt,
      updatedAt: ts,
    );
    _flags[prior.flagId] = updated;
    _idempotentResults[command.idempotencyKey] = updated;
    return updated;
  }
}
