// Admin HTTP gateway for per-location vendor connections.
//
// This is intentionally separate from `IntegrationAdminGateway`, which backs
// global Connected services / platform key rotation. Vendor connection
// lifecycle remains location-only and talks to the Phase 8 admin route family.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'admin_http_timeout.dart';

typedef AdminVendorConnectionsBearerTokenProvider = Future<String> Function();

class AdminHttpVendorConnectionsGateway implements VendorConnectionsGateway {
  AdminHttpVendorConnectionsGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
    String Function()? idempotencyKeyFactory,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout,
       _idempotencyKeyFactory = idempotencyKeyFactory;

  final Uri baseUri;
  final AdminVendorConnectionsBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;
  final String Function()? _idempotencyKeyFactory;

  int _idempotencyCounter = 0;

  static final List<VendorPickerEntry> _catalog =
      InMemoryVendorConnectionsGateway.vendorCatalog;

  @override
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  }) async {
    final op = _requireScopeValue('operator', operatorId);
    final loc = _requireLocationId(locationId);
    final body = await _send(
      method: 'GET',
      path:
          '/v1/admin/operators/${_pathSegment(op)}/locations/'
          '${_pathSegment(loc)}/integrations',
    );
    return _bundleFromJson(body, operatorId: op, locationId: loc);
  }

  @override
  Future<List<VendorPickerEntry>> listAvailableVendors({
    required VendorCategory category,
  }) async {
    return _catalog
        .where((entry) => entry.category == category)
        .toList(growable: false);
  }

  @override
  Future<VendorConnectFlowStart> startConnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    String? module,
  }) async {
    final op = _requireScopeValue('operator', operatorId);
    final loc = _requireLocationId(locationId);
    final vendor = _requireScopeValue('vendor', vendorId);
    final entry = _catalog.firstWhere(
      (candidate) => candidate.vendorId == vendor,
      orElse: () => throw VendorConnectionsGatewayError(
        message: 'Unknown vendor: $vendor',
        remediation: 'Pick a vendor from the connection dialog.',
      ),
    );
    if (entry.authMode == VendorAuthMode.keyPaste) {
      return const VendorConnectFlowStart(
        redirectUrl: '',
        flowKind: VendorConnectFlowKind.keyPasteForm,
      );
    }
    final body = await _send(
      method: 'POST',
      path: '/v1/admin/integrations/oauth/${_pathSegment(vendor)}/start',
      jsonBody: <String, Object?>{
        'operator_id': op,
        'location_id': loc,
        if (_clean(module) != null) 'module': _clean(module),
      },
      idempotencyKey: _nextIdempotencyKey(),
    );
    final redirectUrl =
        _readString(body['redirect_url']) ??
        _readString(body['authorization_url']);
    if (redirectUrl == null) {
      throw VendorConnectionsGatewayError(
        message: 'The admin proxy did not return a connection URL.',
        remediation:
            'Select the location again and retry. If it repeats, check the '
            'admin integration OAuth route binding for this vendor.',
      );
    }
    return VendorConnectFlowStart(
      redirectUrl: redirectUrl,
      flowKind: VendorConnectFlowKind.oauthRedirect,
    );
  }

  @override
  Future<VendorApiKeyConnectResult> connectWithApiKey({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String apiKey,
    String? apiSecret,
    String? module,
  }) async {
    final op = _requireScopeValue('operator', operatorId);
    final loc = _requireLocationId(locationId);
    final vendor = _requireScopeValue('vendor', vendorId);
    final trimmedKey = _clean(apiKey);
    if (trimmedKey == null) {
      throw VendorConnectionsGatewayError(
        message: 'API key is required.',
        remediation: 'Paste the API key from the vendor portal and try again.',
      );
    }
    final body = await _send(
      method: 'POST',
      path: '/v1/admin/integrations/${_pathSegment(vendor)}/connect-key',
      jsonBody: <String, Object?>{
        'operator_id': op,
        'location_id': loc,
        'api_key': trimmedKey,
        if (_clean(apiSecret) != null) 'api_secret': _clean(apiSecret),
        if (_clean(module) != null) 'module': _clean(module),
      },
      idempotencyKey: _stableIdempotencyKey(
        'admin-vendor-connect-api-key',
        <Object?>[
          op,
          loc,
          vendor,
          <String, Object?>{
            'api_key': trimmedKey,
            if (_clean(apiSecret) != null) 'api_secret': _clean(apiSecret),
            if (_clean(module) != null) 'module': _clean(module),
          },
        ],
      ),
    );
    final connectionId =
        _readString(body['connection_id']) ??
        _readString(body['connector_connection_id']);
    if (connectionId == null) {
      throw VendorConnectionsGatewayError(
        message: 'The admin proxy did not return a connection id.',
        remediation:
            'Retry once. If it repeats, Forge & Flow support should check the '
            'admin connect-key route for this vendor.',
      );
    }
    final connectedAt =
        _readDate(body['connected_at']) ??
        _readDate(body['updated_at']) ??
        DateTime.now().toUtc();
    return VendorApiKeyConnectResult(
      connectionId: connectionId,
      connectedAt: connectedAt,
      firstBackfillStarted: _firstBackfillStarted(body),
    );
  }

  @override
  Future<VendorTestConnectionResult> testConnection({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    final op = _requireScopeValue('operator', operatorId);
    final loc = _requireLocationId(locationId);
    final vendor = _requireScopeValue('vendor', vendorId);
    final body = await _send(
      method: 'POST',
      path: '/v1/admin/integrations/${_pathSegment(vendor)}/test-connection',
      jsonBody: <String, Object?>{'operator_id': op, 'location_id': loc},
      idempotencyKey: _nextIdempotencyKey(),
    );
    final fieldMapping = <String, String>{};
    final rawMapping = body['field_mapping'];
    if (rawMapping is Map<Object?, Object?>) {
      rawMapping.forEach((key, value) {
        if (key is String && value != null) fieldMapping[key] = '$value';
      });
    }
    return VendorTestConnectionResult(
      authValid: body['auth_valid'] == true,
      elapsedMs: _readInt(body['elapsed_ms']) ?? 0,
      sampleSummary:
          _readString(body['sample_summary']) ?? 'No sample rows returned.',
      fieldMapping: Map<String, String>.unmodifiable(fieldMapping),
      note: _readString(body['note']),
    );
  }

  @override
  Future<void> disconnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String reason,
  }) async {
    final op = _requireScopeValue('operator', operatorId);
    final loc = _requireLocationId(locationId);
    final vendor = _requireScopeValue('vendor', vendorId);
    final cleanReason = _clean(reason) ?? 'operator_action';
    await _send(
      method: 'POST',
      path: '/v1/admin/integrations/${_pathSegment(vendor)}/disconnect',
      jsonBody: <String, Object?>{
        'operator_id': op,
        'location_id': loc,
        'reason': cleanReason,
      },
      idempotencyKey: _stableIdempotencyKey(
        'admin-vendor-disconnect',
        <Object?>[op, loc, vendor, cleanReason],
      ),
    );
  }

  @override
  Future<List<VendorSyncLogEntry>> loadLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async {
    throw VendorConnectionsGatewayError(
      message: 'Vendor sync logs are not available yet.',
      remediation: 'Vendor sync logs ship in a follow-up slice.',
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, Object?>? jsonBody,
    Map<String, String>? queryParameters,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path).replace(queryParameters: queryParameters);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer ${token.trim()}'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.trim().isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey.trim();
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
      throw VendorConnectionsGatewayError(
        statusCode: 408,
        message:
            'admin vendor integrations proxy timed out after '
            '${_timeout.inSeconds}s',
        remediation: 'Retry once. If it repeats, check the admin proxy logs.',
      );
    }

    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    throw VendorConnectionsGatewayError(
      statusCode: response.statusCode,
      message:
          _readString(parsed['message']) ??
          _readString(parsed['error']) ??
          'admin vendor integrations proxy returned an error',
      remediation:
          'Confirm a location scope is selected and retry. If it repeats, '
          'check the admin integration route logs.',
    );
  }

  String _nextIdempotencyKey() {
    final factory = _idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return 'admin-vendor-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  static String _stableIdempotencyKey(String action, List<Object?> parts) {
    final canonical = StringBuffer('admin:$action');
    for (final part in parts) {
      canonical.write('|');
      canonical.write(_canonicaliseIdempotencyPart(part));
    }
    final digest = sha256.convert(utf8.encode(canonical.toString()));
    return 'admin-$action-$digest';
  }

  static String _canonicaliseIdempotencyPart(Object? part) {
    if (part == null) return ' ';
    if (part is Map) {
      final sortedKeys =
          part.keys.map((key) => key.toString()).toList(growable: false)
            ..sort();
      return '{${sortedKeys.map((key) => '$key=${_canonicaliseIdempotencyPart(part[key])}').join(',')}}';
    }
    if (part is Iterable) {
      return '[${part.map(_canonicaliseIdempotencyPart).join(',')}]';
    }
    return part.toString();
  }

  static VendorConnectionsBundle _bundleFromJson(
    Map<String, Object?> body, {
    required String operatorId,
    required String locationId,
  }) {
    final connections = <VendorConnectionRow>[];
    final rawConnections = body['connections'] ?? body['connector_connections'];
    if (rawConnections is List) {
      for (final value in rawConnections) {
        if (value is Map<Object?, Object?>) {
          connections.add(_connectionFromJson(value));
        }
      }
    }
    VendorConnectionRow? byCategory(VendorCategory category) {
      for (final row in connections) {
        if (row.category == category) return row;
      }
      return null;
    }

    return VendorConnectionsBundle(
      operatorId: _readString(body['operator_id']) ?? operatorId,
      locationId: _readString(body['location_id']) ?? locationId,
      locationName:
          _readString(body['location_name']) ??
          _readString(body['locationLabel']) ??
          'Location $locationId',
      posConnection:
          _connectionFromTopLevel(body['pos_connection']) ??
          byCategory(VendorCategory.pos),
      laborConnection:
          _connectionFromTopLevel(body['labor_connection']) ??
          byCategory(VendorCategory.labor),
      reservationConnection:
          _connectionFromTopLevel(body['reservation_connection']) ??
          byCategory(VendorCategory.reservation),
      demoFlags: _demoFlagsFromJson(body['demo_flags']),
    );
  }

  static VendorConnectionRow? _connectionFromTopLevel(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    return _connectionFromJson(value);
  }

  static VendorConnectionRow _connectionFromJson(Map<Object?, Object?> raw) {
    final json = Map<Object?, Object?>.from(raw);
    final category = _categoryFromString(
      _readString(json['category']) ??
          _readString(json['integration_category']),
    );
    final vendorId = _readString(json['vendor_id']) ?? 'unknown_vendor';
    return VendorConnectionRow(
      connectionId:
          _readString(json['connection_id']) ??
          _readString(json['connector_connection_id']) ??
          'connection-$vendorId',
      vendorId: vendorId,
      displayName:
          _readString(json['display_name']) ??
          _readString(json['vendor_display_name']) ??
          _displayNameForVendor(vendorId),
      category: category,
      status: _statusFromString(_readString(json['status'])),
      metadata: json['metadata'] is Map<Object?, Object?>
          ? _stringKeyMap(json['metadata'] as Map<Object?, Object?>)
          : const <String, Object?>{},
      module: _readString(json['module']),
      lastSyncAt: _readDate(json['last_sync_at']),
      lastErrorMessage: _readString(json['last_error_message']),
      disconnectReason: _readString(json['disconnect_reason']),
      webhookUrl: _readString(json['webhook_url']),
      recordsLast24h: _readInt(json['records_last_24h']),
      errorsLast24h: _readInt(json['errors_last_24h']),
      firstBackfill: _firstBackfillFromJson(json['first_backfill']),
    );
  }

  static VendorConnectionFirstBackfill? _firstBackfillFromJson(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final status = _firstBackfillStatusFromString(_readString(raw['status']));
    if (status == null) return null;
    return VendorConnectionFirstBackfill(
      status: status,
      startedAt: _readDate(raw['started_at']),
      completedAt: _readDate(raw['completed_at']),
      failureReason: _readString(raw['failure_reason']),
      processedDays: _readInt(raw['processed_days']),
      totalDays: _readInt(raw['total_days']),
    );
  }

  static VendorConnectionFirstBackfillStatus? _firstBackfillStatusFromString(
    String? raw,
  ) {
    if (raw == null) return null;
    switch (raw.trim().toLowerCase()) {
      case 'pending':
        return VendorConnectionFirstBackfillStatus.pending;
      case 'running':
        return VendorConnectionFirstBackfillStatus.running;
      case 'succeeded':
        return VendorConnectionFirstBackfillStatus.succeeded;
      case 'failed':
        return VendorConnectionFirstBackfillStatus.failed;
      case 'dead_lettered':
      case 'deadlettered':
        return VendorConnectionFirstBackfillStatus.deadLettered;
      default:
        return null;
    }
  }

  static Map<String, Object?> _stringKeyMap(Map<Object?, Object?> raw) {
    final result = <String, Object?>{};
    raw.forEach((key, value) {
      if (key is String) result[key] = value;
    });
    return Map<String, Object?>.unmodifiable(result);
  }

  static Map<VendorCategory, bool> _demoFlagsFromJson(Object? value) {
    final flags = <VendorCategory, bool>{
      VendorCategory.pos: false,
      VendorCategory.labor: false,
      VendorCategory.reservation: false,
    };
    if (value is Map<Object?, Object?>) {
      value.forEach((key, flag) {
        final category = _categoryFromString(key is String ? key : '$key');
        flags[category] = flag == true;
      });
    }
    return Map<VendorCategory, bool>.unmodifiable(flags);
  }

  static VendorCategory _categoryFromString(String? raw) {
    switch (raw) {
      case 'labor':
      case 'scheduling':
        return VendorCategory.labor;
      case 'reservation':
      case 'reservations':
        return VendorCategory.reservation;
      case 'pos':
      case 'point_of_sale':
      default:
        return VendorCategory.pos;
    }
  }

  static VendorConnectionStatus _statusFromString(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'connected':
      case 'active':
        return VendorConnectionStatus.connected;
      case 'error':
      case 'failed':
        return VendorConnectionStatus.error;
      case 'disconnected':
      default:
        return VendorConnectionStatus.disconnected;
    }
  }

  static String _displayNameForVendor(String vendorId) {
    for (final entry in _catalog) {
      if (entry.vendorId == vendorId) return entry.displayName;
    }
    return vendorId.replaceAll('_', ' ');
  }

  static bool _firstBackfillStarted(Map<String, Object?> body) {
    final raw = body['first_backfill'];
    if (raw is Map<Object?, Object?>) {
      return raw['started'] == true;
    }
    return body['first_backfill_started'] == true;
  }

  static String _pathSegment(String value) => Uri.encodeComponent(value);

  static String _requireLocationId(String value) {
    final trimmed = _clean(value);
    if (trimmed == null) {
      throw VendorConnectionsGatewayError(
        message: 'A location is required before editing vendor integrations.',
        remediation:
            'Select a location scope from the hierarchy, then retry the vendor '
            'integration action.',
      );
    }
    return trimmed;
  }

  static String _requireScopeValue(String label, String value) {
    final trimmed = _clean(value);
    if (trimmed == null) {
      throw VendorConnectionsGatewayError(
        message: 'A $label id is required for vendor integrations.',
        remediation: 'Refresh the admin workspace and choose the scope again.',
      );
    }
    return trimmed;
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    return _clean(value);
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static DateTime? _readDate(Object? value) {
    if (value is DateTime) return value.toUtc();
    final raw = _readString(value);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}
