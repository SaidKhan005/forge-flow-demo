// Phase 11A.4 - Integration management admin gateway.
//
// Translates the integrations screen's commands into proxy
// `/v1/admin/integrations/*` HTTP calls. The Flutter admin client
// never holds production keys and never reaches KMS directly - every
// rotation flows through the F&F admin proxy, which brokers the KMS
// write and returns the masked-display ledger row.
//
// Two implementations ship in this slice:
//
//   * [HttpIntegrationAdminGateway] - production. GET + POST against
//     the proxy with the signed-in admin's bearer token. The bearer
//     source is injected so production can hand it the Firebase
//     ID-token stream while tests can pin a fixed value.
//
//   * [InMemoryIntegrationAdminGateway] - demo + widget tests.
//     Mutates an in-memory ledger so the admin screen can run
//     end-to-end in `kDemoMode` without a backend or live KMS.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../auth/permission_keys.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart'
    show VendorCategory;
import '../models/integration_admin_models.dart';
import '../../infrastructure/kms/kms_stub_provider.dart';
import 'admin_http_timeout.dart';

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token
/// stream; tests pin a synthetic value.
typedef IntegrationAdminBearerTokenProvider = Future<String> Function();

class IntegrationAdminGatewayError implements Exception {
  const IntegrationAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'IntegrationAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class IntegrationAdminGateway {
  Future<IntegrationBundle> list({AdminIntegrationScopeFilter? scope});

  Future<RotateKeyResult> rotateKey(RotateKeyCommand command);
}

@immutable
class AdminIntegrationScopeFilter {
  const AdminIntegrationScopeFilter({
    required this.operatorId,
    this.locationId,
    this.locationIds = const <String>{},
  });

  final String operatorId;
  final String? locationId;
  final Set<String> locationIds;

  Map<String, String> toQueryParameters() {
    return <String, String>{
      'operator_id': operatorId,
      if (locationId != null && locationId!.isNotEmpty)
        'location_id': locationId!,
      if (locationIds.isNotEmpty) 'location_ids': locationIds.join(','),
    };
  }
}

/// Resolves the current actor's role to gate read-only access for
/// `ff_support` role. Tests can inject a mock implementation.
typedef RoleResolver = Future<List<String>> Function();

class PermissionDeniedException implements Exception {
  const PermissionDeniedException(this.message);

  final String message;

  @override
  String toString() => 'PermissionDeniedException: $message';
}

class HttpIntegrationAdminGateway implements IntegrationAdminGateway {
  HttpIntegrationAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
    RoleResolver? roleResolver,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout,
       _roleResolver = roleResolver;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`).
  final Uri baseUri;
  final IntegrationAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;
  final RoleResolver? _roleResolver;

  static const String listPath = '/v1/admin/integrations';
  static const String rotateAnthropicPath =
      '/v1/admin/integrations/rotate-anthropic';
  static const String rotateVoyagePath = '/v1/admin/integrations/rotate-voyage';
  static const String rotateAzureDbPath =
      '/v1/admin/integrations/rotate-azure-db';
  static const String rotateGeminiPath = '/v1/admin/integrations/rotate-gemini';
  // Phase 9.8 - SendGrid rotation route. Mirrors the existing
  // rotate-* path family.
  static const String rotateSendgridPath =
      '/v1/admin/integrations/rotate-sendgrid';
  static const String statusPath = '/v1/admin/integrations/status';

  // Idempotency key generation lives in the screen layer
  // (`_IntegrationAdminScreenState._nextIdempotencyKey`) so a single
  // minted key flows through both the dialog → command → gateway path
  // and the action handler. Keeping the minter here too would double-
  // mint keys for the same user action.

  static String rotatePathFor(ProviderKeyKind kind) {
    switch (kind) {
      case ProviderKeyKind.anthropic:
        return rotateAnthropicPath;
      case ProviderKeyKind.voyage:
        return rotateVoyagePath;
      case ProviderKeyKind.azureDb:
        return rotateAzureDbPath;
      case ProviderKeyKind.gemini:
        return rotateGeminiPath;
      case ProviderKeyKind.sendgrid:
        return rotateSendgridPath;
    }
  }

  @override
  Future<IntegrationBundle> list({AdminIntegrationScopeFilter? scope}) async {
    final body = await _send(
      method: 'GET',
      path: listPath,
      queryParameters: scope?.toQueryParameters(),
    );
    return _bundleFromJson(body);
  }

  @override
  Future<RotateKeyResult> rotateKey(RotateKeyCommand command) async {
    // Gate mutate operations for ff_support role.
    await _checkNotReadOnly();
    final path = rotatePathFor(command.keyKind);
    final body = await _send(
      method: 'POST',
      path: path,
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return RotateKeyResult.fromJson(body);
  }

  /// Throws [PermissionDeniedException] if the actor holds the
  /// `ff_support` role (read-only access).
  Future<void> _checkNotReadOnly() async {
    final roleResolver = _roleResolver;
    if (roleResolver == null) return; // No role check configured (production).
    final roles = await roleResolver();
    if (roles.contains(PermissionKeys.roleFfSupport)) {
      throw const PermissionDeniedException('Read-only access');
    }
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path).replace(queryParameters: queryParameters);
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
      throw IntegrationAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin integrations proxy timed out after '
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
    throw IntegrationAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ??
          'admin integrations proxy returned an error',
    );
  }
}

IntegrationBundle _bundleFromJson(Map<String, Object?> body) {
  final keys = (body['provider_keys'] as List?) ?? const [];
  final vendor = (body['vendor_connectors'] as List?) ?? const [];
  final fx = (body['fx_rate_source'] as Map?)?.cast<String, Object?>();
  final email = (body['email_provider'] as Map?)?.cast<String, Object?>();
  return IntegrationBundle(
    providerKeys: <ProviderKeyRow>[
      for (final entry in keys)
        ProviderKeyRow.fromJson((entry as Map).cast<String, Object?>()),
    ],
    vendorConnectors: <VendorConnectorStatus>[
      for (final entry in vendor)
        _vendorStatusFromJson((entry as Map).cast<String, Object?>()),
    ],
    fxRateSource: fx == null
        ? const VendorConnectorStatus(
            id: 'fx_rate',
            displayName: 'FX-rate source',
            statusLabel: 'unknown',
            detailMessage: '',
          )
        : _statusFromJson(fx),
    emailProvider: email == null
        ? const VendorConnectorStatus(
            id: 'email',
            displayName: 'Email provider',
            statusLabel: 'unknown',
            detailMessage: '',
          )
        : _statusFromJson(email),
  );
}

VendorConnectorStatus _statusFromJson(Map<String, Object?> json) {
  final apiReachable =
      _boolFromJson(json['api_reachable']) ??
      _boolFromJson(json['apiReachable']);
  return VendorConnectorStatus(
    id: json['id']! as String,
    displayName: json['display_name']! as String,
    statusLabel: json['status_label']! as String,
    detailMessage: (json['detail_message'] as String?) ?? '',
    category: _categoryFromWire(json['category'] as String?),
    apiReachable: apiReachable,
    healthSourceLabel:
        _cleanString(json['health_source_label']) ??
        _healthSourceLabelFromWire(json['health_source'] as String?),
    unlockLabel:
        _cleanString(json['unlock_label']) ??
        _unlockLabelFromWire(json['unlock_state'] as String?) ??
        _unlockLabelFromCanConnect(_boolFromJson(json['can_connect'])),
  );
}

VendorConnectorStatus _vendorStatusFromJson(Map<String, Object?> json) {
  return _normalizeVendorConnectorStatus(_statusFromJson(json));
}

VendorConnectorStatus _normalizeVendorConnectorStatus(
  VendorConnectorStatus status,
) {
  final apiReachable =
      status.apiReachable ??
      _apiReachabilityFromStatusLabel(status.statusLabel);
  final normalizedLabel = _apiReachabilityStatusLabel(
    status.statusLabel,
    apiReachable,
  );
  final category = status.category ?? _categoryForVendor(status.id);
  return VendorConnectorStatus(
    id: status.id,
    displayName: status.displayName,
    statusLabel: normalizedLabel,
    detailMessage: _apiReachabilityDetail(
      rawStatusLabel: status.statusLabel,
      normalizedStatusLabel: normalizedLabel,
      detailMessage: status.detailMessage,
    ),
    category: category,
    apiReachable: apiReachable,
    healthSourceLabel:
        status.healthSourceLabel ??
        _defaultHealthSourceLabel(
          rawStatusLabel: status.statusLabel,
          apiReachable: apiReachable,
        ),
    unlockLabel:
        status.unlockLabel ?? _defaultUnlockLabel(apiReachable: apiReachable),
  );
}

String _apiReachabilityStatusLabel(String statusLabel, bool? apiReachable) {
  if (apiReachable == true) return 'API reachable';
  if (apiReachable == false) return 'API pending';
  final trimmed = statusLabel.trim();
  switch (statusLabel.trim().toLowerCase()) {
    case 'api reachable':
    case 'reachable':
    case 'ready to connect':
    case 'live':
      return 'API reachable';
    case 'api pending':
    case 'pending':
    case 'documented':
    case 'sandbox verified':
      return 'API pending';
    default:
      return trimmed.isEmpty ? 'API status unknown' : trimmed;
  }
}

bool? _apiReachabilityFromStatusLabel(String statusLabel) {
  switch (statusLabel.trim().toLowerCase()) {
    case 'api reachable':
    case 'reachable':
    case 'ready to connect':
    case 'live':
      return true;
    case 'api pending':
    case 'pending':
    case 'documented':
    case 'sandbox verified':
      return false;
    default:
      return null;
  }
}

String _apiReachabilityDetail({
  required String rawStatusLabel,
  required String normalizedStatusLabel,
  required String detailMessage,
}) {
  final detail = detailMessage.trim();
  final rawMatches = rawStatusLabel.trim() == normalizedStatusLabel;
  final alreadyExplainsReachability = detail.toLowerCase().contains(
    'api reachability',
  );
  if (rawMatches || alreadyExplainsReachability) {
    return detail;
  }
  final prefix = normalizedStatusLabel == 'API reachable'
      ? 'API reachable.'
      : normalizedStatusLabel == 'API pending'
      ? 'API reachability pending.'
      : '';
  if (prefix.isEmpty) return detail;
  if (detail.isEmpty) {
    return normalizedStatusLabel == 'API reachable'
        ? 'API reachable for live setup.'
        : 'API reachability pending until production access is verified.';
  }
  return '$prefix $detail';
}

String? _defaultHealthSourceLabel({
  required String rawStatusLabel,
  required bool? apiReachable,
}) {
  if (apiReachable == null) return null;
  return 'Gateway API reachability check';
}

String? _defaultUnlockLabel({required bool? apiReachable}) {
  if (apiReachable == true) return 'Vendor setup unlocked';
  if (apiReachable == false) {
    return 'Vendor setup waits for reachable API access';
  }
  return null;
}

String? _cleanString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool? _boolFromJson(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
    }
  }
  return null;
}

VendorCategory? _categoryFromWire(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'pos':
    case 'point_of_sale':
    case 'point-of-sale':
      return VendorCategory.pos;
    case 'labor':
    case 'scheduling':
    case 'scheduling_and_labor':
    case 'scheduling-and-labor':
      return VendorCategory.labor;
    case 'reservation':
    case 'reservations':
      return VendorCategory.reservation;
  }
  return null;
}

VendorCategory? _categoryForVendor(String vendorId) {
  switch (vendorId) {
    case 'aloha_ncr_voyix':
    case 'clover':
    case 'lightspeed_lsk':
    case 'oracle_micros_simphony':
    case 'revel':
    case 'square':
    case 'toast':
      return VendorCategory.pos;
    case 'adp':
    case 'agendrix':
    case 'humanity':
    case 'push_operations':
    case 'quickbooks_time':
    case 'seven_shifts':
      return VendorCategory.labor;
    case 'libro':
    case 'opentable':
    case 'sevenrooms':
    case 'tock':
      return VendorCategory.reservation;
  }
  return null;
}

String? _healthSourceLabelFromWire(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'api_probe':
    case 'live_api_probe':
    case 'live_probe':
      return 'Live API reachability check';
    case 'mock_gateway':
    case 'mock':
      return 'Mocked gateway reachability seam';
    case 'connector_connection':
    case 'connection_status':
    case 'connected_locations':
      return 'Connected vendor location records';
    case 'lifecycle':
    case 'adapter_lifecycle':
      return 'Gateway reachability projection from vendor lifecycle';
  }
  return _cleanString(value);
}

String? _unlockLabelFromWire(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'unlocked':
    case 'available':
    case 'connectable':
      return 'Vendor setup unlocked';
    case 'locked':
    case 'pending':
    case 'api_pending':
      return 'Vendor setup waits for reachable API access';
  }
  return _cleanString(value);
}

String? _unlockLabelFromCanConnect(bool? canConnect) {
  if (canConnect == true) return 'Vendor setup unlocked';
  if (canConnect == false) {
    return 'Vendor setup waits for reachable API access';
  }
  return null;
}

/// In-memory gateway used by the demo walkthrough and widget tests.
/// Persists nothing across runs - every construction starts from
/// [seed]. Backed by a [KmsStubProvider] so a rotation can be
/// exercised without a real KMS; setting
/// `kmsProvider.failNextWrite = true` exercises the failure path.
class InMemoryIntegrationAdminGateway implements IntegrationAdminGateway {
  InMemoryIntegrationAdminGateway({
    Iterable<ProviderKeyRow> seed = const <ProviderKeyRow>[],
    KmsStubProvider? kmsProvider,
    String? actorUserId,
    DateTime Function()? now,
    String Function()? credentialIdGenerator,
    List<VendorConnectorStatus>? vendorConnectors,
    VendorConnectorStatus? fxRateSource,
    VendorConnectorStatus? emailProvider,
    RoleResolver? roleResolver,
  }) : _kmsProvider = kmsProvider ?? KmsStubProvider(),
       _actorUserId = actorUserId,
       _now = now ?? DateTime.now,
       _credentialIdGenerator = credentialIdGenerator ?? _defaultId,
       _roleResolver = roleResolver,
       _ledger = <ProviderKeyKind, ProviderKeyRow>{
         for (final row in seed) row.keyKind: row,
       },
       _vendorConnectors = List<VendorConnectorStatus>.unmodifiable(
         vendorConnectors ?? _defaultVendorConnectors,
       ),
       _fxRateSource = fxRateSource ?? _defaultFxRateSource,
       _emailProvider = emailProvider ?? _defaultEmailProvider;

  final KmsStubProvider _kmsProvider;
  final String? _actorUserId;
  final DateTime Function() _now;
  final String Function() _credentialIdGenerator;
  final RoleResolver? _roleResolver;
  final Map<ProviderKeyKind, ProviderKeyRow> _ledger;
  final List<VendorConnectorStatus> _vendorConnectors;
  final VendorConnectorStatus _fxRateSource;
  final VendorConnectorStatus _emailProvider;

  /// Per-key cache so a retried rotation on the in-memory gateway
  /// returns the prior result instead of writing a second KMS row -
  /// mirrors the proxy's `admin_request_idempotency` backstop.
  final Map<String, RotateKeyResult> _idempotentResults =
      <String, RotateKeyResult>{};

  KmsStubProvider get kmsProvider => _kmsProvider;

  @override
  Future<IntegrationBundle> list({AdminIntegrationScopeFilter? scope}) async {
    final keys = <ProviderKeyRow>[];
    for (final kind in ProviderKeyKind.values) {
      final row = _ledger[kind];
      if (row != null) keys.add(row);
    }
    return IntegrationBundle(
      providerKeys: List<ProviderKeyRow>.unmodifiable(keys),
      vendorConnectors: List<VendorConnectorStatus>.unmodifiable(
        _vendorConnectors.map(_normalizeVendorConnectorStatus),
      ),
      fxRateSource: _fxRateSource,
      emailProvider: _emailProvider,
    );
  }

  @override
  Future<RotateKeyResult> rotateKey(RotateKeyCommand command) async {
    // Gate mutate operations for ff_support role.
    await _checkNotReadOnly();
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached != null) return cached;
    if (command.plaintextValue.trim().isEmpty) {
      throw const IntegrationAdminGatewayError(
        statusCode: 400,
        errorCode: 'missing_plaintext_value',
        message: 'plaintext_value is required',
      );
    }
    KmsWriteResult writeResult;
    try {
      writeResult = await _kmsProvider.writeSecret(
        logicalKeyKind: command.keyKind.wireName,
        plaintext: command.plaintextValue,
      );
    } on KmsWriteFailure catch (error) {
      throw IntegrationAdminGatewayError(
        statusCode: 503,
        errorCode: 'kms_write_failed',
        message: error.message,
      );
    }
    final ts = _now().toUtc();
    final row = ProviderKeyRow(
      credentialId: _credentialIdGenerator(),
      keyKind: command.keyKind,
      maskedValue: writeResult.maskedDisplay,
      kmsSecretName: writeResult.secretName,
      createdBy: _actorUserId,
      updatedBy: _actorUserId,
      rotatedAt: ts,
    );
    _ledger[command.keyKind] = row;
    final result = RotateKeyResult(
      row: row,
      plaintextValue: command.plaintextValue,
    );
    _idempotentResults[command.idempotencyKey] = result;
    return result;
  }

  static const List<VendorConnectorStatus>
  _defaultVendorConnectors = <VendorConnectorStatus>[
    VendorConnectorStatus(
      id: 'aloha_ncr_voyix',
      displayName: 'Aloha (NCR Voyix)',
      statusLabel: 'Documented',
      detailMessage:
          'POS adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register. Covers: vendor covers field.',
    ),
    VendorConnectorStatus(
      id: 'clover',
      displayName: 'Clover',
      statusLabel: 'Documented',
      detailMessage:
          'POS adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register. Covers: forecast fallback.',
    ),
    VendorConnectorStatus(
      id: 'lightspeed_lsk',
      displayName: 'Lightspeed Restaurant K-Series',
      statusLabel: 'Documented',
      detailMessage:
          'POS adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register. Covers: vendor covers field.',
    ),
    VendorConnectorStatus(
      id: 'oracle_micros_simphony',
      displayName: 'Oracle MICROS Simphony',
      statusLabel: 'Documented',
      detailMessage:
          'POS adapter implemented. Setup state: production credentials pending. Cadence: poll-only. Covers: vendor covers field.',
    ),
    VendorConnectorStatus(
      id: 'revel',
      displayName: 'Revel Systems',
      statusLabel: 'Documented',
      detailMessage:
          'POS adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register. Covers: vendor covers field.',
    ),
    VendorConnectorStatus(
      id: 'square',
      displayName: 'Square',
      statusLabel: 'Documented',
      detailMessage:
          'POS adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register. Covers: forecast fallback.',
    ),
    VendorConnectorStatus(
      id: 'toast',
      displayName: 'Toast',
      statusLabel: 'Documented',
      detailMessage:
          'POS adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register. Covers: vendor covers field.',
    ),
    VendorConnectorStatus(
      id: 'libro',
      displayName: 'Libro Reserve',
      statusLabel: 'Documented',
      detailMessage:
          'Reservations adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register.',
    ),
    VendorConnectorStatus(
      id: 'opentable',
      displayName: 'OpenTable',
      statusLabel: 'Documented',
      detailMessage:
          'Reservations adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register.',
    ),
    VendorConnectorStatus(
      id: 'sevenrooms',
      displayName: 'SevenRooms',
      statusLabel: 'Documented',
      detailMessage:
          'Reservations adapter implemented. Setup state: production credentials pending. Cadence: manual webhook paste.',
    ),
    VendorConnectorStatus(
      id: 'tock',
      displayName: 'Tock',
      statusLabel: 'Documented',
      detailMessage:
          'Reservations adapter implemented. Setup state: production credentials pending. Cadence: manual webhook paste.',
    ),
    VendorConnectorStatus(
      id: 'adp',
      displayName: 'ADP Workforce Now / Workforce Manager',
      statusLabel: 'Documented',
      detailMessage:
          'Scheduling and labor adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register. Product pick required.',
    ),
    VendorConnectorStatus(
      id: 'agendrix',
      displayName: 'Agendrix',
      statusLabel: 'Documented',
      detailMessage:
          'Scheduling and labor adapter implemented. Setup state: production credentials pending. Cadence: poll-only.',
    ),
    VendorConnectorStatus(
      id: 'humanity',
      displayName: 'Humanity',
      statusLabel: 'Documented',
      detailMessage:
          'Scheduling and labor adapter implemented. Setup state: production credentials pending. Cadence: poll-only.',
    ),
    VendorConnectorStatus(
      id: 'push_operations',
      displayName: 'Push Operations',
      statusLabel: 'Documented',
      detailMessage:
          'Scheduling and labor adapter implemented. Setup state: production credentials pending. Cadence: poll-only.',
    ),
    VendorConnectorStatus(
      id: 'quickbooks_time',
      displayName: 'QuickBooks Time',
      statusLabel: 'Documented',
      detailMessage:
          'Scheduling and labor adapter implemented. Setup state: production credentials pending. Cadence: poll-only. Product pick required.',
    ),
    VendorConnectorStatus(
      id: 'seven_shifts',
      displayName: '7shifts',
      statusLabel: 'Documented',
      detailMessage:
          'Scheduling and labor adapter implemented. Setup state: production credentials pending. Cadence: webhook auto-register.',
    ),
  ];

  static const VendorConnectorStatus _defaultFxRateSource =
      VendorConnectorStatus(
        id: 'fx_rate',
        displayName: 'FX-rate source',
        statusLabel: 'green',
        detailMessage: 'ECB daily reference feed (fallback active).',
      );

  static const VendorConnectorStatus _defaultEmailProvider =
      VendorConnectorStatus(
        id: 'email',
        displayName: 'Email provider',
        statusLabel: 'placeholder',
        detailMessage: 'Email provider lands in Phase 9.8.',
      );

  /// Throws [PermissionDeniedException] if the actor holds the
  /// `ff_support` role (read-only access).
  Future<void> _checkNotReadOnly() async {
    final roleResolver = _roleResolver;
    if (roleResolver == null) return; // No role check configured (tests).
    final roles = await roleResolver();
    if (roles.contains(PermissionKeys.roleFfSupport)) {
      throw const PermissionDeniedException('Read-only access');
    }
  }

  static int _idCounter = 0;
  static String _defaultId() {
    _idCounter += 1;
    final hex = _idCounter.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-8000-$hex';
  }
}
