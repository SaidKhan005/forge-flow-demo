# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: inbound webhook delivery (`POST <fnf-webhook-url>`),
  event `order.DELIVERED`.
- Notes:
  - Reference "now" is `2026-05-08T12:00:00Z`. `timeOfOpening` and
    `timeClosed` are set to `2026-05-09T13:00:00Z` and
    `2026-05-09T13:30:00Z` — 25h+ in the future relative to "now".
  - Adapter / framework behavior:
    `InboundWebhookHandler.dispatch` step 4 invokes the sanity hook
    BEFORE handing off to `LightspeedLskPosAdapter.handleWebhook`.
    The framework's sanity rule 2 (`opened_in_future`) declares any
    `opened_at > now + 1h` as out-of-bounds.
  - Mirror reference:
    `lightspeedLskFutureDatedSale(...)` in
    `lightspeed_lsk_orders_fixture.dart` and
    `futureDatedLightspeedLskWebhook(...)` in
    `lightspeed_lsk_webhook_fixture.dart` — both anchor to a
    `referenceUtc` so the harness can assert the same future-window
    drop on either side of the wire.
- Expected outcome: signature verifier accepts; framework sanity
  drops the record; adapter `handleWebhook` is never called for
  this row; one `sanity_log` row + one `connector_sync_log` row.
  No canonical fact write.
