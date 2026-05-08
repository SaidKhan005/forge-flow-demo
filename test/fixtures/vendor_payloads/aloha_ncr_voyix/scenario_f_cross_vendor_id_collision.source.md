# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus delivery, eventType `aloha.check.modified`.
- Notes: Adversarial scenario F. The body is a documented Aloha
  shape; the adversarial element is the chosen low-entropy
  `eventId`/`checkId` string `"12345"` deliberately overlapping with
  IDs Toast might emit. The fixture exercises the idempotency
  namespace contract:
  `inbound_webhook_idempotency UNIQUE (vendor_id, operator_id, vendor_event_id)`.
  Phase 2 harness asserts the framework retains both the prior Toast
  row AND the new Aloha row with no clobbering and writes two
  distinct canonical facts to the sink (one per vendor).
- Cross-reference: scenario F mirror in any sibling POS fixture
  directory should use the SAME colliding string `"12345"` so Phase
  2 can wire pairwise collision tests with mechanical pairing.
