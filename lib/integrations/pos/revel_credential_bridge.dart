// Phase 8 framework — Revel credential bridge.
//
// Deviation note (recorded in the slice report): unlike most Wave 0
// transports, [RevelTransport] (declared in
// `lib/integrations/pos/revel_pos_adapter.dart`) does NOT carry an
// injected credential resolver — every method takes the bearer / client
// credentials as plain parameters. Revel ships in two auth modes:
//   * `RevelAuthMode.oauth`         — bearer JWT with 24h TTL.
//   * `RevelAuthMode.apiKeyHeader`  — synthesised envelope built from
//                                      `<client_id>:<client_secret>`.
//
// The bridge therefore exposes a small helper class — one method per
// thing the proxy / framework needs — that delegates into the shared
// [VendorCredentialBroker]. The proxy's adapter scheduler reads the
// bearer (or client-id/client-secret pair) before calling
// `RevelTransport.listOrders` / `fetchOrder` / etc. and threads the
// plaintext into the method parameter.
//
// CLAUDE.md alignment: HP #4 (per-operator isolation) — every read
// rides `withTenant`. HP #7 — plaintext credentials never leave Cloud
// Run; the helper is server-side only.

import '../_common/vendor_credential_broker.dart';

/// Revel vendor identifier in `vendor_credentials.vendor_id`.
const String kRevelVendorId = 'revel';

/// Closure that runs Revel's `oauth/token` `grant_type=client_credentials`
/// flow when the cached JWT is near expiry. Production wires the live
/// `https://authentication.revelup.com/oauth/token` shape; tests pass a
/// canned closure.
typedef RevelOauthExchangeFn = Future<TokenRefreshResult> Function(
  VendorCredentialBundle current,
);

/// Helper consumed by the proxy / framework to get the credentials
/// Revel's transport needs at call time. The transport itself accepts
/// `accessToken` (oauth mode) or the legacy synthesised envelope
/// (`<client_id>:<client_secret>` in `apiKeyHeader` mode) as a method
/// parameter.
class RevelBrokerCredentialBridge {
  RevelBrokerCredentialBridge({
    required this.broker,
    required this.operatorId,
    required this.locationId,
    required this.oauthExchange,
  });

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;
  final RevelOauthExchangeFn oauthExchange;

  /// OAuth-mode bearer. Refreshes through the broker if the token is
  /// near expiry.
  Future<String> resolveAccessToken() {
    return broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kRevelVendorId,
      doRefresh: oauthExchange,
    );
  }

  /// Returns the full bundle — the proxy reads `clientId` /
  /// `clientSecret` for the OAuth `client_credentials` grant or the
  /// legacy `apiKeyHeader` envelope.
  Future<VendorCredentialBundle> resolveBundle() {
    return broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kRevelVendorId,
    );
  }
}
