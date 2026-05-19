// Phase 11A.1 - Operator + location admin gateway.
//
// Translates UI-side commands into proxy `/v1/admin/operators` and
// `/v1/admin/locations` HTTP calls. The admin Flutter client never
// holds a Postgres connection string and never reaches the database
// directly - every read/write flows through the F&F admin proxy.
//
// Two implementations ship in this slice:
//
//   * [HttpOperatorLocationAdminGateway] - production. POST/PATCH/
//     GET/DELETE against the proxy with the signed-in admin's bearer
//     token. The bearer source is injected so production can hand
//     it the Firebase ID token stream while tests can pin a fixed
//     value.
//
//   * [InMemoryOperatorLocationAdminGateway] - demo + widget tests.
//     Mutates an in-memory collection so the admin screen can run
//     end-to-end in `kDemoMode` without a backend.
//
// All payload shapes mirror the proxy contract documented in
// `tool/advisor_proxy/advisor_proxy.dart` 11A.1 route handlers.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/operator_location_admin_models.dart';
import 'admin_http_timeout.dart';

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token stream;
/// tests pin a synthetic value.
typedef AdminBearerTokenProvider = Future<String> Function();

void _validateParentOrgUnitId(String? value) {
  if (value == null || value.trim().isEmpty) {
    throw const OperatorLocationAdminGatewayError(
      statusCode: 400,
      errorCode: 'missing_parent_org_unit_id',
      message: 'parent_org_unit_id is required when creating a location',
    );
  }
}

/// Top-level error type for gateway calls. Carries an HTTP-style
/// status code + machine-readable error code so the screen can branch
/// on `permission_denied` / `validation_failed` etc. without parsing
/// `message`.
class OperatorLocationAdminGatewayError implements Exception {
  const OperatorLocationAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final int statusCode;
  final String errorCode;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() =>
      'OperatorLocationAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class OperatorLocationAdminGateway {
  Future<List<OperatorAdminBundle>> listOperators();
  Future<OperatorAdminBundle> onboardOperator(OperatorOnboardCommand command);
  Future<OperatorAdminRecord> patchOperator(OperatorPatchCommand command);
  Future<OperatorAdminRecord> suspendOperator(
    String operatorId, {
    required String idempotencyKey,
  });
  Future<OperatorAdminRecord> reactivateOperator(
    String operatorId, {
    required String idempotencyKey,
  });
  Future<LocationAdminRecord> addLocation(LocationCreateCommand command);
  Future<LocationAdminRecord> patchLocation(LocationPatchCommand command);
  Future<void> removeLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  });
}

class HttpOperatorLocationAdminGateway implements OperatorLocationAdminGateway {
  HttpOperatorLocationAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`). The
  /// gateway resolves `/v1/admin/operators` and `/v1/admin/locations`
  /// against this.
  final Uri baseUri;
  final AdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String operatorsPath = '/v1/admin/operators';
  static const String locationsPath = '/v1/admin/locations';

  // Idempotency key generation lives in the screen layer
  // (`_OperatorLocationAdminScreenState._nextIdempotencyKey`) so a
  // single minted key flows through both the dialog → command → gateway
  // path and the action handler. Keeping the minter here too would
  // double-mint keys for the same user action.

  @override
  Future<List<OperatorAdminBundle>> listOperators() async {
    final body = await _send(method: 'GET', path: operatorsPath);
    final list = (body['operators'] as List?) ?? const [];
    return <OperatorAdminBundle>[
      for (final entry in list)
        OperatorAdminBundle.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<OperatorAdminBundle> onboardOperator(
    OperatorOnboardCommand command,
  ) async {
    final body = await _send(
      method: 'POST',
      path: operatorsPath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: _withAdminReason(
        command.toJson(),
        'admin.operator_location.onboard',
      ),
    );
    return OperatorAdminBundle.fromJson(body);
  }

  @override
  Future<OperatorAdminRecord> patchOperator(
    OperatorPatchCommand command,
  ) async {
    final body = await _send(
      method: 'PATCH',
      path: '$operatorsPath/${Uri.encodeComponent(command.operatorId)}',
      idempotencyKey: command.idempotencyKey,
      jsonBody: _withAdminReason(
        command.toJson(),
        'admin.operator_location.patch_operator',
      ),
    );
    return OperatorAdminRecord.fromJson(
      (body['operator'] as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<OperatorAdminRecord> suspendOperator(
    String operatorId, {
    required String idempotencyKey,
  }) async {
    final body = await _send(
      method: 'POST',
      path: '$operatorsPath/${Uri.encodeComponent(operatorId)}/suspend',
      idempotencyKey: idempotencyKey,
      jsonBody: _withAdminReason(
        const <String, Object?>{},
        'admin.operator_location.suspend',
      ),
    );
    return OperatorAdminRecord.fromJson(
      (body['operator'] as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<OperatorAdminRecord> reactivateOperator(
    String operatorId, {
    required String idempotencyKey,
  }) async {
    final body = await _send(
      method: 'POST',
      path: '$operatorsPath/${Uri.encodeComponent(operatorId)}/reactivate',
      idempotencyKey: idempotencyKey,
      jsonBody: _withAdminReason(
        const <String, Object?>{},
        'admin.operator_location.reactivate',
      ),
    );
    return OperatorAdminRecord.fromJson(
      (body['operator'] as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<LocationAdminRecord> addLocation(LocationCreateCommand command) async {
    _validateParentOrgUnitId(command.parentOrgUnitId);
    final body = await _send(
      method: 'POST',
      path: locationsPath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: _withAdminReason(
        command.toJson(),
        'admin.operator_location.add_location',
      ),
    );
    return LocationAdminRecord.fromJson(
      (body['location'] as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<LocationAdminRecord> patchLocation(
    LocationPatchCommand command,
  ) async {
    final body = await _send(
      method: 'PATCH',
      path: '$locationsPath/${Uri.encodeComponent(command.locationId)}',
      idempotencyKey: command.idempotencyKey,
      jsonBody: _withAdminReason(
        command.toJson(),
        'admin.operator_location.patch_location',
      ),
    );
    return LocationAdminRecord.fromJson(
      (body['location'] as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<void> removeLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  }) async {
    await _send(
      method: 'DELETE',
      path: '$locationsPath/${Uri.encodeComponent(locationId)}',
      idempotencyKey: idempotencyKey,
      jsonBody: _withAdminReason(<String, Object?>{
        'operator_id': operatorId,
      }, 'admin.operator_location.remove_location'),
    );
  }

  Map<String, Object?> _withAdminReason(
    Map<String, Object?> body,
    String adminReason,
  ) => <String, Object?>{...body, 'admin_reason': adminReason};

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw OperatorLocationAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin operator/location proxy timed out after '
            '${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        parsed = decoded.cast<String, Object?>();
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    throw OperatorLocationAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ?? 'admin proxy returned an error',
      details: parsed,
    );
  }
}

/// In-memory gateway used by the demo walkthrough and widget tests.
/// Persists nothing across runs - every construction starts from
/// [seed]. Validation rules mirror the proxy:
///
///   * IANA timezone validation on every location write.
///   * legacy create-time `business_day_rollover_hour` 0–23.
///     PATCH rollover writes are retired; Business Timing owns edits.
///   * `preferred_currency` exactly three uppercase letters.
///   * Cannot remove a location that is the operator's
///     `primary_location_id`.
class InMemoryOperatorLocationAdminGateway
    implements OperatorLocationAdminGateway {
  InMemoryOperatorLocationAdminGateway({
    Iterable<OperatorAdminBundle> seed = const <OperatorAdminBundle>[],
    DateTime Function()? now,
    String Function()? idGenerator,
  }) : _now = now ?? DateTime.now,
       _idGenerator = idGenerator ?? _randomId,
       _bundles = <String, _MutableBundle>{
         for (final bundle in seed)
           bundle.operator.operatorId: _MutableBundle.from(bundle),
       };

  final DateTime Function() _now;
  final String Function() _idGenerator;
  final Map<String, _MutableBundle> _bundles;

  /// Per-key cache so a retried mutation on the in-memory gateway
  /// returns the prior result instead of mutating again - mirrors the
  /// proxy's `admin_request_idempotency` backstop.
  final Map<String, Object> _idempotentResults = <String, Object>{};

  @override
  Future<List<OperatorAdminBundle>> listOperators() async {
    final list = _bundles.values.map((b) => b.toBundle()).toList()
      ..sort(
        (a, b) => a.operator.businessName.toLowerCase().compareTo(
          b.operator.businessName.toLowerCase(),
        ),
      );
    return list;
  }

  @override
  Future<OperatorAdminBundle> onboardOperator(
    OperatorOnboardCommand command,
  ) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached is OperatorAdminBundle) return cached;
    _validateCurrency(command.preferredCurrency);
    _validateTimezone(command.primaryLocationTimezone);
    _validateRolloverHour(command.primaryLocationRolloverHour);
    _validateNonBlank(command.businessName, field: 'business_name');
    _validateNonBlank(command.ownerEmail, field: 'owner_email');
    _validateNonBlank(command.adminUserEmail, field: 'admin_user_email');
    _validateNonBlank(
      command.primaryLocationName,
      field: 'primary_location.name',
    );

    final operatorId = _idGenerator();
    final locationId = _idGenerator();
    final ts = _now().toUtc();
    final operator = OperatorAdminRecord(
      operatorId: operatorId,
      businessName: command.businessName.trim(),
      ownerEmail: command.ownerEmail.trim(),
      subscriptionTier: command.subscriptionTier,
      preferredCurrency: command.preferredCurrency.toUpperCase(),
      primaryLocationId: locationId,
      suspendedAt: null,
      createdAt: ts,
      updatedAt: ts,
    );
    final location = LocationAdminRecord(
      locationId: locationId,
      operatorId: operatorId,
      name: command.primaryLocationName.trim(),
      address: '',
      timezone: command.primaryLocationTimezone,
      businessDayRolloverHour: command.primaryLocationRolloverHour,
      createdAt: ts,
      updatedAt: ts,
    );
    final bundle = _MutableBundle(
      operator: operator,
      locations: <LocationAdminRecord>[location],
    );
    _bundles[operatorId] = bundle;
    final result = bundle.toBundle();
    _idempotentResults[command.idempotencyKey] = result;
    return result;
  }

  @override
  Future<OperatorAdminRecord> patchOperator(
    OperatorPatchCommand command,
  ) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached is OperatorAdminRecord) return cached;
    final bundle = _bundleOrThrow(command.operatorId);
    if (command.preferredCurrency != null) {
      _validateCurrency(command.preferredCurrency!);
    }
    final updated = OperatorAdminRecord(
      operatorId: bundle.operator.operatorId,
      businessName:
          command.businessName?.trim() ?? bundle.operator.businessName,
      ownerEmail: command.ownerEmail?.trim() ?? bundle.operator.ownerEmail,
      subscriptionTier:
          command.subscriptionTier ?? bundle.operator.subscriptionTier,
      preferredCurrency:
          command.preferredCurrency?.toUpperCase() ??
          bundle.operator.preferredCurrency,
      primaryLocationId:
          command.primaryLocationId ?? bundle.operator.primaryLocationId,
      suspendedAt: bundle.operator.suspendedAt,
      createdAt: bundle.operator.createdAt,
      updatedAt: _now().toUtc(),
    );
    if (updated.primaryLocationId != null &&
        bundle.locations.every(
          (l) => l.locationId != updated.primaryLocationId,
        )) {
      throw const OperatorLocationAdminGatewayError(
        statusCode: 400,
        errorCode: 'unknown_primary_location',
        message: 'primary_location_id does not belong to operator',
      );
    }
    bundle.operator = updated;
    _idempotentResults[command.idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<OperatorAdminRecord> suspendOperator(
    String operatorId, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotentResults[idempotencyKey];
    if (cached is OperatorAdminRecord) return cached;
    final bundle = _bundleOrThrow(operatorId);
    final updated = _copyOperator(
      bundle.operator,
      suspendedAt: _now().toUtc(),
      updatedAt: _now().toUtc(),
    );
    bundle.operator = updated;
    _idempotentResults[idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<OperatorAdminRecord> reactivateOperator(
    String operatorId, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotentResults[idempotencyKey];
    if (cached is OperatorAdminRecord) return cached;
    final bundle = _bundleOrThrow(operatorId);
    final updated = _copyOperator(
      bundle.operator,
      suspendedAt: null,
      clearSuspended: true,
      updatedAt: _now().toUtc(),
    );
    bundle.operator = updated;
    _idempotentResults[idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<LocationAdminRecord> addLocation(LocationCreateCommand command) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached is LocationAdminRecord) return cached;
    _validateParentOrgUnitId(command.parentOrgUnitId);
    _validateTimezone(command.timezone);
    _validateRolloverHour(command.businessDayRolloverHour);
    _validateNonBlank(command.name, field: 'name');
    final bundle = _bundleOrThrow(command.operatorId);
    final ts = _now().toUtc();
    final location = LocationAdminRecord(
      locationId: _idGenerator(),
      operatorId: command.operatorId,
      parentOrgUnitId: command.parentOrgUnitId!.trim(),
      name: command.name.trim(),
      address: command.address,
      timezone: command.timezone,
      businessDayRolloverHour: command.businessDayRolloverHour,
      createdAt: ts,
      updatedAt: ts,
    );
    bundle.locations.add(location);
    _idempotentResults[command.idempotencyKey] = location;
    return location;
  }

  @override
  Future<LocationAdminRecord> patchLocation(
    LocationPatchCommand command,
  ) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached is LocationAdminRecord) return cached;
    if (command.timezone != null) _validateTimezone(command.timezone!);
    final bundle = _findLocationBundleOrThrow(command.locationId);
    final index = bundle.locations.indexWhere(
      (l) => l.locationId == command.locationId,
    );
    final existing = bundle.locations[index];
    final updated = LocationAdminRecord(
      locationId: existing.locationId,
      operatorId: existing.operatorId,
      parentOrgUnitId: existing.parentOrgUnitId,
      name: command.name?.trim() ?? existing.name,
      address: command.address ?? existing.address,
      timezone: command.timezone ?? existing.timezone,
      businessDayRolloverHour: existing.businessDayRolloverHour,
      suspendedAt: existing.suspendedAt,
      deletedAt: existing.deletedAt,
      createdAt: existing.createdAt,
      updatedAt: _now().toUtc(),
    );
    bundle.locations[index] = updated;
    _idempotentResults[command.idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<void> removeLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  }) async {
    if (_idempotentResults.containsKey(idempotencyKey)) return;
    final bundle = _bundleOrThrow(operatorId);
    if (bundle.operator.primaryLocationId == locationId) {
      throw const OperatorLocationAdminGatewayError(
        statusCode: 400,
        errorCode: 'cannot_remove_primary_location',
        message: 'reassign primary_location_id before removing this location',
      );
    }
    final removed = bundle.locations
        .where((l) => l.locationId != locationId)
        .toList();
    if (removed.length == bundle.locations.length) {
      throw const OperatorLocationAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_location',
        message: 'location not found',
      );
    }
    bundle.locations
      ..clear()
      ..addAll(removed);
    // Sentinel value - `removeLocation` returns void so any non-null
    // marker suffices for the cache hit branch above.
    _idempotentResults[idempotencyKey] = const Object();
  }

  _MutableBundle _bundleOrThrow(String operatorId) {
    final bundle = _bundles[operatorId];
    if (bundle == null) {
      throw const OperatorLocationAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_operator',
        message: 'operator not found',
      );
    }
    return bundle;
  }

  _MutableBundle _findLocationBundleOrThrow(String locationId) {
    for (final bundle in _bundles.values) {
      if (bundle.locations.any((l) => l.locationId == locationId)) {
        return bundle;
      }
    }
    throw const OperatorLocationAdminGatewayError(
      statusCode: 404,
      errorCode: 'unknown_location',
      message: 'location not found',
    );
  }

  static void _validateCurrency(String currency) {
    final pattern = RegExp(r'^[A-Z]{3}$');
    if (!pattern.hasMatch(currency.toUpperCase())) {
      throw const OperatorLocationAdminGatewayError(
        statusCode: 400,
        errorCode: 'invalid_preferred_currency',
        message: 'preferred_currency must be a 3-letter ISO code',
      );
    }
  }

  static void _validateTimezone(String timezone) {
    if (!isLikelyIanaTimezone(timezone)) {
      throw const OperatorLocationAdminGatewayError(
        statusCode: 400,
        errorCode: 'invalid_timezone',
        message: 'timezone must be a valid IANA name (e.g. America/Toronto)',
      );
    }
  }

  static void _validateRolloverHour(int hour) {
    if (hour < 0 || hour > 23) {
      throw const OperatorLocationAdminGatewayError(
        statusCode: 400,
        errorCode: 'invalid_rollover_hour',
        message: 'business_day_rollover_hour must be between 0 and 23',
      );
    }
  }

  static void _validateNonBlank(String value, {required String field}) {
    if (value.trim().isEmpty) {
      throw OperatorLocationAdminGatewayError(
        statusCode: 400,
        errorCode: 'missing_$field',
        message: '$field is required',
      );
    }
  }

  static OperatorAdminRecord _copyOperator(
    OperatorAdminRecord source, {
    DateTime? suspendedAt,
    bool clearSuspended = false,
    DateTime? updatedAt,
  }) {
    return OperatorAdminRecord(
      operatorId: source.operatorId,
      businessName: source.businessName,
      ownerEmail: source.ownerEmail,
      subscriptionTier: source.subscriptionTier,
      preferredCurrency: source.preferredCurrency,
      primaryLocationId: source.primaryLocationId,
      suspendedAt: clearSuspended ? null : (suspendedAt ?? source.suspendedAt),
      createdAt: source.createdAt,
      updatedAt: updatedAt ?? source.updatedAt,
    );
  }

  static int _idCounter = 0;
  static String _randomId() {
    _idCounter += 1;
    final hex = _idCounter.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-8000-$hex';
  }
}

class _MutableBundle {
  _MutableBundle({
    required this.operator,
    required List<LocationAdminRecord> locations,
  }) : locations = List<LocationAdminRecord>.from(locations);

  factory _MutableBundle.from(OperatorAdminBundle bundle) {
    return _MutableBundle(
      operator: bundle.operator,
      locations: bundle.locations,
    );
  }

  OperatorAdminRecord operator;
  final List<LocationAdminRecord> locations;

  OperatorAdminBundle toBundle() => OperatorAdminBundle(
    operator: operator,
    locations: List<LocationAdminRecord>.unmodifiable(locations),
  );
}
