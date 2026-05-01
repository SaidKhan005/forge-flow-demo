// Phase 9.0Σ.f — live Azure Blob client for the daily audit anchor.
//
// Replaces [ScaffoldRejectingAuditAnchorBlobClient] in production. Auth
// uses cross-cloud Workload Identity Federation: the GCP Cloud Run Job
// service account fetches an OIDC token from the metadata server, then
// exchanges it at Azure AD for a short-lived Storage bearer token. No
// long-lived secrets — no SAS tokens, no shared account keys, no client
// secrets — live anywhere in code, env, or logs.
//
// Container immutability is enforced server-side by a *container-scope*
// time-based retention policy that is **locked** at provisioning time.
// The writer additionally sets `If-None-Match: *` so a conflicting
// re-write surfaces as `409 BlobAlreadyExists` rather than racing the
// retention policy.
//
// On 409/403 (BlobAlreadyExists or ImmutableBlob): the client reads the
// existing blob and throws [AuditAnchorBlobAlreadyAnchored] carrying
// the live URI + ETag + evidence body. The orchestrator's
// `_anchorOne` recovery path then validates that the existing blob's
// evidence still matches the in-DB chain terminal and inserts the
// missing `audit_chain_anchors` row with the blob's *original*
// `anchored_at`. This makes the daily sweep idempotent across crashed
// partial runs without ever attempting to rewrite an immutable blob.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'audit_anchor.dart';

/// Provides a bearer token for Azure Storage. Production wiring uses
/// [WorkloadIdentityFederationTokenProvider]; tests inject a fake.
abstract class AzureAccessTokenProvider {
  /// Returns a bearer token valid for `https://storage.azure.com/.default`.
  /// Implementations may cache and refresh transparently.
  Future<String> getStorageAccessToken();
}

/// Snapshot of one HTTP response. Headers are lowercased on capture so
/// callers can read them case-insensitively (Azure returns `ETag`,
/// `Content-Type`, `x-ms-version-id` etc. with mixed casing).
class AzureBlobHttpResponse {
  AzureBlobHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> bodyBytes;

  String? get etag => headers['etag'];
}

/// Sends one HTTP request and returns a snapshot of the response.
/// Production: [DartIoAzureBlobHttpRequester] (uses `dart:io`'s
/// [HttpClient]). Tests: pass a stub that asserts shape + returns a
/// canned response.
abstract class AzureBlobHttpRequester {
  Future<AzureBlobHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    List<int>? body,
  });
}

/// Default HTTP requester backed by `dart:io`'s [HttpClient]. The
/// client is owned by this requester (one per blob-client instance);
/// closed via [close] when the surrounding tool exits.
class DartIoAzureBlobHttpRequester implements AzureBlobHttpRequester {
  DartIoAzureBlobHttpRequester({HttpClient? client})
      : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<AzureBlobHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    List<int>? body,
  }) async {
    final request = await _client.openUrl(method, uri);
    headers.forEach((name, value) {
      request.headers.set(name, value);
    });
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final bodyBytes = <int>[];
    await for (final chunk in response) {
      bodyBytes.addAll(chunk);
    }
    final captured = <String, String>{};
    response.headers.forEach((name, values) {
      captured[name.toLowerCase()] = values.join(',');
    });
    return AzureBlobHttpResponse(
      statusCode: response.statusCode,
      headers: captured,
      bodyBytes: bodyBytes,
    );
  }

  void close() => _client.close(force: false);
}

/// Workload Identity Federation token provider:
///
///   1. GET the GCP metadata server's instance identity endpoint with
///      `audience=api://AzureADTokenExchange` → Google-signed OIDC JWT.
///
///   2. POST that JWT as a `client_assertion` to Azure AD's
///      `oauth2/v2.0/token` endpoint with `scope=https://storage.azure.com/.default`
///      → Azure access token.
///
/// The Azure access token is cached until five minutes before its
/// `exp` so a crashed-and-restarted Cloud Run Job avoids hammering AD
/// across rapid re-anchors. No access token (Google or Azure) is ever
/// logged.
class WorkloadIdentityFederationTokenProvider
    implements AzureAccessTokenProvider {
  WorkloadIdentityFederationTokenProvider({
    required this.tenantId,
    required this.clientId,
    AzureBlobHttpRequester? requester,
    Uri? metadataIdentityUrl,
    Uri? azureAdTokenUrl,
    DateTime Function()? clock,
    Duration refreshBuffer = const Duration(minutes: 5),
    String azureAdAudience = 'api://AzureADTokenExchange',
    String storageScope = 'https://storage.azure.com/.default',
  })  : _requester = requester ?? DartIoAzureBlobHttpRequester(),
        _metadataIdentityUrl = metadataIdentityUrl ??
            Uri.parse(
              'http://metadata.google.internal/computeMetadata/v1/'
              'instance/service-accounts/default/identity'
              '?audience=$azureAdAudience&format=full',
            ),
        _azureAdTokenUrl = azureAdTokenUrl ??
            Uri.parse(
              'https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token',
            ),
        _clock = clock ?? DateTime.now,
        _refreshBuffer = refreshBuffer,
        _azureAdAudience = azureAdAudience,
        _storageScope = storageScope;

  final String tenantId;
  final String clientId;
  final AzureBlobHttpRequester _requester;
  final Uri _metadataIdentityUrl;
  final Uri _azureAdTokenUrl;
  final DateTime Function() _clock;
  final Duration _refreshBuffer;
  final String _azureAdAudience;
  final String _storageScope;

  String? _cachedToken;
  DateTime? _cachedExpiry;

  @override
  Future<String> getStorageAccessToken() async {
    final now = _clock().toUtc();
    final cached = _cachedToken;
    final expiry = _cachedExpiry;
    if (cached != null &&
        expiry != null &&
        expiry.subtract(_refreshBuffer).isAfter(now)) {
      return cached;
    }
    final googleJwt = await _fetchGoogleOidcToken();
    final exchanged = await _exchangeAtAzureAd(googleJwt);
    _cachedToken = exchanged.accessToken;
    _cachedExpiry = now.add(exchanged.lifetime);
    return exchanged.accessToken;
  }

  Future<String> _fetchGoogleOidcToken() async {
    final response = await _requester.send(
      method: 'GET',
      uri: _metadataIdentityUrl,
      headers: const <String, String>{'Metadata-Flavor': 'Google'},
    );
    if (response.statusCode != 200) {
      throw AuditAnchorBlobUnavailable(
        'GCP metadata identity endpoint returned '
        'HTTP ${response.statusCode} '
        '(audience=$_azureAdAudience); confirm Cloud Run service '
        'account has the metadata server reachable',
      );
    }
    final body = utf8.decode(response.bodyBytes).trim();
    if (body.isEmpty) {
      throw const AuditAnchorBlobUnavailable(
        'GCP metadata identity endpoint returned an empty body',
      );
    }
    return body;
  }

  Future<_AzureAccessTokenResponse> _exchangeAtAzureAd(
    String googleJwt,
  ) async {
    final form = <String, String>{
      'grant_type': 'client_credentials',
      'client_id': clientId,
      'scope': _storageScope,
      'client_assertion_type':
          'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
      'client_assertion': googleJwt,
    };
    final encoded = form.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}='
              '${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    final response = await _requester.send(
      method: 'POST',
      uri: _azureAdTokenUrl,
      headers: const <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
      },
      body: utf8.encode(encoded),
    );
    if (response.statusCode != 200) {
      // Body may include a structured AAD error code; surface that
      // (it never contains secrets — error payloads document the
      // failure shape, not credentials). Truncate aggressively in case.
      final excerpt = _truncateExcerpt(utf8.decode(response.bodyBytes));
      throw AuditAnchorBlobUnavailable(
        'Azure AD token exchange returned HTTP '
        '${response.statusCode}: $excerpt',
      );
    }
    final raw = jsonDecode(utf8.decode(response.bodyBytes));
    if (raw is! Map<String, Object?>) {
      throw const AuditAnchorBlobUnavailable(
        'Azure AD token response is not a JSON object',
      );
    }
    final accessToken = raw['access_token'];
    final expiresIn = raw['expires_in'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const AuditAnchorBlobUnavailable(
        'Azure AD token response missing access_token',
      );
    }
    final lifetimeSeconds = switch (expiresIn) {
      final int v => v,
      final String v => int.tryParse(v) ?? 3600,
      _ => 3600,
    };
    return _AzureAccessTokenResponse(
      accessToken: accessToken,
      lifetime: Duration(seconds: lifetimeSeconds),
    );
  }
}

class _AzureAccessTokenResponse {
  const _AzureAccessTokenResponse({
    required this.accessToken,
    required this.lifetime,
  });

  final String accessToken;
  final Duration lifetime;
}

/// Live Azure Blob client. Reads/writes a single immutable JSON blob
/// per `(operator_id, chain_date)` against the F&F-owned storage
/// account (endpoint set at construction time from env name
/// `AZURE_BLOB_AUDIT_ENDPOINT`). Container-level retention enforces
/// immutability server-side; this client adds `If-None-Match: *` on
/// PUT for fast rejection of accidental rewrites.
class AzureBlobAuditAnchorBlobClient implements AuditAnchorBlobClient {
  AzureBlobAuditAnchorBlobClient({
    required this.endpoint,
    required AzureAccessTokenProvider tokenProvider,
    AzureBlobHttpRequester? requester,
    DateTime Function()? clock,
    String apiVersion = '2021-12-02',
  })  : _tokenProvider = tokenProvider,
        _requester = requester ?? DartIoAzureBlobHttpRequester(),
        _clock = clock ?? DateTime.now,
        _apiVersion = apiVersion;

  /// Storage account endpoint, e.g. `https://acct.blob.core.windows.net`.
  /// Trailing slash optional; trimmed on construction so the blob URL
  /// builder produces a single `/` between segments.
  final String endpoint;
  final AzureAccessTokenProvider _tokenProvider;
  final AzureBlobHttpRequester _requester;
  final DateTime Function() _clock;
  final String _apiVersion;

  Uri _blobUri({required String containerName, required String blobName}) {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    final encodedBlob = blobName
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return Uri.parse(
      '$base/${Uri.encodeComponent(containerName)}/$encodedBlob',
    );
  }

  Future<Map<String, String>> _baseHeaders() async {
    final token = await _tokenProvider.getStorageAccessToken();
    final dateHeader = HttpDate.format(_clock().toUtc());
    return <String, String>{
      'Authorization': 'Bearer $token',
      'x-ms-version': _apiVersion,
      'x-ms-date': dateHeader,
    };
  }

  @override
  Future<AnchorBlobWriteResult> writeImmutable({
    required String containerName,
    required String blobName,
    required List<int> evidenceBytes,
  }) async {
    final uri = _blobUri(containerName: containerName, blobName: blobName);
    final headers = await _baseHeaders();
    final putHeaders = <String, String>{
      ...headers,
      'x-ms-blob-type': 'BlockBlob',
      'Content-Type': 'application/json',
      // Container-level retention enforces immutability server-side;
      // this header is the fast-fail rejection of rewrite attempts.
      'If-None-Match': '*',
    };
    final response = await _requester.send(
      method: 'PUT',
      uri: uri,
      headers: putHeaders,
      body: evidenceBytes,
    );
    if (response.statusCode == 201) {
      final etag = response.etag;
      if (etag == null || etag.isEmpty) {
        throw const AuditAnchorBlobUnavailable(
          'Azure Blob PUT returned 201 with no ETag header',
        );
      }
      return AnchorBlobWriteResult(uri: uri.toString(), etag: etag);
    }
    if (response.statusCode == 409 || response.statusCode == 403) {
      // Blob already exists (409) or container immutability policy
      // refused the rewrite (403). Read the existing blob so the
      // orchestrator's recovery path can validate evidence ↔ chain
      // and write the missing audit_chain_anchors row.
      final existing = await readImmutable(
        containerName: containerName,
        blobName: blobName,
      );
      throw AuditAnchorBlobAlreadyAnchored(
        uri: uri.toString(),
        etag: existing.etag,
        evidenceBytes: existing.bytes,
      );
    }
    throw AuditAnchorBlobUnavailable(
      'Azure Blob PUT $blobName returned HTTP ${response.statusCode}: '
      '${_truncateExcerpt(utf8.decode(response.bodyBytes))}',
    );
  }

  @override
  Future<AnchorBlobReadResult> readImmutable({
    required String containerName,
    required String blobName,
  }) async {
    final uri = _blobUri(containerName: containerName, blobName: blobName);
    final headers = await _baseHeaders();
    final response = await _requester.send(
      method: 'GET',
      uri: uri,
      headers: headers,
    );
    if (response.statusCode == 200) {
      final etag = response.etag;
      if (etag == null || etag.isEmpty) {
        throw const AuditAnchorBlobUnavailable(
          'Azure Blob GET returned 200 with no ETag header',
        );
      }
      return AnchorBlobReadResult(bytes: response.bodyBytes, etag: etag);
    }
    if (response.statusCode == 404) {
      throw const AuditAnchorBlobUnavailable(
        'Azure Blob GET returned 404 (blob not found)',
      );
    }
    throw AuditAnchorBlobUnavailable(
      'Azure Blob GET $blobName returned HTTP ${response.statusCode}: '
      '${_truncateExcerpt(utf8.decode(response.bodyBytes))}',
    );
  }
}

/// Truncates response-body excerpts so error messages stay short and
/// never approach a token / key boundary even if Azure ever returned
/// one. 240 chars is enough for the AAD `error_description` field.
String _truncateExcerpt(String text) {
  const limit = 240;
  final stripped = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (stripped.length <= limit) return stripped;
  return '${stripped.substring(0, limit)}…';
}
