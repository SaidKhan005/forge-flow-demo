# Source

- URL: https://docs.clover.com/reference/orderget
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders`
- Notes: minimum-shape order in `state = 'open'` with `total = 0` —
  representative of a brand-new order that hasn't been paid yet. The
  documented Clover order schema permits this state (an opened ticket
  before any line items are rung in).
- Adapter behavior cite (`lib/integrations/pos/clover_pos_adapter.dart`
  `_project`):
    - Order id present → ok.
    - `createdTime` and `modifiedTime` present and `int` → ok.
    - `total` present and `int` → ok.
    - `state != 'paid'` → `closed_at = null` per
      `kCloverClosedOrderState` gate
      (`docs/integrations/clover/field_mapping.md` "ambiguity calls").
- Outcome (Phase 2 harness): adapter writes one canonical fact for
  `CLV-ORDER-MINIMAL-001` with `actual_sales = 0.00`, `closed_at =
  null`, `vendor_modified_at = 2026-05-02T18:45:00Z`. This row may be
  superseded later by the `state = 'paid'` UPDATE webhook delivery.
