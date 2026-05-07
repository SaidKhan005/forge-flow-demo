// Phase 8 framework — 7shifts access-token provider bridge.
//
// Concrete [SevenShiftsAccessTokenProvider] (a typedef declared in
// `lib/integrations/labor/seven_shifts_labor_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. The
// transport calls the typedef per request to mint the bearer; the
// bridge holds the tenant context as constructor state so the typedef
// signature `Future<String> Function()` works untouched.

import '../_common/vendor_credential_broker.dart';
import 'seven_shifts_labor_adapter.dart' show kSevenShiftsVendorId;
import 'seven_shifts_labor_production_api_client.dart';

// `kSevenShiftsVendorId` is the canonical vendor id key (`'seven_shifts'`)
// declared in `seven_shifts_labor_adapter.dart`. It is re-exported here
// purely so existing call sites that import the bridge can continue to
// reference the symbol unchanged. The credential broker, OAuth
// dispatcher, refresh worker, and adapter registry all key off the
// same `'seven_shifts'` value.
export 'seven_shifts_labor_adapter.dart' show kSevenShiftsVendorId;

/// Build a [SevenShiftsAccessTokenProvider] closure bound to the named
/// (operator, location). 7shifts uses operator-wide grants today, so
/// `vendor_credentials.location_id` may be NULL and the broker's
/// fallback search picks up the operator-wide row.
SevenShiftsAccessTokenProvider makeSevenShiftsAccessTokenProvider({
  required VendorCredentialBroker broker,
  required String operatorId,
  required String locationId,
  required Future<TokenRefreshResult> Function(VendorCredentialBundle)
      oauthRefresh,
}) {
  return () => broker.resolveAccessToken(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: kSevenShiftsVendorId,
        doRefresh: oauthRefresh,
      );
}
