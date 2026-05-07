// Phase 8 framework — QuickBooks Time credential bridges.
//
// Concrete implementations of two abstracts declared in
// `lib/integrations/labor/quickbooks_time_labor_production_api_client.dart`:
//
//   * [QuickBooksTimeCredentialStore]      — async accessor for the
//                                              per-tenant OAuth bearer.
//   * [QuickBooksTimeOauthClientCredentials] — sync accessors for the
//                                              app-wide OAuth client_id /
//                                              client_secret used by the
//                                              token + revoke endpoints.
//
// QuickBooks Time uses Intuit's OAuth 2.0 surface — the `client_id` /
// `client_secret` pair is one app-wide partner registration (loaded
// from server-side env at bootstrap), while the bearer is per-tenant.

import '../_common/vendor_credential_broker.dart';
import 'quickbooks_time_labor_production_api_client.dart';

/// QuickBooks Time vendor identifier in `vendor_credentials.vendor_id`.
const String kQuickBooksTimeVendorId = 'quickbooks_time';

class QuickBooksTimeBrokerCredentialStore
    implements QuickBooksTimeCredentialStore {
  QuickBooksTimeBrokerCredentialStore({
    required this.broker,
    required this.operatorId,
    required this.locationId,
    required this.oauthRefresh,
  });

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;
  final Future<TokenRefreshResult> Function(VendorCredentialBundle)
      oauthRefresh;

  @override
  Future<String> readAccessToken() {
    return broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kQuickBooksTimeVendorId,
      doRefresh: oauthRefresh,
    );
  }
}

/// Static [QuickBooksTimeOauthClientCredentials] backed by app-wide
/// env-loaded values. The bootstrap reads `INTUIT_OAUTH_CLIENT_ID` /
/// `INTUIT_OAUTH_CLIENT_SECRET` once at startup.
class StaticQuickBooksTimeBrokerOauthClientCredentials
    implements QuickBooksTimeOauthClientCredentials {
  const StaticQuickBooksTimeBrokerOauthClientCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  @override
  final String clientId;
  @override
  final String clientSecret;
}
