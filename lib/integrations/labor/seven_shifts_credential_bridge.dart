// Phase 8 framework — 7shifts access-token provider bridge.
//
// Concrete [SevenShiftsAccessTokenProvider] (a typedef declared in
// `lib/integrations/labor/seven_shifts_labor_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. The
// transport calls the typedef per request to mint the bearer; the
// bridge holds the tenant context as constructor state so the typedef
// signature `Future<String> Function()` works untouched.

import '../_common/vendor_credential_broker.dart';
import 'seven_shifts_labor_production_api_client.dart';

/// 7shifts vendor identifier in `vendor_credentials.vendor_id`.
const String kSevenShiftsVendorId = '7shifts';

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
