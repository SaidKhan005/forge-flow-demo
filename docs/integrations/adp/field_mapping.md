# ADP Workforce Now / Workforce Manager — Field Mapping

**Vendor ID**: `adp`
**Source documentation**: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
(public ADP developer-portal API catalog. Same portal hosts the
Workforce Manager (WFM) catalog. Endpoint shapes gated on ADP
Marketplace Developer Participation Agreement — see
`partnership_status.md`.)
**Retrieval date**: 2026-05-04

> **Every row in this file is an assumption to verify in
> `8.S.ADP.live.sandbox`.** ADP's exact field paths for Time Events
> v2 / Team Time Cards v2 / Time Work Schedules v1 / Work Assignments
> are released to partners after the DPA clears. The adapter is
> engineered against the published shapes (developer-portal catalog
> overview + industry-standard ADP DTOs). `*.live.sandbox` diffs each
> row against the first observed sandbox response; mismatches become
> bounded fixes, not slice rebuilds, per
> `docs/contracts/vendor_adapter_slice_contract.md`.

---

## Source field → canonical field

| Vendor field path (assumed) | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `time_event.id` | string | `vendor_entity_id` | direct | <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog> |
| `time_event.last_modified_date_time` | iso8601 utc | `vendor_modified_at` | direct utc | <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog> |
| `time_event.entry_date_time` | iso8601 utc | `shift_start` | direct utc | <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog> |
| `time_event.exit_date_time` | iso8601 utc / null | `shift_end` | direct utc; null preserves "open punch" | <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog> |
| `worker.position.position_title` (WFN) **or** `worker.workAssignment.jobTitle` (WFM) | string | `role_name` | direct; canonicalizer falls back from WFN to WFM path | <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog> |
| `worker.associate_oid` | string | `employee_id` | direct | <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog> |

Module disambiguation note: each row carries a `verify_in_live_sandbox`
flag in `documentedPerAdpV1FieldMapping`. WFN and WFM share schema
where it matters for schedule + punch data; the only documented
divergence is the `role_name` source path. The canonicalizer in
`lib/integrations/labor/adp_labor_adapter.dart` already handles both
paths and flags which one was used per record so the live diff
records the actual production split.

---

## Covers source classification

`not_applicable`

ADP is a labor / scheduling system; it does not expose
covers / number-of-guests data. Covers come from the operator's POS
adapter (Phase 8). The capability profile records
`coversFieldExposed: false` and the labor adapter NEVER writes a
`covers_source` value. The covers card on the operator dashboard
honors `docs/contracts/metric_card_honesty_contract.md`: when no POS
adapter is connected the card renders `MetricCardNotYetAvailable`;
the ADP connection alone does not flip that card's state.

---

## Timestamp shapes

For every consumed timestamp:

| Field | Format (assumed) | Timezone | Policy doc reference |
|---|---|---|---|
| `time_event.entry_date_time` | ISO 8601 with explicit `Z` | UTC | `vendorTimestampPolicy['adp']` (declared locally as `adpTimestampPolicy`; deferred-merged into the framework catalog at the integration commit). |
| `time_event.exit_date_time` | ISO 8601 with explicit `Z` (or null for open punch) | UTC | same as above |
| `time_event.last_modified_date_time` | ISO 8601 with explicit `Z` | UTC | same as above |

The local `adpTimestampPolicy` constant in
`lib/integrations/labor/adp_labor_adapter.dart` declares
`AmbiguousTimestampConvention.refuse` so the adapter rejects any
observed timestamp that lacks a `Z` or offset until the
`*.live.sandbox` slice confirms ADP's exact convention. Silent
fallback to "treat as UTC" is exactly the bug Scenario E of
`vendor_timestamp_sanity.dart` is designed to catch.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live` slice will verify these first:

- **`time_event.id` exact path**: WFN endpoints commonly expose a
  stable item id; some surfaces use `time_event.itemID` and the WFM
  side uses `timePunch.punchID`. The canonicalizer reads
  `time_event.id` first; the live diff records which path each
  module / endpoint returns and the adapter trims the dead path.
- **Open-punch handling**: when `exit_date_time` is null the
  canonical fact persists `shift_end = null` and downstream reads
  project "in progress". The live diff confirms ADP emits null (vs
  some other "open" sentinel like `0001-01-01T00:00:00Z`).
- **Module-aware role path**: WFN `worker.position.position_title`
  vs WFM `worker.workAssignment.jobTitle`. The fallback chain in
  `_canonicalize` reads WFN first, then WFM. The live diff confirms
  per module.
- **`associate_oid` cross-module stability**: ADP documents
  `associate_oid` as stable across worker lifecycle. The adapter
  binds employee identity to this field; cross-vendor employee
  identity is an explicit non-goal at V1 (per Phase 8.S plan).

---

## Forbidden fields

The adapter intentionally ignores these vendor fields. They MUST NOT
land in any canonical fact:

- `worker.legal_name.given_name`, `worker.legal_name.family_name`,
  `worker.preferred_name`, `worker.demographic.*` — PII not required
  for schedule / punch / role mapping.
- `worker.compensation.*`, `worker.pay_rate`, any salary or annual
  comp surface — not required for V1 wage ingestion (handled in a
  later slice on the `pay_rate` path only when wage ingestion lights
  up; see Phase 8.S "Wage Ingestion Policy"; this engineering slice
  ships `wage_source = vendor` declaration only).
- `worker.governmentIds`, SSN, tax id — never read or persisted.
- `worker.contact.*` — phone / email out of scope.
- Any payment / direct-deposit / banking field — out of scope and
  PCI-adjacent.

The banned-items grep test in
`test/integrations/labor/adp_labor_adapter_test.dart` does not look
for these field names directly (those are vendor-shape, not engine-
shape); the adapter source review at acceptance verifies none of
them are read.

---

## How the live slice diffs this file

The `8.S.ADP.live.sandbox` slice walks every row in
`documentedPerAdpV1FieldMapping`, fetches one observed sandbox
record, and asserts each path + type + transform. Mismatches become
bounded fixes:

1. Update the row in `documentedPerAdpV1FieldMapping` (and the
   fixture mirror) with the observed shape.
2. Update this `field_mapping.md` table.
3. Bump `documented_per_adp_<api_version>` if the API version
   string changed.
4. Update the relevant test fixture sample so the test-connection
   path returns the right shape.

No slice rebuild required — the diff is bounded.
