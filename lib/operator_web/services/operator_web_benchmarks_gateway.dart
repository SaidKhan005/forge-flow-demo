import '../../services/baseline/benchmark_override_resolver.dart';
import 'operator_web_proxy_client.dart';

const String kOperatorWebBenchmarkOverridesPath =
    '/v1/operator/benchmarks/overrides';
const String kOperatorWebBenchmarkOverridesPrefix =
    '$kOperatorWebBenchmarkOverridesPath/';

abstract class OperatorWebBenchmarksGateway {
  Future<List<BenchmarkOverrideCandidate>> listOverrides({
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
  });

  Future<BenchmarkOverrideCandidate?> clearOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
  });
}

abstract class OperatorWebBenchmarksGatewayProvider {
  OperatorWebBenchmarksGateway get benchmarksGateway;
}

class OperatorWebHttpBenchmarksGateway implements OperatorWebBenchmarksGateway {
  OperatorWebHttpBenchmarksGateway({
    required OperatorWebProxyClient client,
    required Future<String?> Function() idTokenProvider,
  }) : _client = client,
       _idTokenProvider = idTokenProvider;

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;

  @override
  Future<List<BenchmarkOverrideCandidate>> listOverrides({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    final token = await _requireToken();
    final response = await _client.getJson(
      kOperatorWebBenchmarkOverridesPath,
      idToken: token,
    );
    final raw = response.body['overrides'];
    if (raw is! List<Object?>) {
      throw const OperatorWebProxyException(
        code: 'malformed_benchmark_overrides',
        message: 'The proxy returned malformed benchmark overrides.',
      );
    }
    return <BenchmarkOverrideCandidate>[
      for (final row in raw)
        if (row is Map<Object?, Object?>)
          _candidateFromJson(Map<String, Object?>.from(row)),
    ];
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
  }) async {
    final token = await _requireToken();
    final response = await _client.postJson(
      kOperatorWebBenchmarkOverridesPath,
      idToken: token,
      body: <String, Object?>{
        'scope_type': scopeType.wire,
        'org_unit_id': orgUnitId,
        'location_id': targetLocationId,
        'metric_key': metricKey,
        'override_value': overrideValue,
      },
    );
    return _readOverride(response.body);
  }

  @override
  Future<BenchmarkOverrideCandidate?> clearOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
  }) async {
    final token = await _requireToken();
    final response = await _client.deleteJson(
      '$kOperatorWebBenchmarkOverridesPrefix${Uri.encodeComponent(overrideId)}',
      idToken: token,
    );
    final raw = response.body['override'];
    if (raw == null) return null;
    if (raw is! Map<Object?, Object?>) {
      throw const OperatorWebProxyException(
        code: 'malformed_benchmark_override',
        message: 'The proxy returned a malformed benchmark override.',
      );
    }
    return _candidateFromJson(Map<String, Object?>.from(raw));
  }

  Future<String> _requireToken() async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebProxyException(
        statusCode: 401,
        code: 'unauthenticated',
        message: 'Sign in again to edit benchmark overrides.',
      );
    }
    return token.trim();
  }

  static BenchmarkOverrideCandidate _readOverride(
    Map<String, Object?> body,
  ) {
    final raw = body['override'];
    if (raw is! Map<Object?, Object?>) {
      throw const OperatorWebProxyException(
        code: 'malformed_benchmark_override',
        message: 'The proxy returned a malformed benchmark override.',
      );
    }
    return _candidateFromJson(Map<String, Object?>.from(raw));
  }
}

class DemoOperatorWebBenchmarksGateway implements OperatorWebBenchmarksGateway {
  final List<BenchmarkOverrideCandidate> _rows =
      <BenchmarkOverrideCandidate>[];
  int _sequence = 1;

  @override
  Future<List<BenchmarkOverrideCandidate>> listOverrides({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    return _rows.where((row) => row.isCurrent).toList(growable: false);
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
  }) async {
    final now = DateTime.now().toUtc();
    for (var i = 0; i < _rows.length; i += 1) {
      final row = _rows[i];
      final sameScope = row.metricKey == metricKey &&
          row.scopeType == scopeType &&
          row.orgUnitId == orgUnitId &&
          row.locationId == targetLocationId &&
          row.isCurrent;
      if (sameScope) {
        _rows[i] = BenchmarkOverrideCandidate(
          overrideId: row.overrideId,
          operatorId: row.operatorId,
          scopeType: row.scopeType,
          orgUnitId: row.orgUnitId,
          locationId: row.locationId,
          metricKey: row.metricKey,
          value: row.value,
          effectiveFrom: row.effectiveFrom,
          effectiveUntil: now,
          createdBy: row.createdBy,
          sourceLabel: row.sourceLabel,
        );
      }
    }
    final row = BenchmarkOverrideCandidate(
      overrideId: 'demo-benchmark-${_sequence++}',
      operatorId: operatorId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: targetLocationId,
      metricKey: metricKey,
      value: overrideValue,
      effectiveFrom: now,
      effectiveUntil: null,
      createdBy: actorUserId,
      sourceLabel: _sourceLabel(scopeType),
    );
    _rows.add(row);
    return row;
  }

  @override
  Future<BenchmarkOverrideCandidate?> clearOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
  }) async {
    final now = DateTime.now().toUtc();
    for (var i = 0; i < _rows.length; i += 1) {
      final row = _rows[i];
      if (row.overrideId == overrideId && row.isCurrent) {
        final closed = BenchmarkOverrideCandidate(
          overrideId: row.overrideId,
          operatorId: row.operatorId,
          scopeType: row.scopeType,
          orgUnitId: row.orgUnitId,
          locationId: row.locationId,
          metricKey: row.metricKey,
          value: row.value,
          effectiveFrom: row.effectiveFrom,
          effectiveUntil: now,
          createdBy: row.createdBy,
          sourceLabel: row.sourceLabel,
        );
        _rows[i] = closed;
        return closed;
      }
    }
    return null;
  }

  static String _sourceLabel(BenchmarkOverrideScopeType type) {
    return switch (type) {
      BenchmarkOverrideScopeType.operatorWide => 'Business',
      BenchmarkOverrideScopeType.orgUnit => 'Org unit',
      BenchmarkOverrideScopeType.location => 'Location',
      BenchmarkOverrideScopeType.fallback => 'Target cycle',
    };
  }
}

BenchmarkOverrideCandidate _candidateFromJson(Map<String, Object?> json) {
  return BenchmarkOverrideCandidate(
    overrideId: _requiredString(json, 'override_id'),
    operatorId: _requiredString(json, 'operator_id'),
    scopeType: BenchmarkOverrideScopeType.parse(
      _requiredString(json, 'scope_type'),
    ),
    orgUnitId: _optionalString(json, 'org_unit_id'),
    locationId: _optionalString(json, 'location_id'),
    metricKey: _requiredString(json, 'metric_key'),
    value: _requiredDouble(json, 'override_value'),
    effectiveFrom: _requiredDate(json, 'effective_from'),
    effectiveUntil: _optionalDate(json, 'effective_until'),
    createdBy: _requiredString(json, 'created_by'),
    sourceLabel: _optionalString(json, 'source_label'),
  );
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  throw OperatorWebProxyException(
    code: 'malformed_benchmark_override',
    message: 'Benchmark override is missing $key.',
  );
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

double _requiredDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  if (value is String) return double.parse(value);
  throw OperatorWebProxyException(
    code: 'malformed_benchmark_override',
    message: 'Benchmark override is missing $key.',
  );
}

DateTime _requiredDate(Map<String, Object?> json, String key) {
  final value = _optionalDate(json, key);
  if (value != null) return value;
  throw OperatorWebProxyException(
    code: 'malformed_benchmark_override',
    message: 'Benchmark override is missing $key.',
  );
}

DateTime? _optionalDate(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  return null;
}
