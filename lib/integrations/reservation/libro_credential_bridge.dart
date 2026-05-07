// Phase 8 framework — Libro bearer-token resolver bridge.
//
// Concrete [LibroBearerTokenResolver] (a typedef declared in
// `lib/integrations/reservation/libro_reservation_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. Libro's
// transport identifies a credential by an opaque
// [VendorCredentialHandle]; the bridge maps that into a
// `(operatorId, locationId, vendor=libro)` triple by holding the tenant
// context as constructor state.
//
// CLAUDE.md alignment: HP #4 — every read rides `withTenant`. HP #7 —
// plaintext bearer tokens never leave Cloud Run.

import '../_common/vendor_credential_broker.dart';
import 'libro_reservation_adapter.dart' show VendorCredentialHandle;
import 'libro_reservation_production_api_client.dart';

/// Libro vendor identifier in `vendor_credentials.vendor_id`.
const String kLibroVendorId = 'libro';

/// Build a [LibroBearerTokenResolver] closure bound to the named
/// (operator, location). The bootstrap calls this once per request
/// after resolving the operator/location.
///
/// `oauthRefresh` is the vendor-specific refresh closure — when the
/// stored bearer is within `kAccessTokenRefreshLeadTime` of expiry,
/// the broker calls it to mint a fresh token via Libro's OAuth flow.
LibroBearerTokenResolver makeLibroBearerTokenResolver({
  required VendorCredentialBroker broker,
  required String operatorId,
  required String locationId,
  required Future<TokenRefreshResult> Function(VendorCredentialBundle)
      oauthRefresh,
}) {
  return (VendorCredentialHandle credential) {
    return broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kLibroVendorId,
      doRefresh: oauthRefresh,
    );
  };
}
