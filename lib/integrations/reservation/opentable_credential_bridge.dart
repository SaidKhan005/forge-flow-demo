// Phase 8 framework — OpenTable credential store bridge.
//
// Concrete [OpenTableCredentialStore] (declared in
// `lib/integrations/reservation/opentable_reservation_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. The
// OpenTable store-shape exposes only `readClientId` + `readClientSecret`
// — the transport mints its own bearer via `client_credentials` and
// caches it in-process. The bridge therefore returns the static OAuth
// `client_id`/`client_secret` pair stored on the per-tenant
// `vendor_credentials` row.

import '../_common/vendor_credential_broker.dart';
import 'opentable_reservation_production_api_client.dart';

/// OpenTable vendor identifier in `vendor_credentials.vendor_id`.
const String kOpenTableVendorId = 'opentable';

class OpenTableBrokerCredentialStore implements OpenTableCredentialStore {
  OpenTableBrokerCredentialStore({
    required this.broker,
    required this.operatorId,
    required this.locationId,
  });

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;

  @override
  Future<String> readClientId() async {
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kOpenTableVendorId,
    );
    final clientId = bundle.clientId;
    if (clientId == null || clientId.isEmpty) {
      throw VendorCredentialNotFound(
        'opentable@$operatorId/$locationId: '
        'metadata.client_id missing',
      );
    }
    return clientId;
  }

  @override
  Future<String> readClientSecret() async {
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kOpenTableVendorId,
    );
    final clientSecret = bundle.clientSecret;
    if (clientSecret == null || clientSecret.isEmpty) {
      throw VendorCredentialNotFound(
        'opentable@$operatorId/$locationId: '
        'metadata.client_secret missing',
      );
    }
    return clientSecret;
  }
}
