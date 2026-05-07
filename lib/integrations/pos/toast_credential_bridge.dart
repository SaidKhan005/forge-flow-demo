// Phase 8 framework — Toast access-token resolver bridge.
//
// Concrete [ToastAccessTokenResolver] (declared in
// `lib/integrations/pos/toast_pos_production_api_client.dart`) that
// delegates into the shared [VendorCredentialBroker]. Production wires
// this bridge from the proxy bootstrap with a per-(operator, location)
// instance; the broker mediates `vendor_credentials` decryption +
// caching + refresh.
//
// `forceRefresh: true` paths (the transport sets this after a 401) flow
// through `VendorCredentialBroker.refreshAccessToken` with a Toast-
// specific closure that re-runs the OAuth `client_credentials` exchange
// against the Toast OAuth host. The transport itself owns the OAuth
// HTTP shape; this bridge supplies the closure.
//
// CLAUDE.md alignment: HP #4 (per-operator isolation) — the bridge
// holds (operatorId, locationId); the broker's withTenant SET LOCAL
// path injects on every read/write. HP #7 (server-side keys) — plaintext
// bearer tokens never leave Cloud Run.

import '../_common/vendor_credential_broker.dart';
import 'toast_pos_adapter.dart' show ToastCredentialHandle;
import 'toast_pos_production_api_client.dart';

/// Toast vendor identifier in `vendor_credentials.vendor_id`.
const String kToastVendorId = 'toast';

/// Closure that knows how to talk to Toast's OAuth `client_credentials`
/// endpoint to mint a fresh bearer. Production wires this against the
/// Toast OAuth host using the operator-stored `client_id`/`client_secret`
/// pair. Tests pass an in-memory closure that returns canned strings.
///
/// The closure receives the current [VendorCredentialBundle] (which
/// carries `clientId` / `clientSecret` in metadata) so the OAuth
/// exchange can use the right credentials for this tenant.
typedef ToastOauthExchangeFn = Future<TokenRefreshResult> Function(
  VendorCredentialBundle current,
);

/// Production [ToastAccessTokenResolver]. One instance per
/// (operatorId, locationId); the bindings holder constructs it after
/// resolving the operator/location from the request.
class ToastBrokerAccessTokenResolver implements ToastAccessTokenResolver {
  ToastBrokerAccessTokenResolver({
    required this.broker,
    required this.operatorId,
    required this.locationId,
    required this.oauthExchange,
  });

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;
  final ToastOauthExchangeFn oauthExchange;

  @override
  Future<String> resolveAccessToken({
    required ToastCredentialHandle credentials,
    bool forceRefresh = false,
  }) {
    if (forceRefresh) {
      return broker.refreshAccessToken(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: kToastVendorId,
        doRefresh: oauthExchange,
      );
    }
    return broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kToastVendorId,
      doRefresh: oauthExchange,
    );
  }
}
