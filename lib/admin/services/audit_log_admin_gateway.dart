// Lane B B8 — admin audit log gateway for the hierarchy-filtered
// admin screen.
//
// The gateway exposes one read method
// (`listByHierarchy`) that mirrors the proxy route
// `GET /v1/admin/auth/audit-log/hierarchy`. Production binds
// [HttpAuditLogAdminGateway]; demo / widget tests use
// [InMemoryAuditLogAdminGateway].
//
// HP discipline:
//   * No client-side `kDemoMode` carve-out — reader paths are
//     identical between demo and prod (the demo gateway returns the
//     same row shape; only the source differs).
//   * Read-only by construction. No audit_logs writes from this file
//     anywhere.
//   * `admin_reason` is REQUIRED on every read; the gateway carries
//     it through the HTTP header (`admin_reason`) so the proxy
//     surfaces it in the structured log line.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'admin_http_timeout.dart';

/// Hierarchy scope wire token. Mirrors the proxy enum so the screen
/// uses the same vocabulary the route does.
enum AuditLogAdminScopeType { operatorWide, orgUnit, location }

String auditLogAdminScopeWire(AuditLogAdminScopeType scope) {
  switch (scope) {
    case AuditLogAdminScopeType.operatorWide:
      return 'operator_wide';
    case AuditLogAdminScopeType.orgUnit:
      return 'org_unit';
    case AuditLogAdminScopeType.location:
      return 'location';
  }
}

AuditLogAdminScopeType? auditLogAdminScopeFromWire(String? raw) {
  switch (raw) {
    case 'operator_wide':
      return AuditLogAdminScopeType.operatorWide;
    case 'org_unit':
      return AuditLogAdminScopeType.orgUnit;
    case 'location':
      return AuditLogAdminScopeType.location;
  }
  return null;
}

/// One projected row the admin audit log screen renders.
class AuditLogAdminRow {
  const AuditLogAdminRow({
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

  factory AuditLogAdminRow.fromJson(Map<String, Object?> json) {
    final occurredRaw = json['occurred_at'];
    final occurredAt = occurredRaw is String
        ? DateTime.parse(occurredRaw).toUtc()
        : DateTime.now().toUtc();
    final payloadRaw = json['payload'];
    final payload = payloadRaw is Map
        ? payloadRaw.cast<String, Object?>()
        : const <String, Object?>{};
    return AuditLogAdminRow(
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

/// Request envelope: every value is optional except the time range,
/// which the gateway defaults when null.
class AuditLogAdminListCommand {
  const AuditLogAdminListCommand({
    required this.adminReason,
    required this.scopeType,
    this.operatorId,
    this.locationId,
    this.orgUnitId,
    this.locationFilter,
    this.from,
    this.to,
    this.actorUserId,
    this.action,
    this.limit,
    this.beforeId,
  });

  final String adminReason;
  final AuditLogAdminScopeType scopeType;
  final String? operatorId;
  final String? locationId;
  final String? orgUnitId;
  final String? locationFilter;
  final DateTime? from;
  final DateTime? to;
  final String? actorUserId;
  final String? action;
  final int? limit;
  final String? beforeId;
}

class AuditLogAdminListResult {
  const AuditLogAdminListResult({
    required this.rows,
    this.nextCursor,
  });

  final List<AuditLogAdminRow> rows;
  final String? nextCursor;
}

/// Plain-English wrapper for gateway errors. Mirrors the
/// `FeatureFlagsAdminGatewayError` pattern so the screen surfaces a
/// consistent envelope across admin surfaces.
class AuditLogAdminGatewayError implements Exception {
  const AuditLogAdminGatewayError(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'AuditLogAdminGatewayError($statusCode): $message';
}

/// Read seam. Production: [HttpAuditLogAdminGateway]. Demo / widget
/// tests: [InMemoryAuditLogAdminGateway].
abstract class AuditLogAdminGateway {
  Future<AuditLogAdminListResult> listByHierarchy(
    AuditLogAdminListCommand command,
  );
}

/// HTTP-backed binding. Posts the seven filter query parameters to
/// the B8 proxy route. The admin Firebase token is supplied via the
/// [tokenProvider] closure (mirrors the rest of `lib/admin/services/`
/// gateways so the screen does not couple to a specific auth source).
class HttpAuditLogAdminGateway implements AuditLogAdminGateway {
  HttpAuditLogAdminGateway({
    required Uri proxyBaseUri,
    required Future<String> Function() tokenProvider,
    http.Client? httpClient,
    Duration? timeout,
  })  : _proxyBaseUri = proxyBaseUri,
        _tokenProvider = tokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout ?? kAdminHttpRequestTimeout;

  final Uri _proxyBaseUri;
  final Future<String> Function() _tokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  @override
  Future<AuditLogAdminListResult> listByHierarchy(
    AuditLogAdminListCommand command,
  ) async {
    final query = <String, String>{
      'scope_type': auditLogAdminScopeWire(command.scopeType),
      if (command.operatorId != null) 'operator_id': command.operatorId!,
      if (command.locationId != null) 'location_id': command.locationId!,
      if (command.orgUnitId != null) 'org_unit_id': command.orgUnitId!,
      if (command.locationFilter != null)
        'location_filter': command.locationFilter!,
      if (command.from != null) 'from': command.from!.toUtc().toIso8601String(),
      if (command.to != null) 'to': command.to!.toUtc().toIso8601String(),
      if (command.actorUserId != null) 'actor_user_id': command.actorUserId!,
      if (command.action != null) 'action': command.action!,
      if (command.limit != null) 'limit': command.limit!.toString(),
      if (command.beforeId != null) 'before_id': command.beforeId!,
    };
    final uri = _proxyBaseUri.replace(
      path: '/v1/admin/auth/audit-log/hierarchy',
      queryParameters: query,
    );
    final token = await _tokenProvider();
    final response = await _httpClient
        .get(
          uri,
          headers: <String, String>{
            'authorization': 'Bearer $token',
            'admin_reason': command.adminReason,
          },
        )
        .timeout(_timeout);
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      if (body is! Map) {
        throw const AuditLogAdminGatewayError(
          'audit log read returned an unexpected shape',
        );
      }
      final rowsRaw = body['rows'];
      final rows = rowsRaw is List
          ? <AuditLogAdminRow>[
              for (final row in rowsRaw)
                if (row is Map)
                  AuditLogAdminRow.fromJson(row.cast<String, Object?>()),
            ]
          : const <AuditLogAdminRow>[];
      return AuditLogAdminListResult(
        rows: rows,
        nextCursor: body['next_cursor']?.toString(),
      );
    }
    String? errorMessage;
    try {
      final body = jsonDecode(response.body);
      if (body is Map) {
        errorMessage = body['message']?.toString() ?? body['error']?.toString();
      }
    } catch (_) {
      // Fall through to status-code-only error.
    }
    throw AuditLogAdminGatewayError(
      errorMessage ??
          'audit log read failed with HTTP ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }
}

/// Demo / widget-test binding. Returns a deterministic in-memory page
/// so the screen can render without the proxy being up.
class InMemoryAuditLogAdminGateway implements AuditLogAdminGateway {
  InMemoryAuditLogAdminGateway({
    List<AuditLogAdminRow>? rows,
    AuditLogAdminGatewayError? failWith,
  })  : _rows = List<AuditLogAdminRow>.unmodifiable(
          rows ?? const <AuditLogAdminRow>[],
        ),
        _failWith = failWith;

  final List<AuditLogAdminRow> _rows;
  final AuditLogAdminGatewayError? _failWith;
  final List<AuditLogAdminListCommand> calls = <AuditLogAdminListCommand>[];

  @override
  Future<AuditLogAdminListResult> listByHierarchy(
    AuditLogAdminListCommand command,
  ) async {
    calls.add(command);
    if (_failWith != null) throw _failWith;
    final filtered = <AuditLogAdminRow>[];
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
        case AuditLogAdminScopeType.operatorWide:
          break;
        case AuditLogAdminScopeType.orgUnit:
          // The in-memory fake cannot expand a real subtree; the
          // caller passes a synthetic mapping via [_rows] so each row
          // carries its expected match shape.
          break;
        case AuditLogAdminScopeType.location:
          if (row.locationId != command.locationFilter) continue;
          break;
      }
      filtered.add(row);
    }
    final limit = command.limit ?? 100;
    final page = filtered.take(limit).toList(growable: false);
    return AuditLogAdminListResult(
      rows: page,
      nextCursor: page.length == limit && filtered.length > limit
          ? page.last.id
          : null,
    );
  }
}
