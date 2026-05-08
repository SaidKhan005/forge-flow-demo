# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus delivery, eventType `aloha.check.modified`
  with `voided: true`.
- Notes: Aloha sandbox does not currently document whether voided
  checks emit a dedicated event or arrive as a `modified` event
  with `voided: true`. The fixture follows the second interpretation
  per the developer-portal landing — the bounded fix in
  `8.AL.live.sandbox` is to add a separate event-name filter if the
  vendor uses a distinct `aloha.check.voided` event. `totalAmount`
  is `0.00` to model the post-void state; the adapter should treat
  voided checks as zero-sales facts.
- `_sourcing_gap` is set to flag this ambiguity for the Phase 2
  harness reviewer. Phase 2 may assert the canonical write happens
  with `actual_sales = 0.00` and a void marker; exact assertion
  shape resolves in the live slice.
