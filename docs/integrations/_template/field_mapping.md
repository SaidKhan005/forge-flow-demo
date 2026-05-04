# `<vendor_display_name>` — Field Mapping

**Vendor ID**: `<vendor_id>`
**Source documentation**: `<https://...>`
**Retrieval date**: YYYY-MM-DD

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates MUST have a row here. Every row here MUST be cited in the
adapter as a `documented_per_<vendor>_<api_version>` constant in
fixtures.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `orders[].guests` | int | `covers` | direct | `<URL>` |
| `orders[].opened_at` | ISO 8601 UTC | `opened_at` | direct UTC | `<URL>` |
| `orders[].closed_at` | ISO 8601 UTC | `closed_at` | direct UTC | `<URL>` |
| `orders[].total_amount.cents` | int | `actual_sales` | cents → dollars | `<URL>` |
| `orders[].id` | string | `vendor_entity_id` | direct | `<URL>` |
| `orders[].updated_at` | ISO 8601 UTC | `vendor_modified_at` | direct UTC | `<URL>` |

Every row above gets a constant in the fixture file:

```dart
// test/integrations/<category>/fixtures/<vendor_id>_field_mapping.dart
const documented_per_<vendor>_<api_version> = <const Map<...>>{
  'covers_path': 'orders[].guests',
  'covers_type': 'int',
  ...
};
```

---

## Covers source classification

`direct` | `forecast_fallback` | `not_applicable`

Cite vendor doc: `<URL>`

If `forecast_fallback`, the adapter records `covers_source =
forecast_fallback` per the documented degrade path. Operator chrome
shows "covers via forecast" in the dashboard pill (per
`docs/contracts/metric_card_honesty_contract.md`).

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `opened_at` | ISO 8601 | UTC | `vendor_timestamp_policy.<vendor>.asUtc` |
| `closed_at` | ISO 8601 | UTC | `vendor_timestamp_policy.<vendor>.asUtc` |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

If the vendor's timestamps are ambiguous, declare the policy in
`vendor_timestamp_policy.dart` (see Phase 8 framework). Adapters that
cannot disambiguate MUST refuse the timestamp at parse time, not
guess.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live.sandbox` slice will verify these first.

- **`<field>`**: doc says X, but the adapter assumes Y because Z.
  Verify on live by `<test method>`.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `customer.email` / `customer.name` / `customer.phone` — privacy.
  See operator T&Cs at Phase 9.8.
- `payment.cardholder_name` / `payment.card_last4` — PCI scope; F&F
  is not a payment processor.
- `tip_amount` (per-cardholder) — aggregate-first; per-employee tip
  attribution is operator's payroll system's job.
