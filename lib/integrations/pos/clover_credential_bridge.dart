// Phase 8 framework — Clover credential bridge.
//
// Wires Clover's three injected typedefs declared in
// `lib/integrations/pos/clover_pos_production_api_client.dart` to the
// shared [VendorCredentialBroker] (per-merchant access token) plus
// app-wide static sources (app token + app id).
//
//   * [CloverAccessTokenSource] — async; per `(operatorId, locationId)`
//     bearer token. The broker path mediates `vendor_credentials`
//     decryption + caching.
//   * [CloverAppTokenSource] — sync; one app-wide value loaded from
//     `CLOVER_APP_TOKEN` server-side env at startup.
//   * [CloverAppIdSource] — sync; one app-wide value loaded from
//     `CLOVER_APP_ID` server-side env at startup.
//
// CLAUDE.md alignment: HP #4 (per-operator isolation) — every read
// rides `withTenant`. HP #7 (server-side keys) — the app token + app
// id are server-side env vars; they never enter the Flutter build.

import '../_common/vendor_credential_broker.dart';
import 'clover_pos_production_api_client.dart';

/// Clover vendor identifier in `vendor_credentials.vendor_id`.
const String kCloverVendorId = 'clover';

/// Builder that produces a [CloverAccessTokenSource] closure bound to
/// the given (operatorId, locationId). The proxy bootstrap calls this
/// once per request after resolving the operator/location.
///
/// `oauthRefresh` is the vendor-specific refresh closure — when the
/// merchant token is within `kAccessTokenRefreshLeadTime` of expiry,
/// the broker invokes it to mint a fresh token via Clover's OAuth flow
/// (`POST /oauth/v2/refresh`).
CloverAccessTokenSource makeCloverAccessTokenSource({
  required VendorCredentialBroker broker,
  required String operatorId,
  required String locationId,
  required Future<TokenRefreshResult> Function(VendorCredentialBundle)
      oauthRefresh,
}) {
  return () => broker.resolveAccessToken(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: kCloverVendorId,
        doRefresh: oauthRefresh,
      );
}

/// Static [CloverAppTokenSource] — returns the same string forever.
/// Production loads the value from `CLOVER_APP_TOKEN` env at bootstrap.
CloverAppTokenSource makeStaticCloverAppTokenSource(String appToken) {
  return () => appToken;
}

/// Static [CloverAppIdSource] — returns the same string forever.
/// Production loads the value from `CLOVER_APP_ID` env at bootstrap.
CloverAppIdSource makeStaticCloverAppIdSource(String appId) {
  return () => appId;
}
