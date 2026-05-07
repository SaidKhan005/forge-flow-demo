// Phase 8 framework — Oracle MICROS Simphony token-store bridge.
//
// Concrete [SimphonyTokenStore] (declared in
// `lib/integrations/pos/oracle_micros_simphony_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. The store
// surface has two methods:
//   * `fetchAccessToken` — return the cached bearer (mints fresh when
//     no cache exists or the cached entry expired).
//   * `refreshAccessToken` — force a fresh `client_credentials` round
//     trip; called reactively on a 401.
//
// Both flow through the broker so `vendor_credentials` writes go
// through `withTenant`. The store-shape returns a [SimphonyAccessToken]
// (token + expiry); the bridge constructs that from the broker's bundle.

import '../_common/vendor_credential_broker.dart';
import 'oracle_micros_simphony_production_api_client.dart';

/// Oracle MICROS Simphony vendor identifier in
/// `vendor_credentials.vendor_id`.
const String kOracleMicrosSimphonyVendorId = 'oracle_micros_simphony';

class OracleMicrosSimphonyBrokerTokenStore implements SimphonyTokenStore {
  OracleMicrosSimphonyBrokerTokenStore({
    required this.broker,
    required this.oauthExchange,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final VendorCredentialBroker broker;

  /// Closure that runs Oracle MICROS Simphony's
  /// `client_credentials` exchange. Production wires the live HTTP
  /// shape against the partner-issued token endpoint.
  final Future<TokenRefreshResult> Function(VendorCredentialBundle)
      oauthExchange;

  final DateTime Function() _clock;

  @override
  Future<SimphonyAccessToken> fetchAccessToken({
    required String operatorId,
    required String locationId,
    required SimphonyVendorCredentialHandle credential,
  }) async {
    final token = await broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kOracleMicrosSimphonyVendorId,
      doRefresh: oauthExchange,
    );
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kOracleMicrosSimphonyVendorId,
    );
    return SimphonyAccessToken(
      accessToken: token,
      // The store contract requires a non-null expiry. Fall back to a
      // short-lived sentinel so the framework's reactive refresh path
      // kicks in if the broker's bundle was missing an explicit expiry.
      expiresAt: bundle.expiresAt ??
          _clock().toUtc().add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<SimphonyAccessToken> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required SimphonyVendorCredentialHandle credential,
  }) async {
    final token = await broker.refreshAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kOracleMicrosSimphonyVendorId,
      doRefresh: oauthExchange,
    );
    final bundle = await broker.resolveCredentialBundle(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kOracleMicrosSimphonyVendorId,
    );
    return SimphonyAccessToken(
      accessToken: token,
      expiresAt: bundle.expiresAt ??
          _clock().toUtc().add(const Duration(minutes: 5)),
    );
  }
}
