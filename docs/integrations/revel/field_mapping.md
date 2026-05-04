# Revel Systems — Field Mapping

**Vendor ID**: `revel`
**Source documentation**: <https://developer.revelsystems.com/revelsystems/docs/webhooks>
**Retrieval date**: 2026-05-03

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here; every row here is mirrored in
`documentedPerRevelV1` (in
`lib/integrations/pos/revel_pos_adapter.dart`) and in
`documentedPerRevelV1FieldMapping` (in
`test/integrations/pos/fixtures/revel_orders_fixture.dart`). The
`*.live.sandbox` slice diffs observed sandbox responses against these
constants.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `order.number_of_people` | int | `covers` | direct | <https://developer.revelsystems.com/revelsystems/docs/webhooks> |
| `order.created_date` | ISO 8601 UTC | `opened_at` | direct UTC | <https://developer.revelsystems.com/revelsystems/docs/webhooks> |
| `order.updated_date` | ISO 8601 UTC | `closed_at` | direct UTC | <https://developer.revelsystems.com/revelsystems/docs/webhooks> |
| `order.final_total` | string-decimal or number (dollars) | `actual_sales` | parse to `num` | <https://developer.revelsystems.com/revelsystems/docs/webhooks> |
| `order.id` | int / string | `vendor_entity_id` | `.toString()` | <https://developer.revelsystems.com/revelsystems/docs/webhooks> |
| `order.updated_date` | ISO 8601 UTC | `vendor_modified_at` | direct UTC | <https://developer.revelsystems.com/revelsystems/docs/webhooks> |

Fixture constant: `test/integrations/pos/fixtures/revel_orders_fixture.dart`
exposes `documentedPerRevelV1FieldMapping`. The adapter source pins
the same mapping in `documentedPerRevelV1` so the two diff cleanly.

---

## Covers source classification

`direct`

Cite vendor doc:
<https://developer.revelsystems.com/revelsystems/docs/webhooks> —
the `order.number_of_people` field is documented as the guest count
for the order. The adapter records `covers_source = direct` for every
canonical fact write; no forecast fallback is engaged.

Operator chrome consequence: dashboards render live covers as soon as
the first canonical fact lands. The top-left honesty pill does not
need a "covers via forecast" line for Revel-connected operators (per
`docs/contracts/metric_card_honesty_contract.md`).

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `created_date` | ISO 8601 (`YYYY-MM-DDTHH:MM:SS[Z]`) | UTC (Revel's documented convention) | `vendorTimestampPolicy.revel.asUtc` (declared in `revel_pos_adapter.dart` `revelTimestampPolicy`; merges into the framework catalog at `8.0.lifecycle`'s integration commit) |
| `updated_date` | ISO 8601 (`YYYY-MM-DDTHH:MM:SS[Z]`) | UTC | same |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` (computed at write-time from `location.timezone` + `business_day_rollover_hour` per Phase 7.55 Rule 11) |

Revel's developer portal pins UTC as the convention but does not
universally include the trailing `Z` in every endpoint's responses.
The adapter treats any ambiguous form as UTC (`AmbiguousTimestampConvention.asUtc`)
and the `*.live.sandbox` slice confirms the assumption against
observed sandbox payloads. If the sandbox surface ever emits
location-local timestamps with no offset, the adapter REFUSES the
event at parse time (drops with `connector_sync_log.event_kind =
parse_error`); it does NOT silently re-interpret.

---

## Ambiguity calls

Per-field decisions where the documentation was unclear and the
adapter made a choice. The `*.live.sandbox` slice will verify these
first.

- **`order.final_total`**: doc shows the field as a string-decimal in
  some examples and as a number in others. The adapter accepts both
  (`_parseSales` falls through `num` → `String.tryParse`); the
  canonical fact stores the parsed `num`. Verify on live by
  inspecting raw payloads at the sandbox-verification slice.
- **`order.dining_option`**: doc maps integer codes to dine-in /
  pickup / delivery / etc., but the code → label mapping is not
  fully published. The adapter currently ignores `dining_option`;
  Phase 11W's vendor-connections widget shows order count without
  channel split until the mapping is verified at `*.live.sandbox`.
- **`order.local_id`**: Revel exposes both `id` (numeric global) and
  `local_id` (per-POS short string). The adapter treats `id` as the
  canonical `vendor_entity_id` because it is globally unique; the
  human-readable `local_id` is stored on the raw payload but not
  used for upsert keys.
- **Webhook auto-register endpoint path**: the `webhooks` portal
  documents the inbound HMAC-SHA1 contract but the developer-portal
  page consulted at retrieval time does not pin the exact path for
  the auto-register POST. The adapter's `RevelTransport.registerWebhook`
  signature accommodates the eventual exact path; the
  `*.live.sandbox` slice fills in the path observed at sandbox
  before the adapter ever runs against production.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores at canonical-write
time, even when present in the payload:

- `order.customer.email`, `order.customer.name`, `order.customer.phone`
  — privacy. F&F's operator-side T&Cs (Phase 9.8) commit to not
  storing guest PII outside what the operator explicitly opts into.
- `order.payments[].card_last4`, `order.payments[].card_brand`,
  `order.payments[].cardholder_name` — PCI scope. F&F is not a
  payment processor; the adapter never persists card-data fields.
  Revel's developer portal explicitly notes these fields are
  populated only when the operator's PCI scope allows; the adapter
  reads but does not write them.
- `order.tip_amount` (per-card breakdown) — aggregate tip totals
  are useful for variance, but per-card attribution belongs to the
  operator's payroll system, not F&F. The adapter ignores per-payment
  tip rows; aggregate `tip_total` may be consumed in a future slice.
- `order.history[]` (state-transition log) — out of scope for the
  POS canonical fact at V1; revisit if `closed_at` accuracy becomes
  load-bearing.
