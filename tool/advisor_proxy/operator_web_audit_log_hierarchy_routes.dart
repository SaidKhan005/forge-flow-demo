// Lane B B8.b — operator-web parity for the hierarchy-scoped audit log
// filter (companion to B8's admin-side route).
//
// Path:
//
//   GET /v1/auth/audit-log/hierarchy
//
// B8 shipped the admin variant under
// `/v1/admin/auth/audit-log/hierarchy` (gated on
// `{super_admin, ff_support}` + `admin_reason` ceremony). This sibling
// is the operator-facing twin so the same hierarchy filter renders
// inside the operator-web shell. Differences vs the admin twin are
// deliberate:
//
//   * Auth gate: operator-web users authenticate via Firebase JWT
//     carrying operator context. We resolve [OperatorContext] via
//     `authGuard.requireOperatorContext` (the same path the existing
//     `/v1/auth/audit-log` route uses) and gate on the
//     `team.audit_log.view` permission key through the proxy's
//     permission snapshot resolver. Roles are not consulted here —
//     the snapshot is the authority.
//   * No `admin_reason` header. The admin-side ceremony exists so a
//     deploy grep can correlate a cross-tenant read with a support
//     ticket. Operator-web reads are tenant-bound (JWT pins the
//     operator) so the audit chain already carries the actor identity;
//     no extra reason string is required. This mirrors the posture of
//     the existing `/v1/auth/audit-log` route.
//   * Tenant scope: every read is clamped to the JWT's
//     `(operator_id, location_id)`. Client-supplied operator_id /
//     location_id query parameters are explicitly REJECTED (400
//     scope_param_forbidden). The admin-side route has the inverse
//     posture (scope-less global admin tokens MUST supply both); for
//     operator-web the JWT is always tenant-scoped so accepting query
//     params would be a cross-tenant escape hatch.
//
// Filter query parameters (all optional):
//
//   * `scope_type`      enum    — `operator_wide` | `org_unit` |
//                                 `location` (default `operator_wide`).
//   * `org_unit_id`     uuid    — Required when scope_type=org_unit.
//   * `location_filter` uuid    — Required when scope_type=location.
//   * `from`            ISO8601 — Lower-bound UTC instant
//                                 (default = `to - 7d`).
//   * `to`              ISO8601 — Upper-bound UTC instant
//                                 (default = now).
//   * `actor_user_id`   uuid    — Narrow to one actor.
//   * `action`          string  — Narrow to one action token
//                                 (e.g. `auth.password_changed`).
//   * `limit`           int     — 1..200 (default 100).
//   * `before_id`       int     — Cursor; returns rows with `id <
//                                 before_id`.
//
// Response (200, body):
//
//   {
//     "rows": [<AuditLogRow as JSON>...],
//     "next_cursor": "<id of the last row in the page>" | null,
//     "scope": {
//       "operator_id": "<uuid>",
//       "location_id": "<uuid>",
//       "scope_type":  "operator_wide" | "org_unit" | "location",
//       "org_unit_id": "<uuid>" | null,
//       "location_filter": "<uuid>" | null,
//       "from":  "<iso8601>",
//       "to":    "<iso8601>"
//     }
//   }
//
// HP discipline:
//
//   * HP #4 per-operator isolation: every read routes through
//     [AuditLogsReader.listByHierarchy], which extends
//     [OperatorScopedRepository] — `withTenant` issues SET LOCAL
//     `app.operator_id`, and the existing RLS policy on
//     `public.audit_logs` clamps to the GUC. The operator_id is taken
//     from the verified JWT; never read from the URL.
//   * HP #6 advisor-only: pure read; nothing writes.
//   * Read-only by construction: no `audit_logs` INSERT / UPDATE /
//     DELETE anywhere. Sibling-file pattern preserves the
//     `tool/advisor_proxy_size_lint.dart` bleed-stop ceiling
//     (`tool/advisor_proxy/advisor_proxy.dart` UNTOUCHED).
//
// Sibling-file mounting: `main.dart` calls
// [OperatorWebAuditLogHierarchyRouter.tryHandle] before delegating to
// the monolithic `routeRequest`. Returns `true` when the request
// matched and was handled.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';

/// Path the operator-web Flutter client hits. Lives under the
/// existing `/v1/auth/audit-log` root so the surface clusters with
/// the legacy unfiltered audit-log route the operator-web Audit Log
/// screen already consumes.
const String operatorWebAuthAuditLogHierarchyPath =
    '/v1/auth/audit-log/hierarchy';

/// Default time window when the caller does not supply `from` / `to`.
/// Sized to match the admin route so a future surface that toggles
/// between admin + operator views renders the same default page.
const Duration kOperatorWebAuditLogHierarchyDefaultWindow =
    Duration(days: 7);

/// Verified caller context the route hands to the gateway after auth
/// + permission gate succeed. Mirrors the [OperatorContext] shape the
/// proxy already produces, narrowed to the fields this route reads
/// so unit tests do not have to mint a full OperatorContext.
class OperatorWebAuditLogHierarchyActor {
  const OperatorWebAuditLogHierarchyActor({
    required this.actorUserId,
    required this.actorOperatorId,
    required this.actorLocationId,
  });

  /// Authenticated user_id from the verified JWT.
  final String actorUserId;

  /// JWT operator_id claim. MUST be non-empty for operator-web — the
  /// resolver returns null (which the route maps to 401) when the
  /// claim is missing so a scope-less token cannot reach this route.
  final String actorOperatorId;

  /// JWT location_id claim. Same non-empty requirement: the tenant
  /// transaction wrapper needs a location_id to anchor the SET LOCAL
  /// chain.
  final String actorLocationId;
}

/// Resolves an [OperatorWebAuditLogHierarchyActor] from an inbound
/// `HttpRequest`. Production binds this to a closure over the
/// proxy's existing `ProxyRequestGuard.requireOperatorContext` plus
/// the `team.audit_log.view` permission check; tests pass an
/// in-memory implementation that returns a pinned actor (null = 401
/// / 403, throwing returns a typed error envelope below).
typedef OperatorWebAuditLogHierarchyAuthResolver
    = Future<OperatorWebAuditLogHierarchyAuthResult> Function(
        HttpRequest request);

/// Outcome of [OperatorWebAuditLogHierarchyAuthResolver]. Splits the
/// happy-path actor from the failure envelopes so the route handler
/// stays free of permission-snapshot plumbing and the resolver owns
/// every auth-related status code.
class OperatorWebAuditLogHierarchyAuthResult {
  const OperatorWebAuditLogHierarchyAuthResult.allow(this.actor)
      : status = OperatorWebAuditLogHierarchyAuthStatus.allow,
        errorCode = null,
        errorMessage = null,
        httpStatus = 200;

  const OperatorWebAuditLogHierarchyAuthResult.unauthorized({
    String message = 'verified bearer token required',
  })  : status = OperatorWebAuditLogHierarchyAuthStatus.unauthorized,
        actor = null,
        errorCode = 'unauthorized',
        errorMessage = message,
        httpStatus = 401;

  const OperatorWebAuditLogHierarchyAuthResult.forbidden({
    String message =
        'team.audit_log.view permission is required to read the audit log',
  })  : status = OperatorWebAuditLogHierarchyAuthStatus.forbidden,
        actor = null,
        errorCode = 'permission_denied',
        errorMessage = message,
        httpStatus = 403;

  const OperatorWebAuditLogHierarchyAuthResult.unavailable({
    String message = 'permissions are unavailable; please retry',
  })  : status = OperatorWebAuditLogHierarchyAuthStatus.unavailable,
        actor = null,
        errorCode = 'permission_snapshot_unavailable',
        errorMessage = message,
        httpStatus = 503;

  final OperatorWebAuditLogHierarchyAuthStatus status;
  final OperatorWebAuditLogHierarchyActor? actor;
  final String? errorCode;
  final String? errorMessage;
  final int httpStatus;
}

enum OperatorWebAuditLogHierarchyAuthStatus {
  allow,
  unauthorized,
  forbidden,
  unavailable,
}

/// Read seam — production binds [RepositoryOperatorWebAuditLogHierarchyGateway]
/// which wraps [AuditLogsReader]; tests pass a fake. Shared with the
/// admin-side reader so a single Postgres call graph backs both
/// surfaces.
abstract class OperatorWebAuditLogHierarchyGateway {
  Future<List<AuditLogRow>> listByHierarchy({
    required String operatorId,
    required String locationId,
    required AuditLogHierarchyScope scopeType,
    String? orgUnitId,
    String? locationFilter,
    required DateTime from,
    required DateTime to,
    String? actorUserId,
    String? action,
    int? limit,
    int? beforeId,
    String? userId,
  });
}

/// Production [OperatorWebAuditLogHierarchyGateway] backed by
/// [AuditLogsReader]. The reader extends `OperatorScopedRepository`
/// so every call routes through `withTenant` — RLS clamps the
/// operator already, and this wrapper simply forwards the call. The
/// admin-side variant uses the same reader through a parallel
/// gateway wrapper; binding two gateways lets production share the
/// reader without coupling the two route handlers.
class RepositoryOperatorWebAuditLogHierarchyGateway
    implements OperatorWebAuditLogHierarchyGateway {
  const RepositoryOperatorWebAuditLogHierarchyGateway({
    required AuditLogsReader reader,
  }) : _reader = reader;

  final AuditLogsReader _reader;

  @override
  Future<List<AuditLogRow>> listByHierarchy({
    required String operatorId,
    required String locationId,
    required AuditLogHierarchyScope scopeType,
    String? orgUnitId,
    String? locationFilter,
    required DateTime from,
    required DateTime to,
    String? actorUserId,
    String? action,
    int? limit,
    int? beforeId,
    String? userId,
  }) {
    return _reader.listByHierarchy(
      operatorId: operatorId,
      locationId: locationId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationFilter: locationFilter,
      from: from,
      to: to,
      actorUserId: actorUserId,
      action: action,
      limit: limit,
      beforeId: beforeId,
      userId: userId,
    );
  }
}

/// Latency-recorder hook shared in spirit with the admin route. Null
/// in tests that only assert HTTP shape.
typedef OperatorWebAuditLogHierarchyLatencyRecorder = void Function({
  required String operatorId,
  required int locationCount,
  required Duration elapsed,
});

/// Top-level router. Mounted in `main.dart` ahead of `routeRequest`.
class OperatorWebAuditLogHierarchyRouter {
  OperatorWebAuditLogHierarchyRouter({
    required OperatorWebAuditLogHierarchyGateway gateway,
    required OperatorWebAuditLogHierarchyAuthResolver authResolver,
    DateTime Function()? now,
    OperatorWebAuditLogHierarchyLatencyRecorder? latencyRecorder,
  })  : _gateway = gateway,
        _authResolver = authResolver,
        _now = now ?? DateTime.now,
        _latencyRecorder = latencyRecorder;

  final OperatorWebAuditLogHierarchyGateway _gateway;
  final OperatorWebAuditLogHierarchyAuthResolver _authResolver;
  final DateTime Function() _now;
  final OperatorWebAuditLogHierarchyLatencyRecorder? _latencyRecorder;

  /// Permission key the operator-web route gates on. Aliased to the
  /// frozen catalog constant in `lib/auth/permission_keys.dart` so a
  /// reader can audit the gate against the permission catalog
  /// without grepping for literal strings.
  static const String permissionKey = PermissionKeys.teamAuditLogView;

  /// Returns `true` when the request matched the audit-log hierarchy
  /// route and was fully handled — the caller (main.dart marked
  /// region) must skip the rest of the dispatcher in that case.
  /// Returns `false` for unrelated paths so `routeRequest` continues.
  Future<bool> tryHandle(HttpRequest request) async {
    if (request.method != 'GET') return false;
    if (request.uri.path != operatorWebAuthAuditLogHierarchyPath) return false;

    final response = request.response;
    final stopwatch = Stopwatch()..start();

    // ---- Auth + permission gate -----------------------------------
    OperatorWebAuditLogHierarchyAuthResult auth;
    try {
      auth = await _authResolver(request);
    } catch (_) {
      _writeJson(response, 401, <String, Object?>{
        'error': 'unauthorized',
        'message': 'verified bearer token required',
      });
      return true;
    }
    if (auth.status != OperatorWebAuditLogHierarchyAuthStatus.allow) {
      _writeJson(response, auth.httpStatus, <String, Object?>{
        'error': auth.errorCode ?? 'unauthorized',
        'message': auth.errorMessage ?? 'request not authorized',
      });
      return true;
    }
    final actor = auth.actor!;

    // ---- Reject scope query params --------------------------------
    // The JWT pins the operator; accepting client-supplied
    // operator_id / location_id would let a verified caller try to
    // fan out across tenants. RLS would still clamp the read, but the
    // route refuses the params so the surface is explicit.
    final params = request.uri.queryParameters;
    if (params.containsKey('operator_id') ||
        params.containsKey('location_id')) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'scope_param_forbidden',
        'message':
            'operator_id / location_id are taken from the verified '
            'token; do not supply them as query parameters',
      });
      return true;
    }

    final scopeType =
        auditLogHierarchyScopeFromWire(params['scope_type']) ??
            AuditLogHierarchyScope.operatorWide;

    // Scope-branch sanity checks.
    final orgUnitId = _nonEmpty(params['org_unit_id']);
    final locationFilter = _nonEmpty(params['location_filter']);
    if (scopeType == AuditLogHierarchyScope.orgUnit) {
      if (orgUnitId == null) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'missing_org_unit_id',
          'message':
              'scope_type=org_unit requires the org_unit_id query '
              'parameter',
        });
        return true;
      }
      if (!_isUuid(orgUnitId)) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_org_unit_id',
          'message': 'org_unit_id must be a uuid',
        });
        return true;
      }
    }
    if (scopeType == AuditLogHierarchyScope.location) {
      if (locationFilter == null) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'missing_location_filter',
          'message':
              'scope_type=location requires the location_filter query '
              'parameter',
        });
        return true;
      }
      if (!_isUuid(locationFilter)) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_location_filter',
          'message': 'location_filter must be a uuid',
        });
        return true;
      }
    }

    // Optional actor_user_id / action narrowing.
    final actorUserIdFilter = _nonEmpty(params['actor_user_id']);
    if (actorUserIdFilter != null && !_isUuid(actorUserIdFilter)) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'invalid_actor_user_id',
        'message': 'actor_user_id must be a uuid',
      });
      return true;
    }
    final actionFilter = _nonEmpty(params['action']);
    if (actionFilter != null && actionFilter.length > 200) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'invalid_action',
        'message':
            'action filter must be 200 characters or fewer (matches '
            'the audit_logs.action CHECK constraint)',
      });
      return true;
    }

    // Time-range parsing.
    final now = _now().toUtc();
    final fromRaw = params['from'];
    final toRaw = params['to'];
    DateTime? fromInstant;
    DateTime? toInstant;
    if (fromRaw != null && fromRaw.isNotEmpty) {
      try {
        fromInstant = DateTime.parse(fromRaw).toUtc();
      } catch (_) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_from',
          'message': 'from must be an ISO 8601 timestamp (UTC)',
        });
        return true;
      }
    }
    if (toRaw != null && toRaw.isNotEmpty) {
      try {
        toInstant = DateTime.parse(toRaw).toUtc();
      } catch (_) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_to',
          'message': 'to must be an ISO 8601 timestamp (UTC)',
        });
        return true;
      }
    }
    final to = toInstant ?? now;
    final from = fromInstant ??
        to.subtract(kOperatorWebAuditLogHierarchyDefaultWindow);
    if (!from.isBefore(to) && !from.isAtSameMomentAs(to)) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'invalid_range',
        'message': 'from must be on or before to',
      });
      return true;
    }

    // Limit + cursor parsing.
    int? limit;
    final limitRaw = params['limit'];
    if (limitRaw != null && limitRaw.isNotEmpty) {
      final parsed = int.tryParse(limitRaw);
      if (parsed == null || parsed < 1) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_limit',
          'message': 'limit must be a positive integer',
        });
        return true;
      }
      limit = parsed.clamp(1, AuditLogsReader.maxLimit);
    }
    int? beforeId;
    final beforeIdRaw = params['before_id'];
    if (beforeIdRaw != null && beforeIdRaw.isNotEmpty) {
      final parsed = int.tryParse(beforeIdRaw);
      if (parsed == null || parsed < 0) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_before_id',
          'message': 'before_id must be a non-negative integer cursor',
        });
        return true;
      }
      beforeId = parsed;
    }

    // ---- Repository read ------------------------------------------
    final List<AuditLogRow> rows;
    try {
      rows = await _gateway.listByHierarchy(
        operatorId: actor.actorOperatorId,
        locationId: actor.actorLocationId,
        scopeType: scopeType,
        orgUnitId: orgUnitId,
        locationFilter: locationFilter,
        from: from,
        to: to,
        actorUserId: actorUserIdFilter,
        action: actionFilter,
        limit: limit,
        beforeId: beforeId,
        userId: actor.actorUserId,
      );
    } catch (_) {
      _writeJson(response, 503, <String, Object?>{
        'error': 'audit_log_hierarchy_unavailable',
        'message': 'audit log read is unavailable; please retry',
      });
      return true;
    }

    stopwatch.stop();
    if (_latencyRecorder != null) {
      final distinctLocations = <String>{
        for (final row in rows)
          if (row.locationId != null) row.locationId!,
      };
      _latencyRecorder(
        operatorId: actor.actorOperatorId,
        locationCount: distinctLocations.length,
        elapsed: stopwatch.elapsed,
      );
    }

    String? nextCursor;
    if (rows.isNotEmpty) {
      final lastId = rows.last.id;
      if (int.tryParse(lastId) != null) {
        nextCursor = lastId;
      }
    }

    _writeJson(response, 200, <String, Object?>{
      'rows': <Map<String, Object?>>[for (final row in rows) row.toJson()],
      'next_cursor': nextCursor,
      'scope': <String, Object?>{
        'operator_id': actor.actorOperatorId,
        'location_id': actor.actorLocationId,
        'scope_type': auditLogHierarchyScopeWireName(scopeType),
        'org_unit_id': orgUnitId,
        'location_filter': locationFilter,
        'from': from.toIso8601String(),
        'to': to.toIso8601String(),
      },
    });
    return true;
  }
}

/// Lowercase-hex UUID-shape check. Matches the validator used by
/// `audit_log_hierarchy_routes.dart` so the wire posture is identical
/// across operator + admin sibling routes.
bool _isUuid(String s) {
  final lower = s.toLowerCase();
  return RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(lower);
}

String? _nonEmpty(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

void _writeJson(HttpResponse response, int status, Object? body) {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  // Sibling-file routers close their own response because main.dart
  // short-circuits `routeRequest` when `tryHandle` returns true.
  response.close();
}
