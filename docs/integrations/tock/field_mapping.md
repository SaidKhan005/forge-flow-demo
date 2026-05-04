# Tock — Field Mapping

**Vendor ID**: `tock`
**Source documentation**:
<https://api.exploretock.com/docs/latest/reservation.html>
**Retrieval date**: 2026-05-04

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates is rowed below and is also captured in the
`documentedPerTockReservation20260504` constant in
[lib/integrations/reservation/tock_reservation_adapter.dart](../../../lib/integrations/reservation/tock_reservation_adapter.dart).
The fixture mirror lives at
[test/integrations/reservation/fixtures/tock_reservations_fixture.dart](../../../test/integrations/reservation/fixtures/tock_reservations_fixture.dart).

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `id` | string (Tock reservation id; `res_…` prefix) | `vendor_entity_id` | direct | <https://api.exploretock.com/docs/latest/reservation.html> |
| `lastUpdatedTimestamp` | ISO 8601 UTC (with `Z`) | `vendor_modified_at` | direct UTC | <https://api.exploretock.com/docs/latest/reservation.html> |
| `serviceDateTimestamp` | ISO 8601 UTC (with `Z`) | `reservation_at` | direct UTC | <https://api.exploretock.com/docs/latest/reservation.html> |
| `partySize` | int | `party_size` | direct | <https://api.exploretock.com/docs/latest/reservation.html> |
| `status` | enum (one of `EXPECTED` / `ARRIVED` / `SEATED` / `LEFT` / `NO_SHOW` / `CANCELLED`) | `status` | normalize to lower-snake-case (`expected` / `arrived` / `seated` / `left` / `no_show` / `canceled`); unknown vendor strings → `unknown` | <https://api.exploretock.com/docs/latest/reservation.html> |
| `status` (raw) | string | `vendor_status_raw` | direct (preserved for audit trace) | <https://api.exploretock.com/docs/latest/reservation.html> |
| `createdTimestamp` | ISO 8601 UTC (with `Z`) | `created_timestamp` | direct UTC | <https://api.exploretock.com/docs/latest/reservation.html> |

The `documentedPerTockReservation20260504` constant in the adapter
file is the machine-readable mirror of this table. Diff-on-merge keeps
the two in sync; CI lint will flag drift.

---

## Covers source classification

`not_applicable`

Tock is a reservation vendor; it does not emit a "covers" field in the
POS sense. The reservation analog is `partySize`, which the adapter
captures as `party_size`. The forecast-fallback degrade path that POS
adapters use (Square / Clover) does NOT apply here; the reservation
canonical fact carries `party_size` first-class.

`VendorCapabilityProfile.coversFieldExposed = false` because the field
is genuinely not present on the source. Picker chrome / dashboard
chrome reads this flag alongside `category = reservation` and renders
the appropriate metric — see
[docs/contracts/metric_card_honesty_contract.md](../../contracts/metric_card_honesty_contract.md).

Cite vendor doc:
<https://api.exploretock.com/docs/latest/reservation.html>

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `serviceDateTimestamp` → `reservation_at` | ISO 8601 with `Z` | UTC | `vendorTimestampPolicy['tock'].asUtc` (registry entry deferred to `8R.TC.live.sandbox` slice) |
| `lastUpdatedTimestamp` → `vendor_modified_at` | ISO 8601 with `Z` | UTC | same |
| `createdTimestamp` → `created_timestamp` | ISO 8601 with `Z` | UTC | same |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` |

Tock's public reservation reference documents each timestamp with a
trailing `Z` (UTC). Scenario E (ambiguous-timestamp policy) is not
documented to apply at the wire level for the consumed fields, but
the adapter still declares `timestampPolicyDocId: 'tock'` so the
framework's refuse-by-default protection recognizes Tock as a
registered vendor.

> **Engineering-vs-framework boundary.** The
> `vendor_timestamp_policy.dart` registry currently lacks a `'tock'`
> entry. Adding the entry is a registry-wiring change to
> `lib/services/integration/*` (out of scope for this slice — see
> "Files to leave alone" in the slice prompt). The
> `8R.TC.live.sandbox` slice will land the registry entry alongside
> the live verification.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `*.live.sandbox` slice will verify these first.

- **Per-status transition timestamps** — **Ambiguity: yes — verify in
  `8R.TC.live.sandbox`.** Tock's public reservation reference lists
  three timestamps on the reservation resource:
  `createdTimestamp`, `lastUpdatedTimestamp`, `serviceDateTimestamp`.
  Per-status transition timestamps (`arrived_at`, `seated_at`,
  `left_at`, `canceled_at`) are NOT documented on the public
  reference. The adapter does NOT assume their presence — the
  canonical fact captures only the documented three timestamps. The
  `8R.TC.live.sandbox` slice will diff observed sandbox payloads and
  adopt any per-transition timestamps present as a **bounded fix**
  (not a slice rebuild). The `documentedPerTockReservation20260504`
  constant carries `per_transition_timestamps_documented: false` so
  the diff is mechanical.
- **Status vocabulary edge cases** — Tock's public reference
  enumerates `EXPECTED`, `ARRIVED`, `SEATED`, `LEFT`, `NO_SHOW`,
  `CANCELLED`. The adapter normalizes lookup via
  `.trim().toUpperCase()` so case / whitespace differences from
  Tock's payload do not silently miss; an unknown vendor string is
  mapped to canonical `unknown` (NOT silently re-mapped to a known
  value). The `*.live.sandbox` slice asserts every observed status
  string maps to a known canonical value or surfaces the gap.
- **API-key auth header shape** — Tock's public reference does not
  document the exact `Authorization` header shape (bearer vs
  custom). The adapter treats it as bearer-style; the
  `*.live.sandbox` slice verifies the observed shape matches.
- **`reservation.updated` payload completeness** — The adapter
  assumes Tock webhook payloads carry the full reservation shape
  (no id-only events on the webhook path). The `*.live.sandbox`
  slice asserts this; if Tock emits id-only events, the adapter
  adds the round-trip to `fetchReservationById` as a bounded fix
  (the transport already exposes that method for the polling
  resume path).

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `guest.firstName` / `guest.lastName` / `guest.email` /
  `guest.phone` — privacy. Operator T&Cs at Phase 9.8 do not
  authorize PII collection for Tock-fed canonical facts.
- `paymentInstrument` — PCI scope; F&F is not a payment processor.
  Tock prepayment data does not flow into canonical reservation
  facts.
- Per-guest dietary / preference notes — operator-scoped sensitive
  data; aggregate-first reservation surface only for V1.
