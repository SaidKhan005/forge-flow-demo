# Toast — Field Mapping

**Vendor ID**: `toast`
**Source documentation**:
<https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
**Retrieval date**: 2026-05-03

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates is rowed below and is also captured in the
`documentedPerToastV2` constant in
[lib/integrations/pos/toast_pos_adapter.dart](../../../lib/integrations/pos/toast_pos_adapter.dart).
The fixture mirror lives at
[test/integrations/pos/fixtures/toast_orders_fixture.dart](../../../test/integrations/pos/fixtures/toast_orders_fixture.dart).

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `numberOfGuests` | int | `covers` | direct | <https://doc.toasttab.com/openapi/orders/schema/Order> |
| `openedDate` | ISO 8601 UTC (with `Z`) | `opened_at` | direct UTC | <https://doc.toasttab.com/openapi/orders/schema/Order> |
| `closedDate` | ISO 8601 UTC (with `Z`) | `closed_at` | direct UTC | <https://doc.toasttab.com/openapi/orders/schema/Order> |
| `totalAmount` | decimal (dollars) | `actual_sales` | direct dollars | <https://doc.toasttab.com/openapi/orders/schema/Order> |
| `guid` | string (UUID) | `vendor_entity_id` | direct | <https://doc.toasttab.com/openapi/orders/schema/Order> |
| `modifiedDate` | ISO 8601 UTC (with `Z`) | `vendor_modified_at` | direct UTC | <https://doc.toasttab.com/openapi/orders/schema/Order> |

The `documentedPerToastV2` constant in the adapter file is the
machine-readable mirror of this table. Diff-on-merge keeps the two in
sync; CI lint will flag drift.

---

## Covers source classification

`direct`

Toast exposes covers as a first-class field (`numberOfGuests`,
integer). The adapter records `covers_source = direct` per the
documented mapping; degrade path (`forecast_fallback`) is not used.

Cite vendor doc:
<https://doc.toasttab.com/openapi/orders/schema/Order>

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `openedDate` → `opened_at` | ISO 8601 with `Z` | UTC | `vendorTimestampPolicy['toast'].asUtc` (deferred to a later registry-wiring slice) |
| `closedDate` → `closed_at` | ISO 8601 with `Z` | UTC | same |
| `modifiedDate` → `vendor_modified_at` | ISO 8601 with `Z` | UTC | same |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

Toast never emits ambiguous timestamps in the consumed endpoints —
the trailing `Z` is always present per the OpenAPI specification.
Scenario E (ambiguous-timestamp policy) does not apply at the wire
level, but the adapter still declares
`timestampPolicyDocId: 'toast'` so the framework's refuse-by-default
protection recognizes Toast as a registered vendor.

> **Engineering-vs-framework boundary.** The
> `vendor_timestamp_policy.dart` registry currently lacks a `'toast'`
> entry. Adding the entry is a registry-wiring change to
> `lib/services/integration/*` (out of scope for this slice — see
> "Files to leave alone" in the slice prompt). The `8.TS.live.sandbox`
> slice will land the registry entry alongside the live verification.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live.sandbox` slice will verify these first.

- **`totalAmount`** — Toast docs document this as a decimal-dollar
  amount on the `Order` resource. The adapter passes it through as
  decimal dollars (no cents conversion). The `*.live.sandbox` slice
  asserts a sample `totalAmount` against the operator's POS-verified
  total to confirm.
- **Webhook event id** — Toast events expose `eventGuid`; the
  framework's `_vendorEventIdOrSynthetic` helper falls through to
  `id` / `eventId` so a future shape change does not silently break
  idempotency. Documented in
  [webhook_signature.md](webhook_signature.md).

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `customer.firstName` / `customer.lastName` / `customer.email` —
  privacy. Operator T&Cs at Phase 9.8 do not authorize PII collection
  for Toast-fed canonical facts.
- `payments.cardholderName` / `payments.cardLast4` — PCI scope; F&F
  is not a payment processor.
- `tip_amount` (per-cardholder) — aggregate-first; per-employee tip
  attribution is the operator's payroll system's job, not POS
  ingest's.
