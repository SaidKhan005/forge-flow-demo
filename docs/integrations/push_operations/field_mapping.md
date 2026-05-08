# Push Operations — Field Mapping

**Vendor ID**: `push_operations`
**Source documentation**: <https://developers.pushoperations.com/>
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here; every row here is mirrored in the fixture
constant `documented_per_push_operations_v1` at
`test/integrations/labor/fixtures/push_operations_punches_fixture.dart`.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `shifts[].id` | int (stringified at canonical write) | `vendor_entity_id` | direct | <https://developers.pushoperations.com/> |
| `shifts[].employee_id` | int (stringified at canonical write) | `employee_id` | direct | <https://developers.pushoperations.com/> |
| `shifts[].position_name` | string (free-form vendor-defined position label) | `role_name` | direct (FOH/BOH classification mapped at admin onboarding via `role_assignment`, not in the adapter) | <https://developers.pushoperations.com/> |
| `shifts[].start_at` | ISO 8601 UTC (with explicit `Z`) | `shift_start` | direct UTC | <https://developers.pushoperations.com/> |
| `shifts[].end_at` | ISO 8601 UTC (with explicit `Z`) | `shift_end` | direct UTC | <https://developers.pushoperations.com/> |
| `shifts[].updated_at` | ISO 8601 UTC (with explicit `Z`) | `vendor_modified_at` | direct UTC | <https://developers.pushoperations.com/> |

Every row above also appears as an entry in
`documented_per_push_operations_v1` (fixture). Adapter source:
`lib/integrations/labor/push_operations_labor_adapter.dart`
(`_mapShiftToCanonical`).

---

## Covers source classification

`not_applicable`

Cite vendor doc: <https://developers.pushoperations.com/>
(Push Operations is a scheduling / time-tracking vendor; covers data
is not exposed by the workforce-management API surface.)

The adapter records `covers_source = 'not_applicable'` on every
canonical fact write — see the constant in `_mapShiftToCanonical`. The
operator dashboard's "covers via forecast" line is governed by the
operator's POS adapter, never this adapter; the metric-card honesty
chrome reads `coversFieldExposed = false` here as a no-op (the labor
adapter does not contribute to covers provenance).

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `start_at` | ISO 8601 | UTC (explicit `Z`) | `push_operations.asUtc` (declared as `timestampPolicyDocId` on the capability profile; mirrored in `vendor_timestamp_policy.dart` when `8.0.lifecycle` registers it). |
| `end_at` | ISO 8601 | UTC (explicit `Z`) | `push_operations.asUtc` |
| `updated_at` | ISO 8601 | UTC (explicit `Z`) | `push_operations.asUtc` |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

The adapter parses every documented timestamp via
`DateTime.parse(...).toUtc()`. Ambiguous shapes (no `Z`, no offset)
are refused per the timestamp policy — Scenario E from the binding A-F
test set (`docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`).
The `8.S.PU.live.sandbox` slice verifies that production shift records
always carry the explicit-Z form.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `8.S.PU.live.sandbox` slice will verify these first.

- **`shifts[].position_name` vs separate `position_id` lookup**: Push
  Operations exposes both a position id and the resolved position
  name on a shift record. The adapter records the human-readable
  `position_name` directly so role mapping works without a second
  lookup; the `8.S.PU.live.sandbox` slice will verify the field is
  populated on every shift (vs occasionally null requiring a join
  through `/api/v1/positions`). If null, the live slice switches the
  canonical transform to a `position_id` → `/api/v1/positions` join
  and bumps the fixture constant.
- **`shifts[].start_at` vs `scheduled_start_at` vs `actual_start_at`**:
  Push Operations distinguishes scheduled vs actual on labour entries
  (`/api/v1/labour`); on the shifts surface (`/api/v1/shifts`) the
  documented field is `start_at`. The adapter records the published
  schedule shift's `start_at`; punch-level actual time lives on
  `/api/v1/labour` and is a follow-up canonical fact in the
  `8.S.PU.live.*` slices. The `documented` slice ships shifts only.
- **Polling cadence**: Push Operations does not publish a recommended
  poll cadence. The adapter assumes 5 minutes per location at default;
  partner approval may raise the soft cap. The `8.S.PU.live.sandbox`
  slice confirms 5 min does not trip the documented soft cap. The
  `/api/v1/labour` 2-day max date-range window means the bridge
  worker batches the 60-day backfill in 2-day chunks when `/labour`
  goes live.
- **Bearer token expiry**: Push Operations bearer tokens are
  partner-issued static credentials; the documented surface does not
  expose a refresh hop. The adapter treats the bearer as a durable
  credential and surfaces an `error` connection state when the token
  is revoked at the partner portal. The `8.S.PU.live.prod` slice
  verifies the revoke-then-401 path.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `employees[].first_name` / `employees[].last_name` /
  `employees[].email` / `employees[].phone` — privacy. The adapter
  works in employee-id space only; operator-facing employee names are
  rendered through F&F's `EmployeeDirectoryService`, not pulled via
  the Push surface. See operator T&Cs at Phase 9.8.
- `employees[].ssn` / `employees[].sin` / any tax-id field — privacy +
  PII scope. F&F is not a payroll-of-record system.
- `labour[].tip_amount` (per-employee) — aggregate-first; per-employee
  tip attribution is the operator's payroll system's job.
- `shifts[].notes` (free-form scheduler notes) — out of scope for the
  canonical fact; the adapter retains the full vendor record on
  `raw_payload` if the operator later asks for note auditing.
