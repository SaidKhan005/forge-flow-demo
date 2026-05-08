# Source

- URL: https://docs.clover.com/reference/orderget
- URL: https://docs.clover.com/reference/orders
- URL: https://docs.clover.com/docs/working-with-list-endpoints
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03` (matches `kCloverApiVersion` in
  `lib/integrations/pos/clover_pos_adapter.dart` and
  `cloverApiVersion` in
  `test/integrations/pos/fixtures/clover_orders_fixture.dart`)
- Endpoint: `GET /v3/merchants/{mId}/orders` — list endpoint with the
  `elements` + `href` + `offset` + `limit` envelope documented for all
  Clover list endpoints.
- Notes: payload is the documented response shape — the `order` body
  inside `elements[0]` carries the canonical fields the
  `CloverPosAdapter._project` consumes (`id`, `createdTime`,
  `modifiedTime`, `state`, `total`, `merchant.id`). `lineItems` and
  `payments` are present in the schema but the documented adapter
  ignores them at lifecycle = `documented` (per
  `docs/integrations/clover/field_mapping.md` "Forbidden fields"
  table). They are kept here because the verbatim vendor payload shape
  carries them.
- Adapter mapping cite:
  `docs/integrations/clover/field_mapping.md` —
  `order.id` → `vendor_entity_id`,
  `order.createdTime` → `opened_at`,
  `order.modifiedTime` → `closed_at` (when `state == 'paid'`),
  `order.total` → `actual_sales` (cents → dollars),
  `order.merchant.id` → `connector_connection.metadata.merchant_id`.
- Outcome (Phase 2 harness): adapter writes one canonical sales fact
  for `CLV-ORDER-7HXJ-2026-05-02-001` with `actual_sales = 31.40`,
  `covers = null`, `covers_source = 'forecast_fallback'`,
  `closed_at = 2026-05-02T19:43:00Z`.
