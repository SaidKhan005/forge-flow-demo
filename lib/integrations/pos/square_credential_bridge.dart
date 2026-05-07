// Phase 8 framework — Square credential resolver bridge.
//
// Concrete [SquareCredentialResolver] (declared in
// `lib/integrations/pos/square_pos_production_api_client.dart`) that
// delegates `resolveAccessToken` into the shared
// [VendorCredentialBroker]. Square's OAuth client id / client secret
// are app-wide (one F&F partner registration), so they are sourced from
// constructor arguments at the proxy bootstrap, not from the per-tenant
// credential row.
//
// CLAUDE.md alignment: HP #7 — plaintext access tokens never leave
// Cloud Run. The `clientId` / `clientSecret` strings live in env-loaded
// secrets (`SQUARE_OAUTH_CLIENT_ID` / `SQUARE_OAUTH_CLIENT_SECRET`) and
// are read once at bootstrap time, not per-request.

import '../_common/vendor_credential_broker.dart';
import 'square_pos_production_api_client.dart';
import 'square_pos_adapter.dart';

/// Square vendor identifier in `vendor_credentials.vendor_id`.
const String kSquareVendorId = 'square';

/// Closure that mints a fresh Square bearer token via Square's OAuth
/// `refresh_token` grant. Production wires the live OAuth-token-endpoint
/// HTTP shape (`POST https://connect.squareup.com/oauth2/token`); the
/// bridge supplies the closure to the broker so the broker can persist
/// the refreshed ciphertext through `withTenant`.
typedef SquareOauthRefreshFn = Future<TokenRefreshResult> Function(
  VendorCredentialBundle current,
);

class SquareBrokerCredentialResolver implements SquareCredentialResolver {
  SquareBrokerCredentialResolver({
    required this.broker,
    required this.operatorId,
    required this.locationId,
    required this.oauthRefresh,
    required String clientId,
    required String clientSecret,
  })  : _clientId = clientId,
        _clientSecret = clientSecret;

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;
  final SquareOauthRefreshFn oauthRefresh;

  /// Square OAuth client id; app-wide (server-side env-loaded). Never
  /// echoed to clients.
  final String _clientId;

  /// Square OAuth client secret; app-wide (server-side env-loaded).
  /// Never echoed to clients.
  final String _clientSecret;

  @override
  Future<String> resolveAccessToken(SquareCredentialHandle handle) {
    return broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kSquareVendorId,
      doRefresh: oauthRefresh,
    );
  }

  @override
  String get clientId => _clientId;

  @override
  String get clientSecret => _clientSecret;
}
