// Phase 11W.live - web-safe Vendor Connections gateway.
//
// Production operator web must not silently fall back to the in-memory
// fixture gateway. This adapter talks to the existing Phase 8 proxy routes
// and lets the shared VendorConnectionsWidget render whatever the proxy
// returns.

import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'operator_web_proxy_client.dart';

abstract class OperatorWebVendorConnectionsGatewayProvider {
  VendorConnectionsGateway? get vendorConnectionsGateway;
}

class OperatorWebHttpVendorConnectionsGateway
    implements VendorConnectionsGateway {
  OperatorWebHttpVendorConnectionsGateway({
    required OperatorWebProxyClient proxyClient,
    required Future<String?> Function() idTokenProvider,
  }) : _proxyClient = proxyClient,
       _idTokenProvider = idTokenProvider;

  final OperatorWebProxyClient _proxyClient;
  final Future<String?> Function() _idTokenProvider;

  static const List<VendorPickerEntry> _catalog = <VendorPickerEntry>[
    VendorPickerEntry(
      vendorId: 'lightspeed_lsk',
      displayName: 'Lightspeed Restaurant K-Series',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.productionCredentialed,
      coversFieldExposed: true,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'libro',
      displayName: 'Libro',
      category: VendorCategory.reservation,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.productionCredentialed,
      coversFieldExposed: true,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'quickbooks_time',
      displayName: 'QuickBooks Time',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.productionCredentialed,
      coversFieldExposed: false,
      requiresModule: true,
      modules: <String>['time', 'accounting', 'payroll'],
    ),
  ];

  @override
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  }) async {
    final body = await _getJson(
      '/v1/admin/operators/$operatorId/locations/$locationId/integrations',
    );
    return _bundleFromJson(
      body,
      operatorId: operatorId,
      locationId: locationId,
    );
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
    final entry = _catalog.firstWhere(
      (candidate) => candidate.vendorId == vendorId,
      orElse: () => throw VendorConnectionsGatewayError(
        message: 'Unknown vendor: $vendorId',
        remediation: 'Pick a vendor from the connection dialog.',
      ),
    );
    final path = entry.authMode == VendorAuthMode.keyPaste
        ? '/v1/admin/integrations/$vendorId/connect-key'
        : '/v1/admin/integrations/oauth/$vendorId/start';
    final body = await _postJson(
      path,
      body: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        if (module != null && module.trim().isNotEmpty) 'module': module,
      },
    );
    final redirectUrl = _readString(body['redirect_url']);
    if (redirectUrl == null) {
      throw VendorConnectionsGatewayError(
        message: 'The proxy did not return a connection URL.',
        remediation:
            'Try again in a moment. If it repeats, Forge & Flow support should '
            'check the integration route binding for this vendor.',
      );
    }
    return VendorConnectFlowStart(
      redirectUrl: redirectUrl,
      flowKind: entry.authMode == VendorAuthMode.keyPaste
          ? VendorConnectFlowKind.keyPasteForm
          : VendorConnectFlowKind.oauthRedirect,
    );
  }

  @override
  Future<VendorTestConnectionResult> testConnection({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    final body = await _postJson(
      '/v1/admin/integrations/$vendorId/test-connection',
      body: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
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
    await _postJson(
      '/v1/admin/integrations/$vendorId/disconnect',
      body: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'reason': reason,
      },
    );
  }

  @override
  Future<List<VendorSyncLogEntry>> loadLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async {
    final body = await _getJson(
      '/v1/admin/integrations/$vendorId/logs',
      queryParameters: <String, String>{
        'operator_id': operatorId,
        'location_id': locationId,
        'limit': '$limit',
      },
    );
    final logs = body['logs'];
    if (logs is! List) return const <VendorSyncLogEntry>[];
    return logs
        .whereType<Map<Object?, Object?>>()
        .map(_syncLogFromJson)
        .toList(growable: false);
  }

  Future<Map<String, Object?>> _getJson(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final token = await _requireToken();
    try {
      return (await _proxyClient.getJson(
        path,
        idToken: token,
        queryParameters: queryParameters,
      )).body;
    } on OperatorWebProxyException catch (error) {
      throw _gatewayError(error);
    }
  }

  Future<Map<String, Object?>> _postJson(
    String path, {
    Map<String, Object?> body = const <String, Object?>{},
  }) async {
    final token = await _requireToken();
    try {
      return (await _proxyClient.postJson(
        path,
        idToken: token,
        body: body,
      )).body;
    } on OperatorWebProxyException catch (error) {
      throw _gatewayError(error);
    }
  }

  Future<String> _requireToken() async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw VendorConnectionsGatewayError(
        message: 'Your sign-in expired.',
        remediation: 'Sign out, sign in again, then retry the connection step.',
        statusCode: 401,
      );
    }
    return token.trim();
  }

  static VendorConnectionsGatewayError _gatewayError(
    OperatorWebProxyException error,
  ) {
    return VendorConnectionsGatewayError(
      message: error.message,
      remediation:
          'Retry once. If it repeats, Forge & Flow support should check the '
          'staging proxy integration route and permission binding.',
      statusCode: error.statusCode,
    );
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
    );
  }

  static VendorSyncLogEntry _syncLogFromJson(Map<Object?, Object?> raw) {
    final json = Map<Object?, Object?>.from(raw);
    return VendorSyncLogEntry(
      occurredAt: _readDate(json['occurred_at']) ?? DateTime.now().toUtc(),
      eventKind: _readString(json['event_kind']) ?? 'sync_event',
      recordsCount: _readInt(json['records_count']),
      errorMessage: _readString(json['error_message']),
    );
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
    switch (raw) {
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

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
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
