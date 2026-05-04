// Phase 8.RV — Revel Systems webhook payload fixtures.
//
// Documented per
// `https://developer.revelsystems.com/revelsystems/docs/webhooks`.
// Retrieval date: 2026-05-03.
//
// The payload shape mirrors the `order.finalized` event Revel emits:
// the top-level envelope carries an `order` key whose value is the
// vendor-shape order row (same shape as the integrations-list response
// row in `revel_orders_fixture.dart`).

const String revelWebhookEventOrderFinalized = 'order.finalized';

/// Sample raw-body string for an `order.finalized` webhook. The
/// signature verifier MUST sign the raw bytes — no JSON
/// re-serialization between the proxy and the verifier.
const String revelOrderFinalizedRawBody =
    '{"order":{"id":8842301,"local_id":"A-0142","created_date":"2026-05-02T18:45:00Z","updated_date":"2026-05-02T19:31:00Z","final_total":"64.30","number_of_people":3,"closed":true,"establishment_id":4421,"instance_name":"demo-instance"}}';

/// Pre-decoded payload that matches `revelOrderFinalizedRawBody`. The
/// inbound handler hands the adapter both the raw bytes (for HMAC) and
/// the decoded JSON (for the field-mapping work).
const Map<String, Object?> revelOrderFinalizedPayload = <String, Object?>{
  'order': <String, Object?>{
    'id': 8842301,
    'local_id': 'A-0142',
    'created_date': '2026-05-02T18:45:00Z',
    'updated_date': '2026-05-02T19:31:00Z',
    'final_total': '64.30',
    'number_of_people': 3,
    'closed': true,
    'establishment_id': 4421,
    'instance_name': 'demo-instance',
  },
};
