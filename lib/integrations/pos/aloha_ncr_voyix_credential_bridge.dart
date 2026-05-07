// Phase 8 framework — Aloha NCR Voyix credential store bridge.
//
// Concrete [AlohaNcrVoyixCredentialStore] (a typedef declared in
// `lib/integrations/pos/aloha_ncr_voyix_pos_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. The
// store-typedef shape returns a [AlohaNcrVoyixResolvedCredentials]
// record — the bridge fans the credential bundle out into the four
// fields (access token + application key + organization id + site id)
// the NCR Voyix Aloha module needs on every request.
//
// Plaintext lives only inside the resolved record for the duration of
// one HTTP call; the broker re-resolves on every request so a stale
// record cannot outlive a credential rotation. The bridge therefore
// produces a [AlohaNcrVoyixCredentialStore] closure (not a class) so
// each call materialises a fresh record.
//
// Layout of the underlying credential row:
//   * `vendor_credentials.access_token_ciphertext`      — bearer token.
//   * `vendor_credentials.metadata.application_key`     — NCR Voyix
//                                                          `nep-application-key`.
//   * `vendor_credentials.metadata.organization_id`     — NCR Voyix
//                                                          `nep-organization`.
//   * `connector_connection.metadata.site_id`           — Aloha-Site-Id.

import '../_common/vendor_credential_broker.dart';
import 'aloha_ncr_voyix_pos_adapter.dart'
    show AlohaNcrVoyixCredentialHandle;
import 'aloha_ncr_voyix_pos_production_api_client.dart';

/// Aloha NCR Voyix vendor identifier in `vendor_credentials.vendor_id`.
const String kAlohaNcrVoyixVendorId = 'aloha_ncr_voyix';

/// Metadata key carrying the static NCR Voyix application key
/// (`nep-application-key` header).
const String kAlohaNcrVoyixMetadataApplicationKey = 'application_key';

/// Metadata key carrying the NCR Voyix organization id
/// (`nep-organization` header).
const String kAlohaNcrVoyixMetadataOrganizationId = 'organization_id';

/// Connection-metadata key carrying the Aloha site id (`Aloha-Site-Id`
/// header). Mirrors the WebhookBindingExtractor convention.
const String kAlohaNcrVoyixConnectionMetadataSiteId = 'site_id';

/// Build an [AlohaNcrVoyixCredentialStore] closure bound to the named
/// (operator, location). The bootstrap calls this once per request
/// after the operator/location have been resolved.
AlohaNcrVoyixCredentialStore makeAlohaNcrVoyixCredentialStore({
  required VendorCredentialBroker broker,
  required String operatorId,
  required String locationId,
  required Future<TokenRefreshResult> Function(VendorCredentialBundle)
      oauthRefresh,
}) {
  return (AlohaNcrVoyixCredentialHandle handle) async {
    // Force the freshness check on the bearer side; the broker handles
    // refresh + cache.
    final bearer = await broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kAlohaNcrVoyixVendorId,
      doRefresh: oauthRefresh,
    );
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kAlohaNcrVoyixVendorId,
    );
    final applicationKey = _readMetadataString(
      bundle.metadata,
      kAlohaNcrVoyixMetadataApplicationKey,
    );
    final organizationId = _readMetadataString(
      bundle.metadata,
      kAlohaNcrVoyixMetadataOrganizationId,
    );
    final siteId = _readMetadataString(
      bundle.connectionMetadata,
      kAlohaNcrVoyixConnectionMetadataSiteId,
    ) ?? handle.siteId;
    if (applicationKey == null) {
      throw VendorCredentialNotFound(
        'aloha_ncr_voyix@$operatorId/$locationId: '
        'metadata.$kAlohaNcrVoyixMetadataApplicationKey missing',
      );
    }
    if (organizationId == null) {
      throw VendorCredentialNotFound(
        'aloha_ncr_voyix@$operatorId/$locationId: '
        'metadata.$kAlohaNcrVoyixMetadataOrganizationId missing',
      );
    }
    return AlohaNcrVoyixResolvedCredentials(
      accessToken: bearer,
      applicationKey: applicationKey,
      organizationId: organizationId,
      siteId: siteId,
    );
  };
}

String? _readMetadataString(Map<String, Object?> metadata, String key) {
  final value = metadata[key];
  if (value is String && value.isNotEmpty) return value;
  return null;
}
