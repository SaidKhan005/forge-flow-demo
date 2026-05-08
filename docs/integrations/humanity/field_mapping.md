# Humanity (TCP) — Field Mapping

**Vendor ID**: `humanity`
**Source documentation**: <https://platform.humanity.com/v1.0>
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here; every row here is cited in the adapter as
a `documented_per_humanity_v1_0` constant entry in the fixture
(`test/integrations/labor/fixtures/humanity_punches_fixture.dart`)
and the adapter source
(`lib/integrations/labor/humanity_labor_adapter.dart`
`documentedPerHumanityV10FieldMapping`).

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `shifts.in_time` | ISO 8601 UTC | `shift_start` | direct UTC | <https://platform.humanity.com/v1.0/shifts> |
| `shifts.out_time` | ISO 8601 UTC | `shift_end` | direct UTC | <https://platform.humanity.com/v1.0/shifts> |
| `positions.name` | string | `role_name` | direct | <https://platform.humanity.com/v1.0/positions> |
| `employees.id` | string or int | `employee_id` | direct (stringify) | <https://platform.humanity.com/v1.0/employees> |
| `shifts.id` | string or int | `vendor_entity_id` | direct (stringify) | <https://platform.humanity.com/v1.0/shifts> |
| `shifts.updated` | ISO 8601 UTC | `vendor_modified_at` | direct UTC | <https://platform.humanity.com/v1.0/shifts> |

Each row above is mirrored as a constant entry in
`documentedPerHumanityV10FieldMapping` (adapter) and
`documentedPerHumanityV10FieldMappingFixture` (fixture). The test
"field-mapping constant mirrors fixture" pins the two in sync; the
`*.live.sandbox` slice diffs observed Humanity responses against
this constant. Mismatches become bounded fixes (one PR per drifted
field), not slice rebuilds, per
`docs/contracts/vendor_adapter_slice_contract.md`.

---

## Covers source classification

`not_applicable` — Humanity is a labor / scheduling adapter; covers
come from the operator's POS adapter (Phase 8). The adapter does
**not** populate a `covers` field on its canonical writes;
`coversFieldExposed = false` on the capability profile.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `shifts.in_time` | ISO 8601 with explicit `Z` | UTC | `humanityTimestampPolicy.asUtc` (declared locally in the adapter; deferred-merged into `vendor_timestamp_policy.dart` at the integration commit) |
| `shifts.out_time` | ISO 8601 with explicit `Z` | UTC | same |
| `shifts.updated` | ISO 8601 with explicit `Z` | UTC | same |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

The Humanity v1 documented response always carries the trailing
`Z`. The policy stays declarative as `asUtc` so a future API change
that drops `Z` does not silently break business-date bucketing —
the framework refuses ambiguous timestamps for vendors whose policy
is `refuse` (Scenario E from the binding A-F test set), but
Humanity declares `asUtc` since the doc convention is fixed.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made
a choice. The `*.live.sandbox` slice will verify these first.

- **`shifts.id` type**: vendor doc shows it as integer in some
  examples and string in others. The adapter stringifies in
  `HumanityShiftDto.tryFromMap` so both shapes round-trip cleanly.
  Verify on live by inspecting the first sandbox response.
- **`employees.id` vs `employees.employee_id`**: the documented
  shape uses both keys depending on the endpoint. The DTO accepts
  either (`map['employee_id'] ?? map['employee']`). The
  `*.live.sandbox` row "Field-mapping diff" pins which one each
  endpoint actually returns.
- **`positions.name` vs `position_name`**: same — adapter accepts
  both keys.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores (privacy +
out-of-scope):

- `employees.email` — operator-owned PII; F&F never persists.
- `employees.phone` — operator-owned PII.
- `employees.name` (full name) — operator-owned PII; the canonical
  fact stores only `employee_id`. Display names (when surfaced in
  the operator app) come from the operator's existing employee
  directory, not from Humanity.
- `positions.pay_rate` — wage data lands via the wage-source
  pipeline (Phase 7.58); Humanity exposes only position-level pay
  rates, not per-employee, so the adapter's wage path falls back
  to the app-owned wage generator (`wage_source = app_fallback`)
  per the Wage Ingestion Policy in
  `docs/archive/phases/phase_8S/phase_8S_scheduling_connector_plan.md`.
