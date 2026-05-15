// Lane B B8.b — Operator Web hierarchy-filtered audit log gateway.
//
// Companion to `web_team_audit_log_gateway.dart`. The legacy gateway
// reads the unfiltered ledger via `/v1/auth/audit-log`; this one
// reads the hierarchy-filtered surface via
// `/v1/auth/audit-log/hierarchy` (sibling-file proxy route
// `tool/advisor_proxy/operator_web_audit_log_hierarchy_routes.dart`,
// gated on `team.audit_log.view`).
//
// Mirrors the admin-side `audit_log_admin_gateway.dart` shape so the
// screen-side ergonomics line up; the operator variant strips the
// `admin_reason` parameter because the operator-facing route does
// not require it (the JWT identifies the actor, the audit chain
// captures the read implicitly).
//
// HP discipline:
//   * No client-side `kDemoMode` carve-out — demo + prod gateways
//     return the same row shape; only the source differs.
//   * Read-only by construction. No audit_logs writes.
//   * Tenant-scoped on the wire: the proxy clamps operator_id /
//     location_id to the verified JWT; this gateway never sends
//     either query parameter (the route 400s if they appear).

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Hierarchy scope discriminator. Wire tokens match the proxy enum so
/// the operator-web client and the proxy share one vocabulary.
enum WebAuditLogHierarchyScopeType { operatorWide, orgUnit, location }

String webAuditLogHierarchyScopeWire(
  WebAuditLogHierarchyScopeType scope,
) {
  switch (scope) {
    case WebAuditLogHierarchyScopeType.operatorWide:
      return 'operator_wide';
    case WebAuditLogHierarchyScopeType.orgUnit:
      return 'org_unit';
    case WebAuditLogHierarchyScopeType.location:
      return 'location';
  }
}

WebAuditLogHierarchyScopeType? webAuditLogHierarchyScopeFromWire(
  String? raw,
) {
  switch (raw) {
    case 'operator_wide':
      return WebAuditLogHierarchyScopeType.operatorWide;
    case 'org_unit':
      return WebAuditLogHierarchyScopeType.orgUnit;
    case 'location':
      return WebAuditLogHierarchyScopeType.location;
  }
  return null;
}

/// One projected row the operator-web hierarchy audit log surface
/// renders. Mirrors the proxy `AuditLogRow.toJson` envelope.
class WebAuditLogHierarchyRow {
  const WebAuditLogHierarchyRow({
    required this.id,
    required this.operatorId,
    required this.occurredAt,
    required this.actorKind,
    required this.action,
    this.locationId,
    this.actorUserId,
    this.actorPrincipalId,
    this.targetKind,
    this.targetId,
    this.payload = const <String, Object?>{},
    this.adminReason,
    this.businessDate,
  });

  final String id;
  final String operatorId;
  final String? locationId;
  final DateTime occurredAt;
  final String actorKind;
  final String? actorUserId;
  final String? actorPrincipalId;
  final String? targetKind;
  final String? targetId;
  final String action;
  final Map<String, Object?> payload;
  final String? adminReason;
  final String? businessDate;

  factory WebAuditLogHierarchyRow.fromJson(Map<String, Object?> json) {
    final occurredRaw = json['occurred_at'];
    final occurredAt = occurredRaw is String
        ? DateTime.parse(occurredRaw).toUtc()
        : DateTime.now().toUtc();
    final payloadRaw = json['payload'];
    final payload = payloadRaw is Map
        ? payloadRaw.cast<String, Object?>()
        : const <String, Object?>{};
    return WebAuditLogHierarchyRow(
      id: json['id']?.toString() ?? '',
      operatorId: json['operator_id']?.toString() ?? '',
      locationId: json['location_id']?.toString(),
      occurredAt: occurredAt,
      actorKind: json['actor_kind']?.toString() ?? 'unknown',
      actorUserId: json['actor_user_id']?.toString(),
      actorPrincipalId: json['actor_principal_id']?.toString(),
      targetKind: json['target_kind']?.toString(),
      targetId: json['target_id']?.toString(),
      action: json['action']?.toString() ?? '',
      payload: payload,
      adminReason: json['admin_reason']?.toString(),
      businessDate: json['business_date']?.toString(),
    );
  }
}

/// Request envelope for the hierarchy-filtered list.
class WebAuditLogHierarchyListCommand {
  const WebAuditLogHierarchyListCommand({
    required this.scopeType,
    this.orgUnitId,
    this.locationFilter,
    this.from,
    this.to,
    this.actorUserId,
    this.action,
    this.limit,
    this.beforeId,
  });

  final WebAuditLogHierarchyScopeType scopeType;

  /// Required when `scopeType == orgUnit`.
  final String? orgUnitId;

  /// Required when `scopeType == location`.
  final String? locationFilter;

  final DateTime? from;
  final DateTime? to;
  final String? actorUserId;
  final String? action;
  final int? limit;
  final String? beforeId;
}

class WebAuditLogHierarchyListResult {
  const WebAuditLogHierarchyListResult({
    required this.rows,
    this.nextCursor,
  });

  final List<WebAuditLogHierarchyRow> rows;
  final String? nextCursor;
}

/// Plain-English wrapper for gateway errors. Mirrors the existing
/// 11W gateway error envelopes so the screen surfaces a consistent
/// error path across operator-web surfaces.
class WebAuditLogHierarchyGatewayError implements Exception {
  const WebAuditLogHierarchyGatewayError(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'WebAuditLogHierarchyGatewayError($statusCode): $message';
}

/// Read seam. Production: [HttpWebAuditLogHierarchyGateway].
/// Demo / widget tests: [InMemoryWebAuditLogHierarchyGateway].
abstract class WebAuditLogHierarchyGateway {
  Future<WebAuditLogHierarchyListResult> listByHierarchy(
    WebAuditLogHierarchyListCommand command,
  );
}

/// Mixin signalling that an operator-web auth source exposes a live
/// hierarchy-filtered audit log gateway. Follows the same
/// gateway-provider sentinel shape as the other operator-web gateway
/// providers (e.g. `OperatorWebDataAccuracyGatewayProvider`) so the
/// router can resolve the live binding when available and fall back to
/// a demo / in-memory implementation otherwise.
abstract class OperatorWebAuditLogHierarchyGatewayProvider {
  WebAuditLogHierarchyGateway get auditLogHierarchyGateway;
}

/// HTTP-backed binding. Posts the filter query parameters to the
/// operator-web hierarchy route. The operator-web Firebase token is
/// supplied via the [tokenProvider] closure (mirrors the rest of
/// `lib/operator_web/services/` gateways).
class HttpWebAuditLogHierarchyGateway implements WebAuditLogHierarchyGateway {
  HttpWebAuditLogHierarchyGateway({
    required Uri proxyBaseUri,
    required Future<String> Function() tokenProvider,
    http.Client? httpClient,
    Duration? timeout,
  })  : _proxyBaseUri = proxyBaseUri,
        _tokenProvider = tokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 30);

  final Uri _proxyBaseUri;
  final Future<String> Function() _tokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  /// Wire path: lives under `/v1/auth/audit-log` so the surface
  /// clusters with the legacy unfiltered route. Exposed as a static
  /// const so the HTTP wire test can pin the exact path.
  static const String wirePath = '/v1/auth/audit-log/hierarchy';

  @override
  Future<WebAuditLogHierarchyListResult> listByHierarchy(
    WebAuditLogHierarchyListCommand command,
  ) async {
    final query = <String, String>{
      'scope_type': webAuditLogHierarchyScopeWire(command.scopeType),
      if (command.orgUnitId != null) 'org_unit_id': command.orgUnitId!,
      if (command.locationFilter != null)
        'location_filter': command.locationFilter!,
      if (command.from != null)
        'from': command.from!.toUtc().toIso8601String(),
      if (command.to != null) 'to': command.to!.toUtc().toIso8601String(),
      if (command.actorUserId != null) 'actor_user_id': command.actorUserId!,
      if (command.action != null) 'action': command.action!,
      if (command.limit != null) 'limit': command.limit!.toString(),
      if (command.beforeId != null) 'before_id': command.beforeId!,
    };
    final uri = _proxyBaseUri.replace(
      path: wirePath,
      queryParameters: query,
    );
    final token = await _tokenProvider();
    final response = await _httpClient
        .get(
          uri,
          headers: <String, String>{
            'authorization': 'Bearer $token',
          },
        )
        .timeout(_timeout);
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      if (body is! Map) {
        throw const WebAuditLogHierarchyGatewayError(
          'audit log read returned an unexpected shape',
        );
      }
      final rowsRaw = body['rows'];
      final rows = rowsRaw is List
          ? <WebAuditLogHierarchyRow>[
              for (final row in rowsRaw)
                if (row is Map)
                  WebAuditLogHierarchyRow.fromJson(
                    row.cast<String, Object?>(),
                  ),
            ]
          : const <WebAuditLogHierarchyRow>[];
      return WebAuditLogHierarchyListResult(
        rows: rows,
        nextCursor: body['next_cursor']?.toString(),
      );
    }
    String? errorMessage;
    try {
      final body = jsonDecode(response.body);
      if (body is Map) {
        errorMessage =
            body['message']?.toString() ?? body['error']?.toString();
      }
    } catch (_) {
      // Fall through to status-code-only error.
    }
    throw WebAuditLogHierarchyGatewayError(
      errorMessage ??
          'audit log read failed with HTTP ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }
}

/// Demo / widget-test binding. Returns a deterministic in-memory
/// page so the screen pane can render without the proxy being up.
/// Mirrors `InMemoryAuditLogAdminGateway` in posture.
class InMemoryWebAuditLogHierarchyGateway
    implements WebAuditLogHierarchyGateway {
  InMemoryWebAuditLogHierarchyGateway({
    List<WebAuditLogHierarchyRow>? rows,
    WebAuditLogHierarchyGatewayError? failWith,
  })  : _rows = List<WebAuditLogHierarchyRow>.unmodifiable(
          rows ?? const <WebAuditLogHierarchyRow>[],
        ),
        _failWith = failWith;

  final List<WebAuditLogHierarchyRow> _rows;
  final WebAuditLogHierarchyGatewayError? _failWith;
  final List<WebAuditLogHierarchyListCommand> calls =
      <WebAuditLogHierarchyListCommand>[];

  @override
  Future<WebAuditLogHierarchyListResult> listByHierarchy(
    WebAuditLogHierarchyListCommand command,
  ) async {
    calls.add(command);
    if (_failWith != null) throw _failWith;
    final filtered = <WebAuditLogHierarchyRow>[];
    for (final row in _rows) {
      if (command.actorUserId != null &&
          row.actorUserId != command.actorUserId) {
        continue;
      }
      if (command.action != null && row.action != command.action) {
        continue;
      }
      if (command.from != null && row.occurredAt.isBefore(command.from!)) {
        continue;
      }
      if (command.to != null && row.occurredAt.isAfter(command.to!)) {
        continue;
      }
      switch (command.scopeType) {
        case WebAuditLogHierarchyScopeType.operatorWide:
          break;
        case WebAuditLogHierarchyScopeType.orgUnit:
          // The in-memory fake cannot expand a real subtree; callers
          // pre-mark rows that should belong to a given org_unit via
          // the [_rows] seed. The demo gateway treats every seeded
          // row as in-scope.
          break;
        case WebAuditLogHierarchyScopeType.location:
          if (row.locationId != command.locationFilter) continue;
          break;
      }
      filtered.add(row);
    }
    final limit = command.limit ?? 100;
    final page = filtered.take(limit).toList(growable: false);
    return WebAuditLogHierarchyListResult(
      rows: page,
      nextCursor: page.length == limit && filtered.length > limit
          ? page.last.id
          : null,
    );
  }
}
