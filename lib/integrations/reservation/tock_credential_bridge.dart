// Phase 8 framework — Tock credential resolver bridge.
//
// Concrete [TockCredentialResolver] (declared in
// `lib/integrations/reservation/tock_reservation_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. Tock uses a
// static API key (stored in `vendor_credentials.metadata.api_key` for
// the per-tenant connection), so the bridge maps the resolver
// signatures onto bundle reads.
//
// Note: Tock's transport uses `metadata.api_key` rather than the
// `access_token_ciphertext` envelope. Production migrations move that
// value into the encrypted column at the live-promotion slice; the
// bridge reads from the currently-active source via the broker's
// typed accessor and surfaces `VendorCredentialNotFound` when neither
// channel populates a key.

import '../_common/vendor_credential_broker.dart';
import 'tock_reservation_adapter.dart';
import 'tock_reservation_production_api_client.dart';

/// Tock vendor identifier in `vendor_credentials.vendor_id`.
const String kTockVendorId = 'tock';

class TockBrokerCredentialResolver implements TockCredentialResolver {
  TockBrokerCredentialResolver({
    required this.broker,
    required this.operatorId,
    required this.locationId,
  });

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;

  @override
  Future<String> resolveApiKey({
    required TockCredentialHandle handle,
  }) async {
    // Prefer the dedicated `apiKey` accessor (metadata.api_key); fall
    // back to the bearer slot since some early-deployment connections
    // landed the API key as the access-token ciphertext envelope.
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kTockVendorId,
    );
    final apiKey = bundle.apiKey ?? bundle.accessToken;
    if (apiKey.isEmpty) {
      throw VendorCredentialNotFound(
        'tock@$operatorId/$locationId: api_key missing',
      );
    }
    return apiKey;
  }

  @override
  Future<String> resolvePastedApiKey({
    required String operatorId,
    required String locationId,
    required String pastedApiKey,
  }) async {
    if (pastedApiKey.isEmpty) {
      throw VendorCredentialNotFound(
        'tock@$operatorId/$locationId: pasted api_key empty',
      );
    }
    return pastedApiKey;
  }
}
