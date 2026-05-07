// Operator Web W4.B - Audit chain anchor integrity badge gateway.
//
// Reads the operator's most-recent `audit_chain_anchors` row through
// the new per-tenant proxy route `GET /v1/operator/audit-chain-anchors/
// latest` so the operator-web Audit Log screen can render an
// integrity badge (healthy / delayed / failed / unknown). The
// F&F Ops Console (`HealthAdminScreen`) already exposes anchor
// freshness globally via the `/health` envelope; this gateway is the
// per-tenant equivalent the operator sees.
//
// Web-safe: pure-Dart over `package:http`. No `dart:io`, no sqflite.
//
// Provider seam pattern (mirrors siblings like
// [OperatorWebTeamAuditLogGatewayProvider]): the Audit Log screen
// reaches the gateway through the auth source. The demo auth source
// mixes in [OperatorWebAuditChainAnchorsGatewayProvider] with the
// in-memory demo impl; the live source mixes in the same provider
// with the `package:http` impl.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Locked path the operator-web build hits. Mirrors
/// `operatorAuditChainAnchorsLatestPath` in
/// `tool/advisor_proxy/audit_chain_anchors_routes.dart`.
const String kOperatorAuditChainAnchorsLatestPath =
    '/v1/operator/audit-chain-anchors/latest';

/// Server-side classification of the chain anchor health. Mirrors the
/// proxy enum so the screen always renders the same status the proxy
/// computed.
enum OperatorWebAuditChainAnchorStatus { healthy, delayed, failed, unknown }

OperatorWebAuditChainAnchorStatus operatorWebAuditChainAnchorStatusFromWire(
  String? raw,
) {
  switch (raw) {
    case 'healthy':
      return OperatorWebAuditChainAnchorStatus.healthy;
    case 'delayed':
      return OperatorWebAuditChainAnchorStatus.delayed;
    case 'failed':
      return OperatorWebAuditChainAnchorStatus.failed;
    case 'unknown':
    default:
      return OperatorWebAuditChainAnchorStatus.unknown;
  }
}

/// Snapshot of the integrity badge for one operator.
class OperatorWebAuditChainAnchorSnapshot {
  const OperatorWebAuditChainAnchorSnapshot({
    required this.status,
    this.anchoredAt,
    this.lastAnchorBlobAt,
    this.chainDate,
  });

  /// Always set. `unknown` when no anchor row exists yet.
  final OperatorWebAuditChainAnchorStatus status;

  /// `anchored_at` from the audit_chain_anchors row in UTC. Null when
  /// the operator has no anchor recorded yet.
  final DateTime? anchoredAt;

  /// M3 breadcrumb: when the Cloud Run sweep last persisted the Blob
  /// URL. Used by the screen to render a more honest "last anchor"
  /// timestamp when the L9 sweep wrote the Blob ahead of the row
  /// commit.
  final DateTime? lastAnchorBlobAt;

  /// `chain_date` from the row in UTC. Null when no anchor exists.
  final DateTime? chainDate;

  /// True when the operator has no anchor recorded yet. Renders the
  /// "No anchor recorded yet" copy on the badge.
  bool get isUnknown => status == OperatorWebAuditChainAnchorStatus.unknown;

  /// True when the latest anchor exists and the daily sweep is on
  /// cadence.
  bool get isHealthy => status == OperatorWebAuditChainAnchorStatus.healthy;

  /// True when the most recent anchor is older than the daily-cadence
  /// window (renders the "Anchor delayed" copy).
  bool get isDelayed => status == OperatorWebAuditChainAnchorStatus.delayed;

  /// True when the M3 breadcrumb columns or the row state indicate a
  /// half-written sweep (renders the "Anchor failed" copy).
  bool get isFailed => status == OperatorWebAuditChainAnchorStatus.failed;
}

/// Read-only gateway the screen consumes. Demo and live impls keep the
/// same shape so the screen has one code path.
abstract class OperatorWebAuditChainAnchorsGateway {
  Future<OperatorWebAuditChainAnchorSnapshot> latest();
}

/// Provider sentinel the auth source mixes in when it can supply a
/// gateway. Mirrors [OperatorWebTeamAuditLogGatewayProvider]. Demo
/// auth source mixes this in with the demo impl; the live source
/// mixes it in with the `package:http` impl.
abstract class OperatorWebAuditChainAnchorsGatewayProvider {
  OperatorWebAuditChainAnchorsGateway get auditChainAnchorsGateway;
}

/// Thrown when the proxy returns a non-2xx. The screen renders a
/// neutral "Unknown" badge on any error so a transient proxy outage
/// does not surface as Failed.
class OperatorWebAuditChainAnchorsError implements Exception {
  const OperatorWebAuditChainAnchorsError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'OperatorWebAuditChainAnchorsError(code: $code, '
      'status: $statusCode, message: $message)';
}

/// Live `package:http` implementation. Threads the Firebase ID token
/// through every call so a refreshed token lands on the next request.
class OperatorWebAuditChainAnchorsGatewayLive
    implements OperatorWebAuditChainAnchorsGateway {
  OperatorWebAuditChainAnchorsGatewayLive({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 15),
  })  : _idTokenProvider = idTokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  @override
  Future<OperatorWebAuditChainAnchorSnapshot> latest() async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebAuditChainAnchorsError(
        code: 'no_id_token',
        message:
            'audit chain anchors gateway has no live Firebase ID token to '
            'attach to the request.',
      );
    }
    final url = proxyBaseUri.resolve(kOperatorAuditChainAnchorsLatestPath);
    final request = http.Request('GET', url);
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer ${token.trim()}',
    });
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const OperatorWebAuditChainAnchorsError(
        code: 'transport_timeout',
        message:
            'audit chain anchors request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw OperatorWebAuditChainAnchorsError(
        code: 'transport_error',
        message: 'audit chain anchors request failed before reaching the '
            'proxy ($error).',
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
    if (streamed.statusCode != 200) {
      final code = (body['error']?.toString().trim().isNotEmpty == true)
          ? body['error']!.toString().trim()
          : 'audit_chain_anchors_failed';
      final message = (body['message']?.toString().trim().isNotEmpty == true)
          ? body['message']!.toString().trim()
          : 'proxy returned status ${streamed.statusCode}';
      throw OperatorWebAuditChainAnchorsError(
        code: code,
        message: message,
        statusCode: streamed.statusCode,
      );
    }
    return _snapshotFromJson(body);
  }

  static OperatorWebAuditChainAnchorSnapshot _snapshotFromJson(
    Map<String, Object?> body,
  ) {
    final anchorRaw = body['anchor'];
    if (anchorRaw is! Map) {
      return const OperatorWebAuditChainAnchorSnapshot(
        status: OperatorWebAuditChainAnchorStatus.unknown,
      );
    }
    final anchor = Map<String, Object?>.from(anchorRaw);
    final status = operatorWebAuditChainAnchorStatusFromWire(
      anchor['status']?.toString(),
    );
    final anchoredAt = _parseUtc(anchor['anchored_at']);
    final lastAnchorBlobAt = _parseUtc(anchor['last_anchor_blob_at']);
    final chainDate = _parseUtc(anchor['chain_date']);
    return OperatorWebAuditChainAnchorSnapshot(
      status: status,
      anchoredAt: anchoredAt,
      lastAnchorBlobAt: lastAnchorBlobAt,
      chainDate: chainDate,
    );
  }

  static DateTime? _parseUtc(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = DateTime.tryParse(trimmed);
    return parsed?.toUtc();
  }
}

/// Demo / fixture gateway. Returns a healthy snapshot with the
/// supplied [now] mapped to a recent anchor so the demo walkthrough
/// shows a green badge. Tests can construct
/// [OperatorWebAuditChainAnchorsGatewayDemo] with a fixed snapshot to
/// exercise the badge state matrix.
class OperatorWebAuditChainAnchorsGatewayDemo
    implements OperatorWebAuditChainAnchorsGateway {
  OperatorWebAuditChainAnchorsGatewayDemo({
    OperatorWebAuditChainAnchorSnapshot? snapshot,
    DateTime Function()? clock,
  })  : _fixedSnapshot = snapshot,
        _clock = clock ?? DateTime.now;

  final OperatorWebAuditChainAnchorSnapshot? _fixedSnapshot;
  final DateTime Function() _clock;

  @override
  Future<OperatorWebAuditChainAnchorSnapshot> latest() async {
    final fixed = _fixedSnapshot;
    if (fixed != null) return fixed;
    final now = _clock().toUtc();
    // Default demo posture: healthy, anchored 4h before "now".
    final anchored = now.subtract(const Duration(hours: 4));
    return OperatorWebAuditChainAnchorSnapshot(
      status: OperatorWebAuditChainAnchorStatus.healthy,
      anchoredAt: anchored,
      lastAnchorBlobAt: anchored.subtract(const Duration(seconds: 2)),
      chainDate: DateTime.utc(now.year, now.month, now.day - 1),
    );
  }
}
