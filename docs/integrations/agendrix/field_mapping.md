# Agendrix — Field Mapping

**Vendor ID**: `agendrix`
**Source documentation**: <https://developers.agendrix.com/en/documentation>
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here; every row here is mirrored in the fixture
constant `documented_per_agendrix_v2` at
`test/integrations/labor/fixtures/agendrix_punches_fixture.dart`.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `time_entries[].start_time` | ISO 8601 UTC (with explicit `Z`) | `shift_start` | direct UTC | <https://developers.agendrix.com/en/documentation> |
| `time_entries[].end_time` | ISO 8601 UTC (with explicit `Z`) | `shift_end` | direct UTC | <https://developers.agendrix.com/en/documentation> |
| `time_entries[].position.name` | string | `role_name` | direct | <https://developers.agendrix.com/en/documentation> |
| `time_entries[].user_id` | string (Agendrix user id) | `employee_id` | direct (within-vendor namespace; no cross-vendor reconciliation at V1) | <https://developers.agendrix.com/en/documentation> |
| `time_entries[].id` | string (Agendrix time entry id) | `vendor_entity_id` | direct | <https://developers.agendrix.com/en/documentation> |
| `time_entries[].updated_at` | ISO 8601 UTC (with explicit `Z`) | `vendor_modified_at` | direct UTC | <https://developers.agendrix.com/en/documentation> |

Every row above also appears as an entry in
`documented_per_agendrix_v2` (fixture). Adapter source:
`lib/integrations/labor/agendrix_labor_adapter.dart`
(`_mapTimeEntryToCanonical`).

---

## Covers source classification

`not_applicable`

Cite vendor doc:
<https://developers.agendrix.com/en/documentation>
(Agendrix is a scheduling / time-clock vendor; covers / number-of-guests
is a POS-side concept and is not exposed by Agendrix's public API.)

The adapter records `covers_source = 'not_applicable'` on every
canonical fact write — see the constant in `_mapTimeEntryToCanonical`.
The operator-facing covers metric never sources from Agendrix; the POS
adapter family owns it. The dashboard pill drops the "covers via
forecast" line based on the POS adapter's `coversFieldExposed`, not
the labor adapter's.

---

## Wage source classification

`app_fallback`

Agendrix exposes `position.pay_rate` (per-position wage), not a
per-shift wage. The adapter therefore records
`wage_source = 'app_fallback'` and degrades to the app-owned wage
generator (`lib/services/wage_authority_service.dart`) per the
`LaborModel` contract and the Phase 8.S wage ingestion policy table.
The `8.S.AG.live.sandbox` slice will diff observed wage data against
the documented per-position shape; if production proves reliable the
live slice may bump this to `'vendor'` for the per-position rate
component (per-shift wage stays `'app_fallback'`).

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `start_time` | ISO 8601 | UTC (explicit `Z`) | `agendrix.asUtc` (declared as `timestampPolicyDocId` on the capability profile; mirrored in `vendor_timestamp_policy.dart` when `8.0.lifecycle` registers it). |
| `end_time` | ISO 8601 | UTC (explicit `Z`) | `agendrix.asUtc` |
| `updated_at` | ISO 8601 | UTC (explicit `Z`) | `agendrix.asUtc` |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

The adapter parses every documented timestamp via
`DateTime.parse(...).toUtc()`. Ambiguous shapes (no `Z`, no offset)
are refused per the timestamp policy — Scenario E from the binding A-F
test set (`docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`).
The `8.S.AG.live.sandbox` slice verifies that production time entries
always carry the explicit-Z form.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `8.S.AG.live.sandbox` slice will verify these first.

- **`time_entries[].position` shape**: the documented shape exposes
  `position` as a nested object with `id` + `name`. The adapter reads
  `position.name` for `role_name`. If production returns
  `position_id` as a flat field instead (vendor sometimes flattens
  references in older API tiers), the live slice switches the
  field path and bumps the fixture constant.
- **`time_entries[].id` opacity**: the adapter treats the entry id as
  an opaque vendor string. If production returns a numeric id rather
  than a string, the canonical write coerces to string form
  (`id?.toString()`); the canonical UNIQUE keys on string form anyway,
  so no slice rebuild is required either way.
- **`time_entries[].updated_at` rotation**: Agendrix documents
  `updated_at` as the authoritative modification cursor; the adapter
  treats it as monotonically non-decreasing within a single page chain.
  The live slice verifies this on a production sample with a known
  edit history.
- **Polling cadence**: Agendrix does not publish a recommended poll
  cadence. The adapter assumes 5 minutes per organization at default;
  the soft cap is confirmed on the live slice.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `time_entries[].user.first_name` / `time_entries[].user.last_name`
  — privacy. The adapter binds employee identity through opaque
  `user_id` only. Operator T&Cs cover the lawful basis for the user
  id binding (Phase 9.8).
- `time_entries[].user.email` / `phone_number` — privacy; not needed
  for labor ingestion.
- `time_entries[].notes` (free-text) — out of scope for V1; may carry
  PII or operator-confidential context that should not be captured by
  the adapter.
- Cross-vendor employee reconciliation — explicit non-goal at V1 per
  `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md`.
  Agendrix `user_id` is treated as a within-vendor namespace.
