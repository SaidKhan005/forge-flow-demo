import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart';
import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';
import 'package:forge_and_flow/services/observability/dependency_timeout_exception.dart';

import 'operator_routes.dart';

const String operatorBenchmarkOverridesPath =
    '/v1/operator/benchmarks/overrides';
const String operatorBenchmarkOverridesPrefix = '$operatorBenchmarkOverridesPath/';

abstract class OperatorBenchmarkOverridesGateway {
  Future<List<BenchmarkOverrideCandidate>> listCurrent({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  });

  Future<BenchmarkOverrideCandidate> setOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required BenchmarkOverrideScopeType scopeType,
    required String? orgUnitId,
    required String? targetLocationId,
    required String metricKey,
    required double overrideValue,
    DateTime? effectiveFrom,
  });

  Future<BenchmarkOverrideCandidate?> patchOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
    required double overrideValue,
  });

  Future<BenchmarkOverrideCandidate?> clearOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
  });

}

class BenchmarkOverrideMutationResult {
  const BenchmarkOverrideMutationResult({
    required this.override,
    required this.previous,
    required this.cleared,
  });

  final BenchmarkOverrideCandidate override;
  final BenchmarkOverrideCandidate? previous;
  final bool cleared;
}

extension OperatorBenchmarkOverridesGatewayAudit
    on OperatorBenchmarkOverridesGateway {
  Future<BenchmarkOverrideMutationResult> setOverrideWithPrevious({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required BenchmarkOverrideScopeType scopeType,
    required String? orgUnitId,
    required String? targetLocationId,
    required String metricKey,
    required double overrideValue,
    DateTime? effectiveFrom,
  }) async {
    final previous = await _findPreviousOverride(
      gateway: this,
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      targetLocationId: targetLocationId,
      metricKey: metricKey,
    );
    final row = await setOverride(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      targetLocationId: targetLocationId,
      metricKey: metricKey,
      overrideValue: overrideValue,
      effectiveFrom: effectiveFrom,
    );
    return BenchmarkOverrideMutationResult(
      override: row,
      previous: previous,
      cleared: false,
    );
  }

  Future<BenchmarkOverrideMutationResult?> patchOverrideWithPrevious({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
    required double overrideValue,
  }) async {
    final previous = await _findOverrideById(
      gateway: this,
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      overrideId: overrideId,
    );
    final row = await patchOverride(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      overrideId: overrideId,
      overrideValue: overrideValue,
    );
    if (row == null) return null;
    return BenchmarkOverrideMutationResult(
      override: row,
      previous: previous,
      cleared: false,
    );
  }

  Future<BenchmarkOverrideMutationResult?> clearOverrideWithPrevious({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
  }) async {
    final previous = await _findOverrideById(
      gateway: this,
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      overrideId: overrideId,
    );
    final row = await clearOverride(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      overrideId: overrideId,
    );
    if (row == null) return null;
    return BenchmarkOverrideMutationResult(
      override: row,
      previous: previous,
      cleared: true,
    );
  }
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
  Future<BenchmarkOverrideCandidate> setOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required BenchmarkOverrideScopeType scopeType,
    required String? orgUnitId,
    required String? targetLocationId,
    required String metricKey,
    required double overrideValue,
    DateTime? effectiveFrom,
  }) {
    return repository.setOverride(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      targetLocationId: targetLocationId,
      metricKey: metricKey,
      overrideValue: overrideValue,
      createdBy: actorUserId,
      effectiveFrom: effectiveFrom,
    );
  }

  @override
  Future<BenchmarkOverrideCandidate?> patchOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
    required double overrideValue,
  }) {
    return repository.patchOverride(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      overrideId: overrideId,
      overrideValue: overrideValue,
      createdBy: actorUserId,
    );
  }

  @override
  Future<BenchmarkOverrideCandidate?> clearOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
  }) {
    return repository.clearOverride(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      overrideId: overrideId,
    );
  }

}

Future<BenchmarkOverrideCandidate?> _findOverrideById({
  required OperatorBenchmarkOverridesGateway gateway,
  required String operatorId,
  required String locationId,
  required String actorUserId,
  required String overrideId,
}) async {
  final rows = await gateway.listCurrent(
    operatorId: operatorId,
    locationId: locationId,
    actorUserId: actorUserId,
  );
  for (final row in rows) {
    if (row.overrideId == overrideId) return row;
  }
  return null;
}

Future<BenchmarkOverrideCandidate?> _findPreviousOverride({
  required OperatorBenchmarkOverridesGateway gateway,
  required String operatorId,
  required String locationId,
  required String actorUserId,
  required BenchmarkOverrideScopeType scopeType,
  required String? orgUnitId,
  required String? targetLocationId,
  required String metricKey,
}) async {
  final rows = await gateway.listCurrent(
    operatorId: operatorId,
    locationId: locationId,
    actorUserId: actorUserId,
  );
  for (final row in rows) {
    final sameScope = row.scopeType == scopeType &&
        row.orgUnitId == orgUnitId &&
        row.locationId == targetLocationId &&
        row.metricKey == metricKey;
    if (sameScope) return row;
  }
  return null;
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
typedef OperatorBenchmarkOverridesAuthResolver
    = Future<OperatorBenchmarkOverridesActor?> Function(HttpRequest request);

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
/// [OperatorBenchmarkOverridesPermissionEffect] so the router can write
/// a 403 / 503 envelope without coupling to the proxy's
/// `ProxyPermissionSnapshot` shape directly. Production bridges this
/// onto `ProxyPermissionSnapshotResolver.load(...)`. The keyed-on
/// permission is `forgeflow.baseline.override` (see B6 contract).
typedef OperatorBenchmarkOverridesPermissionGate
    = Future<OperatorBenchmarkOverridesPermissionEffect> Function(
  OperatorBenchmarkOverridesActor actor,
);

/// Logger hook fired whenever the router catches an unhandled error in
/// the write path. Production binds this to the proxy's structured
/// `log` channel (matches the `proxy.unhandled_error` surface used by
/// the inline dispatch before B6 decompose). Null in tests that only
/// assert HTTP shape.
typedef OperatorBenchmarkOverridesUnhandledErrorLogger = void Function({
  required String method,
  required String path,
  required Object error,
  required StackTrace stackTrace,
});

class OperatorBenchmarkOverridesRouter {
  OperatorBenchmarkOverridesRouter({
    required this.gateway,
    required this.auditSink,
    OperatorWriteIdempotencyCache? idempotencyCache,
    DateTime Function()? now,
    OperatorBenchmarkOverridesAuthResolver? authResolver,
    OperatorBenchmarkOverridesPermissionGate? permissionGate,
    OperatorBenchmarkOverridesUnhandledErrorLogger? unhandledErrorLogger,
  }) : _idempotencyCache = idempotencyCache ?? OperatorWriteIdempotencyCache(),
       _now = now ?? DateTime.now,
       _authResolver = authResolver,
       _permissionGate = permissionGate,
       _unhandledErrorLogger = unhandledErrorLogger;

  final OperatorBenchmarkOverridesGateway gateway;
  final OperatorWriteAuditSink auditSink;
  final OperatorWriteIdempotencyCache _idempotencyCache;
  final DateTime Function() _now;
  final OperatorBenchmarkOverridesAuthResolver? _authResolver;
  final OperatorBenchmarkOverridesPermissionGate? _permissionGate;
  final OperatorBenchmarkOverridesUnhandledErrorLogger? _unhandledErrorLogger;

  static bool matches(String path, String method) {
    if (path == operatorBenchmarkOverridesPath) {
      return method == 'GET' || method == 'POST';
    }
    if (!path.startsWith(operatorBenchmarkOverridesPrefix)) return false;
    final id = path.substring(operatorBenchmarkOverridesPrefix.length);
    return id.isNotEmpty && (method == 'PATCH' || method == 'DELETE');
  }

  static bool isReadOnly(String path, String method) =>
      path == operatorBenchmarkOverridesPath && method == 'GET';

  /// Pre-check dispatch invoked by `main.dart` ahead of `routeRequest`.
  ///
  /// Returns `true` when the request matched the operator benchmark
  /// override routes and was fully handled — the caller (main.dart
  /// marked region) must skip the rest of the dispatcher in that case.
  /// Returns `false` for unrelated paths so `routeRequest` continues.
  ///
  /// Reproduces verbatim the auth + role + permission + Idempotency-Key
  /// + body-parse + handle + error-envelope dispatch that previously
  /// lived inline in `advisor_proxy.dart` (B6 +149 LoC block). The
  /// sibling-file pattern preserves the
  /// `tool/advisor_proxy_size_lint.dart` bleed-stop ceiling
  /// (`advisor_proxy.dart` UNTOUCHED). Mirrors C-1 SendGrid + B8
  /// audit-log-hierarchy precedents.
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
    if (!actor.roles.any(kOperatorWriteRoles.contains)) {
      _writeJson(response, 403, <String, Object?>{
        'error': 'forbidden',
        'message': 'operator owner or operator admin role is required',
        'required_roles': kOperatorWriteRoles.toList(),
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
              'forgeflow.baseline.override permission is required to manage benchmark overrides',
          'permission_key': 'forgeflow.baseline.override',
        });
        return true;
      case OperatorBenchmarkOverridesPermissionEffect.allow:
        break;
    }

    final readOnly = isReadOnly(path, method);
    String idempotencyKey;
    Map<String, Object?> requestBody;
    if (readOnly) {
      idempotencyKey = '';
      requestBody = const <String, Object?>{};
    } else {
      final headerKey = request.headers.value('Idempotency-Key')?.trim();
      if (headerKey == null || headerKey.isEmpty) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'idempotency_key_missing',
          'message': 'Idempotency-Key header is required',
        });
        return true;
      }
      if (headerKey.length > 200) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'idempotency_key_too_long',
          'message':
              'Idempotency-Key header must be 200 characters or fewer',
        });
        return true;
      }
      final bodyResult = await readOperatorJsonBody(request);
      if (bodyResult.errorStatus != null) {
        _writeJson(
          response,
          bodyResult.errorStatus!,
          bodyResult.errorBody!,
        );
        return true;
      }
      idempotencyKey = headerKey;
      requestBody = bodyResult.body!;
    }
    try {
      final result = await handle(
        method: method,
        path: path,
        operatorId: actor.operatorId,
        locationId: actor.locationId,
        actorUserId: actor.userId,
        actorKind: actor.actorKind,
        idempotencyKey: idempotencyKey,
        body: requestBody,
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
  }) async {
    if (isReadOnly(path, method)) {
      return _list(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
      );
    }
    final bodyHash = hashOperatorRequestBody(body);
    final route = '$method $path';
    try {
      return await _idempotencyCache.runOrReplay(
        operatorId: operatorId,
        route: route,
        idempotencyKey: idempotencyKey,
        requestBodyHash: bodyHash,
        compute: () => _dispatchWrite(
          method: method,
          path: path,
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: actorUserId,
          actorKind: actorKind,
          body: body,
        ),
      );
    } on OperatorWriteRejected catch (rejected) {
      return (
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
          ...rejected.extras,
        },
      );
    }
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

  Future<({int statusCode, Map<String, Object?> body})> _dispatchWrite({
    required String method,
    required String path,
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required Map<String, Object?> body,
  }) {
    if (method == 'POST' && path == operatorBenchmarkOverridesPath) {
      return _set(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        body: body,
      );
    }
    final overrideId = path.startsWith(operatorBenchmarkOverridesPrefix)
        ? Uri.decodeComponent(
            path.substring(operatorBenchmarkOverridesPrefix.length),
          )
        : '';
    if (overrideId.isEmpty) {
      return Future.value((
        statusCode: 404,
        body: const <String, Object?>{
          'error': 'not_found',
          'message': 'benchmark override route not found',
        },
      ));
    }
    if (method == 'PATCH') {
      return _patch(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        overrideId: overrideId,
        body: body,
      );
    }
    if (method == 'DELETE') {
      return _clear(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        overrideId: overrideId,
      );
    }
    return Future.value((
      statusCode: 405,
      body: const <String, Object?>{
        'error': 'method_not_allowed',
        'message': 'benchmark override route does not allow this method',
      },
    ));
  }

  Future<({int statusCode, Map<String, Object?> body})> _set({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required Map<String, Object?> body,
  }) async {
    final parsed = _parseSetBody(body);
    if (parsed.error != null) return parsed.error!;
    final result = await gateway.setOverrideWithPrevious(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      scopeType: parsed.scopeType!,
      orgUnitId: parsed.orgUnitId,
      targetLocationId: parsed.locationId,
      metricKey: parsed.metricKey!,
      overrideValue: parsed.overrideValue!,
      effectiveFrom: parsed.effectiveFrom,
    );
    await auditSink.record(
      operatorId: operatorId,
      actorUserId: actorUserId,
      actorKind: actorKind,
      eventKind: 'benchmark.override.set',
      payload: _auditPayload(result),
      occurredAt: _now().toUtc(),
    );
    return (
      statusCode: 201,
      body: <String, Object?>{'override': result.override.toJson()},
    );
  }

  Future<({int statusCode, Map<String, Object?> body})> _patch({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String overrideId,
    required Map<String, Object?> body,
  }) async {
    final value = _readPositiveNumber(body['override_value']);
    if (value == null) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'invalid_override_value',
          'message': 'override_value must be a positive number',
        },
      );
    }
    final result = await gateway.patchOverrideWithPrevious(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      overrideId: overrideId,
      overrideValue: value,
    );
    if (result == null) {
      return (
        statusCode: 404,
        body: const <String, Object?>{
          'error': 'override_not_found',
          'message': 'benchmark override was not found for this operator',
        },
      );
    }
    await auditSink.record(
      operatorId: operatorId,
      actorUserId: actorUserId,
      actorKind: actorKind,
      eventKind: 'benchmark.override.set',
      payload: _auditPayload(result),
      occurredAt: _now().toUtc(),
    );
    return (
      statusCode: 200,
      body: <String, Object?>{'override': result.override.toJson()},
    );
  }

  Future<({int statusCode, Map<String, Object?> body})> _clear({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String overrideId,
  }) async {
    final result = await gateway.clearOverrideWithPrevious(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      overrideId: overrideId,
    );
    if (result == null) {
      return (
        statusCode: 404,
        body: const <String, Object?>{
          'error': 'override_not_found',
          'message': 'benchmark override was not found for this operator',
        },
      );
    }
    await auditSink.record(
      operatorId: operatorId,
      actorUserId: actorUserId,
      actorKind: actorKind,
      eventKind: 'benchmark.override.clear',
      payload: _auditPayload(result),
      occurredAt: _now().toUtc(),
    );
    return (
      statusCode: 200,
      body: <String, Object?>{'override': result.override.toJson()},
    );
  }

  ({
    ({int statusCode, Map<String, Object?> body})? error,
    BenchmarkOverrideScopeType? scopeType,
    String? orgUnitId,
    String? locationId,
    String? metricKey,
    double? overrideValue,
    DateTime? effectiveFrom,
  })
  _parseSetBody(Map<String, Object?> body) {
    final rawScope = _readString(body['scope_type'] ?? body['scopeType']);
    final rawMetric = _readString(body['metric_key'] ?? body['metricKey']);
    final value = _readPositiveNumber(
      body['override_value'] ?? body['overrideValue'],
    );
    if (rawScope == null) {
      return _bodyError('missing_scope_type', 'scope_type is required');
    }
    if (rawMetric == null ||
        !kBenchmarkOverrideMetricKeys.contains(rawMetric)) {
      return _bodyError(
        'invalid_metric_key',
        'metric_key must be target_cplh, target_splh, or target_ppa',
      );
    }
    if (value == null) {
      return _bodyError(
        'invalid_override_value',
        'override_value must be a positive number',
      );
    }
    final BenchmarkOverrideScopeType scopeType;
    try {
      scopeType = BenchmarkOverrideScopeType.parse(rawScope);
    } on ArgumentError {
      return _bodyError(
        'invalid_scope_type',
        'scope_type must be operator_wide, org_unit, or location',
      );
    }
    final effectiveFrom = _readDate(
      body['effective_from'] ?? body['effectiveFrom'],
    );
    return (
      error: null,
      scopeType: scopeType,
      orgUnitId: _readString(body['org_unit_id'] ?? body['orgUnitId']),
      locationId: _readString(body['location_id'] ?? body['locationId']),
      metricKey: rawMetric,
      overrideValue: value,
      effectiveFrom: effectiveFrom,
    );
  }

  ({
    ({int statusCode, Map<String, Object?> body})? error,
    BenchmarkOverrideScopeType? scopeType,
    String? orgUnitId,
    String? locationId,
    String? metricKey,
    double? overrideValue,
    DateTime? effectiveFrom,
  })
  _bodyError(String code, String message) {
    return (
      error: (
        statusCode: 400,
        body: <String, Object?>{'error': code, 'message': message},
      ),
      scopeType: null,
      orgUnitId: null,
      locationId: null,
      metricKey: null,
      overrideValue: null,
      effectiveFrom: null,
    );
  }

  Map<String, Object?> _auditPayload(BenchmarkOverrideMutationResult result) {
    final row = result.override;
    final previous = result.previous;
    return <String, Object?>{
      'override_id': row.overrideId,
      'scope_type': row.scopeType.wire,
      'target_id': row.scopeId,
      'scope_id': row.scopeId,
      'org_unit_id': row.orgUnitId,
      'location_id': row.locationId,
      'metric_key': row.metricKey,
      'prev_value': previous?.value,
      'new_value': result.cleared ? null : row.value,
      'override_value': row.value,
      'cleared': result.cleared,
    };
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim().toLowerCase();
    return trimmed.isEmpty ? null : trimmed;
  }

  static double? _readPositiveNumber(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
    return parsed;
  }

  static DateTime? _readDate(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim())?.toUtc();
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
