// Phase 8 framework — Humanity credential bridge.
//
// Deviation note (recorded in the slice report): unlike most Wave 0
// transports, [HumanityHttpClient] (declared in
// `lib/integrations/labor/humanity_labor_adapter.dart`) does NOT take
// an injected credential resolver — every method takes a
// [VendorCredentialHandle], and the production transport is expected
// to resolve the handle internally. The transport file
// `humanity_labor_production_api_client.dart` doesn't currently route
// through a resolver seam (it hands the `Authorization` header off to
// the proxy at request-build time).
//
// The bridge therefore exposes a small helper class — one method per
// bearer / refresh-token resolution — that delegates into the shared
// [VendorCredentialBroker]. The proxy reads the bearer from this
// bridge before constructing the outbound request.
//
// CLAUDE.md alignment: HP #4 — every read rides `withTenant`. HP #7 —
// plaintext bearer + refresh tokens never leave Cloud Run.

import '../_common/vendor_credential_broker.dart';
import 'humanity_labor_adapter.dart' show VendorCredentialHandle;

/// Humanity (TCP) vendor identifier in `vendor_credentials.vendor_id`.
const String kHumanityVendorId = 'humanity';

class HumanityBrokerCredentialBridge {
  HumanityBrokerCredentialBridge({
    required this.broker,
    required this.operatorId,
    required this.locationId,
    required this.oauthRefresh,
  });

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;

  /// Closure that runs Humanity's `oauth2/token` `refresh_token` grant
  /// when the cached bearer is near expiry. Production wires the live
  /// `https://platform.humanity.com/v1.0/oauth2/token` shape; tests
  /// pass a canned closure.
  final Future<TokenRefreshResult> Function(VendorCredentialBundle)
      oauthRefresh;

  /// Resolve the current bearer token. Refreshes via [oauthRefresh]
  /// when the cached token is within `kAccessTokenRefreshLeadTime` of
  /// expiry.
  Future<String> resolveAccessToken(VendorCredentialHandle handle) {
    return broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kHumanityVendorId,
      doRefresh: oauthRefresh,
    );
  }

  /// Resolve the persisted refresh token. Required by Humanity's
  /// `revokeCredential` path on disconnect.
  Future<String?> resolveRefreshToken(
    VendorCredentialHandle handle,
  ) async {
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kHumanityVendorId,
    );
    return bundle.refreshToken;
  }
}
