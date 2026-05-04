# OpenTable — Field Mapping

**Vendor ID**: `opentable`
**Source documentation**: <https://restaurant.opentable.com/products/opentable-platform/>
(operator-facing only — partner doc gated; see `api_consumed.md`)
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. EVERY row below is an **assumption**:
ambiguity is resolved against the industry-standard reservation
envelope (the field shape shared by every reservation vendor F&F has
examined), not against an observed OpenTable Partner API response.
The `8R.OT.live.sandbox` slice diffs each row against the first
observed sandbox payload and cuts bounded fixes for any drift.

The constants the adapter binds to live in:
- `lib/integrations/reservation/opentable_reservation_adapter.dart`
  → `documentedPerOpentableV1FieldMapping`
- `test/integrations/reservation/fixtures/opentable_reservations_fixture.dart`
  → `documentedPerOpentableV1FieldMappingFixture`

The two constants are kept in sync by the `field-mapping constant
mirrors fixture` test.

---

## Source field → canonical field

| Vendor field path (assumed) | Type / shape | Canonical field | Transform | Doc URL | Ambiguity |
|---|---|---|---|---|---|
| `reservation.id` | string | `vendor_entity_id` | direct | <https://restaurant.opentable.com/products/opentable-platform/> | yes — verify in `*.live.sandbox` |
| `reservation.reserved_at` | ISO 8601 UTC | `reservation_at` | direct UTC | <https://restaurant.opentable.com/products/opentable-platform/> | yes — verify in `*.live.sandbox` |
| `reservation.party_size` | int | `party_size` | direct | <https://restaurant.opentable.com/products/opentable-platform/> | yes — verify in `*.live.sandbox` |
| `reservation.status` | enum string | `status` | normalize to app `ReservationStatus` (lower-case) | <https://restaurant.opentable.com/products/opentable-platform/> | yes — verify in `*.live.sandbox` |
| `reservation.modified_at` | ISO 8601 UTC | `vendor_modified_at` | direct UTC | <https://restaurant.opentable.com/products/opentable-platform/> | yes — verify in `*.live.sandbox` |
| `reservation.restaurant_id` | string-or-int (`rid`) | binding `restaurant_id` | to_string | <https://restaurant.opentable.com/products/opentable-platform/> | yes — verify in `*.live.sandbox` |

---

## Covers source classification

`not_applicable`

OpenTable is a reservation system; it does not expose a covers field
suitable for the F&F COVERS card. Covers come from the POS adapter
on the same location. The adapter records `coversFieldExposed: false`
on `VendorCapabilityProfile`.

Cite vendor doc:
<https://restaurant.opentable.com/products/opentable-platform/>

---

## Timestamp shapes

| Field | Format (assumed) | Timezone (assumed) | Policy |
|---|---|---|---|
| `reservation.reserved_at` | ISO 8601 with explicit `Z` | UTC | `vendor_timestamp_policy.opentable.refuse` until `*.live.sandbox` confirms; reads convert to UTC instant |
| `reservation.modified_at` | ISO 8601 with explicit `Z` | UTC | as above |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

OpenTable's published reservation envelope is assumed to emit ISO-8601
UTC instants with explicit `Z`. The adapter binds
`AmbiguousTimestampConvention.refuse` so that ambiguous shapes (no
`Z`, no offset) are dropped at the parse boundary instead of silently
treated as UTC — the bug Scenario E is designed to catch. The
`8R.OT.live.sandbox` slice will re-bind to `asUtc` once observed
sandbox payloads confirm the shape.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live.sandbox` slice will verify these first.

- **`reservation.id`**: assumed string per industry standard; some
  vendors expose integer ids. Adapter `to_string` coerces either.
  Verify exact type in `*.live.sandbox`.
- **`reservation.reserved_at`**: assumed UTC ISO-8601 with `Z`. Some
  reservation systems emit local wall-clock (Libro). Verify in
  `*.live.sandbox`; if local, switch the policy to
  `asLocationLocal`.
- **`reservation.party_size`**: assumed `party_size`. Some vendors
  expose it as `covers` or `guests`. Verify exact key.
- **`reservation.status`**: assumed lower-case enum drawn from
  `{booked, seated, completed, no_show, cancelled}`. The exact
  vocabulary is partnership-gated; the canonicalizer lower-cases
  whatever string lands and the app surface maps it once observed
  vendor strings are in hand.
- **`reservation.modified_at`**: assumed UTC ISO-8601 with `Z`.
  When absent, the canonicalizer falls back to `reservation.reserved_at`
  so the watermark advances. Verify presence + format.
- **`reservation.restaurant_id` (`rid`)**: assumed string-or-int.
  Used for the binding cross-check on inbound webhooks.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores per the F&F privacy
posture (operator's T&Cs at Phase 9.8 — guest detail is
out-of-scope at launch):

- `reservation.guest.name` — guest name is not persisted.
- `reservation.guest.email` — guest email is not persisted.
- `reservation.guest.phone` — guest phone is not persisted.
- `reservation.notes`, `reservation.special_requests` — free-text
  guest detail; not persisted at launch.
- Any payment / card-on-file field — out of PCI scope.
- Any VIP / dietary tag — deferred to later auth-aware Barrio work,
  not the launch reservation surface.

The fixture's sample reservation
(`openTableSampleReservation` in
`test/integrations/reservation/fixtures/opentable_reservations_fixture.dart`)
includes the forbidden `guest` block so the canonicalizer's
"persists only allowed fields" behavior can be asserted against an
explicit positive sample.
