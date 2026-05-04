# Lightspeed Restaurant K-Series — Field Mapping

**Vendor ID**: `lightspeed_lsk`
**Source documentation**: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
**Retrieval date**: 2026-05-03

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field
`LightspeedLskPosAdapter` populates has a row here; every row here
is mirrored in
`test/integrations/pos/fixtures/lightspeed_lsk_orders_fixture.dart`
under the `documented_per_lightspeed_lsk_f_v2_2026_05` constant. The
field accessors live in `LightspeedLskSaleFields` inside
`lib/integrations/pos/lightspeed_lsk_pos_adapter.dart`.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `sales[].nbCovers` | double | `covers` | round-half-to-even → int | <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales> |
| `sales[].timeOfOpening` | ISO-8601 (UTC, with `Z`) | `opened_at` | direct UTC instant | <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales> |
| `sales[].timeClosed` | ISO-8601 (UTC, with `Z`) | `closed_at` | direct UTC instant; falls back to `timeOfOpening` if absent | <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales> |
| `sales[].payments[].netAmountWithTax` | decimal string (major units, two-decimals) | `actual_sales` | sum across payments → double; rounded to 2 decimals | <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales> |
| `sales[].accountFiscId` | string (e.g., `A65315.17`) | `vendor_entity_id` | direct | <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales> |
| `sales[].timeClosed` (or `timeOfOpening` fallback) | ISO-8601 UTC | `vendor_modified_at` | latest of `timeOfOpening` / `timeClosed`; UTC | <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales> |

Every row above gets a row in
`test/integrations/pos/fixtures/lightspeed_lsk_orders_fixture.dart`'s
`documented_per_lightspeed_lsk_f_v2_2026_05` constant. The constant
name embeds the API version so a vendor shape change appears as a
renamed constant + diff in git history.

---

## Covers source classification

`direct`.

Cite vendor doc:
<https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
(`nbCovers` field — "the number of covers"; double precision).

K-Series exposes covers natively, so the adapter sets
`coversFieldExposed: true` on the capability profile and writes
`covers_source = direct`. Operator chrome (per
`docs/contracts/metric_card_honesty_contract.md`) does NOT flag
covers as forecast-fallback for this vendor.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `timeOfOpening` | ISO 8601 with `Z` | UTC | `vendor_timestamp_policy.lightspeed_lsk.asUtc` |
| `timeClosed` | ISO 8601 with `Z` | UTC | `vendor_timestamp_policy.lightspeed_lsk.asUtc` |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

Lightspeed K-Series spec says order/event timestamps are UTC
instants; some endpoints occasionally drop the trailing `Z` but the
convention is fixed UTC. The framework's
`lib/services/integration/vendor_timestamp_policy.dart` declares
`AmbiguousTimestampConvention.asUtc` for K-Series, so an ambiguous
parse never silently coerces to location-local.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `8.LSK.live.sandbox` slice will verify these first.

- **`covers` rounding**: K-Series exposes `nbCovers` as a double.
  Fractional covers (e.g., `2.5`) are theoretically possible; the
  adapter rounds half-to-even because canonical `covers` is `int`.
  Verify on live by sampling 20 random sandbox sales and confirming
  no integer rounding loses operator-meaningful precision.
- **`actual_sales` units**: the prompt's Block 2 specified "cents →
  dollars," but the K-Series Sales reference returns
  `payments[].netAmountWithTax` as a decimal string already in major
  units (e.g., `"11.00"`). The adapter sums and rounds to 2 decimals;
  the `*.live.sandbox` slice will diff observed numeric scale on real
  data.
- **`vendor_modified_at` source**: the K-Series Sales endpoint does
  not expose a dedicated `lastModifiedAt`. The adapter uses
  `max(timeOfOpening, timeClosed)` as a deterministic, monotone-
  enough proxy. Verify: a sale that re-opens (e.g., comp added after
  close) bumps `timeClosed` and arrives in the next poll window.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `sales[].consumer.*` (when `include=consumer` is requested) — guest
  identity / contact details. Privacy: see operator T&Cs at Phase
  9.8. The adapter does not request `include=consumer`.
- `sales[].account_profile.*` — same privacy rationale.
- `sales[].payments[].cardholder_name` / card-PAN — PCI scope; F&F
  is not a payment processor.
- `sales[].staff[]` (when `include=staff`) — labor attribution lives
  on the labor-vendor side (Phase 8.S). The adapter does not request
  staff inclusion.
