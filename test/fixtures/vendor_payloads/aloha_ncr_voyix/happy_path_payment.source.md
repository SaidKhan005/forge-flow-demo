# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus delivery, eventType `aloha.check.modified`
  with `paymentStatus = "paid"` denoting closed/settled check.
- Notes: F&F adapter does NOT consume per-cardholder payment fields
  (PCI scope avoided per `field_mapping.md` forbidden-fields list).
  This fixture intentionally exposes only the aggregate
  `paymentStatus` indicator and the `totalAmount` field the adapter
  already maps. `payments[]`, `cardholderName`, and `cardLast4` are
  scrubbed and the absence is the test signal — the adapter must
  never reach for them.
- Sourcing fallback: NCR Voyix portal landing references
  `paymentStatus` on Aloha checks; specific enum values verified in
  `8.AL.live.sandbox`. Marked `_sourcing_gap` is NOT applied here
  because the canonical fields the adapter consumes
  (`totalAmount`, `closedAt`, `modifiedAt`) come straight from
  `documentedPerAlohaNcrVoyixV1`.
