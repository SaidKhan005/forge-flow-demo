# SevenRooms — Field Mapping

**Vendor ID**: `sevenrooms`
**Source documentation**:
- Reservations endpoint shape (Airship guide):
  <https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms>
- Partner API portal (account-rep gated):
  <https://api-docs.sevenrooms.com/>

**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field
`SevenRoomsReservationAdapter` populates has a row here; every row
here is mirrored in
`test/integrations/reservation/fixtures/sevenrooms_reservations_fixture.dart`
under the `documented_per_sevenrooms_v2_2_2026_05` constant. The
field accessors live in `SevenRoomsReservationFields` inside
`lib/integrations/reservation/sevenrooms_reservation_adapter.dart`.

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `reservations[].id` | string | `vendor_entity_id` | direct | <https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms> |
| `reservations[].arrival_time` | ISO-8601 with timezone offset | `reservation_at` | parse → UTC instant | <https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms> |
| `reservations[].party_size` | int | `party_size` | direct | <https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms> |
| `reservations[].status` | enum (`BOOKED` / `ARRIVED` / `SEATED` / `COMPLETED` / `CANCELLED` / `NO_SHOW`) | `status` | enum-map → `SevenRoomsCanonicalStatus` | <https://api-docs.sevenrooms.com/> |
| `reservations[].last_updated_at` | ISO-8601 UTC | `vendor_modified_at` | direct UTC instant; falls back to `arrival_time` if absent | <https://api-docs.sevenrooms.com/> |
| `reservations[].arrived_time` | ISO-8601 (optional) | `status_transitions.arrived` | parse → UTC instant | <https://api-docs.sevenrooms.com/> |
| `reservations[].seated_time` | ISO-8601 (optional) | `status_transitions.seated` | parse → UTC instant | <https://api-docs.sevenrooms.com/> |
| `reservations[].departed_time` | ISO-8601 (optional) | `status_transitions.departed` | parse → UTC instant | <https://api-docs.sevenrooms.com/> |
| `reservations[].cancellation_time` | ISO-8601 (optional) | `status_transitions.cancelled` | parse → UTC instant | <https://api-docs.sevenrooms.com/> |

Every row above gets a row in
`test/integrations/reservation/fixtures/sevenrooms_reservations_fixture.dart`'s
`documented_per_sevenrooms_v2_2_2026_05` constant. The constant name
embeds the API version so a vendor shape change appears as a renamed
constant + diff in git history.

---

## Covers source classification

`not_applicable`.

Reservations carry `party_size` (canonical reservation field), not
covers (canonical POS field). The capability profile sets
`coversFieldExposed: false` — operator chrome (per
`docs/contracts/metric_card_honesty_contract.md`) does NOT show
covers chrome from a reservation-only adapter.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `arrival_time` | ISO 8601 with offset | venue-local with offset | `vendor_timestamp_policy.sevenrooms.asUtc` (parse offset → UTC) |
| `last_updated_at` | ISO 8601 UTC | UTC | `vendor_timestamp_policy.sevenrooms.asUtc` |
| `arrived_time` / `seated_time` / `departed_time` / `cancellation_time` | ISO 8601 (optional) | venue-local with offset | parse → UTC |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

The framework's
`lib/services/integration/vendor_timestamp_policy.dart` declares
`AmbiguousTimestampConvention.asUtc` for SevenRooms, so an ambiguous
parse never silently coerces to location-local.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `8R.SR.live.sandbox` slice will verify these first.

- **`status` enum coverage**: documented values are `BOOKED`,
  `ARRIVED`, `SEATED`, `COMPLETED`, `CANCELLED`, `NO_SHOW`. The
  adapter rejects (returns null + drops at boundary) any unknown
  value. Verify on live: enumerate every status string the sandbox
  emits across a sample week of reservations.
- **`arrival_time` timezone shape**: documented as ISO 8601 with
  offset. Verify on live: confirm offset is venue-local (matches the
  operator's IANA timezone), not UTC.
- **`last_updated_at` source**: documented as the partner-API cursor
  for `?updated_since=`. Falls back to `arrival_time` when absent on
  legacy reservations.
- **Per-status transition timestamps presence**: not enumerated in
  the publicly fetched docs. The adapter parses them when present and
  stores them in `status_transitions`; verify on live which statuses
  carry which timestamps.
- **`party_size` rounding**: documented as int; the adapter rounds
  any numeric value defensively. Verify no fractional party sizes
  appear on live.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `reservations[].guest.first_name` / `last_name` / `email` / `phone`
  — guest identity / contact details. Privacy: see operator T&Cs at
  Phase 9.8. The adapter does not request guest profile expansion.
- `reservations[].client_id` and the `/2_2/clients/{client_id}`
  endpoint — guest profile detail; refused at the adapter boundary
  per privacy. F&F at V1 is aggregate-first per
  `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md`
  Non-Negotiables.
- `reservations[].notes` / `internal_notes` — operator-private notes
  may carry guest PII; out of V1 scope.
- `reservations[].payment.*` — PCI scope; F&F is not a payment
  processor.
