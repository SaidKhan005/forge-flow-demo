// Phase 8 framework — Vendor credential broker.
//
// Central server-side service that brokers per-(operator, location, vendor)
// credentials between the encrypted `vendor_credentials` Postgres table and
// the 17 production HTTP transports landed in Wave 0. Each transport
// declares its own credential resolver interface (typedefs / abstract
// classes); the per-vendor bridge files in
// `lib/integrations/{pos,reservation,labor}/` implement those interfaces
// by delegating into this broker.
//
// CLAUDE.md alignment:
//   * Hard Promise #7 — F&F holds all provider keys server-side. The
//     broker never returns plaintext to the client process; it lives
//     under `tool/advisor_proxy/` (Cloud Run) and decrypts via
//     `pgp_sym_decrypt` against an envelope key supplied at startup.
//   * Hard Promise #4 — per-operator isolation. Every read/write is
//     mediated by `OperatorScopedRepository.withTenant(...)`, so the
//     `(operator_id, location_id)` SET LOCAL trio injects before the
//     row touches the wire.
//   * Hard Promise #1 — pure transport swap. The broker only reads /
//     writes the Wave 0 framework tables; it does not touch canonical
//     fact tables.
//
// Behaviour summary:
//
//   * `resolveAccessToken(operatorId, locationId, vendorId)` returns the
//     current decrypted bearer token. Decryption uses pgp_sym_decrypt
//     (mirroring `RepositoryInboundWebhookGateway.lookupSigningSecret`
//     in `lib/services/integration/repository_inbound_webhook_gateway.dart`).
//     The plaintext is cached in process memory keyed by
//     `(operatorId, locationId, vendorId)` with TTL =
//     `(token_expires_at - now() - kAccessTokenRefreshLeadTime)`.
//   * If the cached token is within `kAccessTokenRefreshLeadTime` of
//     expiry (or absent), `resolveAccessToken` will call `refreshAccessToken`
//     under a per-tenant Future lock so concurrent callers wait on the
//     same in-flight refresh.
//   * `resolveCredentialBundle(...)` returns a typed
//     [VendorCredentialBundle] populated from the `vendor_credentials`
//     row + the row's `metadata` JSONB. Used by transports that need
//     more than a bearer (Clover app id; Aloha NCR Voyix application
//     key + organization id; Square clientId/clientSecret pair when
//     persisted there; etc.).
//   * `refreshAccessToken(... doRefresh: ...)` accepts a vendor-specific
//     closure that knows how to talk to the vendor's OAuth endpoint —
//     the broker doesn't know vendor-specific OAuth shapes. The closure
//     receives the current bundle and returns a [TokenRefreshResult];
//     the broker writes the new ciphertext back into `vendor_credentials`
//     and updates the in-memory cache.
//   * `invalidate(...)` drops the cached bearer (called on disconnect or
//     explicit revoke).
//
// Schema notes (db/migrations/202605040000_phase_8_0_integration_framework.sql):
//   * `vendor_credentials.access_token_ciphertext bytea` and
//     `refresh_token_ciphertext bytea` — pgcrypto-envelope-encrypted.
//   * `vendor_credentials.token_expires_at timestamptz` — UTC instant
//     the access token expires. Nullable.
//   * `vendor_credentials.metadata jsonb` — non-secret extra fields the
//     adapter / proxy need (e.g. apiKey, clientId, merchantId, webhook
//     subscription id). The broker projects this directly into the
//     bundle's `metadata` field; richer top-level accessors
//     (`apiKey`, `clientId`, `merchantId`, `webhookSubscriptionId`) read
//     from well-known metadata keys and fall back to `null`.
//   * `connector_connection.metadata jsonb` — additional non-secret
//     metadata at the connection level (vendor-side identity bindings:
//     restaurant_id, business_id, site_id, …). The broker exposes this
//     under `bundle.connectionMetadata` so per-vendor bridges can read
//     fields like `merchant_id` or `webhook_subscription_id` that live
//     on the connection row instead of the credential row.

import 'dart:async';
import 'dart:convert';

import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../../infrastructure/persistence/postgres/tenant_transaction.dart';

/// Refresh the access token when its remaining lifetime is at or below
/// this threshold. 60 s leaves enough headroom for a slow OAuth round
/// trip + clock skew across the vendor and our process.
const Duration kAccessTokenRefreshLeadTime = Duration(seconds: 60);

/// Common metadata keys the broker projects into top-level bundle
/// fields. Bridges can also read directly from the merged `metadata`
/// map using vendor-specific keys.
const String kBundleMetadataApiKey = 'api_key';
const String kBundleMetadataApiSecret = 'api_secret';
const String kBundleMetadataClientId = 'client_id';
const String kBundleMetadataClientSecret = 'client_secret';
const String kBundleMetadataMerchantId = 'merchant_id';
const String kBundleMetadataWebhookSubscriptionId =
    'webhook_subscription_id';

/// Typed credential bundle returned by [VendorCredentialBroker.resolveCredentialBundle].
///
/// `accessToken` is always non-null when the broker returns the bundle;
/// missing access-token rows surface as [VendorCredentialNotFound].
/// Other fields are nullable because vendor schemas vary widely —
/// per-vendor bridges read whichever subset is relevant for their
/// transport.
class VendorCredentialBundle {
  const VendorCredentialBundle({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.accessToken,
    required this.metadata,
    required this.connectionMetadata,
    this.refreshToken,
    this.expiresAt,
    this.apiKey,
    this.apiSecret,
    this.clientId,
    this.clientSecret,
    this.merchantId,
    this.webhookSubscriptionId,
  });

  final String operatorId;
  final String locationId;
  final String vendorId;
  final String accessToken;
  final String? refreshToken;

  /// UTC instant the access token expires. Null when the credential
  /// row does not record an expiry (long-lived API keys, manually
  /// rotated bearers, etc.).
  final DateTime? expiresAt;

  /// `vendor_credentials.metadata` JSONB merged into a Map. Excludes the
  /// six well-known keys hoisted into the typed accessors below.
  final Map<String, Object?> metadata;

  /// `connector_connection.metadata` JSONB. Vendor-side identity
  /// bindings live here (restaurant_id, business_id, site_id, ...).
  final Map<String, Object?> connectionMetadata;

  /// Static API key (non-OAuth vendors). Read from
  /// `metadata.api_key` when present.
  final String? apiKey;

  /// API secret paired with [apiKey] for vendors that mint a key+secret
  /// pair. Read from `metadata.api_secret` when present.
  final String? apiSecret;

  /// OAuth client id for vendors where the `(client_id, client_secret)`
  /// pair is per-tenant rather than app-wide. Read from
  /// `metadata.client_id` when present.
  final String? clientId;

  /// OAuth client secret. Read from `metadata.client_secret` when
  /// present.
  final String? clientSecret;

  /// Vendor-side merchant identifier (Clover, Square). Read from
  /// `connection_metadata.merchant_id` first, then `metadata.merchant_id`.
  final String? merchantId;

  /// Vendor-side webhook subscription identifier. Stored on the
  /// connection row first; falls back to `metadata` when absent.
  final String? webhookSubscriptionId;
}

/// Returned by the per-vendor refresh closure passed into
/// [VendorCredentialBroker.refreshAccessToken]. Carries the freshly-
/// minted access token plus optional refresh token + expiry the broker
/// persists back to `vendor_credentials`.
class TokenRefreshResult {
  const TokenRefreshResult({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.metadataPatch,
  });

  /// Plaintext bearer minted by the vendor.
  final String accessToken;

  /// New refresh token (rotation). Null when the vendor does not rotate
  /// refresh tokens; the broker leaves the stored ciphertext untouched
  /// in that case.
  final String? refreshToken;

  /// New `token_expires_at`. Null when the vendor does not provide an
  /// expiry. The broker writes null in that case so the next
  /// `resolveAccessToken` triggers another refresh.
  final DateTime? expiresAt;

  /// Optional metadata patch merged into the existing
  /// `vendor_credentials.metadata` map. Null leaves metadata untouched.
  final Map<String, Object?>? metadataPatch;
}

/// Typed errors. The broker never throws a bare exception — every
/// failure surfaces as one of these so callers can decide between
/// "reconnect required" (NotFound), "rotate envelope key" (Decrypt),
/// and "vendor side issue" (Refresh).
sealed class VendorCredentialBrokerError implements Exception {
  const VendorCredentialBrokerError(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

class VendorCredentialNotFound extends VendorCredentialBrokerError {
  const VendorCredentialNotFound(super.message);
}

class VendorCredentialDecryptFailed extends VendorCredentialBrokerError {
  const VendorCredentialDecryptFailed(super.message);
}

class VendorRefreshFailed extends VendorCredentialBrokerError {
  const VendorRefreshFailed(super.message);
}

/// Cache entry. Held in memory only; never serialized.
class _CachedAccessToken {
  _CachedAccessToken({required this.token, required this.expiresAt});
  final String token;

  /// Real (vendor-reported) `token_expires_at`. The broker treats the
  /// token as expired when `now() + kAccessTokenRefreshLeadTime >= expiresAt`.
  /// Null `expiresAt` means "do not cache" — the broker re-resolves
  /// every call, which is the correct behaviour for long-lived API keys
  /// because the source-of-truth lives in Postgres.
  final DateTime? expiresAt;
}

/// Broker. One instance per Cloud Run worker; the bridges call
/// `resolveAccessToken` / `resolveCredentialBundle` from inside the
/// adapter loop. Thread-safe — concurrent refresh calls collapse to a
/// single in-flight Future per `(operatorId, locationId, vendorId)`.
class VendorCredentialBroker extends OperatorScopedRepository {
  VendorCredentialBroker({
    required TenantTransactionWrapper tenantWrapper,
    required String pgcryptoEnvelopeKey,
    DateTime Function()? clock,
  })  : _pgcryptoEnvelopeKey = pgcryptoEnvelopeKey,
        _clock = clock ?? DateTime.now,
        super(tenantWrapper) {
    if (pgcryptoEnvelopeKey.isEmpty) {
      throw ArgumentError.value(
        pgcryptoEnvelopeKey,
        'pgcryptoEnvelopeKey',
        'must be non-empty (vendor credential decryption requires it)',
      );
    }
  }

  final String _pgcryptoEnvelopeKey;
  final DateTime Function() _clock;

  /// Process-local cache. Keyed on `(operatorId, locationId, vendorId)`
  /// — the same triple `vendor_credentials` is keyed on. Cleared via
  /// [invalidate] on disconnect or explicit revoke.
  final Map<String, _CachedAccessToken> _accessTokenCache =
      <String, _CachedAccessToken>{};

  /// Per-key Future locks. Concurrent refresh calls return the same
  /// in-flight Future so the vendor sees one OAuth round trip per
  /// expired credential, not N.
  final Map<String, Future<String>> _inFlightRefreshes =
      <String, Future<String>>{};

  /// Returns the current bearer for the named tenant + vendor. Refreshes
  /// transparently when the cached token is within
  /// [kAccessTokenRefreshLeadTime] of expiry.
  ///
  /// The `doRefresh` closure is required when the broker may need to
  /// refresh — bridges supply a vendor-specific closure that calls the
  /// transport's OAuth-exchange method. When `doRefresh` is null and a
  /// refresh is needed, the broker throws [VendorRefreshFailed] so the
  /// caller surfaces a reconnect prompt.
  Future<String> resolveAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    Future<TokenRefreshResult> Function(VendorCredentialBundle current)?
        doRefresh,
  }) async {
    final key = _cacheKey(operatorId, locationId, vendorId);
    final cached = _accessTokenCache[key];
    if (cached != null && !_isExpired(cached.expiresAt)) {
      return cached.token;
    }
    // Read the row from Postgres. If the row says the token is still
    // valid (a different worker refreshed since our last cache hit),
    // re-cache and return without OAuth round trip.
    final bundle = await _readBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );
    if (!_isExpired(bundle.expiresAt)) {
      _accessTokenCache[key] = _CachedAccessToken(
        token: bundle.accessToken,
        expiresAt: bundle.expiresAt,
      );
      return bundle.accessToken;
    }
    // Refresh required.
    if (doRefresh == null) {
      throw VendorRefreshFailed(
        'access token for $vendorId@$operatorId/$locationId is expired '
        'and no refresh closure was supplied',
      );
    }
    return refreshAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      doRefresh: doRefresh,
    );
  }

  /// Resolves the full credential bundle. Does NOT refresh — bridges
  /// that need bundle data plus a fresh bearer should call
  /// [resolveAccessToken] first to satisfy the refresh path, then call
  /// this method which (post-refresh) sees the new bearer.
  Future<VendorCredentialBundle> resolveCredentialBundle({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) {
    return _readBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );
  }

  /// Forces a refresh through `doRefresh` and persists the new
  /// ciphertext back to `vendor_credentials`. Concurrent callers
  /// observe a single in-flight Future so the vendor sees exactly one
  /// OAuth round trip per (tenant, vendor) pair.
  Future<String> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) {
    final key = _cacheKey(operatorId, locationId, vendorId);
    final inFlight = _inFlightRefreshes[key];
    if (inFlight != null) return inFlight;
    final future = _doRefresh(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      doRefresh: doRefresh,
    );
    _inFlightRefreshes[key] = future;
    // Whichever way the future resolves, drop the in-flight slot so a
    // later refresh can run. `whenComplete` runs after both resolve and
    // error paths.
    future.whenComplete(() {
      // Only clear if our future is still the registered one — a fast
      // failure followed by a re-issue could otherwise wipe a valid
      // newer in-flight Future.
      if (identical(_inFlightRefreshes[key], future)) {
        _inFlightRefreshes.remove(key);
      }
    });
    return future;
  }

  Future<String> _doRefresh({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) async {
    final current = await _readBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );
    final TokenRefreshResult refreshed;
    try {
      refreshed = await doRefresh(current);
    } catch (error) {
      throw VendorRefreshFailed(
        '$vendorId@$operatorId/$locationId refresh closure '
        'threw ${error.runtimeType}: $error',
      );
    }
    if (refreshed.accessToken.isEmpty) {
      throw VendorRefreshFailed(
        '$vendorId@$operatorId/$locationId refresh closure '
        'returned an empty access token',
      );
    }
    final mergedMetadata = <String, Object?>{
      ...current.metadata,
      if (current.apiKey != null) kBundleMetadataApiKey: current.apiKey,
      if (current.apiSecret != null)
        kBundleMetadataApiSecret: current.apiSecret,
      if (current.clientId != null) kBundleMetadataClientId: current.clientId,
      if (current.clientSecret != null)
        kBundleMetadataClientSecret: current.clientSecret,
      if (current.merchantId != null)
        kBundleMetadataMerchantId: current.merchantId,
      if (current.webhookSubscriptionId != null)
        kBundleMetadataWebhookSubscriptionId: current.webhookSubscriptionId,
      ...?refreshed.metadataPatch,
    };
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    await withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'update public.vendor_credentials set '
        '  access_token_ciphertext = '
        '    pgp_sym_encrypt(@access_token_plaintext, @envelope_key), '
        '  refresh_token_ciphertext = case '
        '    when @refresh_token_plaintext is null '
        '      then refresh_token_ciphertext '
        '    else pgp_sym_encrypt(@refresh_token_plaintext, @envelope_key) '
        '  end, '
        '  token_expires_at = @token_expires_at, '
        '  metadata = @metadata::jsonb, '
        '  is_active = true, '
        '  consecutive_refresh_failures = 0, '
        '  updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and vendor_id = @vendor_id '
        '  and (location_id = @location_id::uuid or location_id is null)',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'access_token_plaintext': refreshed.accessToken,
          'refresh_token_plaintext': refreshed.refreshToken,
          'token_expires_at': refreshed.expiresAt?.toUtc(),
          'metadata': jsonEncode(mergedMetadata),
          'envelope_key': _pgcryptoEnvelopeKey,
        },
      );
    });
    final key = _cacheKey(operatorId, locationId, vendorId);
    _accessTokenCache[key] = _CachedAccessToken(
      token: refreshed.accessToken,
      expiresAt: refreshed.expiresAt,
    );
    return refreshed.accessToken;
  }

  /// Drop the cached bearer for `(operatorId, locationId, vendorId)`.
  /// Bridges call this on disconnect or explicit revoke so a freshly
  /// reconnected credential doesn't get shadowed by a stale cache.
  Future<void> invalidate({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    _accessTokenCache.remove(_cacheKey(operatorId, locationId, vendorId));
  }

  // ── Internals ─────────────────────────────────────────────────────

  String _cacheKey(String operatorId, String locationId, String vendorId) {
    return '$operatorId|$locationId|$vendorId';
  }

  bool _isExpired(DateTime? expiresAt) {
    if (expiresAt == null) return true;
    final now = _clock().toUtc();
    return now.add(kAccessTokenRefreshLeadTime).isAfter(expiresAt.toUtc());
  }

  Future<VendorCredentialBundle> _readBundle({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<VendorCredentialBundle>(ctx, (exec) async {
      final List<PostgresRow> rows;
      try {
        rows = await exec.query(
          'select '
          '  pgp_sym_decrypt(vc.access_token_ciphertext, @envelope_key) '
          '    as access_token_plaintext, '
          '  case when vc.refresh_token_ciphertext is null then null '
          '       else pgp_sym_decrypt(vc.refresh_token_ciphertext, '
          '              @envelope_key) end '
          '    as refresh_token_plaintext, '
          '  vc.token_expires_at, '
          '  vc.metadata, '
          '  cc.metadata as connection_metadata '
          'from public.vendor_credentials vc '
          'left join public.connector_connection cc '
          '  on cc.operator_id = vc.operator_id '
          '  and cc.vendor_id = vc.vendor_id '
          '  and (cc.location_id = vc.location_id '
          '       or vc.location_id is null) '
          'where vc.operator_id = @operator_id::uuid '
          '  and vc.vendor_id = @vendor_id '
          '  and vc.is_active = true '
          '  and vc.access_token_ciphertext is not null '
          '  and (vc.location_id = @location_id::uuid '
          '       or vc.location_id is null) '
          'order by '
          '  case when vc.location_id is null then 1 else 0 end, '
          '  vc.updated_at desc '
          'limit 1',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'vendor_id': vendorId,
            'envelope_key': _pgcryptoEnvelopeKey,
          },
        );
      } on VendorCredentialBrokerError {
        rethrow;
      } catch (error) {
        // pgcrypto wrong-key, malformed ciphertext, or any other
        // server-side decrypt failure surfaces here.
        throw VendorCredentialDecryptFailed(
          'pgp_sym_decrypt failed for $vendorId@$operatorId/$locationId: '
          '${error.runtimeType}',
        );
      }
      if (rows.isEmpty) {
        throw VendorCredentialNotFound(
          'no active vendor_credentials row for '
          '$vendorId@$operatorId/$locationId',
        );
      }
      final row = rows.single;
      final access = _coerceText(row['access_token_plaintext']);
      if (access == null || access.isEmpty) {
        throw VendorCredentialDecryptFailed(
          'access_token decrypted to null/empty for '
          '$vendorId@$operatorId/$locationId',
        );
      }
      final refresh = _coerceText(row['refresh_token_plaintext']);
      final expiresAt = _coerceTimestamp(row['token_expires_at']);
      final metadataRaw = _coerceJsonbObject(row['metadata']);
      final connectionMetadataRaw =
          _coerceJsonbObject(row['connection_metadata']);
      // Hoist the common metadata keys into typed accessors. The
      // remaining keys stay in [VendorCredentialBundle.metadata] so
      // bridges can read vendor-specific keys verbatim.
      final apiKey = _readString(metadataRaw, kBundleMetadataApiKey);
      final apiSecret = _readString(metadataRaw, kBundleMetadataApiSecret);
      final clientId = _readString(metadataRaw, kBundleMetadataClientId);
      final clientSecret = _readString(metadataRaw, kBundleMetadataClientSecret);
      // Merchant id / webhook subscription id may live on either the
      // credential row's metadata OR the connection row's metadata
      // (Clover uses the connection row; Square uses the connection row).
      final merchantId = _readString(connectionMetadataRaw, kBundleMetadataMerchantId)
          ?? _readString(metadataRaw, kBundleMetadataMerchantId);
      final webhookSubscriptionId = _readString(
            connectionMetadataRaw, kBundleMetadataWebhookSubscriptionId,
          )
          ?? _readString(metadataRaw, kBundleMetadataWebhookSubscriptionId);
      final filteredMetadata = <String, Object?>{
        for (final entry in metadataRaw.entries)
          if (!_kHoistedMetadataKeys.contains(entry.key))
            entry.key: entry.value,
      };
      return VendorCredentialBundle(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        accessToken: access,
        refreshToken: refresh,
        expiresAt: expiresAt,
        apiKey: apiKey,
        apiSecret: apiSecret,
        clientId: clientId,
        clientSecret: clientSecret,
        merchantId: merchantId,
        webhookSubscriptionId: webhookSubscriptionId,
        metadata: Map<String, Object?>.unmodifiable(filteredMetadata),
        connectionMetadata:
            Map<String, Object?>.unmodifiable(connectionMetadataRaw),
      );
    });
  }

  static const Set<String> _kHoistedMetadataKeys = <String>{
    kBundleMetadataApiKey,
    kBundleMetadataApiSecret,
    kBundleMetadataClientId,
    kBundleMetadataClientSecret,
    kBundleMetadataMerchantId,
    kBundleMetadataWebhookSubscriptionId,
  };

  static String? _coerceText(Object? raw) {
    if (raw == null) return null;
    if (raw is String) return raw;
    if (raw is List<int>) return utf8.decode(raw);
    return raw.toString();
  }

  static DateTime? _coerceTimestamp(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw.toUtc();
    if (raw is String) {
      try {
        return DateTime.parse(raw).toUtc();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Map<String, Object?> _coerceJsonbObject(Object? raw) {
    if (raw == null) return const <String, Object?>{};
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    if (raw is String) {
      if (raw.isEmpty) return const <String, Object?>{};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) return decoded;
        if (decoded is Map) {
          return decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        }
      } catch (_) {
        return const <String, Object?>{};
      }
    }
    return const <String, Object?>{};
  }

  static String? _readString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is String && value.isNotEmpty) return value;
    return null;
  }
}
