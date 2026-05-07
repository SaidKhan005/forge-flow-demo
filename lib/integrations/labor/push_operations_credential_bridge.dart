// Phase 8 framework — Push Operations bearer-resolver bridge.
//
// Concrete [PushOperationsBearerResolver] (a typedef declared in
// `lib/integrations/labor/push_operations_labor_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. The typedef
// signature is `Future<String?> Function({operatorId, locationId})`, so
// the bridge produces a closure that the proxy bootstrap installs once
// at startup; the closure resolves through the broker per request.
//
// Returns `null` (rather than throwing) when the broker reports no
// active credential — the transport surfaces null as
// [PushOperationsAuthMissingException], which the framework maps onto
// a reconnect prompt.

import '../_common/vendor_credential_broker.dart';
import 'push_operations_labor_production_api_client.dart';

/// Push Operations vendor identifier in `vendor_credentials.vendor_id`.
const String kPushOperationsVendorId = 'push_operations';

/// Build a [PushOperationsBearerResolver] closure backed by the
/// broker. The closure short-circuits to null on
/// `VendorCredentialNotFound` so the transport's null-handling path
/// fires per the typedef contract.
PushOperationsBearerResolver makePushOperationsBearerResolver({
  required VendorCredentialBroker broker,
}) {
  return ({required String operatorId, required String locationId}) async {
    try {
      return await broker.resolveAccessToken(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: kPushOperationsVendorId,
      );
    } on VendorCredentialNotFound {
      return null;
    }
  };
}
