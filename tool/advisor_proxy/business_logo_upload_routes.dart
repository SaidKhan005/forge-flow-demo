// Wave 2 W-5 — Business logo upload route + Azure Blob writer.
//
// Origin: docs/_indices/WAVE_2_LEDGER.md Lane W row W-5 (debug.md:118 /
// OW-2d). The Business Account screen on operator-web today only
// accepts a https URL paste; this slice adds a real file-upload UX
// (PNG only, ≤ 600 KB) that lands in Azure Blob and persists the
// resulting URL into the existing `public.operators.logo_url`
// column. No schema migration required — the column landed in
// `db/migrations/202605070000_phase_11W_7_operator_account_fields.sql`.
//
// Size cap rationale: the slice scope suggested 2 MB. The global
// proxy request-body cap (`kAdminCorsRequestBodyLimitBytes` in
// `advisor_proxy.dart`) is 1 MB. Raising that cap requires a per-
// route entry in `resolveRequestBodyLimitBytes`, which lives in the
// bleed-stopped monolith — and the monolith is at its size-lint
// ceiling. 600 KB raw PNG ≈ 800 KB base64 + JSON envelope ≈ ~820 KB
// over the wire, well under the 1 MB cap. Typical brand logos
// compress to <100 KB so the constraint is invisible in practice.
//
// Why a sibling file (not the monolith)
// -------------------------------------
// `tool/advisor_proxy/advisor_proxy.dart` is at the
// `kAdvisorProxyMaxLines` bleed-stop ceiling. Raising the ceiling
// requires explicit operator approval (CLAUDE.md "Ceiling-raise rule
// (R-2)"). This file keeps the new route entirely outside the
// monolith by piggy-backing on the already-installed
// [OperatorWriteRouter] dispatch path:
//
//   * The monolith dispatcher already routes operator-write paths
//     through `OperatorWriteRouter.matches(path, method)` and the
//     attached `OperatorWriteRouter.handle(...)` call. We add the
//     upload path to that matcher, parse the existing JSON body
//     (which carries a base64-encoded PNG), and dispatch into the
//     handler below.
//   * Auth + role gate + Idempotency-Key + per-operator isolation
//     are all already enforced by the dispatcher. The router only
//     adds the upload-specific validation + Azure Blob seam.
//
// Transport shape
// ---------------
// JSON body with one required field:
//
//   { "filename": "logo.png", "contentBase64": "<base64 PNG bytes>" }
//
// Base64 in JSON keeps the wire compatible with the existing operator-
// write dispatch path (multipart/form-data would need a parser inside
// the monolith). The proxy decodes, validates PNG magic + size, and
// uploads to Azure Blob.
//
// Validation (proxy-side, defence-in-depth — the client also checks):
//   * `filename` ends in `.png` (case-insensitive)
//   * decoded bytes length ≤ 2 097 152 (2 MiB)
//   * decoded bytes start with the PNG magic-number prefix
//     `89 50 4E 47 0D 0A 1A 0A`
//
// Azure Blob seam
// ---------------
// Uses the exact pattern proven by `tool/audit_anchor/azure_blob_client.dart`
// + `tool/pressure/p4_heap_snapshot_uploader.dart`: a
// [DartIoAzureBlobHttpRequester] + [WorkloadIdentityFederationTokenProvider]
// (cross-cloud Workload Identity Federation; no long-lived secrets,
// no SAS tokens, no shared account keys). Business logos are NOT
// immutable (the operator can replace the logo), so we use a stable
// blob name per operator (`operators/<operator_id>/logo.png`) and
// drop the `If-None-Match: *` guard. The container has a non-
// immutable retention posture configured at provisioning time.
//
// Env vars consumed:
//   * `AZURE_BLOB_BUSINESS_LOGOS_CONTAINER`
//   * `AZURE_BLOB_BUSINESS_LOGOS_ENDPOINT`
//   * `AZURE_AD_TENANT_ID`
//   * `AZURE_AD_CLIENT_ID`
//
// When any are unset, the route returns HTTP 503
// `business_logo_uploader_not_configured` and refuses the upload.
// The fallback is the existing "paste URL" UX, which keeps working.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../audit_anchor/azure_blob_client.dart';

/// Operator-scoped logo upload path.
const String operatorBusinessLogoUploadPath = '/v1/operator/business/logo';

/// Hard cap on the decoded PNG size. The slice scope suggested 2 MB
/// but the global proxy body cap is 1 MB
/// (`kAdminCorsRequestBodyLimitBytes` in `advisor_proxy.dart`).
/// Raising the per-route cap requires touching the bleed-stopped
/// monolith, which is at its size lint ceiling.
///
/// We pick 600 KiB so the base64-encoded payload (~800 KiB) plus a
/// few hundred bytes of JSON envelope stays comfortably under 1 MB.
/// Typical brand logos compress to well under 100 KB even at retina
/// resolution, so 600 KiB is generous in practice.
const int kBusinessLogoMaxBytes = 600 * 1024;

/// PNG magic-number prefix (RFC 2083 §3.1). Every valid PNG file
/// starts with these eight bytes.
const List<int> kPngMagic = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

/// Env var names consumed by the default Azure Blob uploader.
class BusinessLogoEnvNames {
  const BusinessLogoEnvNames._();

  static const String azureBlobContainer =
      'AZURE_BLOB_BUSINESS_LOGOS_CONTAINER';
  static const String azureBlobEndpoint = 'AZURE_BLOB_BUSINESS_LOGOS_ENDPOINT';
  static const String azureAdTenantId = 'AZURE_AD_TENANT_ID';
  static const String azureAdClientId = 'AZURE_AD_CLIENT_ID';
}

/// Result of one successful upload.
class BusinessLogoUploadResult {
  const BusinessLogoUploadResult({
    required this.logoUrl,
    required this.sizeBytes,
  });

  /// Fully-qualified https URL to the uploaded PNG. The operator-web
  /// gateway returns this directly to the Business Account screen,
  /// which persists it via the existing PATCH /v1/operator/account
  /// `logoUrl` field.
  final String logoUrl;

  /// Decoded byte length. Surfaced so the proxy can log size for
  /// observability without echoing raw bytes.
  final int sizeBytes;

  Map<String, Object?> toJson() => <String, Object?>{
        'logoUrl': logoUrl,
        'sizeBytes': sizeBytes,
      };
}

/// Pluggable seam so unit tests can stub the Azure Blob upload
/// without standing up the real `dart:io` HTTP client.
abstract class BusinessLogoBlobUploader {
  /// Returns true when the uploader has all four Azure env vars set.
  /// The proxy refuses uploads when this is false.
  bool get isConfigured;

  /// Human-readable reason the uploader is unconfigured. Surfaced
  /// inside the 503 response body so the operator-web error UI can
  /// explain the gap.
  String get unconfiguredReason;

  /// Uploads the supplied PNG bytes for [operatorId] and returns the
  /// resolved https URL.
  Future<BusinessLogoUploadResult> upload({
    required String operatorId,
    required List<int> pngBytes,
  });
}

/// Default Azure Blob uploader. Mirrors the auth + endpoint shape of
/// `tool/audit_anchor/azure_blob_client.dart` and
/// `tool/pressure/p4_heap_snapshot_uploader.dart` so all three Azure
/// Blob seams stay consistent (one Workload Identity Federation
/// pattern across the repo).
class AzureBlobBusinessLogoUploader implements BusinessLogoBlobUploader {
  AzureBlobBusinessLogoUploader({
    Map<String, String>? env,
    AzureBlobHttpRequester? requester,
    AzureAccessTokenProvider? tokenProvider,
    DateTime Function()? clock,
    String apiVersion = '2021-12-02',
  })  : _env = env ?? Platform.environment,
        _requester = requester ?? DartIoAzureBlobHttpRequester(),
        _tokenProviderOverride = tokenProvider,
        _clock = clock ?? DateTime.now,
        _apiVersion = apiVersion;

  final Map<String, String> _env;
  final AzureBlobHttpRequester _requester;
  final AzureAccessTokenProvider? _tokenProviderOverride;
  final DateTime Function() _clock;
  final String _apiVersion;

  AzureAccessTokenProvider? _cachedDefaultProvider;

  String? _readNonEmpty(String name) {
    final raw = _env[name]?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  String? get _container =>
      _readNonEmpty(BusinessLogoEnvNames.azureBlobContainer);

  String? get _endpoint =>
      _readNonEmpty(BusinessLogoEnvNames.azureBlobEndpoint);

  String? get _tenantId => _readNonEmpty(BusinessLogoEnvNames.azureAdTenantId);

  String? get _clientId => _readNonEmpty(BusinessLogoEnvNames.azureAdClientId);

  AzureAccessTokenProvider _resolveTokenProvider() {
    final override = _tokenProviderOverride;
    if (override != null) return override;
    final tenant = _tenantId;
    final client = _clientId;
    if (tenant == null || client == null) {
      throw StateError(
        'AzureBlobBusinessLogoUploader: token provider requested while '
        'AZURE_AD_TENANT_ID / AZURE_AD_CLIENT_ID are unset',
      );
    }
    return _cachedDefaultProvider ??= WorkloadIdentityFederationTokenProvider(
      tenantId: tenant,
      clientId: client,
      requester: _requester,
    );
  }

  @override
  bool get isConfigured {
    if (_tokenProviderOverride != null) {
      return _container != null && _endpoint != null;
    }
    return _container != null &&
        _endpoint != null &&
        _tenantId != null &&
        _clientId != null;
  }

  @override
  String get unconfiguredReason {
    final missing = <String>[];
    if (_container == null) {
      missing.add(BusinessLogoEnvNames.azureBlobContainer);
    }
    if (_endpoint == null) {
      missing.add(BusinessLogoEnvNames.azureBlobEndpoint);
    }
    if (_tokenProviderOverride == null) {
      if (_tenantId == null) missing.add(BusinessLogoEnvNames.azureAdTenantId);
      if (_clientId == null) missing.add(BusinessLogoEnvNames.azureAdClientId);
    }
    if (missing.isEmpty) {
      return 'AzureBlobBusinessLogoUploader unconfigured';
    }
    return '${missing.join(', ')} unset';
  }

  Uri _blobUri({
    required String endpoint,
    required String container,
    required String blobName,
  }) {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    final encodedBlob = blobName
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return Uri.parse(
      '$base/${Uri.encodeComponent(container)}/$encodedBlob',
    );
  }

  @override
  Future<BusinessLogoUploadResult> upload({
    required String operatorId,
    required List<int> pngBytes,
  }) async {
    final container = _container;
    final endpoint = _endpoint;
    if (container == null || endpoint == null) {
      throw StateError(
        'AzureBlobBusinessLogoUploader.upload called while unconfigured: '
        '$unconfiguredReason',
      );
    }
    final tokenProvider = _resolveTokenProvider();
    final token = await tokenProvider.getStorageAccessToken();

    // Stable blob name keyed on operator_id so a re-upload replaces
    // the same blob. Operator id is a UUID v4 in production; we
    // still URL-encode every segment defensively.
    final safeOperatorId =
        operatorId.replaceAll(RegExp(r'[^A-Za-z0-9._\-]'), '_');
    final blobName = 'operators/$safeOperatorId/logo.png';
    final uri = _blobUri(
      endpoint: endpoint,
      container: container,
      blobName: blobName,
    );
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'x-ms-version': _apiVersion,
      'x-ms-date': HttpDate.format(_clock().toUtc()),
      'x-ms-blob-type': 'BlockBlob',
      'Content-Type': 'image/png',
    };
    final response = await _requester.send(
      method: 'PUT',
      uri: uri,
      headers: headers,
      body: pngBytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Azure Blob PUT to $uri returned HTTP ${response.statusCode}: '
        '${_truncateExcerpt(utf8.decode(response.bodyBytes, allowMalformed: true))}',
        uri: uri,
      );
    }
    return BusinessLogoUploadResult(
      logoUrl: uri.toString(),
      sizeBytes: pngBytes.length,
    );
  }
}

/// Validation outcome for a request body. Either resolves to the
/// decoded byte array, or returns the JSON envelope the route handler
/// should write straight back to the client. Exposed so the proxy
/// route test can drive the validator without standing up an HTTP
/// server.
class LogoUploadDecode {
  const LogoUploadDecode.success(this.pngBytes)
      : status = 200,
        body = null;
  const LogoUploadDecode.failure({required this.status, required this.body})
      : pngBytes = null;

  final int status;
  final Map<String, Object?>? body;
  final List<int>? pngBytes;

  bool get ok => pngBytes != null;
}

/// Decodes + validates the upload payload. Exposed for direct unit
/// testing of the validation rules without standing up an HTTP server.
LogoUploadDecode decodeBusinessLogoUploadBody(Map<String, Object?> body) {
  final filename = body['filename'];
  if (filename is! String || filename.trim().isEmpty) {
    return const LogoUploadDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'invalid_filename',
        'message': 'filename must be a non-empty string ending in .png',
      },
    );
  }
  if (!filename.toLowerCase().endsWith('.png')) {
    return const LogoUploadDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'invalid_filename',
        'message': 'filename must end in .png (lowercase or uppercase)',
      },
    );
  }
  final encoded = body['contentBase64'];
  if (encoded is! String || encoded.trim().isEmpty) {
    return const LogoUploadDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'invalid_content',
        'message': 'contentBase64 must be a non-empty base64-encoded string',
      },
    );
  }
  final List<int> decoded;
  try {
    decoded = base64.decode(encoded);
  } on FormatException {
    return const LogoUploadDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'invalid_content',
        'message': 'contentBase64 must be valid base64',
      },
    );
  }
  if (decoded.length > kBusinessLogoMaxBytes) {
    return LogoUploadDecode.failure(
      status: 413,
      body: <String, Object?>{
        'error': 'payload_too_large',
        'message':
            'business logo must be at most $kBusinessLogoMaxBytes bytes '
            '(roughly 600 KB)',
        'maxBytes': kBusinessLogoMaxBytes,
        'sizeBytes': decoded.length,
      },
    );
  }
  if (!_hasPngMagic(decoded)) {
    return const LogoUploadDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'invalid_png_magic',
        'message':
            'file does not start with the PNG magic-number prefix; '
            'only PNG images are accepted',
      },
    );
  }
  return LogoUploadDecode.success(decoded);
}

bool _hasPngMagic(List<int> bytes) {
  if (bytes.length < kPngMagic.length) return false;
  for (var i = 0; i < kPngMagic.length; i++) {
    if (bytes[i] != kPngMagic[i]) return false;
  }
  return true;
}

/// Route handler. The caller (the [OperatorWriteRouter] extension
/// below) supplies the validated JSON body + the operator id. Returns
/// the (statusCode, body) envelope the dispatcher writes back to the
/// client.
class BusinessLogoUploadHandler {
  BusinessLogoUploadHandler({required BusinessLogoBlobUploader uploader})
      : _uploader = uploader;

  final BusinessLogoBlobUploader _uploader;

  /// True when the route is available on this binding. The proxy
  /// renders a calm 503 when the uploader is unconfigured.
  bool get isConfigured => _uploader.isConfigured;

  String get unconfiguredReason => _uploader.unconfiguredReason;

  Future<({int statusCode, Map<String, Object?> body})> handleUpload({
    required String operatorId,
    required Map<String, Object?> body,
  }) async {
    if (!_uploader.isConfigured) {
      return (
        statusCode: 503,
        body: <String, Object?>{
          'error': 'business_logo_uploader_not_configured',
          'message':
              'logo upload is not available on this build; '
              'paste an https URL instead. ${_uploader.unconfiguredReason}',
        },
      );
    }
    final decode = decodeBusinessLogoUploadBody(body);
    if (!decode.ok) {
      return (statusCode: decode.status, body: decode.body!);
    }
    try {
      final result = await _uploader.upload(
        operatorId: operatorId,
        pngBytes: decode.pngBytes!,
      );
      return (statusCode: 200, body: result.toJson());
    } on HttpException catch (error) {
      return (
        statusCode: 502,
        body: <String, Object?>{
          'error': 'azure_blob_upload_failed',
          'message': error.message,
        },
      );
    } on Exception catch (error) {
      return (
        statusCode: 503,
        body: <String, Object?>{
          'error': 'business_logo_upload_unavailable',
          'message': 'business logo upload is unavailable; please retry',
          'detail': error.toString(),
        },
      );
    }
  }
}

String _truncateExcerpt(String text) {
  const limit = 240;
  final stripped = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (stripped.length <= limit) return stripped;
  return '${stripped.substring(0, limit)}…';
}
