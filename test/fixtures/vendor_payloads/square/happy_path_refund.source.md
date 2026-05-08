# Source

- URL: https://developer.squareup.com/reference/square/objects/Refund
- URL (webhook envelope): https://developer.squareup.com/docs/webhooks/build-with-webhooks
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `refund.updated` (status = `APPROVED`,
  partial-refund amount = $7.91 CAD against the parent ticket from
  `happy_path_order_completed.json`).

## Adapter mapping

The Square POS adapter's V1 scope is sales facts only — refunds are
NOT mapped to a separate canonical fact. Square's contract is that
the parent Order's `total_money.amount` is the operator's net sales
figure; refunds against that order trigger an `order.updated` event
with the new (lower) `total_money.amount`, which the adapter
re-upserts via the idempotency key
`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`.

This fixture exists in the corpus because:

1. The framework's `InboundWebhookHandler` must accept the signed
   payload without crashing.
2. The event-type allowlist (`kSquareWebhookEvents`) drops it before
   the adapter sees it.
3. Phase 2 harnesses can assert "no canonical fact written" given a
   refund event, and assert that the paired `order.updated` event
   (which Square emits in tandem) handles the net-sales decrement.

## Field-level edits

- Currency: `CAD`.
- `tender_id` matches the tender id used in
  `happy_path_order_completed.json` so cross-fixture correlation
  works.
- Identifiers are public-example placeholders verbatim from
  Square's doc.

All other field paths and casing are verbatim per Square's
published Refund object reference.
