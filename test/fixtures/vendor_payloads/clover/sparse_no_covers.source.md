# Source

- URL: https://docs.clover.com/reference/orderget
- URL: https://docs.clover.com/reference/orders
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders` — same shape as
  `happy_path_order_paid.json`, but with **no `lineItems`, no
  `payments`, no `employee`** keys. Per Clover's order schema these
  are optional / nullable on the response — the documented order
  contract only mandates `id`, `createdTime`, `modifiedTime`, `total`,
  `state`, `currency`, and `merchant.id`.
- Notes: this fixture exercises Clover's **architectural absence of
  guest-count fields**. Per
  `docs/integrations/clover/field_mapping.md`:
    - "the order schema does NOT expose a `guests`, `coverCount`, or
      `partySize` field"
    - the adapter writes `covers = null`, `covers_source =
      'forecast_fallback'` on every Clover row.
- Outcome (Phase 2 harness): adapter writes one canonical fact for
  `CLV-ORDER-SPARSE-COVERS-001` with `actual_sales = 42.80`,
  `covers = null`, `covers_source = 'forecast_fallback'`. The
  `wage_source = app_fallback` path on the labor side downstream
  consumes the same row's null covers. Operator-facing chrome
  surfaces the forecast-fallback degradation pill per
  `docs/contracts/metric_card_honesty_contract.md`.
