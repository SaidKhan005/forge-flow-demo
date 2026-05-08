# Source

- URL: https://developer.squareup.com/reference/square/objects/Payment
- URL (webhook envelope): https://developer.squareup.com/docs/webhooks/build-with-webhooks
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `payment.updated` (`status = COMPLETED`).

## Adapter mapping

The adapter does NOT consume the `payment.*` event family — Square's
Order resource carries `total_money.amount` and `closed_at` directly,
so the adapter listens to `order.created` / `order.updated` only
(see `kSquareWebhookEvents` in `lib/integrations/pos/square_pos_adapter.dart`).

This fixture is included as part of the corpus because Square's
public docs do publish Payment-shape webhooks, and the framework's
`InboundWebhookHandler` must NOT crash when an out-of-scope event
type arrives. The expected adapter behavior is:

1. Webhook signature verifies (HMAC-SHA256 over
   `notification_url + raw_body` per `webhook_signature.md`).
2. The framework's event-type allowlist drops the event (Square
   adapter's `kSquareWebhookEvents` does not include `payment.*`).
3. No canonical fact is written.

## Field-level edits

- Currency: `CAD` for parity with the order fixture.
- `order_id` matches `happy_path_order_completed.json` so the two
  fixtures can be paired in cross-event correlation tests.
- Identifiers are public-example placeholders matching Square's
  doc-example shapes (e.g. `ccof:uqaB3ULrF3g7OrIU`). No PII.

All other field paths and casing are verbatim per Square's
published Payment object reference.
