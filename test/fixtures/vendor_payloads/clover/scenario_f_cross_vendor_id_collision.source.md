# Source

- URL: https://docs.clover.com/reference/orderget
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders` — same envelope as
  `happy_path_order_paid.json`, but `order.id = "ORD-2026-05-02-001"`
  is a deliberately **vendor-agnostic** id that could plausibly be
  emitted by **another vendor's** adapter (e.g. Toast, Square).
  Real Clover ids are typically 13-char alphanumeric (per the
  `fixtureMerchantId = 'CLV-MERCH-CCD13C7B'` example in
  `test/integrations/pos/fixtures/clover_orders_fixture.dart`); this
  fixture uses a generic shape on purpose.
- Adapter / framework cite: idempotency UNIQUE on
  `(vendor_id, operator_id, vendor_event_id)`. The
  `vendor_id = 'clover'` namespace prevents this row from
  shadow-writing over a same-id row another vendor's adapter
  produced.
- Outcome: **Reject the cross-vendor shadow write**. The proxy's
  idempotency table would accept this Clover row at
  `(vendor_id='clover', operator_id, vendor_event_id='ORD-2026-05-02-001')`
  but a `(vendor_id='toast', ...)` row of the same vendor_event_id is
  a different key — both rows live without collision. If the framework
  ever flattened to `(operator_id, vendor_event_id)` (no vendor
  namespace), this fixture would expose that regression.
- Notes: this is an **architectural assertion**, not a data-shape
  rejection. The Clover adapter accepts the row and writes a
  canonical fact; the test that consumes this fixture asserts the
  proxy `proxy_requests` UNIQUE row carries `vendor_id = 'clover'`
  and that a paired Toast fixture with the same `id` produces a
  separate row.
