// Phase 11W.live - web-safe Vendor Connections gateway.
//
// Production operator web must not silently fall back to the in-memory
// fixture gateway. This adapter talks to operator self-service auth routes
// and lets the shared VendorConnectionsWidget render whatever the proxy
// returns.

import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
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

  // The live operator-web picker must reflect implemented adapter lifecycle
  // truth, not a smaller credentialed-demo subset. Reuse the tested catalog
  // and keep connect actions disabled until a vendor promotes past documented.
  static final List<VendorPickerEntry> _catalog =
      InMemoryVendorConnectionsGateway.vendorCatalog;

  @override
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  }) async {
    final body = await _getJson('/v1/auth/locations/$locationId/integrations');
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
    // PR #283 wired the operator-facing connect routes on the proxy:
    //   * OAuth vendors  → POST /v1/integrations/oauth/{vendor}/begin
    //                      response: {authorization_url, state_token, ...}
    //   * key-paste vendors → POST /v1/integrations/api-key/{vendor}/connect
    //                      response: {connection_id, status, ...}
    // The client sends only `location_id` + optional `module`; the
    // proxy resolves operator_id from the bearer token's scope.
    final isKeyPaste = entry.authMode == VendorAuthMode.keyPaste;
    final path = isKeyPaste
        ? '/v1/integrations/api-key/$vendorId/connect'
        : '/v1/integrations/oauth/$vendorId/begin';
    final body = await _postJson(
      path,
      body: <String, Object?>{
        'location_id': locationId,
        if (module != null && module.trim().isNotEmpty) 'module': module,
      },
    );
    // OAuth begin returns `authorization_url`; the api-key connect path
    // does not return a redirect URL because it persists the credential
    // synchronously. The widget treats a non-empty redirect URL as an
    // OAuth handoff, so api-key vendors fall back to a stub URL the
    // widget recognizes as the locally-rendered key-paste form.
    final redirectUrl =
        _readString(body['authorization_url']) ??
        _readString(body['redirect_url']) ??
        (isKeyPaste ? '' : null);
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
      flowKind: isKeyPaste
          ? VendorConnectFlowKind.keyPasteForm
          : VendorConnectFlowKind.oauthRedirect,
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
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) {
      throw VendorConnectionsGatewayError(
        message: 'API key is required.',
        remediation: 'Paste the API key from the vendor portal and try again.',
      );
    }
    final connectBody = <String, Object?>{
      'api_key': trimmedKey,
      if (apiSecret != null && apiSecret.trim().isNotEmpty)
        'api_secret': apiSecret.trim(),
      'location_id': locationId,
      if (module != null && module.trim().isNotEmpty) 'module': module.trim(),
    };
    final body = await _postJson(
      '/v1/integrations/api-key/$vendorId/connect',
      body: connectBody,
      // OW-G72 — caller-STABLE idempotency key, parity with #855/G60.
      // Credential persist is a write: a retried connect of the SAME
      // vendor at the SAME location with the SAME credential collapses
      // against the proxy `proxy_requests` UNIQUE guard instead of
      // persisting a duplicate connection. The credential payload is
      // part of the key so rotating the key is a distinct logical
      // write; a different vendor/location also differs.
      idempotencyAction: 'vendor-connect-api-key',
      idempotencyParts: <Object?>[locationId, vendorId, connectBody],
    );
    final connectionId =
        _readString(body['connection_id']) ??
        _readString(body['connector_connection_id']);
    if (connectionId == null) {
      throw VendorConnectionsGatewayError(
        message: 'The proxy did not return a connection id.',
        remediation:
            'Try again in a moment. If it repeats, Forge & Flow support should '
            'check the integration route binding for this vendor.',
      );
    }
    final connectedAt =
        _readDate(body['connected_at']) ??
        _readDate(body['updated_at']) ??
        DateTime.now().toUtc();
    final firstBackfillRaw = body['first_backfill'];
    bool firstBackfillStarted;
    if (firstBackfillRaw is Map<Object?, Object?>) {
      firstBackfillStarted = firstBackfillRaw['started'] == true;
    } else {
      firstBackfillStarted = body['first_backfill_started'] == true;
    }
    return VendorApiKeyConnectResult(
      connectionId: connectionId,
      connectedAt: connectedAt,
      firstBackfillStarted: firstBackfillStarted,
    );
  }

  @override
  Future<VendorTestConnectionResult> testConnection({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    final body = await _postJson(
      '/v1/integrations/$vendorId/test-connection',
      body: <String, Object?>{'location_id': locationId},
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
      '/v1/integrations/$vendorId/disconnect',
      body: <String, Object?>{'location_id': locationId, 'reason': reason},
      // OW-G72 — caller-STABLE idempotency key, parity with #855/G60.
      // A retried disconnect of the SAME vendor connection at the SAME
      // location collapses against the proxy `proxy_requests` UNIQUE
      // guard instead of double-applying the disconnect. Keyed on the
      // connection identity (location + vendor); the reason is included
      // so a re-disconnect with a different reason is a distinct write.
      idempotencyAction: 'vendor-disconnect',
      idempotencyParts: <Object?>[locationId, vendorId, reason],
    );
  }

  @override
  Future<List<VendorSyncLogEntry>> loadLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async {
    final cappedLimit = limit < 1 ? 1 : (limit > 500 ? 500 : limit);
    final body = await _getJson(
      '/v1/auth/locations/$locationId/integrations/$vendorId/logs',
      queryParameters: <String, String>{'limit': cappedLimit.toString()},
    );
    final rawLogs = body['logs'];
    if (rawLogs is! List) return const <VendorSyncLogEntry>[];
    return <VendorSyncLogEntry>[
      for (final raw in rawLogs)
        if (raw is Map<Object?, Object?>) _logEntryFromJson(raw),
    ];
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

  /// [idempotencyAction] / [idempotencyParts] are OW-G72: when supplied
  /// the call carries a caller-STABLE `Idempotency-Key` (parity with
  /// the #855/G60 pattern) so a retried logical write collapses against
  /// the proxy `proxy_requests` UNIQUE guard. When omitted (OAuth begin
  /// / test-connection probe) the proxy client's existing per-request
  /// auto-mint fallback is unchanged.
  Future<Map<String, Object?>> _postJson(
    String path, {
    Map<String, Object?> body = const <String, Object?>{},
    String? idempotencyAction,
    List<Object?>? idempotencyParts,
  }) async {
    final token = await _requireToken();
    try {
      return (await _proxyClient.postJson(
        path,
        idToken: token,
        body: body,
        extraHeaders: idempotencyAction == null
            ? const <String, String>{}
            : _stableKeyHeader(
                idempotencyAction,
                idempotencyParts ?? const <Object?>[],
              ),
      )).body;
    } on OperatorWebProxyException catch (error) {
      throw _gatewayError(error);
    }
  }

  /// OW-G72 — builds the `Idempotency-Key` header carrying a
  /// caller-STABLE key derived from [action] + [parts]. Same logical
  /// write on retry => same key (proxy `proxy_requests` UNIQUE guard
  /// collapses it); distinct actions / scopes / payloads => distinct
  /// keys. Exact parity with the #855/G60 `_stableKeyHeader` in
  /// `web_account_gateway.dart` / `web_business_timing_gateway.dart`.
  static Map<String, String> _stableKeyHeader(
    String action,
    List<Object?> parts,
  ) {
    return <String, String>{
      'Idempotency-Key': OperatorWebProxyClient.stableIdempotencyKey(
        action,
        parts,
      ),
    };
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
    final connections = _connectionsFromJson(
      body['connections'] ?? body['connector_connections'],
    );

    return VendorConnectionsBundle(
      operatorId: _readString(body['operator_id']) ?? operatorId,
      locationId: _readString(body['location_id']) ?? locationId,
      locationName:
          _readString(body['location_name']) ??
          _readString(body['locationLabel']) ??
          'Location $locationId',
      posConnection:
          _connectionFromTopLevel(body['pos_connection']) ??
          _connectionByCategory(connections, VendorCategory.pos),
      laborConnection:
          _connectionFromTopLevel(body['labor_connection']) ??
          _connectionByCategory(connections, VendorCategory.labor),
      reservationConnection:
          _connectionFromTopLevel(body['reservation_connection']) ??
          _connectionByCategory(connections, VendorCategory.reservation),
      demoFlags: _demoFlagsFromJson(body['demo_flags']),
    );
  }

  static List<VendorConnectionRow> _connectionsFromJson(Object? raw) {
    if (raw is! List) return const <VendorConnectionRow>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(_connectionFromJson)
        .toList(growable: false);
  }

  static VendorConnectionRow? _connectionByCategory(
    List<VendorConnectionRow> connections,
    VendorCategory category,
  ) {
    for (final row in connections) {
      if (row.category == category) return row;
    }
    return null;
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

  static VendorSyncLogEntry _logEntryFromJson(Map<Object?, Object?> raw) {
    return VendorSyncLogEntry(
      occurredAt:
          _readDate(raw['occurred_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      eventKind: _readString(raw['event_kind']) ?? 'unknown',
      recordsCount: _readInt(raw['records_count']),
      errorMessage: _readString(raw['error_message']),
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
