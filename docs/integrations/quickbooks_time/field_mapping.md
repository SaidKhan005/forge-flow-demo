# QuickBooks Time — Field Mapping

**Vendor ID**: `quickbooks_time`
**Source documentation**: <https://tsheetsteam.github.io/api_docs/>
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical labor fact field the
adapter populates has a row here. Every row here is cited in the
adapter as a `documented_per_quickbooks_time_v1` constant in
`test/integrations/labor/fixtures/quickbooks_time_punches_fixture.dart`.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `timesheets[].id` | int | `vendor_entity_id` | int → string at write | <https://tsheetsteam.github.io/api_docs/?javascript#timesheets> |
| `timesheets[].start` | ISO 8601 with explicit `Z` (UTC) | `shift_start` | direct UTC | <https://tsheetsteam.github.io/api_docs/?javascript#timesheets> |
| `timesheets[].end` | ISO 8601 with explicit `Z` (UTC); empty string when timesheet is open | `shift_end` | direct UTC; null when empty | <https://tsheetsteam.github.io/api_docs/?javascript#timesheets> |
| `timesheets[].last_modified` | ISO 8601 with explicit `Z` (UTC) | `vendor_modified_at` | direct UTC | <https://tsheetsteam.github.io/api_docs/?javascript#timesheets> |
| `timesheets[].user_id` | int | `employee_id` | int → string at write | <https://tsheetsteam.github.io/api_docs/?javascript#users> |
| `jobcodes[].name` (joined via `timesheets[].jobcode_id`) | string | `role_name` | direct (FOH/BOH classification overlay applied at admin-surface onboarding, not at the adapter boundary) | <https://tsheetsteam.github.io/api_docs/?javascript#jobcodes> |
| `users[].pay_rate` | decimal string | `wage_rate` | string → decimal; `wage_source = vendor` when present | <https://tsheetsteam.github.io/api_docs/?javascript#users> |

Every row above is mirrored in
`documented_per_quickbooks_time_v1` (in
`lib/integrations/labor/quickbooks_time_labor_adapter.dart` and the
fixture file). The `*.live.sandbox` slice diffs observed responses
against this constant.

---

## Covers source classification

`not_applicable` — labor systems do not expose a covers field. Covers
come from POS adapters per
`docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`.

The adapter records `covers_source = not_applicable` so the
operator-facing chrome (per
`docs/contracts/metric_card_honesty_contract.md`) does not show a
"covers via forecast" pill on labor-only connections.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `start` | ISO 8601 | UTC | `vendor_timestamp_policy.quickbooks_time.asUtc` |
| `end` | ISO 8601 | UTC (or empty when timesheet still open) | `vendor_timestamp_policy.quickbooks_time.asUtc` |
| `last_modified` | ISO 8601 | UTC | `vendor_timestamp_policy.quickbooks_time.asUtc` |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

The vendor consistently emits ISO-8601 instants with explicit `Z`.
The policy is declared `asUtc` so a future API change that drops the
`Z` does not silently break business-date bucketing — the adapter
will refuse the timestamp at parse time per Scenario E.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live.sandbox` slice will verify these first.

- **`timesheets[].end` empty string vs null.** Doc shows `end` as a
  string field; an open (still-clocked-in) timesheet returns `""`.
  The adapter parses an empty string to `shift_end = null` and
  re-emits the canonical row when the timesheet later closes. Verify
  on live by clocking a real employee in, polling, then clocking out.
- **`role_name` source — joined `jobcode.name` vs flat
  `timesheets[].name`.** The doc exposes `jobcode_id` on the
  timesheet and `name` on the jobcode. The adapter joins
  `timesheets[].jobcode_id` against the cached jobcodes catalog.
  Verify on live by confirming the joined name matches the operator's
  QBT admin-side jobcode label.
- **Pay rate scope.** `users[].pay_rate` is documented but only
  populated when the OAuth grant includes the pay-rate scope. The
  adapter records `wage_source = vendor` when populated;
  `wage_source = app_fallback` otherwise. Verify on live by
  inspecting the scope returned in the access token.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `users[].ssn` — privacy + scope.
- `users[].address` — employee home address; privacy.
- `users[].mobile_number` — privacy.
- `users[].email` — privacy.
- `users[].first_name` / `users[].last_name` — recorded as opaque
  `employee_id` only at V1; per-employee identity reconciliation is
  out of scope per
  `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md`.
