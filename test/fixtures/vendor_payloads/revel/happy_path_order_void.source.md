# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — voided / cancelled order. Vendor doc notes that `order.finalized` fires when an order completes including void / cancellation paths.
- Notes:
  - `voided: true` + `final_total: "0.00"` represents a customer walkout / cancellation. Revel's developer portal exposes a void state on the order row but does not pin `void_reason` enum values; values shown here (`customer_walkout`) are illustrative and not asserted by the adapter.
  - The adapter's `_canonicalize` writes a canonical fact for voids the same as for paid orders (`actual_sales = 0`, `covers = 2`). The Phase 2 sink/spine harness can use this to verify that voided orders still upsert per the idempotency contract.
  - "_sourcing_gap": Revel's published void / cancellation field set was not directly visible on the public webhooks page; the `voided` boolean and `void_reason` shape are reconstructed from third-party Revel integration writeups + the adapter's `_canonicalize` field set. Live shape will be verified at `8.RV.live.sandbox`.
