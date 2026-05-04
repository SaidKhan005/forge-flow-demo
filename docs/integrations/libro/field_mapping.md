# Libro Reserve — Field Mapping

**Vendor ID**: `libro`
**Source documentation**: <https://libroreserve.github.io/api-documentation/>
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here. Every row here is cited in
`test/integrations/reservation/fixtures/libro_reservations_fixture.dart`
as the `documented_per_libro_v1` constant; the live slice
`8R.LB.live.sandbox` diffs observed sandbox responses against that
constant.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `reservations[].id` | string | `vendor_entity_id` | direct | <https://libroreserve.github.io/api-documentation/#operation/listReservations> |
| `reservations[].venue_id` | string | `connector_connection.metadata.venue_id` (binding) | direct | same |
| `reservations[].size` | int | `party_size` | direct | same |
| `reservations[].status` | string enum | `status` (`CanonicalReservationStatus`) | normalize via `LibroReservationAdapter._normalizeStatus` | same |
| `reservations[].reservation_at` | ISO 8601, no tz | `reservation_at` | wall-clock → UTC via `LibroIanaConverter.wallClockToUtc(restaurantTimezone)`; `business_date` derived per Phase 7.55 Rule 11 | same |
| `reservations[].updated_at` | ISO 8601, no tz | `vendor_modified_at` | wall-clock → UTC | same |
| `reservations[].created_at` | ISO 8601, no tz | `status_transitions.expected` | wall-clock → UTC | same |
| `reservations[].confirmed_at` | ISO 8601, no tz | `status_transitions.confirmed` | wall-clock → UTC | same |
| `reservations[].arrived_at` | ISO 8601, no tz | `status_transitions.arrived` | wall-clock → UTC | same |
| `reservations[].seated_at` | ISO 8601, no tz | `status_transitions.seated` | wall-clock → UTC | same |
| `reservations[].completed_at` | ISO 8601, no tz | `status_transitions.completed` | wall-clock → UTC | same |
| `reservations[].canceled_at` | ISO 8601, no tz | `status_transitions.canceled` | wall-clock → UTC | same |

The same shape applies to the webhook envelope's `reservation`
object (see `webhook_signature.md`).

---

## Covers source classification

`not_applicable`

Cite vendor doc: <https://libroreserve.github.io/api-documentation/#operation/listReservations>

The COVERS card on Shift is the POS adapter's job. The reservation
adapter contributes the "In the Books" aggregate count, not covers.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `reservation_at` | ISO 8601 | restaurant-local wall-clock, no tz hint | `vendor_timestamp_policy['libro'] = asLocationLocal` |
| `updated_at` | ISO 8601 | same | same |
| `created_at` / `confirmed_at` / `arrived_at` / `seated_at` / `completed_at` / `canceled_at` | ISO 8601 | same | same |
| `business_date` (computed) | DATE | location-local via IANA | `IanaTimezoneConverter.toBusinessDate` |

The adapter declares the policy at
`lib/services/integration/vendor_timestamp_policy.dart` (`'libro'`
entry, `asLocationLocal`). Adapters that cannot disambiguate refuse
the timestamp at parse time; Libro's policy is declared, so the
adapter projects via the IANA converter.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `8R.LB.live.sandbox` slice verifies these first.

- **Status `pending` vs `expected`**: vendor docs use `pending` in
  examples but the field schema lists both. Adapter normalizes both
  to `CanonicalReservationStatus.expected`. Verify on live which
  string the sandbox emits.
- **Status `cancelled` (UK spelling)**: vendor doc uses `canceled`
  (US) but some legacy venues emit `cancelled`. Adapter treats both
  identically. Verify against sandbox.
- **`completed` vs `left`**: docs treat the two as equivalent for
  the reservation lifecycle. Adapter normalizes both to
  `CanonicalReservationStatus.completed`.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `reservations[].notes` — operator free-text, may include guest
  PII the operator typed in. Privacy / scope; F&F is aggregate-first
  at launch.
- `reservations[].guest_*` (`guest_first_name`, `guest_last_name`,
  `guest_email`, `guest_phone`) — guest PII; F&F is aggregate-first
  per `phase_8R` plan.
- `reservations[].card_holder_*` — payment-card metadata; PCI
  scope, F&F is not a payment processor.
