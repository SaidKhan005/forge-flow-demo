// Phase 8 framework — Lightspeed LSK access-token resolver bridge.
//
// Concrete [LightspeedLskAccessTokenResolver] (declared in
// `lib/integrations/pos/lightspeed_lsk_pos_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. The
// transport identifies a credential by an opaque `credentialId` string;
// the bridge maps that into a `(operatorId, locationId, vendor=lightspeed_lsk)`
// triple by holding the tenant context as constructor state.
//
// Production wires one bridge instance per request after resolving the
// operator/location from the verified JWT.
//
// CLAUDE.md alignment: HP #4 — every resolution rides `withTenant`.
// HP #7 — refresh tokens are persisted as ciphertext; the broker never
// returns them to client memory.

import '../_common/vendor_credential_broker.dart';
import 'lightspeed_lsk_pos_production_api_client.dart';

/// Lightspeed LSK vendor identifier in `vendor_credentials.vendor_id`.
const String kLightspeedLskVendorId = 'lightspeed_lsk';

class LightspeedLskBrokerAccessTokenResolver
    implements LightspeedLskAccessTokenResolver {
  LightspeedLskBrokerAccessTokenResolver({
    required this.broker,
    required this.operatorId,
    required this.locationId,
    required this.oauthRefresh,
  });

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;

  /// Lightspeed OAuth refresh closure — production wires the live
  /// `POST https://cloud.lightspeedapp.com/oauth/access_token.php`
  /// `grant_type=refresh_token` shape; tests pass a canned closure.
  final Future<TokenRefreshResult> Function(VendorCredentialBundle)
      oauthRefresh;

  @override
  Future<String> resolveAccessToken(String credentialId) {
    return broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kLightspeedLskVendorId,
      doRefresh: oauthRefresh,
    );
  }

  @override
  Future<String> resolveRefreshToken(String refreshTokenCredentialId) async {
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kLightspeedLskVendorId,
    );
    final refresh = bundle.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw VendorCredentialNotFound(
        'no refresh token persisted for '
        'lightspeed_lsk@$operatorId/$locationId',
      );
    }
    return refresh;
  }
}
