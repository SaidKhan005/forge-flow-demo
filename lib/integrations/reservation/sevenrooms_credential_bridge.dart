// Phase 8 framework — SevenRooms credential store bridge.
//
// Concrete [SevenRoomsCredentialStore] (declared in
// `lib/integrations/reservation/sevenrooms_reservation_production_api_client.dart`)
// that delegates into the shared [VendorCredentialBroker]. The
// SevenRooms store-shape has two methods:
//
//   * `resolveBearerToken(credentialId)` — read the current bearer.
//   * `persistIssuedBearerToken(...)` — persist a freshly-issued bearer
//     plus its lifetime; returns the credential id the rest of the
//     system addresses the token by.
//
// The persist path uses [VendorCredentialBroker.refreshAccessToken]
// with a no-network refresh closure (the SevenRooms transport already
// minted the token; the closure just hands it back so the broker
// writes it through `withTenant`).

import '../_common/vendor_credential_broker.dart';
import 'sevenrooms_reservation_production_api_client.dart';

/// SevenRooms vendor identifier in `vendor_credentials.vendor_id`.
const String kSevenRoomsVendorId = 'sevenrooms';

/// Metadata key used by the SevenRooms persist path to record the
/// `client_id` paired with the current bearer.
const String kSevenRoomsMetadataClientId = 'client_id';

/// Connection-metadata key used by SevenRooms to record the venue id.
const String kSevenRoomsConnectionMetadataVenueId = 'venue_id';

class SevenRoomsBrokerCredentialStore implements SevenRoomsCredentialStore {
  SevenRoomsBrokerCredentialStore({
    required this.broker,
    required this.operatorId,
    required this.locationId,
  });

  final VendorCredentialBroker broker;
  final String operatorId;
  final String locationId;

  @override
  Future<String> resolveBearerToken({required String credentialId}) {
    return broker.resolveAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kSevenRoomsVendorId,
    );
  }

  @override
  Future<String> persistIssuedBearerToken({
    required String clientId,
    required String venueId,
    required String accessToken,
    required Duration? lifetime,
  }) async {
    final expiresAt = lifetime == null
        ? null
        : DateTime.now().toUtc().add(lifetime);
    await broker.refreshAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kSevenRoomsVendorId,
      doRefresh: (_) async => TokenRefreshResult(
        accessToken: accessToken,
        expiresAt: expiresAt,
        metadataPatch: <String, Object?>{
          kSevenRoomsMetadataClientId: clientId,
        },
      ),
    );
    // The credential-id returned is the deterministic
    // `(operator_id, location_id, vendor_id)` triple the broker
    // already keys on; SevenRooms callers persist this in
    // `connector_connection.credential_id` for cross-reference.
    return '$operatorId|$locationId|$kSevenRoomsVendorId';
  }
}
