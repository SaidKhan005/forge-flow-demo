// Lane B B8 — hierarchy-scoped audit log filter route.
//
// Path:
//
//   GET /v1/admin/auth/audit-log/hierarchy
//
// Auth posture:
//
//   * Bearer token resolves to an [OperatorContext] via the injected
//     [AuditLogHierarchyAuthResolver]. The resolver is a closure over
//     the proxy's existing `ProxyRequestGuard` so we do not duplicate
//     JWT verification here.
//   * Role gate `{super_admin, ff_support}` — same posture as the
//     read-only catalog routes (B2.1). Operator-side roles get 403.
//   * `admin_reason` header required on every request — surfaces in
//     the log line so a deploy grep can correlate an admin action
//     with the support ticket that justified the read.
//
// Filter query parameters (all optional unless noted):
//
//   * `operator_id`     uuid    — Required when caller is a scope-less
//                                 global admin (ff_support /
//                                 super_admin tokens issued by the B1
//                                 sign-in contract carry no
//                                 operator_id; the admin picks one
//                                 here). When the JWT already carries
//                                 a tenant scope the param is
//                                 redundant — if supplied it MUST
//                                 match, otherwise 400.
//   * `location_id`     uuid    — Required when JWT is scope-less; the
//                                 repository needs a location for the
//                                 SET LOCAL tenant transaction.
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
//                                 before_id`. Combine with `limit` to
//                                 paginate chronologically backwards.
//
// Response (200, body):
//
//   {
//     "rows": [<AuditLogRow as JSON>...],
//     "next_cursor": "<id of the last row in the page>" | null,
//     "scope": {
//       "operator_id": "<uuid>",
//       "scope_type": "operator_wide" | "org_unit" | "location",
//       "org_unit_id": "<uuid>" | null,
//       "location_id": "<uuid>" | null,
//       "from":  "<iso8601>",
//       "to":    "<iso8601>"
//     }
//   }
//
// Error envelopes (4xx / 5xx) reuse the proxy convention:
//
//   { "error": "<machine_code>", "message": "<plain English>" }
//
// HP discipline:
//
//   * HP #4 per-operator isolation: every read routes through
//     `AuditLogsReader.listByHierarchy`, which extends
//     [OperatorScopedRepository] — `withTenant` issues SET LOCAL
//     `app.operator_id`, and the existing RLS policy on
//     `public.audit_logs` clamps to the GUC. A global admin (B1
//     scope-less token) MUST supply `operator_id` + `location_id`
//     query params; the route never reads from a JWT for the system
//     path (no `withSystem` here — admin reads are tenant-bound).
//   * HP #6 advisor-only: pure read; nothing writes.
//   * Read-only by construction: no `audit_logs` INSERT / UPDATE /
//     DELETE anywhere. Sibling-file pattern preserves the
//     `tool/advisor_proxy_size_lint.dart` bleed-stop ceiling
//     (`tool/advisor_proxy/advisor_proxy.dart` UNTOUCHED).
//
// Sibling-file mounting: `main.dart` calls
// [AuditLogHierarchyRouter.tryHandle] before delegating to the
// monolithic `routeRequest`. Returns `true` when the request matched
// and was handled.
//
// Testing seam: tests construct [AuditLogHierarchyRouter] directly
// with an in-memory [AuditLogHierarchyGateway] fake; the dart:io
// `HttpRequest` is driven from a loopback server (see
// `test/proxy/audit_log_hierarchy_routes_test.dart`).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';

/// Path the admin Flutter client hits for the hierarchy-filtered
/// audit-log surface. Lives below the existing
/// `/v1/admin/auth/audit-log` root so the legacy unfiltered route is
/// untouched.
const String adminAuthAuditLogHierarchyPath =
    '/v1/admin/auth/audit-log/hierarchy';

/// Roles permitted to read the hierarchy-filtered audit log. Mirrors
/// the B2.1 / B5 posture for read-only F&F-admin surfaces.
const Set<String> kAuditLogHierarchyReadRoles = <String>{
  'super_admin',
  'ff_support',
};

/// Default time window when the caller does not supply `from` / `to`.
/// Sized so the screen renders the most-recent week without forcing a
/// pagination first move; the operator can widen via the URL params.
const Duration kAuditLogHierarchyDefaultWindow = Duration(days: 7);

/// Verified caller context the route hands to the gateway after auth +
/// role + admin_reason checks succeed. Mirrors the
/// `AdminBusinessTimingRouter.handle` parameter shape so reviewers see
/// the same idiom across admin sibling routes.
class AuditLogHierarchyActor {
  const AuditLogHierarchyActor({
    required this.actorUserId,
    required this.actorRoles,
    required this.actorOperatorId,
    required this.actorLocationId,
  });

  /// Authenticated user_id from the verified JWT.
  final String actorUserId;

  /// Verified role claims. The route gate is satisfied when this set
  /// intersects [kAuditLogHierarchyReadRoles].
  final Set<String> actorRoles;

  /// JWT operator_id claim. Empty string when the token is a
  /// scope-less global-admin token (B1 sign-in contract).
  final String actorOperatorId;

  /// JWT location_id claim. Empty string when the token is a
  /// scope-less global-admin token.
  final String actorLocationId;
}

/// Resolves an [AuditLogHierarchyActor] from an inbound `HttpRequest`.
/// Production binds this to a closure over the proxy's existing
/// `ProxyRequestGuard.requireOperatorContext`; tests pass an in-memory
/// implementation that returns a pinned actor (or null = 401 / 403).
typedef AuditLogHierarchyAuthResolver = Future<AuditLogHierarchyActor?>
    Function(HttpRequest request);

/// Read seam — production binds [RepositoryAuditLogHierarchyGateway]
/// which wraps [AuditLogsReader]; tests pass a fake. The gateway
/// boundary lets us swap caching shapes (the L_A2 descendant cache
/// can be threaded through here in a future slice without touching
/// the route handler).
abstract class AuditLogHierarchyGateway {
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

/// Production [AuditLogHierarchyGateway] backed by [AuditLogsReader].
/// The reader extends `OperatorScopedRepository` so every call routes
/// through `withTenant` — RLS clamps the operator already, and this
/// wrapper simply forwards the call.
///
/// The descendant-set cache (L_A2 / [InheritanceDescendantCache]) is
/// NOT consulted from this binding by design — see the architectural
/// choice note in the B8 PR body. The repository's ltree predicate
/// uses the GIST index on `locations.org_unit_path` directly, which
/// is O(log N) and well-behaved without an extra hop through the
/// cache. The cache primitive remains a future-slice opt-in for
/// workloads that read the same scope repeatedly enough that the
/// app-level memoization wins over the index seek.
class RepositoryAuditLogHierarchyGateway implements AuditLogHierarchyGateway {
  const RepositoryAuditLogHierarchyGateway({required AuditLogsReader reader})
      : _reader = reader;

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

/// Optional hook fired on every successful 2xx so a pressure probe /
/// metric exporter can record `audit_log_hierarchy_filter_p95_ms`
/// per `(operator_id, location_count)` bucket. Null in tests that
/// only assert HTTP shape.
typedef AuditLogHierarchyLatencyRecorder = void Function({
  required String operatorId,
  required int locationCount,
  required Duration elapsed,
});

/// Top-level router. Mounted in `main.dart` ahead of `routeRequest`.
class AuditLogHierarchyRouter {
  AuditLogHierarchyRouter({
    required AuditLogHierarchyGateway gateway,
    required AuditLogHierarchyAuthResolver authResolver,
    DateTime Function()? now,
    AuditLogHierarchyLatencyRecorder? latencyRecorder,
  })  : _gateway = gateway,
        _authResolver = authResolver,
        _now = now ?? DateTime.now,
        _latencyRecorder = latencyRecorder;

  final AuditLogHierarchyGateway _gateway;
  final AuditLogHierarchyAuthResolver _authResolver;
  final DateTime Function() _now;
  final AuditLogHierarchyLatencyRecorder? _latencyRecorder;

  /// Returns `true` when the request matched the audit-log hierarchy
  /// route and was fully handled — the caller (main.dart marked
  /// region) must skip the rest of the dispatcher in that case.
  /// Returns `false` for unrelated paths so `routeRequest` continues.
  Future<bool> tryHandle(HttpRequest request) async {
    if (request.method != 'GET') return false;
    if (request.uri.path != adminAuthAuditLogHierarchyPath) return false;

    final response = request.response;
    final stopwatch = Stopwatch()..start();

    // ---- Auth + role gate -----------------------------------------
    AuditLogHierarchyActor? actor;
    try {
      actor = await _authResolver(request);
    } catch (_) {
      _writeJson(response, 401, <String, Object?>{
        'error': 'unauthorized',
        'message': 'verified bearer token required',
      });
      return true;
    }
    if (actor == null) {
      _writeJson(response, 401, <String, Object?>{
        'error': 'unauthorized',
        'message': 'verified bearer token required',
      });
      return true;
    }
    if (!actor.actorRoles.any(kAuditLogHierarchyReadRoles.contains)) {
      _writeJson(response, 403, <String, Object?>{
        'error': 'permission_denied',
        'message': 'super_admin or ff_support role is required',
        'required_roles': kAuditLogHierarchyReadRoles.toList(),
      });
      return true;
    }

    // ---- admin_reason gate ----------------------------------------
    final adminReason =
        request.headers.value('admin_reason')?.trim() ??
        request.headers.value('admin-reason')?.trim() ??
        request.headers.value('Admin-Reason')?.trim();
    if (adminReason == null || adminReason.isEmpty) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'missing_admin_reason',
        'message':
            'admin_reason header is required for every audit-log read',
      });
      return true;
    }

    // ---- Parse + validate query params ----------------------------
    final params = request.uri.queryParameters;

    final scopeType =
        auditLogHierarchyScopeFromWire(params['scope_type']) ??
            AuditLogHierarchyScope.operatorWide;

    // operator_id resolution: JWT first, query param fallback for
    // scope-less global admin tokens.
    final tokenOperatorId = actor.actorOperatorId;
    final paramOperatorId = (params['operator_id'] ?? '').trim();
    final String operatorId;
    if (tokenOperatorId.isNotEmpty) {
      if (paramOperatorId.isNotEmpty && paramOperatorId != tokenOperatorId) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'operator_id_mismatch',
          'message':
              'operator_id query parameter does not match the verified '
              'token scope; remove the parameter or sign in as the '
              'admin for that operator',
        });
        return true;
      }
      operatorId = tokenOperatorId;
    } else {
      if (paramOperatorId.isEmpty) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'missing_operator_id',
          'message':
              'operator_id query parameter is required when the token '
              'does not carry a tenant scope',
        });
        return true;
      }
      if (!_isUuid(paramOperatorId)) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_operator_id',
          'message': 'operator_id must be a uuid',
        });
        return true;
      }
      operatorId = paramOperatorId;
    }

    final tokenLocationId = actor.actorLocationId;
    final paramLocationId = (params['location_id'] ?? '').trim();
    final String locationId;
    if (tokenLocationId.isNotEmpty) {
      locationId = tokenLocationId;
    } else {
      if (paramLocationId.isEmpty) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'missing_location_id',
          'message':
              'location_id query parameter is required when the token '
              'does not carry a tenant scope (needed to anchor the '
              'tenant transaction)',
        });
        return true;
      }
      if (!_isUuid(paramLocationId)) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_location_id',
          'message': 'location_id must be a uuid',
        });
        return true;
      }
      locationId = paramLocationId;
    }

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

    // Optional actor_user_id / action.
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

    // Time-range parsing. Both bounds use ISO 8601 / RFC 3339 — the
    // same shape the existing `/v1/admin/auth/audit-log` route accepts.
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
    final from = fromInstant ?? to.subtract(kAuditLogHierarchyDefaultWindow);
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
        operatorId: operatorId,
        locationId: locationId,
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
      // 503 envelope: do not echo internal exception details — admin
      // routes already log structured errors elsewhere in the proxy.
      _writeJson(response, 503, <String, Object?>{
        'error': 'audit_log_hierarchy_unavailable',
        'message': 'audit log read is unavailable; please retry',
      });
      return true;
    }

    stopwatch.stop();
    // The probe receives the distinct-location count visible in the
    // result page so a high-fan-out scope reads as a higher bucket
    // for `audit_log_hierarchy_filter_p95_ms{location_count=…}`.
    if (_latencyRecorder != null) {
      final distinctLocations = <String>{
        for (final row in rows)
          if (row.locationId != null) row.locationId!,
      };
      _latencyRecorder(
        operatorId: operatorId,
        locationCount: distinctLocations.length,
        elapsed: stopwatch.elapsed,
      );
    }

    // Next-cursor = the smallest id in the current page (rows are
    // ordered DESC). Empty page → null.
    String? nextCursor;
    if (rows.isNotEmpty) {
      final lastId = rows.last.id;
      // Guard against a non-numeric id (defensive — the DB column is
      // bigserial so this should be unreachable).
      if (int.tryParse(lastId) != null) {
        nextCursor = lastId;
      }
    }

    _writeJson(response, 200, <String, Object?>{
      'rows': <Map<String, Object?>>[for (final row in rows) row.toJson()],
      'next_cursor': nextCursor,
      'scope': <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
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
/// `admin_default_role_catalog_routes.dart` so the wire posture is
/// identical across admin sibling routes.
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
