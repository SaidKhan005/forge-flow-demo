// Phase 8 framework — Agendrix credential store bridge.
//
// Concrete [AgendrixCredentialStore] (declared in
// `lib/integrations/labor/agendrix_labor_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. Agendrix
// uses a static partner-issued API key plus a per-tenant `company_id`;
// the bridge maps both onto the broker's bundle:
//
//   * `apiKey`     — read from `metadata.api_key` (or the bearer slot
//                    when a deployment landed it as the access-token
//                    envelope).
//   * `companyId`  — read from `connector_connection.metadata.company_id`
//                    (the canonical home for vendor-side identity
//                    bindings) or the fallback `metadata.company_id`.

import '../_common/vendor_credential_broker.dart';
import 'agendrix_labor_production_api_client.dart';

/// Agendrix vendor identifier in `vendor_credentials.vendor_id`.
const String kAgendrixVendorId = 'agendrix';

/// Connection-metadata key carrying the Agendrix `company_id`.
const String kAgendrixConnectionMetadataCompanyId = 'company_id';

class AgendrixBrokerCredentialStore implements AgendrixCredentialStore {
  AgendrixBrokerCredentialStore({required this.broker});

  final VendorCredentialBroker broker;

  @override
  Future<AgendrixCredential> readCredential({
    required String operatorId,
    required String locationId,
  }) async {
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kAgendrixVendorId,
    );
    final apiKey = bundle.apiKey ?? bundle.accessToken;
    if (apiKey.isEmpty) {
      throw VendorCredentialNotFound(
        'agendrix@$operatorId/$locationId: api_key missing',
      );
    }
    final companyIdRaw = bundle.connectionMetadata[
            kAgendrixConnectionMetadataCompanyId] ??
        bundle.metadata[kAgendrixConnectionMetadataCompanyId];
    final companyId = companyIdRaw is String ? companyIdRaw : null;
    if (companyId == null || companyId.isEmpty) {
      throw VendorCredentialNotFound(
        'agendrix@$operatorId/$locationId: '
        'metadata.$kAgendrixConnectionMetadataCompanyId missing',
      );
    }
    return AgendrixCredential(apiKey: apiKey, companyId: companyId);
  }
}
