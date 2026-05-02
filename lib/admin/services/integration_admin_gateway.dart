// Phase 11A.4 — Integration management admin gateway.
//
// Translates the integrations screen's commands into proxy
// `/v1/admin/integrations/*` HTTP calls. The Flutter admin client
// never holds production keys and never reaches KMS directly — every
// rotation flows through the F&F admin proxy, which brokers the KMS
// write and returns the masked-display ledger row.
//
// Two implementations ship in this slice:
//
//   * [HttpIntegrationAdminGateway] — production. GET + POST against
//     the proxy with the signed-in admin's bearer token. The bearer
//     source is injected so production can hand it the Firebase
//     ID-token stream while tests can pin a fixed value.
//
//   * [InMemoryIntegrationAdminGateway] — demo + widget tests.
//     Mutates an in-memory ledger so the admin screen can run
//     end-to-end in `kDemoMode` without a backend or live KMS.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/integration_admin_models.dart';
import '../../infrastructure/kms/kms_stub_provider.dart';

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
  Future<IntegrationBundle> list();

  Future<RotateKeyResult> rotateKey(RotateKeyCommand command);
}

class HttpIntegrationAdminGateway implements IntegrationAdminGateway {
  HttpIntegrationAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`).
  final Uri baseUri;
  final IntegrationAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;

  static const String listPath = '/v1/admin/integrations';
  static const String rotateAnthropicPath =
      '/v1/admin/integrations/rotate-anthropic';
  static const String rotateVoyagePath = '/v1/admin/integrations/rotate-voyage';
  static const String rotateAzureDbPath =
      '/v1/admin/integrations/rotate-azure-db';
  static const String rotateGeminiPath = '/v1/admin/integrations/rotate-gemini';
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
    }
  }

  @override
  Future<IntegrationBundle> list() async {
    final body = await _send(method: 'GET', path: listPath);
    return _bundleFromJson(body);
  }

  @override
  Future<RotateKeyResult> rotateKey(RotateKeyCommand command) async {
    final path = rotatePathFor(command.keyKind);
    final body = await _send(
      method: 'POST',
      path: path,
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return RotateKeyResult.fromJson(body);
  }

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
    final response = await http.Response.fromStream(
      await _httpClient.send(request),
    );
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
        _statusFromJson((entry as Map).cast<String, Object?>()),
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
  return VendorConnectorStatus(
    id: json['id']! as String,
    displayName: json['display_name']! as String,
    statusLabel: json['status_label']! as String,
    detailMessage: (json['detail_message'] as String?) ?? '',
  );
}

/// In-memory gateway used by the demo walkthrough and widget tests.
/// Persists nothing across runs — every construction starts from
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
  }) : _kmsProvider = kmsProvider ?? KmsStubProvider(),
       _actorUserId = actorUserId,
       _now = now ?? DateTime.now,
       _credentialIdGenerator = credentialIdGenerator ?? _defaultId,
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
  final Map<ProviderKeyKind, ProviderKeyRow> _ledger;
  final List<VendorConnectorStatus> _vendorConnectors;
  final VendorConnectorStatus _fxRateSource;
  final VendorConnectorStatus _emailProvider;

  /// Per-key cache so a retried rotation on the in-memory gateway
  /// returns the prior result instead of writing a second KMS row —
  /// mirrors the proxy's `admin_request_idempotency` backstop.
  final Map<String, RotateKeyResult> _idempotentResults =
      <String, RotateKeyResult>{};

  KmsStubProvider get kmsProvider => _kmsProvider;

  @override
  Future<IntegrationBundle> list() async {
    final keys = <ProviderKeyRow>[];
    for (final kind in ProviderKeyKind.values) {
      final row = _ledger[kind];
      if (row != null) keys.add(row);
    }
    return IntegrationBundle(
      providerKeys: List<ProviderKeyRow>.unmodifiable(keys),
      vendorConnectors: _vendorConnectors,
      fxRateSource: _fxRateSource,
      emailProvider: _emailProvider,
    );
  }

  @override
  Future<RotateKeyResult> rotateKey(RotateKeyCommand command) async {
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
    final result =
        RotateKeyResult(row: row, plaintextValue: command.plaintextValue);
    _idempotentResults[command.idempotencyKey] = result;
    return result;
  }

  static const List<VendorConnectorStatus> _defaultVendorConnectors =
      <VendorConnectorStatus>[
        VendorConnectorStatus(
          id: 'connector_compeat',
          displayName: 'Compeat connector',
          statusLabel: 'placeholder',
          detailMessage: 'Vendor connector lights up in Phase 8.',
        ),
        VendorConnectorStatus(
          id: 'connector_mp',
          displayName: 'Marketman connector',
          statusLabel: 'placeholder',
          detailMessage: 'Vendor connector lights up in Phase 8.',
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

  static int _idCounter = 0;
  static String _defaultId() {
    _idCounter += 1;
    final hex = _idCounter.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-8000-$hex';
  }
}
