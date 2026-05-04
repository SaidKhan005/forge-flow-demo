# Clover — Field Mapping

**Vendor ID**: `clover`
**Source documentation**: <https://docs.clover.com/reference/orderget>
**Retrieval date**: 2026-05-03

This file is the review contract Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here; every row is cited in
`test/integrations/pos/fixtures/clover_orders_fixture.dart` as a
`documented_per_clover_v3_2026_05_03` constant.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `order.id` | string | `vendor_entity_id` | direct | <https://docs.clover.com/reference/orderget> |
| `order.createdTime` | int (epoch millis UTC) | `opened_at` | epoch-millis → UTC instant | <https://docs.clover.com/reference/orderget> |
| `order.modifiedTime` | int (epoch millis UTC) | `closed_at` | epoch-millis → UTC instant **only when `order.state == 'paid'`**; otherwise null | <https://docs.clover.com/reference/orderget> |
| `order.modifiedTime` | int (epoch millis UTC) | `vendor_modified_at` | epoch-millis → UTC instant | <https://docs.clover.com/reference/orderget> |
| `order.total` | int (smallest currency unit; cents for USD/CAD) | `actual_sales` | cents → dollars (`/ 100.0`) | <https://docs.clover.com/reference/orderget> |
| `order.merchant.id` | string | `connector_connection.metadata.merchant_id` | direct | <https://docs.clover.com/reference/merchantget> |

Every row above has a counterpart key in
`documented_per_clover_v3_2026_05_03` (see
`test/integrations/pos/fixtures/clover_orders_fixture.dart`). The
`8.CL.live.sandbox` slice diffs observed sandbox responses against
each constant.

---

## Covers source classification

`forecast_fallback`

**Cite vendor doc**: <https://docs.clover.com/reference/orderget> —
the order schema does NOT expose a `guests`, `coverCount`, or
`partySize` field. Searched the full v3 reference at retrieval date;
no equivalent surface.

The adapter records `covers = null` and `covers_source =
'forecast_fallback'` on every canonical fact written from a Clover
order. The operator dashboard surfaces the
forecast-fallback degradation in the **single top-left pill** per
`docs/contracts/metric_card_honesty_contract.md`; individual metric
cards stay clean.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `order.createdTime` | epoch millis (int) | UTC | `vendor_timestamp_policy.clover.asUtc` |
| `order.modifiedTime` | epoch millis (int) | UTC | `vendor_timestamp_policy.clover.asUtc` |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

Clover emits epoch millis with no timezone offset; per Clover's
documented convention these are UTC instants. The adapter's
`_project` uses `DateTime.fromMillisecondsSinceEpoch(..., isUtc: true)`
so business-date bucketing flows through the framework's IANA
converter at the worker layer.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live.sandbox` slice will verify these first.

- **`closed_at` mapping**: Clover does not expose a
  field literally named `closed_at`. The adapter adopts
  `modifiedTime` as `closed_at` only when `order.state == 'paid'`;
  for any other state (`open`, `voided`, `locked`) `closed_at` is
  null. **Verify on live by**: replaying real fixture orders through
  the lifecycle (open → paid) and asserting the canonical row
  transitions from `closed_at: null` to a populated value at the
  paid-state webhook.
- **Currency**: the adapter assumes `order.total` is in the
  merchant's primary currency smallest unit; multi-currency orders
  (rare on Clover) are out of scope at lifecycle = `documented`.
  **Verify on live by**: pulling a sample where `currency != 'USD'`
  and asserting the dollar conversion still rounds to two decimals.
- **State enum**: only `'paid'` triggers `closed_at` write. Other
  documented states (`'open'`, `'locked'`, `'voided'`,
  `'manualTransaction'`) leave `closed_at` null. **Verify on live
  by**: triggering each state transition in sandbox and asserting
  the canonical row only writes `closed_at` on `'paid'`.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `order.customers` / `order.email` / `order.phoneNumber` —
  privacy. The adapter never reads these. See operator T&Cs at
  Phase 9.8.
- `payment.cardholderName` / `payment.cardLast4` / `payment.tender`
  — PCI scope; F&F is not a payment processor.
- `lineItems[].employee` — per-employee tip / sale attribution is
  the operator's payroll system's job; F&F aggregates.
- `voids` / `discounts` / `serviceCharges` — out of scope at
  lifecycle = `documented`. Phase 11W gross-vs-net surface adds
  these once the operator-trust outcome confirms gross sales is
  load-bearing first.
