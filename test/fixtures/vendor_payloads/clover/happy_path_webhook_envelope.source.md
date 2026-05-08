# Source

- URL: https://docs.clover.com/dev/docs/webhooks
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: Inbound webhook delivery — the canonical Clover envelope
  shape. The `merchants` object can carry **one or more** events per
  merchant per delivery. This fixture demonstrates the multi-event
  shape (CREATE then UPDATE on the same order id), which the framework
  must iterate.
- Event type prefix: `O:` is Clover's documented identifier for
  **Orders** events. Other documented prefixes per the webhooks doc:
    - `A` Apps, `C` Customers, `CA` Cash adjustments, `E` Employees,
      `I` Inventory, `IC` Inventory category,
      `IG` Inventory modifier group, `IM` Inventory modifier,
      `O` Orders, `M` Merchants, `P` Payments, `SH` Service hour.
- Notes: this is the verbatim envelope shape Clover publishes — the
  example values follow the documented `<prefix>:<id>` `objectId`
  format. The framework's
  `lib/services/integration/inbound_webhook_handler.dart`:
    1. Verifies HMAC-SHA256 signature on the **raw body bytes** via
       `lib/integrations/pos/clover_webhook_signature_verifier.dart`.
    2. Iterates `merchants[<merchantId>]`; for each entry resolves
       the `(operator_id, location_id)` from
       `connector_connection.metadata.merchant_id`.
    3. Routes by `objectId` prefix; the documented adapter only
       handles `O:` (Orders). `P:` is hydrated through the parent
       order. Other prefixes are out of scope for the documented
       slice.
    4. Calls `CloverPosAdapter.handleWebhook` once per `O:` entry.
- Headers (HTTP transport):
    - `X-Clover-Auth-Signature: <<TEST_HMAC_SECRET>>`
    - `X-Clover-Auth-Timestamp: 1777750980`
- Outcome (Phase 2 harness): handler iterates two entries, calls
  `CloverApiClient.getOrder` once per entry (idempotency UNIQUE on
  `(vendor_id, operator_id, vendor_event_id)` collapses
  re-deliveries), writes one canonical fact reflecting the latest
  state.
