import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart';
import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';

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

class OperatorBenchmarkOverridesRouter {
  OperatorBenchmarkOverridesRouter({
    required this.gateway,
    required this.auditSink,
    OperatorWriteIdempotencyCache? idempotencyCache,
    DateTime Function()? now,
  }) : _idempotencyCache = idempotencyCache ?? OperatorWriteIdempotencyCache(),
       _now = now ?? DateTime.now;

  final OperatorBenchmarkOverridesGateway gateway;
  final OperatorWriteAuditSink auditSink;
  final OperatorWriteIdempotencyCache _idempotencyCache;
  final DateTime Function() _now;

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
