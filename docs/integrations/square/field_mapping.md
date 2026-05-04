# Square — Field Mapping

**Vendor ID**: `square`
**Source documentation**: https://developer.squareup.com/reference/square/objects/Order
**Retrieval date**: 2026-05-03

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row below; the corresponding constant
`documented_per_square_2024_01_18` lives at the top of
`lib/integrations/pos/square_pos_adapter.dart` (mirror in
`test/integrations/pos/fixtures/square_orders_fixture.dart`).

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `order.created_at` | ISO 8601 UTC (`...Z`) | `opened_at` | direct UTC | https://developer.squareup.com/reference/square/objects/Order#definition__property-created_at |
| `order.closed_at` | ISO 8601 UTC, optional (null when state is OPEN) | `closed_at` | direct UTC | https://developer.squareup.com/reference/square/objects/Order#definition__property-closed_at |
| `order.total_money.amount` | int (smallest currency denomination, i.e. cents) | `actual_sales` | cents → dollars (`amount / 100.0`) | https://developer.squareup.com/reference/square/objects/Money#definition__property-amount |
| `order.id` | string | `vendor_entity_id` | direct | https://developer.squareup.com/reference/square/objects/Order#definition__property-id |
| `order.updated_at` | ISO 8601 UTC | `vendor_modified_at` | direct UTC | https://developer.squareup.com/reference/square/objects/Order#definition__property-updated_at |
| `<not_populated>` | — | `covers` | `covers = null`, `covers_source = forecast_fallback` | (Square Order schema does not define a guest-count field) https://developer.squareup.com/reference/square/objects/Order |

The first five rows are mirrored verbatim in the adapter's
`documented_per_square_2024_01_18` constant; Codex compares both
during review.

---

## Covers source classification

`forecast_fallback`

Cite vendor doc: https://developer.squareup.com/reference/square/objects/Order
(retrieved 2026-05-03 — schema enumerates `id`, `location_id`,
`created_at`, `updated_at`, `closed_at`, `state`, `total_money`,
`line_items`, `taxes`, `discounts`, `fulfillments`, `customer_id`,
and `metadata`. No guest-count or covers field is exposed.)

The adapter records `covers_source = 'forecast_fallback'` on every
canonical fact. Operator dashboard surfaces the forecast number with
a single top-left pill ("Covers: forecast — Square does not expose
guest count") per `docs/contracts/metric_card_honesty_contract.md`.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `created_at` | ISO 8601 with `Z` | UTC | `square.created_at_utc_iso8601_with_z` (declared on `VendorCapabilityProfile.timestampPolicyDocId`) |
| `updated_at` | ISO 8601 with `Z` | UTC | same |
| `closed_at`  | ISO 8601 with `Z` | UTC | same |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` consuming `created_at` |

Square's order timestamps are always UTC instants with a trailing
`Z`. The adapter does NOT need to consult an ambiguous-timestamp
policy because Square never emits an offset-less timestamp for the
endpoints above.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live.sandbox` slice will verify these first.

- **`order.state`**: Square enumerates `OPEN`, `COMPLETED`, `CANCELED`,
  `DRAFT`. The adapter ingests every order regardless of state because
  CPLH/SPLH/PPA need every closed check; canceled orders contribute
  zero `actual_sales` (their `total_money.amount` is 0 by Square's
  contract) and no business-day distortion. Verify on live by seeding
  one CANCELED order in sandbox and asserting the canonical fact has
  `actual_sales = 0`.
- **Thin webhook payloads**: Square sometimes ships only `data.id` +
  `data.location_id` on the webhook event; the adapter falls back to
  `RetrieveOrder` to hydrate the full body. Verify on live by
  inspecting at least one `order.updated` webhook in sandbox; if the
  full order arrives in `data.object.order`, the hydration path is
  used only as the fallback.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `customer_id`, `fulfillments[].pickup_details.recipient.display_name`,
  `fulfillments[].shipment_details.recipient.address_line_1` — privacy.
  Operator T&Cs (Phase 9.8) cover the explicit data-minimization
  promise.
- `tenders[].card_details.card.last_4`, `tenders[].card_details.card.cardholder_name` —
  PCI scope; F&F is not a payment processor.
- `tenders[].tip_money.amount` (per-tender) — aggregate-first; per-employee
  tip attribution is the operator's payroll system's job.
- `metadata` — operator-supplied free-form key/value blob; reserved
  for the operator's own integrations and not interpreted by F&F.
