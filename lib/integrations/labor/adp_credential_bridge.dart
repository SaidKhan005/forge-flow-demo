// Phase 8 framework — ADP credentials bridge.
//
// ADP's transport
// (`lib/integrations/labor/adp_labor_production_api_client.dart`) uses
// two typedefs:
//
//   * [AdpCredentialsProvider]              — Future-returning provider
//                                              of an [AdpClientCredentials]
//                                              record (clientId +
//                                              clientSecret) used at the
//                                              `/auth/oauth/v2/token`
//                                              `client_credentials` round
//                                              trip.
//   * [AdpSubscriptionSecretProvider]       — Future-returning provider
//                                              of the event-subscription
//                                              signing secret used by
//                                              `registerEventSubscription`.
//
// Note: ADP additionally requires mTLS at the OAuth boundary. The mTLS
// material lives outside the credential broker (it ships as a Cloud
// Run-injected client cert + key pair); this bridge only resolves the
// OAuth client_id/client_secret + the subscription signing secret.
//
// Both bridges hold a per-(operatorId, locationId) tenant context and
// return closures that satisfy the typedef shape.

import '../_common/vendor_credential_broker.dart';
import 'adp_labor_production_api_client.dart';

/// ADP Workforce Now vendor identifier in `vendor_credentials.vendor_id`.
const String kAdpVendorId = 'adp';

/// Metadata key carrying the event-subscription signing secret. ADP
/// rotates this periodically; the rotation lands here.
const String kAdpMetadataSubscriptionSecret = 'subscription_secret';

/// Build an [AdpCredentialsProvider] closure that returns the
/// `(client_id, client_secret)` pair for the named (operator, location).
AdpCredentialsProvider makeAdpCredentialsProvider({
  required VendorCredentialBroker broker,
  required String operatorId,
  required String locationId,
}) {
  return () async {
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kAdpVendorId,
    );
    final clientId = bundle.clientId;
    final clientSecret = bundle.clientSecret;
    if (clientId == null || clientId.isEmpty) {
      throw VendorCredentialNotFound(
        'adp@$operatorId/$locationId: metadata.client_id missing',
      );
    }
    if (clientSecret == null || clientSecret.isEmpty) {
      throw VendorCredentialNotFound(
        'adp@$operatorId/$locationId: metadata.client_secret missing',
      );
    }
    return AdpClientCredentials(
      clientId: clientId,
      clientSecret: clientSecret,
    );
  };
}

/// Build an [AdpSubscriptionSecretProvider] closure that returns the
/// HMAC signing secret for the named (operator, location). ADP's
/// `register_event_subscription` call rotates this; the broker bundle's
/// metadata carries the active value under
/// [kAdpMetadataSubscriptionSecret].
AdpSubscriptionSecretProvider makeAdpSubscriptionSecretProvider({
  required VendorCredentialBroker broker,
  required String operatorId,
  required String locationId,
}) {
  return () async {
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kAdpVendorId,
    );
    final secret = bundle.metadata[kAdpMetadataSubscriptionSecret];
    if (secret is String && secret.isNotEmpty) return secret;
    throw VendorCredentialNotFound(
      'adp@$operatorId/$locationId: '
      'metadata.$kAdpMetadataSubscriptionSecret missing',
    );
  };
}
