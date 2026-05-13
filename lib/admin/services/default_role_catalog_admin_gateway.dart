// Lane B B2.1 — Default Role catalog admin gateway.
//
// Thin HTTP client over the two new admin routes:
//   GET  /v1/admin/auth/role-catalogs           {super_admin, ff_support}
//   POST /v1/admin/auth/role-catalogs/publish   super_admin only
//
// The admin Flutter client never holds a Postgres connection string
// and never reaches the database directly — every read/write flows
// through the F&F admin proxy. NO `package:postgres` import here per
// CLAUDE.md "Service-Layer Split".
//
// Payload shapes mirror the proxy contract documented in
// `tool/advisor_proxy/admin_default_role_catalog_routes.dart`.
//
// B2.2 (separate slice) ships the admin editor screen that consumes
// this gateway; this slice provides the gateway shape only.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'admin_http_timeout.dart';

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token stream;
/// tests pin a synthetic value.
typedef DefaultRoleCatalogAdminBearerTokenProvider = Future<String>
    Function();

/// Source for the next idempotency key. Production wires this to the
/// admin idempotency-key minter; tests pin a deterministic value.
typedef DefaultRoleCatalogIdempotencyKeyProvider = String Function();

/// Top-level error type for gateway calls. Carries an HTTP-style
/// status code + machine-readable error code so the screen can branch
/// on `permission_denied` / `validation_failed` / `idempotency_request_in_flight`
/// without parsing `message`.
class DefaultRoleCatalogAdminGatewayError implements Exception {
  const DefaultRoleCatalogAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'DefaultRoleCatalogAdminGatewayError($statusCode/$errorCode): $message';
}

/// One catalog version row as returned by the proxy. Mirrors the
/// `DefaultRoleCatalogVersionRow.toJson` shape from the repository.
class DefaultRoleCatalogVersionView {
  const DefaultRoleCatalogVersionView({
    required this.versionId,
    required this.versionNumber,
    required this.publishedAt,
    required this.publishedByUserId,
    required this.payload,
    required this.payloadSha256,
    required this.isCurrent,
    required this.supersededAt,
    required this.notes,
  });

  final String versionId;
  final int versionNumber;
  final DateTime publishedAt;
  final String publishedByUserId;
  final List<Object?> payload;
  final String payloadSha256;
  final bool isCurrent;
  final DateTime? supersededAt;
  final String? notes;

  factory DefaultRoleCatalogVersionView.fromJson(Map<String, Object?> json) {
    final supersededRaw = json['superseded_at'];
    return DefaultRoleCatalogVersionView(
      versionId: json['version_id'] as String,
      versionNumber: (json['version_number'] as num).toInt(),
      publishedAt: DateTime.parse(json['published_at'] as String).toUtc(),
      publishedByUserId: json['published_by_user_id'] as String,
      payload: (json['payload'] as List?) ?? const <Object?>[],
      payloadSha256: json['payload_sha256'] as String,
      isCurrent: (json['is_current'] as bool?) ?? false,
      supersededAt: supersededRaw is String
          ? DateTime.parse(supersededRaw).toUtc()
          : null,
      notes: json['notes'] as String?,
    );
  }
}

/// Carry-shape for the GET response: current row (when one exists) +
/// history list ordered by `version_number desc`.
class DefaultRoleCatalogListing {
  const DefaultRoleCatalogListing({
    required this.current,
    required this.history,
  });

  final DefaultRoleCatalogVersionView? current;
  final List<DefaultRoleCatalogVersionView> history;
}

abstract class DefaultRoleCatalogAdminGateway {
  /// GET the current catalog version + history. Admits ff_support +
  /// super_admin.
  Future<DefaultRoleCatalogListing> listCatalogs({int historyLimit = 20});

  /// Publish a new catalog version. super_admin only. The proxy
  /// requires an `Idempotency-Key` header — provided here from
  /// [idempotencyKeyProvider].
  Future<DefaultRoleCatalogVersionView> publishVersion({
    required List<Object?> payload,
    String? notes,
  });
}

class HttpDefaultRoleCatalogAdminGateway
    implements DefaultRoleCatalogAdminGateway {
  HttpDefaultRoleCatalogAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    required this.idempotencyKeyProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`). The
  /// gateway resolves `/v1/admin/auth/role-catalogs[/publish]` against
  /// this.
  final Uri baseUri;
  final DefaultRoleCatalogAdminBearerTokenProvider bearerTokenProvider;
  final DefaultRoleCatalogIdempotencyKeyProvider idempotencyKeyProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String listPath = '/v1/admin/auth/role-catalogs';
  static const String publishPath = '/v1/admin/auth/role-catalogs/publish';

  @override
  Future<DefaultRoleCatalogListing> listCatalogs({
    int historyLimit = 20,
  }) async {
    final body = await _send(
      method: 'GET',
      path: '$listPath?limit=$historyLimit',
    );
    final currentJson = body['current'];
    final historyJson = (body['history'] as List?) ?? const <Object?>[];
    return DefaultRoleCatalogListing(
      current: currentJson is Map
          ? DefaultRoleCatalogVersionView.fromJson(
              currentJson.cast<String, Object?>(),
            )
          : null,
      history: <DefaultRoleCatalogVersionView>[
        for (final entry in historyJson)
          if (entry is Map)
            DefaultRoleCatalogVersionView.fromJson(
              entry.cast<String, Object?>(),
            ),
      ],
    );
  }

  @override
  Future<DefaultRoleCatalogVersionView> publishVersion({
    required List<Object?> payload,
    String? notes,
  }) async {
    final body = await _send(
      method: 'POST',
      path: publishPath,
      idempotencyKey: idempotencyKeyProvider(),
      jsonBody: <String, Object?>{
        'payload': payload,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      },
    );
    return DefaultRoleCatalogVersionView.fromJson(body);
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
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
      throw DefaultRoleCatalogAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin default role catalog proxy timed out after '
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
    throw DefaultRoleCatalogAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: (parsed['message'] as String?) ??
          'admin default role catalog proxy returned an error',
    );
  }
}

/// In-memory gateway used by demo + widget tests. Persists nothing
/// across runs. Mirrors the proxy contract:
///   * publish appends a row and flips `is_current`.
///   * list returns the current row + history ordered desc.
class InMemoryDefaultRoleCatalogAdminGateway
    implements DefaultRoleCatalogAdminGateway {
  InMemoryDefaultRoleCatalogAdminGateway({
    DateTime Function()? now,
    String Function()? versionIdGenerator,
    String? publishedByUserId,
  })  : _now = now ?? DateTime.now,
        _versionIdGenerator = versionIdGenerator ?? _defaultVersionIdGenerator,
        _publishedByUserId = publishedByUserId ?? 'demo-admin-user';

  final DateTime Function() _now;
  final String Function() _versionIdGenerator;
  final String _publishedByUserId;
  final List<DefaultRoleCatalogVersionView> _versions =
      <DefaultRoleCatalogVersionView>[];

  @override
  Future<DefaultRoleCatalogListing> listCatalogs({
    int historyLimit = 20,
  }) async {
    final sorted = List<DefaultRoleCatalogVersionView>.from(_versions)
      ..sort((a, b) => b.versionNumber.compareTo(a.versionNumber));
    final history = sorted.take(historyLimit).toList(growable: false);
    final current = sorted.where((v) => v.isCurrent).cast<DefaultRoleCatalogVersionView?>().firstWhere(
          (v) => v != null,
          orElse: () => null,
        );
    return DefaultRoleCatalogListing(current: current, history: history);
  }

  @override
  Future<DefaultRoleCatalogVersionView> publishVersion({
    required List<Object?> payload,
    String? notes,
  }) async {
    final nextVersion = _versions.isEmpty
        ? 1
        : _versions
                .map((v) => v.versionNumber)
                .reduce((a, b) => a > b ? a : b) +
            1;
    // Mark prior current as superseded.
    final supersededAt = _now().toUtc();
    for (var i = 0; i < _versions.length; i++) {
      if (_versions[i].isCurrent) {
        _versions[i] = DefaultRoleCatalogVersionView(
          versionId: _versions[i].versionId,
          versionNumber: _versions[i].versionNumber,
          publishedAt: _versions[i].publishedAt,
          publishedByUserId: _versions[i].publishedByUserId,
          payload: _versions[i].payload,
          payloadSha256: _versions[i].payloadSha256,
          isCurrent: false,
          supersededAt: supersededAt,
          notes: _versions[i].notes,
        );
      }
    }
    final fresh = DefaultRoleCatalogVersionView(
      versionId: _versionIdGenerator(),
      versionNumber: nextVersion,
      publishedAt: _now().toUtc(),
      publishedByUserId: _publishedByUserId,
      payload: List<Object?>.unmodifiable(payload),
      // In-memory only — production SHA-256 happens server-side. We
      // surface a deterministic placeholder so the screen can render.
      payloadSha256: 'a' * 64,
      isCurrent: true,
      supersededAt: null,
      notes: notes,
    );
    _versions.add(fresh);
    return fresh;
  }
}

String _defaultVersionIdGenerator() =>
    'mem-${DateTime.now().microsecondsSinceEpoch}';
