// Phase 8 framework — Production OAuth refresh closures for vendor
// credential bridges.
//
// This file ships one production refresh closure per OAuth-using vendor
// whose `*_credential_bridge.dart` accepts an `oauthRefresh` /
// `oauthExchange` constructor parameter. Each closure:
//
//   * Accepts the per-tenant [VendorCredentialBundle] the broker hands
//     in (carries the current refresh token, optional per-tenant
//     `clientId` / `clientSecret`, and any vendor-specific metadata).
//   * Accepts the app-wide pieces the proxy bootstrap injects from env
//     (`http.Client`, base [Uri], app-wide `clientId`/`clientSecret`
//     when the vendor uses one F&F partner registration rather than a
//     per-tenant pair).
//   * POSTs to the vendor's documented OAuth token endpoint.
//   * Parses the response into a [TokenRefreshResult] the broker writes
//     back through `withTenant`.
//   * Throws [VendorRefreshFailed] (with an actionable diagnostic) on
//     any HTTP status >= 400 or JSON parse failure.
//
// Vendor coverage:
//
//   POS:         Toast, Square, Clover, Lightspeed LSK, Aloha NCR Voyix,
//                Oracle MICROS Simphony, Revel
//   Labor:       7shifts, QuickBooks Time, Libro, Humanity, ADP
//   Reservation: OpenTable
//
// Vendors that do NOT need a refresh closure (their bridges do not
// accept an `oauthRefresh` / `oauthExchange` constructor parameter and
// either use static API keys or have a structural gap that prevents
// broker-driven refresh):
//
//   * SevenRooms        — `client_credentials` re-exchange would require
//                          `client_id + client_secret + venue_id`, but
//                          the bridge persists only `client_id`; the
//                          `client_secret` is dropped after the connect-
//                          time `authenticate(...)` call. Wiring requires
//                          an architectural change (persist
//                          `client_secret` ciphertext on the credential
//                          row + connect-flow update). See the no-closure
//                          reason `sevenrooms_client_secret_not_persisted`
//                          and the 2026-05-09 re-investigation note in
//                          `docs/integrations/sevenrooms/oauth_shape.md`.
//   * Tock              — static API key on `metadata.api_key`.
//   * Push Operations   — partner-issued bearer; no refresh path.
//   * Agendrix          — OAuth sliding-refresh per adapter declaration;
//                          closure factory not yet wired (re-investigated
//                          2026-05-09 — out of scope for this PR).
//
// 2026-05-09 RE-INVESTIGATION (this file's `makeAdpOauthRefreshClosure`
// + `makeOpenTableOauthRefreshClosure`): PR #455 chose option 2b for ADP
// / OpenTable / SevenRooms (deliberate "no closure" entries with
// structured reasons). On re-verification ADP and OpenTable both expose
// a programmatic OAuth `grant_type=refresh_token` surface using
// per-tenant `client_id` / `client_secret` from `metadata` — these are
// genuinely wireable using the same direct-HTTP closure pattern as
// Toast / Square / Clover / etc. SevenRooms remains unwired because the
// re-exchange shape (`client_credentials` with `client_id +
// client_secret + venue_id`) requires `client_secret` to be persisted on
// the credential row, which the existing
// `SevenRoomsBrokerCredentialStore.persistIssuedBearerToken` path drops
// after the connect-time `authenticate(...)` call.
//
// ADP-specific notes:
//   * The transport's `_tokenRequest` adds an `x-adp-module` header
//     keyed off the operator's selected module (`workforce_now` /
//     `workforce_manager`). The closure reads that from
//     `connectionMetadata.module` first (the connect path writes it
//     there via `AdpConnectionRow.toMetadata`), falling back to
//     `metadata.module`, and finally to `workforce_now` per the
//     documented default in `docs/phases/phase_8/vendor_master_list.md`.
//   * mTLS: ADP partner production additionally requires mTLS at the
//     OAuth boundary. The mTLS material is wired into the worker's
//     `http.Client` at boot (via Cloud Run-injected cert/key); the
//     closure itself is mTLS-agnostic. The partner-cert rotation is a
//     SEPARATE concern from `refresh_token` rotation — partner-ops
//     rotates the cert; the closure handles the OAuth refresh.
//
// CLAUDE.md alignment:
//   * HP #4 (per-operator isolation) — the closures are pure HTTP; the
//     broker still rides `withTenant` for the persist back. The
//     closures NEVER touch the database directly.
//   * HP #7 (server-side keys) — closures execute exclusively inside
//     Cloud Run and never log plaintext credentials. Diagnostics
//     surface only the HTTP status and a bounded body excerpt.
//
// No new pub deps; only `package:http` (already in `pubspec.yaml`).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'vendor_credential_broker.dart';

// ─── Diagnostic helpers ─────────────────────────────────────────────────

/// Maximum number of bytes from a vendor response body we surface in a
/// [VendorRefreshFailed] message. Keeps the failure compact and avoids
/// leaking large payloads (or stray secrets) into log streams.
const int _kErrorBodyExcerptLimit = 256;

String _bodyExcerpt(String body) {
  if (body.length <= _kErrorBodyExcerptLimit) return body;
  return '${body.substring(0, _kErrorBodyExcerptLimit)}...';
}

Never _throwRefresh(
  String vendorId,
  String reason, {
  int? statusCode,
  String? body,
}) {
  final pieces = <String>[
    'vendor=$vendorId',
    'reason=$reason',
    if (statusCode != null) 'status=$statusCode',
    if (body != null && body.isNotEmpty) 'body=${_bodyExcerpt(body)}',
  ];
  throw VendorRefreshFailed(pieces.join(' | '));
}

/// Categorize the vendor response into a typed refresh diagnostic.
/// 401 = auth diagnostic; 5xx = transient retry hint; other 4xx =
/// permanent.
void _ensureSuccess(http.Response response, String vendorId) {
  if (response.statusCode >= 200 && response.statusCode < 300) return;
  if (response.statusCode == 401 || response.statusCode == 403) {
    _throwRefresh(
      vendorId,
      'auth_rejected (${response.statusCode}); refresh token / client '
      'credentials likely revoked — operator must reconnect',
      statusCode: response.statusCode,
      body: response.body,
    );
  }
  if (response.statusCode >= 500) {
    _throwRefresh(
      vendorId,
      'vendor_5xx (${response.statusCode}); transient — caller should '
      'retry on the next refresh tick',
      statusCode: response.statusCode,
      body: response.body,
    );
  }
  _throwRefresh(
    vendorId,
    'permanent_4xx (${response.statusCode})',
    statusCode: response.statusCode,
    body: response.body,
  );
}

Map<String, Object?> _parseJsonObject(
  http.Response response,
  String vendorId,
) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    _throwRefresh(
      vendorId,
      'malformed_json: expected JSON object, got ${decoded.runtimeType}',
      statusCode: response.statusCode,
      body: response.body,
    );
  } on FormatException catch (error) {
    _throwRefresh(
      vendorId,
      'malformed_json: ${error.message}',
      statusCode: response.statusCode,
      body: response.body,
    );
  }
}

String _readNonEmptyString(
  Map<String, Object?> json,
  String key,
  String vendorId, {
  int? statusCode,
  String? body,
}) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  _throwRefresh(
    vendorId,
    'malformed_json: missing or empty `$key`',
    statusCode: statusCode,
    body: body,
  );
}

DateTime? _readExpiresInToInstant(
  Map<String, Object?> json, {
  String key = 'expires_in',
  DateTime Function()? clock,
}) {
  final value = json[key];
  if (value is num && value > 0) {
    return (clock ?? DateTime.now)
        .call()
        .toUtc()
        .add(Duration(seconds: value.toInt()));
  }
  return null;
}

DateTime? _readExpiresAtInstant(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value)?.toUtc();
  }
  if (value is num && value > 0) {
    // Square emits `expires_at` as a number of seconds since epoch when
    // the partner registration is configured that way; the documented
    // shape is a string but be defensive.
    return DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000,
            isUtc: true)
        .toUtc();
  }
  return null;
}

String _basicAuthHeader(String clientId, String clientSecret) {
  return 'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}';
}

Future<http.Response> _postForm({
  required http.Client httpClient,
  required Uri uri,
  required Map<String, String> form,
  required String vendorId,
  Map<String, String> extraHeaders = const <String, String>{},
}) async {
  try {
    return await httpClient.post(
      uri,
      headers: <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
        ...extraHeaders,
      },
      body: form,
    );
  } catch (error) {
    _throwRefresh(
      vendorId,
      'transport_error: ${error.runtimeType}',
    );
  }
}

Future<http.Response> _postJson({
  required http.Client httpClient,
  required Uri uri,
  required Map<String, Object?> body,
  required String vendorId,
  Map<String, String> extraHeaders = const <String, String>{},
}) async {
  try {
    return await httpClient.post(
      uri,
      headers: <String, String>{
        'content-type': 'application/json',
        'accept': 'application/json',
        ...extraHeaders,
      },
      body: jsonEncode(body),
    );
  } catch (error) {
    _throwRefresh(
      vendorId,
      'transport_error: ${error.runtimeType}',
    );
  }
}

String _requireMetadataString(
  VendorCredentialBundle current,
  String? hoisted,
  String key,
  String vendorId,
) {
  if (hoisted != null && hoisted.isNotEmpty) return hoisted;
  final fallback = current.metadata[key];
  if (fallback is String && fallback.isNotEmpty) return fallback;
  _throwRefresh(
    vendorId,
    'missing_credential: bundle has no `$key`; operator must reconnect',
  );
}

String _requireRefreshToken(
  VendorCredentialBundle current,
  String vendorId,
) {
  final refresh = current.refreshToken;
  if (refresh != null && refresh.isNotEmpty) return refresh;
  _throwRefresh(
    vendorId,
    'missing_refresh_token: bundle.refreshToken is null/empty; '
    'operator must reconnect',
  );
}

// ─── Toast — POST {oauthBaseUri}/authentication/v1/authentication/login ──
//
// `client_credentials` with JSON body. Response shape per
// `docs/integrations/toast/oauth_shape.md`:
//   { "token": { "accessToken": "...", "expiresIn": 3600,
//                "tokenType": "Bearer" } }
// Toast's response is wrapped in a `token` envelope (not the bare
// `access_token` shape most vendors emit).

const String kToastVendorIdForRefresh = 'toast';
const String kToastDefaultOauthBaseUri = 'https://ws-api.toasttab.com';
const String kToastOauthLoginPath = '/authentication/v1/authentication/login';

/// Production refresh closure for [ToastBrokerAccessTokenResolver].
///
/// Toast uses `client_credentials` (no refresh-token rotation). The
/// per-tenant `clientId` / `clientSecret` live on `metadata.client_id`
/// / `metadata.client_secret` per the Toast credential bridge.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeToastOauthRefreshClosure({
  required http.Client httpClient,
  Uri? oauthBaseUri,
  DateTime Function()? clock,
}) {
  final base = oauthBaseUri ?? Uri.parse(kToastDefaultOauthBaseUri);
  return (VendorCredentialBundle current) async {
    final clientId = _requireMetadataString(
      current,
      current.clientId,
      kBundleMetadataClientId,
      kToastVendorIdForRefresh,
    );
    final clientSecret = _requireMetadataString(
      current,
      current.clientSecret,
      kBundleMetadataClientSecret,
      kToastVendorIdForRefresh,
    );
    final response = await _postJson(
      httpClient: httpClient,
      uri: base.resolve(kToastOauthLoginPath),
      body: <String, Object?>{
        'clientId': clientId,
        'clientSecret': clientSecret,
        'userAccessType': 'TOAST_MACHINE_CLIENT',
      },
      vendorId: kToastVendorIdForRefresh,
    );
    _ensureSuccess(response, kToastVendorIdForRefresh);
    final json = _parseJsonObject(response, kToastVendorIdForRefresh);
    // Toast's response is `{ "token": { "accessToken": ..., "expiresIn": ... } }`.
    final tokenField = json['token'];
    final tokenObj = tokenField is Map<String, Object?>
        ? tokenField
        : tokenField is Map
            ? tokenField.map(
                (key, value) => MapEntry(key.toString(), value),
              )
            : json;
    final accessToken = _readNonEmptyString(
      tokenObj,
      'accessToken',
      kToastVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final expiresAt = _readExpiresInToInstant(
      tokenObj,
      key: 'expiresIn',
      clock: clock,
    );
    return TokenRefreshResult(
      accessToken: accessToken,
      expiresAt: expiresAt,
    );
  };
}

// ─── Square — POST /oauth2/token (refresh_token) ─────────────────────

const String kSquareVendorIdForRefresh = 'square';
const String kSquareDefaultBaseUri = 'https://connect.squareup.com';
const String kSquareOauthTokenRefreshPath = '/oauth2/token';

/// Production refresh closure for [SquareBrokerCredentialResolver].
///
/// Square's OAuth `client_id` / `client_secret` are app-wide (one F&F
/// partner registration); the proxy bootstrap reads them from env once
/// and threads them in here. The refresh token is per-tenant and lives
/// on `vendor_credentials.refresh_token_ciphertext`.
///
/// Square rotates the refresh token on every refresh — the response's
/// `refresh_token` field carries the new value. The closure threads it
/// into [TokenRefreshResult.refreshToken] so the broker re-encrypts
/// and persists it on the row.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeSquareOauthRefreshClosure({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
  Uri? baseUri,
}) {
  final base = baseUri ?? Uri.parse(kSquareDefaultBaseUri);
  return (VendorCredentialBundle current) async {
    final refreshToken =
        _requireRefreshToken(current, kSquareVendorIdForRefresh);
    final response = await _postJson(
      httpClient: httpClient,
      uri: base.resolve(kSquareOauthTokenRefreshPath),
      body: <String, Object?>{
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      },
      vendorId: kSquareVendorIdForRefresh,
    );
    _ensureSuccess(response, kSquareVendorIdForRefresh);
    final json = _parseJsonObject(response, kSquareVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kSquareVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    final expiresAt = _readExpiresAtInstant(json, 'expires_at');
    final merchantId = json['merchant_id'];
    return TokenRefreshResult(
      accessToken: accessToken,
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
      metadataPatch: merchantId is String && merchantId.isNotEmpty
          ? <String, Object?>{kBundleMetadataMerchantId: merchantId}
          : null,
    );
  };
}

// ─── Clover — POST /oauth/v2/refresh (refresh_token) ─────────────────

const String kCloverVendorIdForRefresh = 'clover';
const String kCloverDefaultBaseUri = 'https://api.clover.com';
const String kCloverOauthRefreshPath = '/oauth/v2/refresh';

/// Production refresh closure for the Clover credential bridge.
///
/// Clover's OAuth `client_id` is the "App ID" the proxy bootstrap
/// reads from `CLOVER_APP_ID`; the refresh token is per-merchant and
/// lives on `vendor_credentials.refresh_token_ciphertext`. Clover
/// rotates the refresh token on every refresh.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeCloverOauthRefreshClosure({
  required http.Client httpClient,
  required String clientId,
  Uri? baseUri,
}) {
  final base = baseUri ?? Uri.parse(kCloverDefaultBaseUri);
  return (VendorCredentialBundle current) async {
    final refreshToken =
        _requireRefreshToken(current, kCloverVendorIdForRefresh);
    final response = await _postJson(
      httpClient: httpClient,
      uri: base.resolve(kCloverOauthRefreshPath),
      body: <String, Object?>{
        'client_id': clientId,
        'refresh_token': refreshToken,
      },
      vendorId: kCloverVendorIdForRefresh,
    );
    _ensureSuccess(response, kCloverVendorIdForRefresh);
    final json = _parseJsonObject(response, kCloverVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kCloverVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    final expiresAt = _readExpiresAtInstant(json, 'access_token_expiration');
    return TokenRefreshResult(
      accessToken: accessToken,
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
    );
  };
}

// ─── Lightspeed LSK — POST /oauth/token (refresh_token) ──────────────

const String kLightspeedLskVendorIdForRefresh = 'lightspeed_lsk';
const String kLightspeedLskDefaultBaseUri = 'https://api.lsk.lightspeed.app';
const String kLightspeedLskOauthTokenPath = '/oauth/token';

/// Production refresh closure for [LightspeedLskBrokerAccessTokenResolver].
///
/// Lightspeed K-Series uses a per-tenant `client_id` / `client_secret`
/// pair stored on `metadata.client_id` / `metadata.client_secret`. The
/// refresh token is on `vendor_credentials.refresh_token_ciphertext`.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeLightspeedLskOauthRefreshClosure({
  required http.Client httpClient,
  Uri? baseUri,
  DateTime Function()? clock,
}) {
  final base = baseUri ?? Uri.parse(kLightspeedLskDefaultBaseUri);
  return (VendorCredentialBundle current) async {
    final clientId = _requireMetadataString(
      current,
      current.clientId,
      kBundleMetadataClientId,
      kLightspeedLskVendorIdForRefresh,
    );
    final clientSecret = _requireMetadataString(
      current,
      current.clientSecret,
      kBundleMetadataClientSecret,
      kLightspeedLskVendorIdForRefresh,
    );
    final refreshToken =
        _requireRefreshToken(current, kLightspeedLskVendorIdForRefresh);
    final response = await _postForm(
      httpClient: httpClient,
      uri: base.resolve(kLightspeedLskOauthTokenPath),
      form: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
        'client_secret': clientSecret,
      },
      vendorId: kLightspeedLskVendorIdForRefresh,
    );
    _ensureSuccess(response, kLightspeedLskVendorIdForRefresh);
    final json = _parseJsonObject(response, kLightspeedLskVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kLightspeedLskVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
    );
  };
}

// ─── Aloha NCR Voyix — POST /security/v1/oauth/token (client_credentials) ─

const String kAlohaNcrVoyixVendorIdForRefresh = 'aloha_ncr_voyix';
const String kAlohaNcrVoyixDefaultOauthBaseUri = 'https://api.ncr.com';
const String kAlohaNcrVoyixOauthTokenPath = '/security/v1/oauth/token';

/// Metadata key carrying the static NCR Voyix application key
/// (`nep-application-key` header on the OAuth call).
const String kAlohaNcrVoyixMetadataApplicationKey = 'application_key';

/// Metadata key carrying the NCR Voyix organization id
/// (`nep-organization` header on the OAuth call).
const String kAlohaNcrVoyixMetadataOrganizationId = 'organization_id';

/// Production refresh closure for the Aloha NCR Voyix credential
/// bridge. NCR uses `client_credentials` with HTTP Basic auth carrying
/// the per-tenant `client_id` / `client_secret`, plus two static
/// headers (`nep-application-key`, `nep-organization`) sourced from
/// `metadata.application_key` / `metadata.organization_id`.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeAlohaNcrVoyixOauthRefreshClosure({
  required http.Client httpClient,
  Uri? oauthBaseUri,
  String? scope,
  DateTime Function()? clock,
}) {
  final base = oauthBaseUri ?? Uri.parse(kAlohaNcrVoyixDefaultOauthBaseUri);
  return (VendorCredentialBundle current) async {
    final clientId = _requireMetadataString(
      current,
      current.clientId,
      kBundleMetadataClientId,
      kAlohaNcrVoyixVendorIdForRefresh,
    );
    final clientSecret = _requireMetadataString(
      current,
      current.clientSecret,
      kBundleMetadataClientSecret,
      kAlohaNcrVoyixVendorIdForRefresh,
    );
    final applicationKey = _requireMetadataString(
      current,
      null,
      kAlohaNcrVoyixMetadataApplicationKey,
      kAlohaNcrVoyixVendorIdForRefresh,
    );
    final organizationId = _requireMetadataString(
      current,
      null,
      kAlohaNcrVoyixMetadataOrganizationId,
      kAlohaNcrVoyixVendorIdForRefresh,
    );
    final response = await _postForm(
      httpClient: httpClient,
      uri: base.resolve(kAlohaNcrVoyixOauthTokenPath),
      form: <String, String>{
        'grant_type': 'client_credentials',
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      },
      extraHeaders: <String, String>{
        'authorization': _basicAuthHeader(clientId, clientSecret),
        'nep-application-key': applicationKey,
        'nep-organization': organizationId,
      },
      vendorId: kAlohaNcrVoyixVendorIdForRefresh,
    );
    _ensureSuccess(response, kAlohaNcrVoyixVendorIdForRefresh);
    final json = _parseJsonObject(response, kAlohaNcrVoyixVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kAlohaNcrVoyixVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      expiresAt: expiresAt,
    );
  };
}

// ─── Oracle MICROS Simphony — POST /sim/api/v2/oauth/token (client_credentials) ─

const String kOracleMicrosSimphonyVendorIdForRefresh = 'oracle_micros_simphony';
final Uri kOracleMicrosSimphonyDefaultOauthBaseUri = Uri.parse(
  'https://api.simphony.oracleindustry.com/sim/api/v2/',
);
const String kOracleMicrosSimphonyOauthTokenPath = 'oauth/token';

/// Production exchange closure for [OracleMicrosSimphonyBrokerTokenStore].
///
/// Simphony uses `client_credentials` with HTTP Basic auth carrying
/// the per-tenant `client_id` / `client_secret`. There is no refresh
/// token — every refresh is a fresh `client_credentials` exchange.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeOracleMicrosSimphonyOauthExchangeClosure({
  required http.Client httpClient,
  Uri? oauthBaseUri,
  DateTime Function()? clock,
}) {
  final base = oauthBaseUri ?? kOracleMicrosSimphonyDefaultOauthBaseUri;
  return (VendorCredentialBundle current) async {
    final clientId = _requireMetadataString(
      current,
      current.clientId,
      kBundleMetadataClientId,
      kOracleMicrosSimphonyVendorIdForRefresh,
    );
    final clientSecret = _requireMetadataString(
      current,
      current.clientSecret,
      kBundleMetadataClientSecret,
      kOracleMicrosSimphonyVendorIdForRefresh,
    );
    final response = await _postForm(
      httpClient: httpClient,
      uri: base.resolve(kOracleMicrosSimphonyOauthTokenPath),
      form: const <String, String>{
        'grant_type': 'client_credentials',
      },
      extraHeaders: <String, String>{
        'authorization': _basicAuthHeader(clientId, clientSecret),
      },
      vendorId: kOracleMicrosSimphonyVendorIdForRefresh,
    );
    _ensureSuccess(response, kOracleMicrosSimphonyVendorIdForRefresh);
    final json =
        _parseJsonObject(response, kOracleMicrosSimphonyVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kOracleMicrosSimphonyVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      expiresAt: expiresAt,
    );
  };
}

// ─── Revel — POST {oauthTokenUri} (client_credentials) ───────────────

const String kRevelVendorIdForRefresh = 'revel';
final Uri kRevelDefaultOauthTokenUri =
    Uri.parse('https://authentication.revelup.com/oauth/token');

/// Production exchange closure for [RevelBrokerCredentialBridge].
///
/// Revel issues a 24h JWT bearer via `client_credentials`. There is no
/// refresh token — the closure re-runs the exchange against the same
/// `client_id` / `client_secret` pair and the documented `audience`.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeRevelOauthExchangeClosure({
  required http.Client httpClient,
  required String audience,
  Uri? oauthTokenUri,
  DateTime Function()? clock,
}) {
  final tokenUri = oauthTokenUri ?? kRevelDefaultOauthTokenUri;
  return (VendorCredentialBundle current) async {
    final clientId = _requireMetadataString(
      current,
      current.clientId,
      kBundleMetadataClientId,
      kRevelVendorIdForRefresh,
    );
    final clientSecret = _requireMetadataString(
      current,
      current.clientSecret,
      kBundleMetadataClientSecret,
      kRevelVendorIdForRefresh,
    );
    final response = await _postForm(
      httpClient: httpClient,
      uri: tokenUri,
      form: <String, String>{
        'grant_type': 'client_credentials',
        'client_id': clientId,
        'client_secret': clientSecret,
        'audience': audience,
      },
      vendorId: kRevelVendorIdForRefresh,
    );
    _ensureSuccess(response, kRevelVendorIdForRefresh);
    final json = _parseJsonObject(response, kRevelVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kRevelVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      expiresAt: expiresAt,
    );
  };
}

// ─── 7shifts — POST /v2/oauth/token (refresh_token) ──────────────────

const String kSevenShiftsVendorIdForRefresh = 'seven_shifts';
final Uri kSevenShiftsDefaultOauthTokenUri =
    Uri.parse('https://api.7shifts.com/v2/oauth/token');

/// Production refresh closure for [makeSevenShiftsAccessTokenProvider].
///
/// 7shifts uses an app-wide `client_id` / `client_secret` registered
/// with the partner program; the proxy bootstrap reads them from env
/// once. The refresh token is per-operator.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeSevenShiftsOauthRefreshClosure({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
  Uri? oauthTokenUri,
  DateTime Function()? clock,
}) {
  final tokenUri = oauthTokenUri ?? kSevenShiftsDefaultOauthTokenUri;
  return (VendorCredentialBundle current) async {
    final refreshToken =
        _requireRefreshToken(current, kSevenShiftsVendorIdForRefresh);
    final response = await _postForm(
      httpClient: httpClient,
      uri: tokenUri,
      form: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
        'client_secret': clientSecret,
      },
      vendorId: kSevenShiftsVendorIdForRefresh,
    );
    _ensureSuccess(response, kSevenShiftsVendorIdForRefresh);
    final json = _parseJsonObject(response, kSevenShiftsVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kSevenShiftsVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
    );
  };
}

// ─── QuickBooks Time / Intuit — POST /oauth2/v1/tokens/bearer ─────────

const String kQuickBooksTimeVendorIdForRefresh = 'quickbooks_time';
final Uri kQuickBooksTimeDefaultOauthTokenUri = Uri.parse(
  'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer',
);

/// Production refresh closure for [QuickBooksTimeBrokerCredentialStore].
///
/// Intuit OAuth 2.0: the bearer is per-tenant; the `client_id` /
/// `client_secret` are app-wide (loaded from `INTUIT_OAUTH_CLIENT_ID`
/// / `INTUIT_OAUTH_CLIENT_SECRET` at bootstrap). Intuit rotates the
/// refresh token on every refresh.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeQuickBooksTimeOauthRefreshClosure({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
  Uri? oauthTokenUri,
  DateTime Function()? clock,
}) {
  final tokenUri = oauthTokenUri ?? kQuickBooksTimeDefaultOauthTokenUri;
  return (VendorCredentialBundle current) async {
    final refreshToken =
        _requireRefreshToken(current, kQuickBooksTimeVendorIdForRefresh);
    final response = await _postForm(
      httpClient: httpClient,
      uri: tokenUri,
      form: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
      extraHeaders: <String, String>{
        'authorization': _basicAuthHeader(clientId, clientSecret),
      },
      vendorId: kQuickBooksTimeVendorIdForRefresh,
    );
    _ensureSuccess(response, kQuickBooksTimeVendorIdForRefresh);
    final json =
        _parseJsonObject(response, kQuickBooksTimeVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kQuickBooksTimeVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
    );
  };
}

// ─── Libro — POST /v1/oauth/refresh (refresh_token) ──────────────────

const String kLibroVendorIdForRefresh = 'libro';
final Uri kLibroDefaultBaseUri = Uri.parse('https://api.libroreserve.com');
const String kLibroOauthRefreshPath = '/v1/oauth/refresh';

/// Production refresh closure for [makeLibroBearerTokenResolver].
///
/// Libro uses an app-wide `client_id` / `client_secret` (one F&F
/// partner registration). Refresh token is per-tenant.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeLibroOauthRefreshClosure({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
  Uri? baseUri,
  DateTime Function()? clock,
}) {
  final base = baseUri ?? kLibroDefaultBaseUri;
  return (VendorCredentialBundle current) async {
    final refreshToken =
        _requireRefreshToken(current, kLibroVendorIdForRefresh);
    final response = await _postJson(
      httpClient: httpClient,
      uri: base.resolve(kLibroOauthRefreshPath),
      body: <String, Object?>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
        'client_secret': clientSecret,
      },
      vendorId: kLibroVendorIdForRefresh,
    );
    _ensureSuccess(response, kLibroVendorIdForRefresh);
    final json = _parseJsonObject(response, kLibroVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kLibroVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
    );
  };
}

// ─── ADP — POST /auth/oauth/v2/token (refresh_token) ─────────────────
//
// 2026-05-09 RE-INVESTIGATION: PR #455 documented ADP as "partner-ops
// mTLS rotation out-of-band, no programmatic refresh surface." On
// re-verification this conflated two separate rotation surfaces:
//
//   1. Partner-issued mTLS client certificate — rotated by ADP partner-
//      ops on a vendor-driven cadence; the cert lives in the worker's
//      `http.Client` `SecurityContext` (wired at Cloud Run boot via
//      `ADP_MTLS_CERT_PATH` / `ADP_MTLS_KEY_PATH`); the closure does not
//      touch this surface.
//   2. OAuth `refresh_token` — standard `grant_type=refresh_token`
//      against `/auth/oauth/v2/token` using the per-tenant
//      `client_id` / `client_secret` (HTTP Basic). The transport's
//      `AdpLaborProductionApiClient.refresh(refreshToken:, module:)`
//      already implements this, and the persisted credential row carries
//      the refresh token + per-tenant client credentials.
//
// This closure mirrors the transport's `_tokenRequest` path but POSTs
// directly so the broker stays the single rotation owner (matches the
// Square / Clover / 7shifts / QuickBooks Time pattern). The mTLS
// `http.Client` is the same one the transport uses; production wires
// the SecurityContext at Cloud Run boot.

const String kAdpVendorIdForRefresh = 'adp';
final Uri kAdpDefaultOauthBaseUri = Uri.parse('https://accounts.adp.com');
const String kAdpOauthTokenPath = '/auth/oauth/v2/token';

/// Metadata key carrying the operator's selected ADP module
/// (`workforce_now` / `workforce_manager`). Written by
/// `AdpConnectionRow.toMetadata()` into both `vendor_credentials.metadata`
/// and `connector_connection.metadata` at connect time.
const String kAdpMetadataModule = 'module';

/// Default ADP module when the bundle metadata does not name one. ADP
/// Workforce Now is the documented majority deployment per
/// `docs/phases/phase_8/vendor_master_list.md` "Module Disambiguation
/// Flags"; the fallback keeps the refresh tick from failing closed when
/// a legacy row's metadata is missing the module key.
const String kAdpDefaultModule = 'workforce_now';

/// Production refresh closure for the ADP labor credential bridge.
///
/// ADP uses a per-tenant `client_id` / `client_secret` pair (HTTP Basic
/// against the `/auth/oauth/v2/token` endpoint) plus a per-tenant
/// `refresh_token`. The `x-adp-module` header is required so ADP routes
/// the call against the right product surface (Workforce Now /
/// Workforce Manager); the module is read from
/// `bundle.connectionMetadata['module']` first (where the connect path
/// writes it), falling back to `bundle.metadata['module']`, finally to
/// the documented default ([kAdpDefaultModule]).
///
/// Note: production mTLS lands on the injected [http.Client] (see the
/// SecurityContext wiring in the worker bootstrap). The closure itself
/// is mTLS-agnostic.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeAdpOauthRefreshClosure({
  required http.Client httpClient,
  Uri? oauthBaseUri,
  DateTime Function()? clock,
}) {
  final base = oauthBaseUri ?? kAdpDefaultOauthBaseUri;
  return (VendorCredentialBundle current) async {
    final clientId = _requireMetadataString(
      current,
      current.clientId,
      kBundleMetadataClientId,
      kAdpVendorIdForRefresh,
    );
    final clientSecret = _requireMetadataString(
      current,
      current.clientSecret,
      kBundleMetadataClientSecret,
      kAdpVendorIdForRefresh,
    );
    final refreshToken =
        _requireRefreshToken(current, kAdpVendorIdForRefresh);
    final module = _readAdpModule(current);
    final response = await _postForm(
      httpClient: httpClient,
      uri: base.resolve(kAdpOauthTokenPath),
      form: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
      extraHeaders: <String, String>{
        'authorization': _basicAuthHeader(clientId, clientSecret),
        'x-adp-module': module,
      },
      vendorId: kAdpVendorIdForRefresh,
    );
    _ensureSuccess(response, kAdpVendorIdForRefresh);
    final json = _parseJsonObject(response, kAdpVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kAdpVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      // ADP rotates the refresh token on every refresh per the
      // documented "rotating refresh token" shape; persist the new one
      // when present so the next tick has a fresh token to spend.
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
    );
  };
}

/// Read the ADP module from the bundle's connection metadata first
/// (where `AdpConnectionRow.toMetadata` writes it during connect),
/// falling back to vendor-credentials metadata, finally to the
/// documented default. The fallback chain mirrors the
/// `connector_connection.metadata` precedence the broker bundle exposes.
String _readAdpModule(VendorCredentialBundle current) {
  final connection = current.connectionMetadata[kAdpMetadataModule];
  if (connection is String && connection.isNotEmpty) return connection;
  final credential = current.metadata[kAdpMetadataModule];
  if (credential is String && credential.isNotEmpty) return credential;
  return kAdpDefaultModule;
}

// ─── OpenTable — POST /api/v2/oauth/token (refresh_token) ────────────
//
// 2026-05-09 RE-INVESTIGATION: PR #455 documented OpenTable as
// "transport-internal refresh — `OpenTableTransport.refresh` owns the
// rotation." On re-verification:
//
//   * The transport HAS a `refresh(refreshToken:)` method, but no code
//     in the codebase drives it automatically. There is no
//     scheduling / cron / on-401 retry loop anywhere that calls it.
//   * The "transport-internal refresh" was an aspirational description
//     (`oauth_shape.md` "Refresh handling" + production-api-client
//     doc-comment), not an actual implementation.
//
// The OAuth shape itself is standard: `grant_type=refresh_token`
// against `/api/v2/oauth/token` using the per-tenant `client_id` /
// `client_secret` from `metadata`. This closure mirrors the transport's
// `_runOAuthTokenCall` shape so the broker becomes the single rotation
// owner — same pattern as Square / Clover / 7shifts / QuickBooks Time.

const String kOpenTableVendorIdForRefresh = 'opentable';
final Uri kOpenTableDefaultOauthBaseUriForRefresh =
    Uri.parse('https://oauth-pii.opentable.com');
const String kOpenTableOauthTokenPathForRefresh = '/api/v2/oauth/token';

/// Production refresh closure for the OpenTable reservation credential
/// bridge.
///
/// OpenTable rotates the refresh token on every refresh per
/// `docs/integrations/opentable/oauth_shape.md` ("rotating refresh
/// tokens, 90 days") — the new refresh_token threads back through
/// [TokenRefreshResult.refreshToken] so the broker re-encrypts and
/// persists it on the row.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeOpenTableOauthRefreshClosure({
  required http.Client httpClient,
  Uri? oauthBaseUri,
  DateTime Function()? clock,
}) {
  final base = oauthBaseUri ?? kOpenTableDefaultOauthBaseUriForRefresh;
  return (VendorCredentialBundle current) async {
    final clientId = _requireMetadataString(
      current,
      current.clientId,
      kBundleMetadataClientId,
      kOpenTableVendorIdForRefresh,
    );
    final clientSecret = _requireMetadataString(
      current,
      current.clientSecret,
      kBundleMetadataClientSecret,
      kOpenTableVendorIdForRefresh,
    );
    final refreshToken =
        _requireRefreshToken(current, kOpenTableVendorIdForRefresh);
    final response = await _postForm(
      httpClient: httpClient,
      uri: base.resolve(kOpenTableOauthTokenPathForRefresh),
      form: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
        'client_secret': clientSecret,
      },
      vendorId: kOpenTableVendorIdForRefresh,
    );
    _ensureSuccess(response, kOpenTableVendorIdForRefresh);
    final json = _parseJsonObject(response, kOpenTableVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kOpenTableVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    // OpenTable's transport `_resolveTokenExpiry` accepts either an
    // `expires_at` ISO-8601 string or an `expires_in` seconds count;
    // mirror that two-source resolution here.
    final expiresAt = _readExpiresAtInstant(json, 'expires_at') ??
        _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
    );
  };
}

// ─── Humanity — POST /v1.0/oauth2/token (refresh_token) ──────────────

const String kHumanityVendorIdForRefresh = 'humanity';
final Uri kHumanityDefaultOauthTokenUri = Uri.parse(
  'https://platform.humanity.com/v1.0/oauth2/token',
);

/// Production refresh closure for [HumanityBrokerCredentialBridge].
///
/// Humanity uses an app-wide `client_id` / `client_secret`. The
/// connect-time grant is `password`, but refresh uses `refresh_token`.
Future<TokenRefreshResult> Function(VendorCredentialBundle)
    makeHumanityOauthRefreshClosure({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
  Uri? oauthTokenUri,
  DateTime Function()? clock,
}) {
  final tokenUri = oauthTokenUri ?? kHumanityDefaultOauthTokenUri;
  return (VendorCredentialBundle current) async {
    final refreshToken =
        _requireRefreshToken(current, kHumanityVendorIdForRefresh);
    final response = await _postForm(
      httpClient: httpClient,
      uri: tokenUri,
      form: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
        'client_secret': clientSecret,
      },
      vendorId: kHumanityVendorIdForRefresh,
    );
    _ensureSuccess(response, kHumanityVendorIdForRefresh);
    final json = _parseJsonObject(response, kHumanityVendorIdForRefresh);
    final accessToken = _readNonEmptyString(
      json,
      'access_token',
      kHumanityVendorIdForRefresh,
      statusCode: response.statusCode,
      body: response.body,
    );
    final newRefresh = json['refresh_token'];
    final expiresAt = _readExpiresInToInstant(json, clock: clock);
    return TokenRefreshResult(
      accessToken: accessToken,
      refreshToken:
          newRefresh is String && newRefresh.isNotEmpty ? newRefresh : null,
      expiresAt: expiresAt,
    );
  };
}
