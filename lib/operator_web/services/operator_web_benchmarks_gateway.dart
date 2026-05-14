import '../../services/baseline/benchmark_override_resolver.dart';
import 'operator_web_proxy_client.dart';

const String kOperatorWebBenchmarkOverridesPath =
    '/v1/operator/benchmarks/overrides';
const String kOperatorWebBenchmarkOverridesPrefix =
    '$kOperatorWebBenchmarkOverridesPath/';

/// RP-15 — cap-status read path mirrors the proxy contract
/// (`tool/advisor_proxy/operator_benchmark_overrides_routes.dart`).
const String kOperatorWebBenchmarkOverrideCapStatusPath =
    '/v1/operator/benchmarks/overrides/cap-status';

/// RP-15 — admin-undo suffix mirrors the proxy contract. Appended to
/// `/v1/operator/benchmarks/overrides/{id}` to invoke admin-undo with
/// a distinct audit event.
const String kOperatorWebBenchmarkOverrideAdminUndoSuffix = '/admin-undo';

/// Manager-once cap tier reported back to the operator-web Benchmarks
/// screen. Mirrors the proxy enum (admin = unlimited, manager = capped,
/// none = blocked by upstream role gate).
enum OperatorWebBenchmarkOverrideCapTier {
  admin,
  manager,
  none;

  static OperatorWebBenchmarkOverrideCapTier parse(String raw) {
    return switch (raw) {
      'admin' => OperatorWebBenchmarkOverrideCapTier.admin,
      'manager' => OperatorWebBenchmarkOverrideCapTier.manager,
      _ => OperatorWebBenchmarkOverrideCapTier.none,
    };
  }
}

/// Cap-status snapshot for the operator-web Benchmarks screen.
class OperatorWebBenchmarkOverrideCapStatus {
  const OperatorWebBenchmarkOverrideCapStatus({
    required this.tier,
    required this.limit,
    required this.used,
    required this.remaining,
  });

  final OperatorWebBenchmarkOverrideCapTier tier;
  final int limit;
  final int used;
  final int remaining;

  bool get isAdmin =>
      tier == OperatorWebBenchmarkOverrideCapTier.admin;
  bool get isCapped =>
      tier == OperatorWebBenchmarkOverrideCapTier.manager && remaining <= 0;

  static OperatorWebBenchmarkOverrideCapStatus fromJson(
    Map<String, Object?> json,
  ) {
    return OperatorWebBenchmarkOverrideCapStatus(
      tier: OperatorWebBenchmarkOverrideCapTier.parse(
        (json['tier'] as String?) ?? 'none',
      ),
      limit: (json['limit'] as num?)?.toInt() ?? 0,
      used: (json['used'] as num?)?.toInt() ?? 0,
      remaining: (json['remaining'] as num?)?.toInt() ?? 0,
    );
  }
}

abstract class OperatorWebBenchmarksGateway {
  Future<List<BenchmarkOverrideCandidate>> listOverrides({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  });

  /// RP-15 — returns the actor's manager-once cap status so the
  /// Benchmarks screen can render "you can override this benchmark N
  /// more times this month" before the operator taps Save.
  Future<OperatorWebBenchmarkOverrideCapStatus> getCapStatus({
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

  /// RP-15 — admin-undo of a manager-set override. Writes the
  /// `admin.benchmark_override_undone` audit event with the original
  /// manager + override ids. Manager-tier callers get 403 from the
  /// proxy.
  Future<BenchmarkOverrideCandidate?> adminUndoOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
    String? undoReason,
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

  @override
  Future<OperatorWebBenchmarkOverrideCapStatus> getCapStatus({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    final token = await _requireToken();
    final response = await _client.getJson(
      kOperatorWebBenchmarkOverrideCapStatusPath,
      idToken: token,
    );
    final raw = response.body['cap'];
    if (raw is! Map<Object?, Object?>) {
      throw const OperatorWebProxyException(
        code: 'malformed_benchmark_cap_status',
        message: 'The proxy returned a malformed cap-status payload.',
      );
    }
    return OperatorWebBenchmarkOverrideCapStatus.fromJson(
      Map<String, Object?>.from(raw),
    );
  }

  @override
  Future<BenchmarkOverrideCandidate?> adminUndoOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
    String? undoReason,
  }) async {
    final token = await _requireToken();
    final path =
        '$kOperatorWebBenchmarkOverridesPrefix${Uri.encodeComponent(overrideId)}'
        '$kOperatorWebBenchmarkOverrideAdminUndoSuffix';
    final response = await _client.deleteJson(
      path,
      idToken: token,
      body: <String, Object?>{
        if (undoReason != null && undoReason.trim().isNotEmpty)
          'undo_reason': undoReason.trim(),
      },
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
  DemoOperatorWebBenchmarksGateway({
    this.actorRoles = const <String>{'operator_owner'},
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  /// Demo-mode roles for the signed-in operator. The demo session is
  /// owner-by-default; tests override this to exercise manager-tier
  /// cap behavior without touching the proxy. Honors HP #2: same code
  /// path applies the cap policy in demo and prod.
  final Set<String> actorRoles;

  /// Manager-tier role keys; mirrors the proxy
  /// `BenchmarkOverrideCapPolicy.managerTierRoles`. Duplicated here
  /// rather than imported so the demo gateway stays in the
  /// `lib/operator_web/services/` Layer-9 boundary (Layer-12 proxy
  /// helpers are intentionally not visible to operator-web Dart).
  static const Set<String> _managerTierRoles = <String>{
    'location_manager',
    'supervisor',
  };
  static const Set<String> _adminTierRoles = <String>{
    'operator_owner',
    'operator_admin',
    'operator_general_manager',
    'super_admin',
  };
  static const int _managerMonthlyLimit = 1;

  final DateTime Function() _now;
  final List<BenchmarkOverrideCandidate> _rows =
      <BenchmarkOverrideCandidate>[];
  final List<BenchmarkOverrideCandidate> _history =
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
  Future<OperatorWebBenchmarkOverrideCapStatus> getCapStatus({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    final tier = _tier(actorRoles);
    if (tier == OperatorWebBenchmarkOverrideCapTier.admin) {
      return const OperatorWebBenchmarkOverrideCapStatus(
        tier: OperatorWebBenchmarkOverrideCapTier.admin,
        limit: -1,
        used: 0,
        remaining: -1,
      );
    }
    final used = _countUserOverridesThisMonth(actorUserId);
    final remaining = _managerMonthlyLimit - used;
    return OperatorWebBenchmarkOverrideCapStatus(
      tier: tier,
      limit: _managerMonthlyLimit,
      used: used,
      remaining: remaining < 0 ? 0 : remaining,
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
  }) async {
    // HP #2: demo gateway honors the manager-once cap so a demo
    // manager user sees the same 409 the proxy returns in prod.
    final tier = _tier(actorRoles);
    if (tier == OperatorWebBenchmarkOverrideCapTier.manager) {
      final used = _countUserOverridesThisMonth(actorUserId);
      if (used >= _managerMonthlyLimit) {
        throw const OperatorWebProxyException(
          statusCode: 409,
          code: 'manager_override_cap_reached',
          message:
              'You have already set a benchmark override this month. '
                  'Ask your admin to undo or extend the existing override.',
        );
      }
    }

    final now = _now().toUtc();
    for (var i = 0; i < _rows.length; i += 1) {
      final row = _rows[i];
      final sameScope = row.metricKey == metricKey &&
          row.scopeType == scopeType &&
          row.orgUnitId == orgUnitId &&
          row.locationId == targetLocationId &&
          row.isCurrent;
      if (sameScope) {
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
        _history.add(closed);
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
    return _close(overrideId);
  }

  @override
  Future<BenchmarkOverrideCandidate?> adminUndoOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
    String? undoReason,
  }) async {
    if (_tier(actorRoles) != OperatorWebBenchmarkOverrideCapTier.admin) {
      throw const OperatorWebProxyException(
        statusCode: 403,
        code: 'admin_role_required',
        message:
            'Only owners, general managers, or F&F super admins may '
                'undo a manager-set benchmark override.',
      );
    }
    return _close(overrideId);
  }

  BenchmarkOverrideCandidate? _close(String overrideId) {
    final now = _now().toUtc();
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
        _history.add(closed);
        return closed;
      }
    }
    return null;
  }

  int _countUserOverridesThisMonth(String actorUserId) {
    final ref = _now().toUtc();
    var count = 0;
    for (final row in <BenchmarkOverrideCandidate>[..._rows, ..._history]) {
      if (row.createdBy != actorUserId) continue;
      final ef = row.effectiveFrom.toUtc();
      if (ef.year == ref.year && ef.month == ref.month) {
        count += 1;
      }
    }
    return count;
  }

  static OperatorWebBenchmarkOverrideCapTier _tier(Set<String> roles) {
    if (roles.any(_adminTierRoles.contains)) {
      return OperatorWebBenchmarkOverrideCapTier.admin;
    }
    if (roles.any(_managerTierRoles.contains)) {
      return OperatorWebBenchmarkOverrideCapTier.manager;
    }
    return OperatorWebBenchmarkOverrideCapTier.none;
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
