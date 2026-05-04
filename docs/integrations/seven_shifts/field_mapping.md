# 7shifts — Field Mapping

**Vendor ID**: `seven_shifts`
**Source documentation**: <https://developers.7shifts.com>
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here; every row here is mirrored in the
`documentedPerSevenShiftsV2FieldMapping` constant in
`lib/integrations/labor/seven_shifts_labor_adapter.dart` and in the
fixture-side
`documentedPerSevenShiftsV2FieldMappingFixture`. The two constants
are kept in sync by the `documented field-mapping constant mirrors
fixture` test in
`test/integrations/labor/seven_shifts_labor_adapter_test.dart`.

Two rows are **load-bearing for the Phase 7.58 Primary Driver audit**
per `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md`
(8.S.7S row): `is_approved` (per-punch `approved` boolean) and
`payroll_period_closed_at` (`payroll_period.closed` event +
`/payroll_periods` poll). The `8.S.7S.live.sandbox` slice diffs each
row against the first observed sandbox payload and cuts bounded fixes
for any drift.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `time_punch.id` | int | `vendor_entity_id` | `to_string` | <https://developers.7shifts.com/reference/listtimepunches> |
| `time_punch.modified` | ISO 8601 UTC | `vendor_modified_at` | direct UTC | <https://developers.7shifts.com/reference/listtimepunches> |
| `time_punch.clocked_in` | ISO 8601 UTC | `shift_start` | direct UTC | <https://developers.7shifts.com/reference/listtimepunches> |
| `time_punch.clocked_out` | ISO 8601 UTC or null | `shift_end` | direct UTC when not null | <https://developers.7shifts.com/reference/listtimepunches> |
| `time_punch.role.name` | string | `role_name` | lowercase | <https://developers.7shifts.com/reference/listroles> |
| `time_punch.user_id` | int | `employee_id` | `to_string` | <https://developers.7shifts.com/reference/listusers> |
| `time_punch.approved` | bool | **`is_approved`** | direct | <https://developers.7shifts.com/reference/listtimepunches> |
| `payroll_period.closed_at` | ISO 8601 UTC | **`payroll_period_closed_at`** | direct UTC | <https://developers.7shifts.com/reference/listpayrollperiods> |

The two bolded rows are load-bearing for the Phase 7.58 Primary
Driver audit. The adapter sources `payroll_period_closed_at` from
**both** the polling endpoint
(`GET /v2/company/{id}/payroll_periods?status=closed`) and the
inbound `payroll_period.closed` webhook so finalization lands whether
the operator is on Gourmet (webhook) or a lower plan tier (poll-only).
This dual-source design is verified by the slice's
`payroll_period.closed webhook handler (Test 8)` and the smoke test's
backfill assertion that `gateway.canonicalPayrollPeriodFacts` is
populated even on a Gourmet-plan connection (the polling path runs
alongside webhooks for resilience).

---

## Covers source classification

`not_applicable`

7shifts is a labor / scheduling system; it does not expose a covers
field suitable for the F&F COVERS card. Covers come from the POS
adapter on the same location (Phase 8). The adapter records
`coversFieldExposed: false` on `VendorCapabilityProfile`.

Cite vendor doc: <https://developers.7shifts.com>

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `time_punch.clocked_in` | ISO 8601 with explicit `Z` | UTC | `vendor_timestamp_policy.seven_shifts.refuse` until `*.live.sandbox` confirms; reads convert to UTC instant |
| `time_punch.clocked_out` | ISO 8601 with explicit `Z`, or null | UTC | as above; null → canonical `shift_end` is null |
| `time_punch.modified` | ISO 8601 with explicit `Z` | UTC | as above |
| `payroll_period.closed_at` | ISO 8601 with explicit `Z` | UTC | as above |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

7shifts v2 timestamps include explicit `Z` per the developer
reference. The adapter binds
`AmbiguousTimestampConvention.refuse` so that ambiguous shapes (no
`Z`, no offset) are dropped at the parse boundary instead of silently
treated as UTC — the bug Scenario E is designed to catch. The
`8.S.7S.live.sandbox` slice will re-bind to `asUtc` once observed
sandbox payloads confirm the shape.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live.sandbox` slice will verify these first.

- **`time_punch.id`**: documented as integer; the adapter coerces to
  string via `to_string` to match the
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  idempotency UNIQUE shape every other adapter uses. No live
  ambiguity expected; verify on the first observed payload.
- **`time_punch.clocked_out`**: documented nullable for open punches.
  The canonical fact stores null; the next polling tick re-emits the
  row when the operator clocks out (idempotency UNIQUE on
  `vendor_modified_at` collapses the duplicate write).
- **`time_punch.role`**: documented as a nested object with
  `id` + `name`. The adapter persists only the lowercased `name` so
  the operator's role-mapping override (`FOH/BOH/manager/excluded`)
  works against a stable string. If the live response wraps the
  object differently (e.g., `role_id` as a sibling), adapter cuts a
  bounded fix.
- **`time_punch.approved`**: documented as boolean (true/false). The
  canonical fact stores the bool directly; the Phase 7.58 Primary
  Driver audit's threshold logic is the consumer.
- **`payroll_period.closed_at`**: documented per the
  `/payroll_periods` reference. The webhook envelope is assumed to
  nest the closed period under `payroll_period`; the adapter falls
  back to a `data` key for compatibility with vendor envelope
  variations.
- **Webhook event vocabulary**: 7shifts ships per-event endpoints
  (`time_punch.created` / `.edited` / `.deleted`,
  `shift.created` / `.updated` / `.deleted`,
  `payroll_period.closed`) per the webhook reference. The adapter
  registers the full set so a future event-name change forces an
  explicit subscription update rather than a silent drop.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores per the F&F privacy
posture (operator's T&Cs at Phase 9.8 — employee personal data is
out of scope at launch):

- `user.email` — employee email is not persisted.
- `user.phone` — employee phone is not persisted.
- `user.dob` — date of birth is not persisted.
- `user.ssn`, `user.payroll_id`, etc. — payroll PII; F&F is not the
  payroll processor at launch.
- Any payment / direct-deposit field — out of PCI scope.

The fixture's sample punch
(`sevenShiftsSamplePunch` in
`test/integrations/labor/fixtures/seven_shifts_punches_fixture.dart`)
includes the forbidden `user` block (`email`, `phone`, `dob`) so the
canonicalizer's "persists only allowed fields" behavior can be
asserted against an explicit positive sample.
