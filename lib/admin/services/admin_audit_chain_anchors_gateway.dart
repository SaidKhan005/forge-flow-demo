// Admin audit-integrity badge — admin/cross-tenant audit-chain-anchor
// read gateway.
//
// Admin-side analogue of the operator-web audit-chain-anchors gateway
// (`lib/operator_web/services/operator_web_audit_chain_anchors_gateway_provider.dart`).
// Thin HTTP client over the admin cross-tenant route:
//
//   GET /v1/admin/operators/:operatorId/audit-chain-anchors/latest
//
// READ-ONLY. The admin Flutter client never holds a Postgres
// connection string and never reaches the database directly — every
// read flows through the F&F admin proxy with the signed-in admin's
// bearer token. `operatorId` is a URL path segment (the established
// admin cross-tenant convention); the proxy gates the route to
// super_admin / ff_support and reaches the sanctioned `runAsSystem`
// admin bypass server-side. No write path, no idempotency surface.
//
// The proxy returns the SAME `{operator_id, anchor: null | {...}}` body
// the operator route returns, with the SAME server-side status
// classification (healthy / delayed / failed / unknown), so the admin
// integrity badge cannot drift from the operator-web badge. This
// gateway only parses + carries that shape into an
// [AdminAuditChainAnchorSnapshot]; it never re-derives the status.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'admin_http_timeout.dart';

/// Source for the bearer token attached to every proxy call.
/// Production binds this to the admin Firebase ID-token stream; tests
/// pin a synthetic value. Mirrors [AdminBearerTokenProvider] in
/// `admin_business_timing_resolution_gateway.dart`.
typedef AdminBearerTokenProvider = Future<String> Function();

/// Server-side classification of the chain anchor health. Mirrors the
/// proxy enum (`AuditChainAnchorStatus`) and the operator-web enum so
/// the admin badge always renders the same status the proxy computed.
enum AdminAuditChainAnchorStatus { healthy, delayed, failed, unknown }

AdminAuditChainAnchorStatus adminAuditChainAnchorStatusFromWire(String? raw) {
  switch (raw) {
    case 'healthy':
      return AdminAuditChainAnchorStatus.healthy;
    case 'delayed':
      return AdminAuditChainAnchorStatus.delayed;
    case 'failed':
      return AdminAuditChainAnchorStatus.failed;
    case 'unknown':
    default:
      return AdminAuditChainAnchorStatus.unknown;
  }
}

/// Snapshot of the integrity badge for one operator (the operator the
/// admin has selected). Mirrors
/// [OperatorWebAuditChainAnchorSnapshot].
class AdminAuditChainAnchorSnapshot {
  const AdminAuditChainAnchorSnapshot({
    required this.status,
    this.anchoredAt,
    this.lastAnchorBlobAt,
    this.chainDate,
  });

  /// Always set. `unknown` when no anchor row exists yet for the
  /// selected operator.
  final AdminAuditChainAnchorStatus status;

  /// `anchored_at` from the audit_chain_anchors row in UTC. Null when
  /// the operator has no anchor recorded yet.
  final DateTime? anchoredAt;

  /// M3 breadcrumb: when the Cloud Run sweep last persisted the Blob
  /// URL. The badge prefers this over [anchoredAt] when present so the
  /// "last anchor" age is honest even when the sweep wrote the Blob
  /// ahead of the row commit.
  final DateTime? lastAnchorBlobAt;

  /// `chain_date` from the row in UTC. Null when no anchor exists.
  final DateTime? chainDate;

  bool get isUnknown => status == AdminAuditChainAnchorStatus.unknown;
  bool get isHealthy => status == AdminAuditChainAnchorStatus.healthy;
  bool get isDelayed => status == AdminAuditChainAnchorStatus.delayed;
  bool get isFailed => status == AdminAuditChainAnchorStatus.failed;

  /// Parses the proxy `{operator_id, anchor: null | {...}}` body into a
  /// snapshot. A null / missing / malformed `anchor` maps to the
  /// neutral `unknown` snapshot (never throws) so a tenant with no
  /// anchor yet renders the honest "no anchor recorded" badge.
  static AdminAuditChainAnchorSnapshot fromJson(Map<String, Object?> body) {
    final anchorRaw = body['anchor'];
    if (anchorRaw is! Map) {
      return const AdminAuditChainAnchorSnapshot(
        status: AdminAuditChainAnchorStatus.unknown,
      );
    }
    final anchor = anchorRaw.cast<String, Object?>();
    return AdminAuditChainAnchorSnapshot(
      status: adminAuditChainAnchorStatusFromWire(anchor['status']?.toString()),
      anchoredAt: _parseUtc(anchor['anchored_at']),
      lastAnchorBlobAt: _parseUtc(anchor['last_anchor_blob_at']),
      chainDate: _parseUtc(anchor['chain_date']),
    );
  }

  static DateTime? _parseUtc(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return DateTime.tryParse(trimmed)?.toUtc();
  }
}

/// Top-level error type for admin anchor reads. Carries an HTTP-style
/// status code + machine-readable error code so the caller can branch
/// on `permission_denied` etc. without parsing `message`. Mirrors
/// [AdminBusinessTimingResolutionGatewayError].
class AdminAuditChainAnchorsGatewayError implements Exception {
  const AdminAuditChainAnchorsGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() => 'AdminAuditChainAnchorsGatewayError('
      '$statusCode/$errorCode): $message';
}

/// READ-ONLY gateway the admin Audit screen consumes. Demo and live
/// impls keep the same shape so the screen has one code path.
abstract class AdminAuditChainAnchorsGateway {
  /// Reads the most-recent audit-chain anchor for [operatorId] (the
  /// operator the admin has selected). READ-ONLY.
  Future<AdminAuditChainAnchorSnapshot> latest({required String operatorId});
}

/// Live `package:http` implementation. Hits the admin cross-tenant
/// route with the signed-in admin's bearer token through the shared
/// [sendAdminHttpRequest] chokepoint (so the 401-refresh-retry +
/// MFA-freshness-redirect contract applies here too). Byte-mirrors
/// [HttpAdminBusinessTimingResolutionGateway].
class HttpAdminAuditChainAnchorsGateway
    implements AdminAuditChainAnchorsGateway {
  HttpAdminAuditChainAnchorsGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`).
  final Uri baseUri;
  final AdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  @override
  Future<AdminAuditChainAnchorSnapshot> latest({
    required String operatorId,
  }) async {
    final path = '/v1/admin/operators/${Uri.encodeComponent(operatorId)}'
        '/audit-chain-anchors/latest';
    final uri = baseUri.resolve(path);
    final token = await bearerTokenProvider();
    final request = http.Request('GET', uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    final response = await sendAdminHttpRequest(
      _httpClient,
      request,
      timeout: _timeout,
    );
    final Map<String, Object?> body;
    if (response.body.isEmpty) {
      body = const <String, Object?>{};
    } else {
      final decoded = jsonDecode(response.body);
      body = decoded is Map
          ? decoded.cast<String, Object?>()
          : const <String, Object?>{};
    }
    if (response.statusCode != 200) {
      throw AdminAuditChainAnchorsGatewayError(
        statusCode: response.statusCode,
        errorCode: (body['error'] as String?) ?? 'request_failed',
        message: (body['message'] as String?) ??
            'admin audit chain anchor read failed',
      );
    }
    return AdminAuditChainAnchorSnapshot.fromJson(body);
  }
}

/// In-memory demo gateway. Returns a healthy snapshot anchored a few
/// hours before [clock] so the demo / share-preview walkthrough shows
/// a green "log is intact" badge. Tests can pin a fixed [snapshot] to
/// exercise the badge state matrix. Mirrors
/// [OperatorWebAuditChainAnchorsGatewayDemo].
class InMemoryAdminAuditChainAnchorsGateway
    implements AdminAuditChainAnchorsGateway {
  InMemoryAdminAuditChainAnchorsGateway({
    AdminAuditChainAnchorSnapshot? snapshot,
    DateTime Function()? clock,
  })  : _fixedSnapshot = snapshot,
        _clock = clock ?? DateTime.now;

  final AdminAuditChainAnchorSnapshot? _fixedSnapshot;
  final DateTime Function() _clock;

  @override
  Future<AdminAuditChainAnchorSnapshot> latest({
    required String operatorId,
  }) async {
    final fixed = _fixedSnapshot;
    if (fixed != null) return fixed;
    final now = _clock().toUtc();
    final anchored = now.subtract(const Duration(hours: 4));
    return AdminAuditChainAnchorSnapshot(
      status: AdminAuditChainAnchorStatus.healthy,
      anchoredAt: anchored,
      lastAnchorBlobAt: anchored.subtract(const Duration(seconds: 2)),
      chainDate: DateTime.utc(now.year, now.month, now.day - 1),
    );
  }
}
