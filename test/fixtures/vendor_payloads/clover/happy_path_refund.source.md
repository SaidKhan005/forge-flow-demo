# Source

- URL: https://docs.clover.com/reference/orderget
- URL: https://docs.clover.com/reference/orders
- URL: https://docs.clover.com/dev/docs/webhooks
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders/{orderId}` — single order
  hydration after an `ORDER_UPDATED` webhook fires post-refund. Refunds
  are nested under `payments[].refunds[]` per the documented order
  schema.
- Notes: Clover does NOT publish a refund-event delivery shape distinct
  from `ORDER_UPDATED`; refunds surface via the order's payment chain.
  After refund, `order.state` stays `'paid'` but the net `total` may
  go to zero or a partial amount. This fixture shows a full refund —
  payment amount 3140 cents, refund amount 3140 cents, net 0.
- Adapter behavior: `CloverPosAdapter._project` reads `order.total`
  verbatim, so a fully-refunded order writes `actual_sales = 0.00`.
  Tracking the refund as a separate canonical event is **out of scope
  at lifecycle = `documented`** per
  `docs/integrations/clover/field_mapping.md` "Forbidden fields"
  (`voids` / `discounts` are deferred to Phase 11W gross-vs-net).
- Outcome (Phase 2 harness): adapter writes one canonical fact for
  `CLV-ORDER-7HXJ-2026-05-02-001` with `actual_sales = 0.00`,
  `vendor_modified_at = 2026-05-03T18:55:00Z`.
