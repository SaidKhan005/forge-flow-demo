# Aloha (NCR Voyix) — Field Mapping

**Vendor ID**: `aloha_ncr_voyix`
**Source documentation**: <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here. Every row here is cited in the adapter's
`documentedPerAlohaNcrVoyixV1` constant
(`lib/integrations/pos/aloha_ncr_voyix_pos_adapter.dart`) and mirrored
in the orders fixture
(`test/integrations/pos/fixtures/aloha_ncr_voyix_orders_fixture.dart`).

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `checks[].numberOfGuests` | int | `covers` | direct | <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer> |
| `checks[].openedAt` | ISO 8601 UTC | `opened_at` | direct UTC | <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer> |
| `checks[].closedAt` | ISO 8601 UTC | `closed_at` | direct UTC | <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer> |
| `checks[].totalAmount` | decimal dollars | `actual_sales` | direct | <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer> |
| `checks[].checkId` | string | `vendor_entity_id` | direct | <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer> |
| `checks[].modifiedAt` | ISO 8601 UTC | `vendor_modified_at` | direct UTC | <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer> |
| `checks[].siteId` | string | (binding cross-check only — `connector_connection.metadata.site_id`) | direct | <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer> |

Every row above is encoded in the adapter's
`documentedPerAlohaNcrVoyixV1` constant:

```dart
// lib/integrations/pos/aloha_ncr_voyix_pos_adapter.dart
const Map<String, Object?> documentedPerAlohaNcrVoyixV1 = <String, Object?>{
  'source_url':
      'https://developer.ncrvoyix.com/portals/dev-portal/api-explorer',
  'retrieval_date': '2026-05-04',
  'api_version': 'aloha-v1-2026-05',
  'covers_path': 'numberOfGuests',
  'covers_type': 'int',
  'covers_classification': 'direct',
  'opened_at_path': 'openedAt',
  'opened_at_format': 'iso8601_utc',
  'closed_at_path': 'closedAt',
  'closed_at_format': 'iso8601_utc',
  'actual_sales_path': 'totalAmount',
  'actual_sales_type': 'decimal_dollars',
  'vendor_entity_id_path': 'checkId',
  'vendor_modified_at_path': 'modifiedAt',
  'vendor_modified_at_format': 'iso8601_utc',
  'site_id_path': 'siteId',
  'forbidden_fields': <String>[
    'guest.firstName',
    'guest.lastName',
    'guest.email',
    'payments.cardholderName',
    'payments.cardLast4',
  ],
};
```

---

## Covers source classification

`direct`

Cite vendor doc: <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>

Aloha exposes the guest count on each check via the documented
`numberOfGuests` field. The adapter records `covers_source = direct`
on every canonical fact write. No forecast fallback is needed for
Aloha. If `8.AL.live.sandbox` observes that some Aloha sites surface
`numberOfGuests` as null on quick-service checks, the bounded fix is
to record `covers_source = forecast_fallback` for the null subset
without rebuilding the slice.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `openedAt` | ISO 8601 | UTC | `vendor_timestamp_policy.aloha_ncr_voyix.asUtc` |
| `closedAt` | ISO 8601 | UTC | `vendor_timestamp_policy.aloha_ncr_voyix.asUtc` |
| `modifiedAt` | ISO 8601 | UTC | `vendor_timestamp_policy.aloha_ncr_voyix.asUtc` |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

NCR Voyix Aloha-module timestamps are documented as ISO 8601 UTC with
the `Z` suffix. Scenario E (ambiguous timestamp) does not apply, but
the policy declaration stays so the framework's refuse-by-default
protection still recognizes Aloha (NCR Voyix). The
`vendor_timestamp_policy.dart` registry entry for `'aloha_ncr_voyix'`
lands with `8.AL.live.sandbox` (out of scope for the engineering
slice per the per-slice file-isolation rule).

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `8.AL.live.sandbox` slice will verify these first.

- **`numberOfGuests`**: documented as int; some POS surfaces emit
  decimals. Adapter accepts the documented int shape; live diff fix
  is bounded if vendor emits decimal.
- **`totalAmount`**: documented as decimal dollars (not cents). Live
  diff fix is bounded if vendor emits cents — flip the constant
  `actual_sales_type` to `cents` and divide by 100 in `_canonicalize`.
- **`checkId`**: assumed stable across modifications. If vendor emits
  separate `checkId` per modification (versioned), the bounded fix is
  to use the parent `checkParentId` field for `vendor_entity_id`.
- **Pagination cursor token**: assumed `nextCursor` opaque string per
  the documented portal shape. If vendor uses `next_url`, the adapter
  treats the value as opaque (the adapter never parses cursor
  internals); no fix needed.
- **Webhook event names**: assumed `aloha.check.modified` /
  `aloha.check.opened`. If vendor uses different names, the bounded
  fix is to update the `events` array in the subscription registration
  body (no code path change).

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `guest.firstName` / `guest.lastName` / `guest.email` — privacy.
  See operator T&Cs at Phase 9.8.
- `payments.cardholderName` / `payments.cardLast4` — PCI scope; F&F
  is not a payment processor.
- `tipAmount` (per-cardholder) — aggregate-first; per-employee tip
  attribution is the operator's payroll system's job.
