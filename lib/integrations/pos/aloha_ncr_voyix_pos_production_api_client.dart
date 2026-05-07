// Phase 8 / `8.transport.aloha-ncr-voyix-pos` — Production HTTP transport
// for the Aloha (NCR Voyix) POS adapter.
//
// What this file is:
//
//   * The concrete [AlohaNcrVoyixApiClient] used in production. The
//     abstract surface is REST-shaped (cloud HTTP per the NCR Voyix
//     Developer Portal — `aloha-v1-2026-05`); this file implements it
//     against `package:http`. Tests inject a fake `http.Client` and
//     exercise this same code path; production wires the real client.
//
//   * Pure transport. No fact writes, no business logic, no canonical
//     mapping. The adapter (`aloha_ncr_voyix_pos_adapter.dart`)
//     consumes vendor-shape JSON from this client; the
//     `AlohaNcrVoyixPostgresSink` is the only seam that talks to
//     storage. This split preserves Hard Promise #1 (Phase 8 = pure
//     transport swap) and Hard Promise #4 (RLS-ready repository
//     pattern stays inside the sink, not the transport).
//
// Deployment models:
//
//   The NCR Voyix Aloha module historically supported two surfaces —
//   the cloud REST API (Developer Portal, OAuth 2.0 client_credentials
//   per the documented `oauth_shape.md`) and an on-premise polling
//   agent that exposes the same REST shape over a configurable LAN
//   URL. The abstract `AlohaNcrVoyixApiClient` is REST-shaped, so this
//   client speaks REST regardless of which surface terminates the
//   call. Both surfaces are exercised through `baseUri`:
//
//     * Cloud-hosted Aloha module → `https://api.ncr.com` (default).
//     * On-prem polling agent     → `http://aloha-agent.local:8443`
//                                   (operator-configured per-location).
//
//   PRODUCTION DEPLOYMENT NOTE: when an operator runs the on-prem
//   relay model, the on-prem agent MUST be reachable from the F&F
//   sync worker pod and the URL MUST be configured per location via
//   the `connector_connection.metadata.aloha_relay_base_uri` field
//   (resolved by the credential store before the client is
//   instantiated). The adapter never embeds the URL inline; the
//   credential store mints a `AlohaNcrVoyixCredentialHandle` plus the
//   resolved `baseUri` so the adapter cannot accidentally hard-code
//   a vendor-internal hostname.
//
// Auth shape:
//
//   * `Authorization: Bearer <access_token>` — OAuth 2.0
//     client_credentials. The access token is short-lived (~1h) and
//     the credential store refreshes it transparently; this client
//     consumes a freshly-minted token from the credential store on
//     every call (no in-memory caching, per HP #7 — server-side keys
//     only, never cached past one request lifetime).
//   * `nep-application-key: <api_key>` — NCR Voyix application key,
//     issued by the NCR Voyix Developer Program intake. Static per
//     F&F's developer registration; same value across all operators.
//   * `nep-organization: <org_id>` — NCR Voyix organization id; bound
//     per F&F vendor registration.
//   * `Aloha-Site-Id: <site_id>` — Aloha-module site identifier.
//     Per-operator-location, resolved from
//     `AlohaNcrVoyixCredentialHandle.siteId`.
//
//   Plaintext credentials never reach Flutter. The
//   [AlohaNcrVoyixCredentialStore] dep is the only seam that resolves
//   them; in production the store reads
//   `vendor_credentials.access_token_ciphertext` (Postgres) and
//   decrypts via the platform secret-manager wrapper (the same path
//   `vendor_credentials_repository` uses).
//
// Error shape:
//
//   The transport surfaces typed errors so the adapter / framework
//   can decide retry vs. dead-letter without parsing strings:
//
//     * [AlohaNcrVoyixTransportException] — network / timeout / TLS.
//       The framework retries on this kind.
//     * [AlohaNcrVoyixAuthException] — 401 / 403. The framework
//       triggers a credential refresh; on a second 401 in a row, the
//       connection is auto-disabled per the framework's 3-strike
//       policy.
//     * [AlohaNcrVoyixRateLimitException] — 429. Exposes the
//       `Retry-After` header value so the framework's exponential-
//       backoff scheduler honors vendor-side guidance.
//     * [AlohaNcrVoyixVendorException] — 4xx other / 5xx. Carries the
//       status code + parsed body excerpt for the audit row.
//
// V1 lean cut 2 alignment (`memory/project_v1_lean_cut_2_2026_05_03.md`):
//
//   * No KMS code path / production-key rotation logic.
//   * No SIGTERM graceful drain handler.
//   * No 5-minute strict replay window (24h via the framework ceiling).
//   * No raw-payload sibling tables (writes flow through the sink).
//   * No 5-second test-connection SLA enforcement here (caller times).
//
// No new pub deps. Only `package:http` (already in pubspec) and the
// existing `dart:convert` / `dart:async` are used.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'aloha_ncr_voyix_pos_adapter.dart';

/// NCR Voyix Aloha-module cloud REST base URI. Override per-deployment
/// via the `ALOHA_NCR_VOYIX_BASE_URI` environment variable; on-prem
/// relay deployments override per-location via the credential store.
const String kAlohaNcrVoyixDefaultBaseUri = 'https://api.ncr.com';

/// Default network timeout for every transport call. The framework's
/// scheduler retries on [AlohaNcrVoyixTransportException]; this
/// timeout is the per-call ceiling, not the cumulative budget.
const Duration kAlohaNcrVoyixDefaultTimeout = Duration(seconds: 30);

/// Maximum number of 429 retries before surfacing the rate-limit
/// exception. Each retry honors the vendor-supplied `Retry-After`
/// header (exponential 1s/2s/4s backoff if absent).
const int kAlohaNcrVoyixMaxRateLimitRetries = 3;

/// Documented REST paths — pinned per the abstract's
/// `documentedPerAlohaNcrVoyixV1` constant.
const String kAlohaCheckSearchPath = '/aloha/v1/checks/search';
const String kAlohaCheckByIdPathPrefix = '/aloha/v1/checks/';
const String kAlohaSampleCheckPath = '/aloha/v1/checks/sample';
const String kAlohaWebhookSubscriptionsPath =
    '/aloha/v1/webhooks/subscriptions';
const String kAlohaOauthTokenPath = '/security/v1/oauth/token';

// ─── Credential store seam ───────────────────────────────────────────

/// One resolved set of credentials needed to issue an authenticated
/// request. Plaintext only lives inside this record for the duration
/// of one HTTP call; the production store mints a fresh copy on every
/// resolve so a stale handle cannot accidentally outlive a key
/// rotation.
class AlohaNcrVoyixResolvedCredentials {
  const AlohaNcrVoyixResolvedCredentials({
    required this.accessToken,
    required this.applicationKey,
    required this.organizationId,
    required this.siteId,
    this.baseUriOverride,
  });

  /// Short-lived OAuth 2.0 access token (Bearer).
  final String accessToken;

  /// NCR Voyix application key (`nep-application-key` header). Static
  /// per F&F developer registration.
  final String applicationKey;

  /// NCR Voyix organization id (`nep-organization` header).
  final String organizationId;

  /// Aloha-module site id (`Aloha-Site-Id` header). Per-location.
  final String siteId;

  /// Optional per-connection base URI override. On-prem relay
  /// deployments set this so the request hits the LAN agent rather
  /// than the cloud API. Cloud deployments leave it null and the
  /// client falls back to the constructor's `baseUri`.
  final Uri? baseUriOverride;
}

/// Function shape the production transport calls to resolve fresh
/// credentials per request. Production binds this to the
/// `vendor_credentials_repository`; tests pass a closure that returns
/// a canned record. Keeping the seam as a typedef rather than a class
/// avoids stub explosion in the unit suite.
typedef AlohaNcrVoyixCredentialStore
    = Future<AlohaNcrVoyixResolvedCredentials> Function(
  AlohaNcrVoyixCredentialHandle handle,
);

/// Static OAuth 2.0 client_credentials envelope. Resolved per-
/// (operator, location) by the production credential store; tests
/// pass a canned record.
class AlohaNcrVoyixOauthClientCredentials {
  const AlohaNcrVoyixOauthClientCredentials({
    required this.clientId,
    required this.clientSecret,
    required this.applicationKey,
    required this.organizationId,
    this.scope,
    this.baseUriOverride,
  });

  /// OAuth 2.0 `client_id`.
  final String clientId;

  /// OAuth 2.0 `client_secret`.
  final String clientSecret;

  /// NCR Voyix application key (`nep-application-key` header).
  final String applicationKey;

  /// NCR Voyix organization id (`nep-organization` header).
  final String organizationId;

  /// Optional OAuth scope. NCR Voyix gates per-API access requests
  /// behind the org's developer registration; the scope is the literal
  /// string the registration confirmed.
  final String? scope;

  /// Optional per-connection base URI override (on-prem relay). Cloud
  /// deployments leave it null.
  final Uri? baseUriOverride;
}

// ─── Typed errors ────────────────────────────────────────────────────

/// Base class for all transport-level errors.
sealed class AlohaNcrVoyixApiException implements Exception {
  const AlohaNcrVoyixApiException(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// Network / timeout / TLS error. Framework retries.
class AlohaNcrVoyixTransportException extends AlohaNcrVoyixApiException {
  const AlohaNcrVoyixTransportException(super.message, {this.cause});
  final Object? cause;
}

/// 401 / 403. Framework refreshes credentials; 3-strike auto-disable.
class AlohaNcrVoyixAuthException extends AlohaNcrVoyixApiException {
  const AlohaNcrVoyixAuthException(super.message, {required this.statusCode});
  final int statusCode;
}

/// 429. Framework backs off per `Retry-After`.
class AlohaNcrVoyixRateLimitException extends AlohaNcrVoyixApiException {
  const AlohaNcrVoyixRateLimitException(
    super.message, {
    required this.retryAfter,
  });

  /// Vendor-supplied `Retry-After` header value, or null if absent.
  final Duration? retryAfter;
}

/// 4xx other / 5xx. Framework dead-letters 4xx and retries 5xx.
class AlohaNcrVoyixVendorException extends AlohaNcrVoyixApiException {
  const AlohaNcrVoyixVendorException(
    super.message, {
    required this.statusCode,
    required this.bodyExcerpt,
  });
  final int statusCode;
  final String bodyExcerpt;
}

// ─── Production client ───────────────────────────────────────────────

/// Production [AlohaNcrVoyixApiClient] backed by `package:http`.
///
/// One instance per F&F sync-worker process is cheap (the underlying
/// `http.Client` keeps connections alive for the worker lifetime). The
/// adapter holds a reference; the framework owns the lifecycle.
class AlohaNcrVoyixPosProductionApiClient implements AlohaNcrVoyixApiClient {
  AlohaNcrVoyixPosProductionApiClient({
    required AlohaNcrVoyixCredentialStore credentialStore,
    required AlohaNcrVoyixOauthClientCredentials oauthCredentials,
    http.Client? httpClient,
    Uri? baseUri,
    String? environmentBaseUri,
    Duration? timeout,
    int? maxRateLimitRetries,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  })  : _credentialStore = credentialStore,
        _oauthCredentials = oauthCredentials,
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _baseUri = _resolveBaseUri(baseUri, environmentBaseUri),
        _timeout = timeout ?? kAlohaNcrVoyixDefaultTimeout,
        _maxRateLimitRetries =
            maxRateLimitRetries ?? kAlohaNcrVoyixMaxRateLimitRetries,
        _now = now ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;

  final AlohaNcrVoyixCredentialStore _credentialStore;
  final AlohaNcrVoyixOauthClientCredentials _oauthCredentials;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Uri _baseUri;
  final Duration _timeout;
  final int _maxRateLimitRetries;
  // ignore: unused_field
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  /// Free the underlying `http.Client` if this instance owns it. Tests
  /// that inject a shared client retain ownership and skip this call.
  void close() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  static Uri _resolveBaseUri(Uri? explicit, String? envOverride) {
    if (explicit != null) return explicit;
    if (envOverride != null && envOverride.isNotEmpty) {
      return Uri.parse(envOverride);
    }
    return Uri.parse(kAlohaNcrVoyixDefaultBaseUri);
  }

  // ─── exchangeClientCredentials ─────────────────────────────────────

  @override
  Future<AlohaNcrVoyixCredentialHandle> exchangeClientCredentials({
    required String operatorId,
    required String locationId,
    required String siteId,
    String? oauthState,
  }) async {
    final base = _oauthCredentials.baseUriOverride ?? _baseUri;
    final tokenUri = base.resolve(kAlohaOauthTokenPath);
    final body = <String, String>{
      'grant_type': 'client_credentials',
      if (_oauthCredentials.scope != null) 'scope': _oauthCredentials.scope!,
    };
    final basicAuth = base64Encode(utf8.encode(
      '${_oauthCredentials.clientId}:${_oauthCredentials.clientSecret}',
    ));
    final response = await _send(
      method: 'POST',
      uri: tokenUri,
      headers: <String, String>{
        'Authorization': 'Basic $basicAuth',
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
        'nep-application-key': _oauthCredentials.applicationKey,
        'nep-organization': _oauthCredentials.organizationId,
      },
      body: body.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'),
    );
    _ensureSuccess(response, context: 'oauth_token_exchange');
    final decoded = _decodeJsonObject(response, context: 'oauth_token_exchange');
    final accessToken = decoded['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw AlohaNcrVoyixVendorException(
        'OAuth token response missing access_token',
        statusCode: response.statusCode,
        bodyExcerpt: _bodyExcerpt(response.body),
      );
    }
    // The connection_id is minted server-side and persisted by the
    // framework's vendor_credentials_repository BEFORE the adapter
    // calls this method in production. The transport returns the
    // siteId-bound handle so the adapter has a stable identifier; the
    // framework stitches it into `connector_connection.connection_id`
    // synchronously after this call returns.
    return AlohaNcrVoyixCredentialHandle(
      connectionId: 'aloha-$operatorId-$locationId',
      siteId: siteId,
    );
  }

  // ─── registerWebhook ───────────────────────────────────────────────

  @override
  Future<String> registerWebhook({
    required AlohaNcrVoyixCredentialHandle credentials,
    required String webhookUrl,
  }) async {
    final resolved = await _credentialStore(credentials);
    final base = resolved.baseUriOverride ?? _baseUri;
    final uri = base.resolve(kAlohaWebhookSubscriptionsPath);
    final response = await _send(
      method: 'POST',
      uri: uri,
      headers: _buildHeaders(resolved, contentType: 'application/json'),
      body: jsonEncode(<String, Object?>{
        'url': webhookUrl,
        'events': <String>[
          'aloha.check.created',
          'aloha.check.modified',
          'aloha.check.closed',
        ],
        'siteId': resolved.siteId,
      }),
    );
    _ensureSuccess(response, context: 'register_webhook');
    final decoded = _decodeJsonObject(response, context: 'register_webhook');
    final subscriptionId = decoded['subscriptionId'] ?? decoded['id'];
    if (subscriptionId is! String || subscriptionId.isEmpty) {
      throw AlohaNcrVoyixVendorException(
        'register_webhook response missing subscriptionId',
        statusCode: response.statusCode,
        bodyExcerpt: _bodyExcerpt(response.body),
      );
    }
    return subscriptionId;
  }

  // ─── unregisterWebhook ─────────────────────────────────────────────

  @override
  Future<bool> unregisterWebhook({
    required AlohaNcrVoyixCredentialHandle credentials,
    String? subscriptionId,
  }) async {
    if (subscriptionId == null || subscriptionId.isEmpty) {
      // Best-effort; framework already wipes credentials.
      return false;
    }
    final resolved = await _credentialStore(credentials);
    final base = resolved.baseUriOverride ?? _baseUri;
    final uri =
        base.resolve('$kAlohaWebhookSubscriptionsPath/$subscriptionId');
    try {
      final response = await _send(
        method: 'DELETE',
        uri: uri,
        headers: _buildHeaders(resolved),
      );
      // Treat 404 as already-gone (idempotent unregister).
      if (response.statusCode == 404) return true;
      _ensureSuccess(response, context: 'unregister_webhook');
      return true;
    } on AlohaNcrVoyixApiException {
      // Best-effort; the adapter swallows the error and the framework
      // still wipes credentials.
      return false;
    }
  }

  // ─── fetchSampleCheck ──────────────────────────────────────────────

  @override
  Future<Map<String, Object?>> fetchSampleCheck({
    required AlohaNcrVoyixCredentialHandle credentials,
  }) async {
    final resolved = await _credentialStore(credentials);
    final base = resolved.baseUriOverride ?? _baseUri;
    final uri = base.resolve(kAlohaSampleCheckPath);
    final response = await _send(
      method: 'GET',
      uri: uri,
      headers: _buildHeaders(resolved),
    );
    _ensureSuccess(response, context: 'fetch_sample_check');
    return _decodeJsonObject(response, context: 'fetch_sample_check');
  }

  // ─── fetchChecksPage ───────────────────────────────────────────────

  @override
  Future<AlohaNcrVoyixChecksPage> fetchChecksPage({
    required AlohaNcrVoyixCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  }) async {
    final resolved = await _credentialStore(credentials);
    final base = resolved.baseUriOverride ?? _baseUri;
    final query = <String, String>{
      'modifiedAtMin': windowStart.toUtc().toIso8601String(),
      'modifiedAtMax': windowEnd.toUtc().toIso8601String(),
      'siteId': resolved.siteId,
      if (resumeFromCursor != null && resumeFromCursor.isNotEmpty)
        'cursor': resumeFromCursor,
    };
    final uri = base.resolve(kAlohaCheckSearchPath).replace(
          queryParameters: query,
        );
    final response = await _send(
      method: 'GET',
      uri: uri,
      headers: _buildHeaders(resolved),
    );
    _ensureSuccess(response, context: 'fetch_checks_page');
    final decoded = _decodeJsonObject(response, context: 'fetch_checks_page');
    final rawChecks = decoded['checks'];
    final checks = rawChecks is List
        ? rawChecks
            .whereType<Map<dynamic, dynamic>>()
            .map((m) => m.cast<String, Object?>())
            .toList(growable: false)
        : const <Map<String, Object?>>[];

    final nextCursorRaw = decoded['nextCursor'];
    final nextCursor =
        nextCursorRaw is String && nextCursorRaw.isNotEmpty ? nextCursorRaw : null;

    DateTime lastModifiedSeen = windowStart.toUtc();
    for (final check in checks) {
      final modifiedAt = check['modifiedAt'];
      if (modifiedAt is String && modifiedAt.isNotEmpty) {
        final parsed = DateTime.parse(modifiedAt).toUtc();
        if (parsed.isAfter(lastModifiedSeen)) lastModifiedSeen = parsed;
      }
    }
    return AlohaNcrVoyixChecksPage(
      checks: checks,
      nextCursor: nextCursor,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  // ─── fetchCheckById ────────────────────────────────────────────────

  @override
  Future<Map<String, Object?>?> fetchCheckById({
    required AlohaNcrVoyixCredentialHandle credentials,
    required String checkId,
  }) async {
    final resolved = await _credentialStore(credentials);
    final base = resolved.baseUriOverride ?? _baseUri;
    final uri = base.resolve(
      '$kAlohaCheckByIdPathPrefix${Uri.encodeComponent(checkId)}',
    );
    final response = await _send(
      method: 'GET',
      uri: uri,
      headers: _buildHeaders(resolved),
    );
    if (response.statusCode == 404) return null;
    _ensureSuccess(response, context: 'fetch_check_by_id');
    return _decodeJsonObject(response, context: 'fetch_check_by_id');
  }

  // ─── helpers ───────────────────────────────────────────────────────

  Map<String, String> _buildHeaders(
    AlohaNcrVoyixResolvedCredentials creds, {
    String? contentType,
  }) {
    return <String, String>{
      'Authorization': 'Bearer ${creds.accessToken}',
      'nep-application-key': creds.applicationKey,
      'nep-organization': creds.organizationId,
      'Aloha-Site-Id': creds.siteId,
      'Accept': 'application/json',
      if (contentType != null) 'Content-Type': contentType,
    };
  }

  /// Send + retry-on-429. Throws typed errors for the known shapes;
  /// returns the raw `http.Response` for the caller to validate.
  Future<http.Response> _send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Object? body,
  }) async {
    var attempt = 0;
    while (true) {
      attempt += 1;
      http.Response response;
      try {
        switch (method) {
          case 'GET':
            response = await _httpClient.get(uri, headers: headers).timeout(
                  _timeout,
                  onTimeout: () => throw TimeoutException(
                      'aloha_ncr_voyix transport timeout',
                      _timeout),
                );
          case 'POST':
            response = await _httpClient
                .post(uri, headers: headers, body: body)
                .timeout(
                  _timeout,
                  onTimeout: () => throw TimeoutException(
                      'aloha_ncr_voyix transport timeout',
                      _timeout),
                );
          case 'DELETE':
            response = await _httpClient.delete(uri, headers: headers).timeout(
                  _timeout,
                  onTimeout: () => throw TimeoutException(
                      'aloha_ncr_voyix transport timeout',
                      _timeout),
                );
          default:
            throw StateError('Unsupported HTTP method: $method');
        }
      } on TimeoutException catch (e) {
        throw AlohaNcrVoyixTransportException(
          'aloha_ncr_voyix HTTP $method $uri timed out after '
          '${_timeout.inSeconds}s: ${e.message}',
        );
      } on http.ClientException catch (e) {
        throw AlohaNcrVoyixTransportException(
          'aloha_ncr_voyix HTTP $method $uri network error: ${e.message}',
          cause: e,
        );
      } catch (e) {
        // Catch-all guards against socket-layer errors that bypass the
        // typed package:http exception. The framework retries on
        // [AlohaNcrVoyixTransportException].
        throw AlohaNcrVoyixTransportException(
          'aloha_ncr_voyix HTTP $method $uri failed: $e',
          cause: e,
        );
      }

      if (response.statusCode == 429) {
        if (attempt > _maxRateLimitRetries) {
          throw AlohaNcrVoyixRateLimitException(
            'aloha_ncr_voyix rate limited after $attempt attempts',
            retryAfter: _parseRetryAfter(response),
          );
        }
        final wait = _parseRetryAfter(response) ??
            Duration(seconds: 1 << (attempt - 1));
        await _sleep(wait);
        continue;
      }
      return response;
    }
  }

  void _ensureSuccess(http.Response response, {required String context}) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AlohaNcrVoyixAuthException(
        'aloha_ncr_voyix $context auth failed',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode == 429) {
      // _send normally retries; if the caller bypasses retry it lands
      // here. Surface as a rate-limit so the framework still handles
      // it correctly.
      throw AlohaNcrVoyixRateLimitException(
        'aloha_ncr_voyix $context rate limited',
        retryAfter: _parseRetryAfter(response),
      );
    }
    throw AlohaNcrVoyixVendorException(
      'aloha_ncr_voyix $context returned HTTP ${response.statusCode}',
      statusCode: response.statusCode,
      bodyExcerpt: _bodyExcerpt(response.body),
    );
  }

  Map<String, Object?> _decodeJsonObject(
    http.Response response, {
    required String context,
  }) {
    final body = response.body;
    if (body.isEmpty) {
      return const <String, Object?>{};
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (e) {
      throw AlohaNcrVoyixVendorException(
        'aloha_ncr_voyix $context returned non-JSON body: $e',
        statusCode: response.statusCode,
        bodyExcerpt: _bodyExcerpt(body),
      );
    }
    if (decoded is! Map<String, Object?>) {
      // Some Aloha endpoints wrap a single object in an envelope; try
      // best-effort to surface it. If it's a List or scalar, surface a
      // typed error so the caller can dead-letter.
      if (decoded is Map<dynamic, dynamic>) {
        return decoded.cast<String, Object?>();
      }
      throw AlohaNcrVoyixVendorException(
        'aloha_ncr_voyix $context returned non-object JSON',
        statusCode: response.statusCode,
        bodyExcerpt: _bodyExcerpt(body),
      );
    }
    return decoded;
  }

  static String _bodyExcerpt(String body) {
    if (body.length <= 512) return body;
    return '${body.substring(0, 512)}...[truncated]';
  }

  static Duration? _parseRetryAfter(http.Response response) {
    final header = response.headers['retry-after'] ??
        response.headers['Retry-After'];
    if (header == null || header.isEmpty) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds);
    }
    // RFC 7231 also allows an HTTP-date; we tolerate parse failure by
    // returning null (caller falls back to exponential backoff).
    return null;
  }
}
