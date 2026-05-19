import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart';
import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';
import 'package:forge_and_flow/services/observability/dependency_timeout_exception.dart';

import 'operator_benchmark_override_cap.dart';
import 'operator_routes.dart';

const String operatorBenchmarkOverridesPath =
    '/v1/operator/benchmarks/overrides';
const String operatorBenchmarkOverridesPrefix =
    '$operatorBenchmarkOverridesPath/';

/// Legacy cap-status read path. GET-only. Kept only for existing
/// status/cleanup consumers while mobile Baseline Manager selected-star
/// writes own the baseline override path. Admin-tier callers receive
/// `remaining: -1`.
const String operatorBenchmarkOverrideCapStatusPath =
    '/v1/operator/benchmarks/overrides/cap-status';

/// Legacy admin-undo suffix. The route still matches this path so the
/// proxy can return the same disabled response as the other legacy
/// mutation verbs instead of falling through to another dispatcher.
const String operatorBenchmarkOverrideAdminUndoSuffix = '/admin-undo';

const int operatorBenchmarkOverrideWriteDisabledStatus = HttpStatus.gone;

const String operatorBenchmarkOverrideWriteDisabledError =
    'legacy_benchmark_override_writes_disabled';

const String operatorBenchmarkOverrideWriteDisabledMessage =
    'Legacy benchmark override writes are disabled. Use mobile Baseline '
    'Manager star selection to change the active baseline.';

const Map<String, Object?> _legacyBenchmarkOverrideWriteDisabledBody =
    <String, Object?>{
      'error': operatorBenchmarkOverrideWriteDisabledError,
      'message': operatorBenchmarkOverrideWriteDisabledMessage,
      'replacement': 'mobile_baseline_manager_selected_star',
    };

/// Route-local role allow-list for legacy benchmark override reads.
/// The write verbs are tombstoned before this role gate; GET and
/// cap-status keep the same owner/general-manager/manager read envelope for
/// existing cleanup/status consumers.
///
/// Permission gate (`forgeflow.baseline.override`) is the primary
/// defense for the surviving read-only route.
const Set<String> kOperatorBenchmarkOverrideWriteRoles = <String>{
  'operator_owner',
  'operator_general_manager',
  'location_manager',
  'supervisor',
};

abstract class OperatorBenchmarkOverridesGateway {
  Future<List<BenchmarkOverrideCandidate>> listCurrent({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  });

  /// Returns every benchmark override (current + closed) the gateway
  /// can see for [actorUserId] whose `effective_from` falls in the
  /// same UTC calendar month as [referenceTime]. Used only by the
  /// legacy read-only cap-status path; write routes are disabled.
  Future<List<BenchmarkOverrideCandidate>> listOverridesByUserInMonth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime referenceTime,
  });
}

class RepositoryOperatorBenchmarkOverridesGateway
    implements OperatorBenchmarkOverridesGateway {
  const RepositoryOperatorBenchmarkOverridesGateway({required this.repository});

  final BenchmarkOverridesRepository repository;

  @override
  Future<List<BenchmarkOverrideCandidate>> listCurrent({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) {
    return repository.listCurrent(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
    );
  }

  @override
  Future<List<BenchmarkOverrideCandidate>> listOverridesByUserInMonth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime referenceTime,
  }) async {
    // Legacy cap-status is read-only. The repository exposes current
    // rows here, so this compatibility path reports active rows in
    // the UTC month without reopening the removed write workflow.
    final rows = await repository.listCurrent(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
    );
    return rows
        .where(
          (row) =>
              row.createdBy == actorUserId &&
              _sameUtcMonth(row.effectiveFrom, referenceTime),
        )
        .toList(growable: false);
  }

  static bool _sameUtcMonth(DateTime a, DateTime b) {
    final ua = a.toUtc();
    final ub = b.toUtc();
    return ua.year == ub.year && ua.month == ub.month;
  }
}

/// Verified caller context the router hands to itself after the auth +
/// role + permission gate succeed. Mirrors the
/// `AuditLogHierarchyActor` shape so reviewers see the same idiom
/// across admin sibling routes.
///
/// The shape is intentionally tiny — only the fields the router needs
/// to pass into [OperatorBenchmarkOverridesRouter.handle]. Production
/// builds bridge `OperatorContext.{userId,operatorId,locationId,roles,
/// actorKind}` into this shape; tests pass an [InMemoryActor] (or
/// equivalent) directly.
class OperatorBenchmarkOverridesActor {
  const OperatorBenchmarkOverridesActor({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.roles,
    required this.actorKind,
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final Set<String> roles;
  final String actorKind;
}

/// Resolves an [OperatorBenchmarkOverridesActor] from an inbound
/// `HttpRequest`. Production binds this to a closure over the proxy's
/// existing `ProxyRequestGuard.requireOperatorContext`; tests pass an
/// in-memory implementation that returns a pinned actor (or null = 401).
typedef OperatorBenchmarkOverridesAuthResolver =
    Future<OperatorBenchmarkOverridesActor?> Function(HttpRequest request);

/// Outcome of the permission gate. Production binds this to a closure
/// over the proxy's existing `ProxyPermissionSnapshotResolver`, which
/// checks for `PermissionKeys.forgeflowBaselineOverride`. Tests pass an
/// in-memory implementation that returns the desired effect.
enum OperatorBenchmarkOverridesPermissionEffect {
  allow,
  deny,
  unavailable,
  notConfigured,
}

/// Loads the operator's effective permission for
/// `forgeflow.baseline.override`. Returns an
/// [OperatorBenchmarkOverridesPermissionEffect] so the router can return
/// a 403 / 503 envelope for read-only legacy routes without coupling to
/// the proxy's
/// `ProxyPermissionSnapshot` shape directly. Production bridges this
/// onto `ProxyPermissionSnapshotResolver.load(...)`.
typedef OperatorBenchmarkOverridesPermissionGate =
    Future<OperatorBenchmarkOverridesPermissionEffect> Function(
      OperatorBenchmarkOverridesActor actor,
    );

/// Logger hook fired whenever the router catches an unhandled error in
/// the read path. Production binds this to the proxy's structured
/// `log` channel (matches the `proxy.unhandled_error` surface used by
/// the inline dispatch before B6 decompose). Null in tests that only
/// assert HTTP shape.
typedef OperatorBenchmarkOverridesUnhandledErrorLogger =
    void Function({
      required String method,
      required String path,
      required Object error,
      required StackTrace stackTrace,
    });

class OperatorBenchmarkOverridesRouter {
  OperatorBenchmarkOverridesRouter({
    required this.gateway,
    required this.auditSink,
    DateTime Function()? now,
    OperatorBenchmarkOverridesAuthResolver? authResolver,
    OperatorBenchmarkOverridesPermissionGate? permissionGate,
    OperatorBenchmarkOverridesUnhandledErrorLogger? unhandledErrorLogger,
    BenchmarkOverrideCapPolicy? capPolicy,
  }) : _now = now ?? DateTime.now,
       _authResolver = authResolver,
       _permissionGate = permissionGate,
       _unhandledErrorLogger = unhandledErrorLogger,
       _capPolicy = capPolicy ?? const BenchmarkOverrideCapPolicy();

  final OperatorBenchmarkOverridesGateway gateway;
  final OperatorWriteAuditSink auditSink;
  final DateTime Function() _now;
  final OperatorBenchmarkOverridesAuthResolver? _authResolver;
  final OperatorBenchmarkOverridesPermissionGate? _permissionGate;
  final OperatorBenchmarkOverridesUnhandledErrorLogger? _unhandledErrorLogger;
  final BenchmarkOverrideCapPolicy _capPolicy;

  /// Visible for tests in the same lane. The router itself never
  /// constructs a `BenchmarkOverrideCapPolicy` outside the ctor.
  BenchmarkOverrideCapPolicy get capPolicy => _capPolicy;

  static bool matches(String path, String method) {
    if (path == operatorBenchmarkOverridesPath) {
      return method == 'GET' || method == 'POST';
    }
    if (path == operatorBenchmarkOverrideCapStatusPath) {
      return method == 'GET';
    }
    if (!path.startsWith(operatorBenchmarkOverridesPrefix)) return false;
    final tail = path.substring(operatorBenchmarkOverridesPrefix.length);
    if (tail.isEmpty) return false;
    if (tail.endsWith(operatorBenchmarkOverrideAdminUndoSuffix)) {
      // /overrides/{id}/admin-undo legacy mutation tombstone.
      return method == 'DELETE';
    }
    return method == 'PATCH' || method == 'DELETE';
  }

  static bool isReadOnly(String path, String method) {
    if (method != 'GET') return false;
    return path == operatorBenchmarkOverridesPath ||
        path == operatorBenchmarkOverrideCapStatusPath;
  }

  static bool isLegacyWrite(String path, String method) {
    return matches(path, method) && !isReadOnly(path, method);
  }

  static bool isAdminUndoPath(String path) {
    if (!path.startsWith(operatorBenchmarkOverridesPrefix)) return false;
    final tail = path.substring(operatorBenchmarkOverridesPrefix.length);
    return tail.endsWith(operatorBenchmarkOverrideAdminUndoSuffix) &&
        tail.length > operatorBenchmarkOverrideAdminUndoSuffix.length;
  }

  /// Pre-check dispatch invoked by `main.dart` ahead of `routeRequest`.
  ///
  /// Returns `true` when the request matched the operator benchmark
  /// override routes and was fully handled — the caller (main.dart
  /// marked region) must skip the rest of the dispatcher in that case.
  /// Returns `false` for unrelated paths so `routeRequest` continues.
  ///
  /// Legacy writes are claimed here and returned as gone after auth +
  /// tenant verification, before Idempotency-Key parsing, request-body
  /// reads, gateway calls, or mutation audit work. GET routes keep the
  /// legacy role + permission read gates.
  Future<bool> tryHandle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (!matches(path, method)) return false;

    final response = request.response;

    if (_authResolver == null) {
      _writeJson(response, 503, <String, Object?>{
        'error': 'operator_benchmark_overrides_not_configured',
        'message':
            'route requires an OperatorBenchmarkOverridesAuthResolver to be installed',
      });
      return true;
    }
    OperatorBenchmarkOverridesActor? actor;
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
    if (actor.operatorId.isEmpty || actor.locationId.isEmpty) {
      _writeJson(response, 403, <String, Object?>{
        'error': 'permission_denied',
        'message': 'benchmark overrides require tenant scope',
      });
      return true;
    }
    if (isLegacyWrite(path, method)) {
      _writeJson(
        response,
        operatorBenchmarkOverrideWriteDisabledStatus,
        _legacyBenchmarkOverrideWriteDisabledBody,
      );
      return true;
    }
    if (!actor.roles.any(kOperatorBenchmarkOverrideWriteRoles.contains)) {
      _writeJson(response, 403, <String, Object?>{
        'error': 'forbidden',
        'message':
            'operator owner, general manager, location manager, '
            'or supervisor role is required',
        'required_roles': kOperatorBenchmarkOverrideWriteRoles.toList(),
      });
      return true;
    }
    if (_permissionGate == null) {
      _writeJson(response, 503, <String, Object?>{
        'error': 'permission_snapshot_not_configured',
        'message':
            'route requires an OperatorBenchmarkOverridesPermissionGate to be installed',
      });
      return true;
    }
    final OperatorBenchmarkOverridesPermissionEffect permissionEffect;
    try {
      permissionEffect = await _permissionGate(actor);
    } catch (_) {
      _writeJson(response, 503, <String, Object?>{
        'error': 'permission_snapshot_unavailable',
        'message': 'permissions are unavailable; please retry',
      });
      return true;
    }
    switch (permissionEffect) {
      case OperatorBenchmarkOverridesPermissionEffect.unavailable:
        _writeJson(response, 503, <String, Object?>{
          'error': 'permission_snapshot_unavailable',
          'message': 'permissions are unavailable; please retry',
        });
        return true;
      case OperatorBenchmarkOverridesPermissionEffect.notConfigured:
        _writeJson(response, 503, <String, Object?>{
          'error': 'permission_snapshot_not_configured',
          'message':
              'route requires an OperatorBenchmarkOverridesPermissionGate to be installed',
        });
        return true;
      case OperatorBenchmarkOverridesPermissionEffect.deny:
        _writeJson(response, 403, <String, Object?>{
          'error': 'forbidden',
          'message':
              'forgeflow.baseline.override permission is required to read legacy benchmark override status',
          'permission_key': 'forgeflow.baseline.override',
        });
        return true;
      case OperatorBenchmarkOverridesPermissionEffect.allow:
        break;
    }

    try {
      final result = await handle(
        method: method,
        path: path,
        operatorId: actor.operatorId,
        locationId: actor.locationId,
        actorUserId: actor.userId,
        actorKind: actor.actorKind,
        actorRoles: actor.roles,
        idempotencyKey: '',
        body: const <String, Object?>{},
      );
      _writeJson(response, result.statusCode, result.body);
    } catch (error, stackTrace) {
      if (error is DependencyTimeoutException) {
        // Mirror the proxy's `_writeDependencyTimeoutEnvelope` exactly
        // (status 503, surface + operation in the JSON body). The
        // pre-decompose inline block used `_maybeWriteDependencyTimeout`
        // which wraps the same envelope.
        _writeJson(response, 503, <String, Object?>{
          'error': 'dependency_timeout',
          'surface': error.surface,
          'operation': error.operation,
          'message': 'Upstream dependency timed out; please retry',
        });
        return true;
      }
      if (error is BenchmarkOverridesInputError) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'benchmark_override_invalid',
          'message': error.message,
          'field': error.field,
        });
        return true;
      }
      _unhandledErrorLogger?.call(
        method: method,
        path: path,
        error: error,
        stackTrace: stackTrace,
      );
      _writeJson(response, 503, <String, Object?>{
        'error': 'operator_benchmark_overrides_unavailable',
        'message': 'benchmark overrides are unavailable; please retry',
      });
    }
    return true;
  }

  Future<({int statusCode, Map<String, Object?> body})> handle({
    required String method,
    required String path,
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required Map<String, Object?> body,
    Set<String> actorRoles = const <String>{},
  }) async {
    if (isReadOnly(path, method)) {
      if (path == operatorBenchmarkOverrideCapStatusPath) {
        return _capStatus(
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: actorUserId,
          actorRoles: actorRoles,
        );
      }
      return _list(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
      );
    }
    if (isLegacyWrite(path, method)) return _legacyWriteDisabled();
    return (
      statusCode: 405,
      body: const <String, Object?>{
        'error': 'method_not_allowed',
        'message': 'benchmark override route does not allow this method',
      },
    );
  }

  Future<({int statusCode, Map<String, Object?> body})> _list({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    final rows = await gateway.listCurrent(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
    );
    return (
      statusCode: 200,
      body: <String, Object?>{
        'overrides': <Map<String, Object?>>[
          for (final row in rows) row.toJson(),
        ],
      },
    );
  }

  ({int statusCode, Map<String, Object?> body}) _legacyWriteDisabled() {
    return (
      statusCode: operatorBenchmarkOverrideWriteDisabledStatus,
      body: _legacyBenchmarkOverrideWriteDisabledBody,
    );
  }

  Future<({int statusCode, Map<String, Object?> body})> _capStatus({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required Set<String> actorRoles,
  }) async {
    final status = await _loadCapStatus(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      actorRoles: actorRoles,
    );
    return (statusCode: 200, body: <String, Object?>{'cap': status.toJson()});
  }

  Future<BenchmarkOverrideCapStatus> _loadCapStatus({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required Set<String> actorRoles,
  }) async {
    final now = _now();
    // Admins skip the count load; the legacy read-only cap-status path
    // reports them as uncapped without doing unnecessary DB work.
    final probe = _capPolicy.evaluate(
      actorUserId: actorUserId,
      roles: actorRoles,
      overrides: const <BenchmarkOverrideCandidate>[],
      now: now,
    );
    if (probe.isAdmin) return probe;
    final rows = await gateway.listOverridesByUserInMonth(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      referenceTime: now,
    );
    return _capPolicy.evaluate(
      actorUserId: actorUserId,
      roles: actorRoles,
      overrides: rows,
      now: now,
    );
  }
}

void _writeJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body,
) {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  // Sibling-file routers close their own response because main.dart
  // short-circuits `routeRequest` when `tryHandle` returns true.
  // Mirrors the audit_log_hierarchy_routes.dart pattern (B8).
  response.close();
}
