// Phase 8R.OT — OpenTable webhook payload fixtures.
//
// Documented per the OpenTable Partner page (operator-facing only:
// https://restaurant.opentable.com/products/opentable-platform/) and
// the industry-standard reservation envelope. Retrieval date:
// 2026-05-04.
//
// The payload shape mirrors the assumed `reservation.modified` event:
// the top-level envelope carries a `reservation` key whose value is
// the vendor-shape reservation row (same shape as the search-endpoint
// row in `opentable_reservations_fixture.dart`). Every header and
// signature placement is an assumption flagged for verification in
// `8R.OT.live.sandbox`.

const String openTableWebhookEventReservationModified =
    'reservation.modified';

/// Sample raw-body string for a `reservation.modified` webhook. The
/// signature verifier MUST sign the raw bytes — no JSON
/// re-serialization between the proxy and the verifier.
const String openTableReservationModifiedRawBody =
    '{"reservation":{"id":"OT-12345","restaurant_id":"rid-9876","reserved_at":"2026-05-10T19:30:00Z","modified_at":"2026-05-04T11:45:00Z","party_size":4,"status":"booked"}}';

/// Pre-decoded payload that matches
/// [openTableReservationModifiedRawBody]. The inbound handler hands
/// the adapter both the raw bytes (for HMAC) and the decoded JSON
/// (for the field-mapping work).
const Map<String, Object?> openTableReservationModifiedPayload =
    <String, Object?>{
  'reservation': <String, Object?>{
    'id': 'OT-12345',
    'restaurant_id': 'rid-9876',
    'reserved_at': '2026-05-10T19:30:00Z',
    'modified_at': '2026-05-04T11:45:00Z',
    'party_size': 4,
    'status': 'booked',
  },
};
