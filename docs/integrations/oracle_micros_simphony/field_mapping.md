# Oracle MICROS Simphony — Field Mapping

**Vendor ID**: `oracle_micros_simphony`
**Source documentation**: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/>
**Retrieval date**: 2026-05-05

This file is the **review contract** Codex grades the adapter's
field-mapping code against. Every canonical fact field the adapter
populates has a row here; every row here is mirrored in the fixture
constant `documented_per_oracle_micros_simphony_v2` at
`test/integrations/pos/fixtures/oracle_micros_simphony_checks_fixture.dart`.

The 2026-05-05 falsehood corrections in
`docs/contracts/integration_spine_architecture_contract.md` lock the
covers field path at `items[].header.guestCount` (Gen2). The Gen1
`guestChecks[].numOfGst` and the earlier Wave B guess
`numberOfGuests` are both wrong and must not be reintroduced (see
`8.spine-bridge.1.OR` field-path audit).

---

## Source field → canonical field

| Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
|---|---|---|---|---|
| `items[].header.guestCount` | int | `covers` | direct | <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html> |
| `items[].header.opnUTC` | ISO 8601 UTC (with explicit `Z`) | `opened_at` | direct UTC | <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html> |
| `items[].header.cmplOrClsdUTC` | ISO 8601 UTC (with explicit `Z`) | `closed_at` | direct UTC | <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html> |
| `items[].header.subTtlCents` | int (cents) | `actual_sales` | cents → dollars (`/ 100.0`) | <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html> |
| `items[].header.chkNum` | int (stringified at canonical write) | `vendor_entity_id` | direct | <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html> |
| `items[].header.lastUpdatedUTC` | ISO 8601 UTC (with explicit `Z`) | `vendor_modified_at` | direct UTC | <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html> |

Every row above also appears as an entry in
`documented_per_oracle_micros_simphony_v2` (fixture). Adapter source:
`lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart`
(`_mapGuestCheckToCanonical`, which reads each record's `header`
sub-object).

---

## Covers source classification

`direct`

Cite vendor doc:
<https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html>
(`items[].header.guestCount` returns the documented number of guests
on a check in the STSGen2 schema.)

The adapter records `covers_source = 'direct'` on every canonical fact
write — see the constant in `_mapGuestCheckToCanonical`. Operator
chrome reads this as the live data path; the dashboard pill drops the
"covers via forecast" line when `posSourceVendorId == oracle_micros_simphony`
and `coversFieldExposed == true`.

---

## Timestamp shapes

| Field | Format | Timezone | Policy |
|---|---|---|---|
| `items[].header.opnUTC` | ISO 8601 | UTC (explicit `Z`) | `oracle_micros_simphony.asUtc` (declared as `timestampPolicyDocId` on the capability profile; mirrored in `vendor_timestamp_policy.dart` when `8.0.lifecycle` registers it). |
| `items[].header.cmplOrClsdUTC` | ISO 8601 | UTC (explicit `Z`) | `oracle_micros_simphony.asUtc` |
| `items[].header.lastUpdatedUTC` | ISO 8601 | UTC (explicit `Z`) | `oracle_micros_simphony.asUtc` |
| `business_date` (computed) | DATE | location-local via IANA | `iana_timezone_converter.toBusinessDate` from the canonical `closed_at` projected from `cmplOrClsdUTC`. |

The adapter parses every documented timestamp via
`DateTime.parse(...).toUtc()`. Ambiguous shapes (no `Z`, no offset)
are refused per the timestamp policy — Scenario E from the binding A-F
test set (`docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`).
The `8.OR.live.sandbox` slice verifies that production guest checks
always carry the explicit-Z form.

---

## Ambiguity calls

Per-field decisions where the doc was unclear and the adapter made a
choice. The `8.OR.live.sandbox` slice will verify these first.

- **`items[].header.subTtlCents`**: Simphony documents the check
  sub-total in `header.subTtl` as a decimal value; the adapter assumes
  a sister field `subTtlCents` returns the same value as a cents
  integer to avoid floating-point parsing drift. Verify on sandbox by
  pulling a small sample and comparing both fields against a hand-
  computed cents total. If the cents sister is not exposed, the live
  slice switches the canonical transform to `subTtl * 100` (cast int)
  and bumps the fixture constant.
- **`items[].header.chkNum` uniqueness across locations**: Simphony
  scopes `chkNum` to the location, not the organization. The canonical
  UNIQUE keys on `(vendor_id, operator_id, vendor_entity_id,
  vendor_modified_at)` AND the F&F `location_id` is bound through the
  per-location grant scope, so cross-location collisions cannot reach
  the canonical table. Verify on the live slice with a multi-location
  partner test fixture.
- **Polling cadence**: Simphony does not publish a recommended poll
  cadence. The adapter assumes 5 minutes per location at default;
  partner activation may raise the soft cap. The `8.OR.live.sandbox`
  slice confirms 5 min does not trip the documented soft cap.

---

## Forbidden fields

Vendor fields the adapter intentionally ignores:

- `items[].header.guestInfo` (any sub-field carrying guest name /
  loyalty id / contact info) — privacy. See operator T&Cs at
  Phase 9.8.
- `items[].payments[].cardholder_name` /
  `items[].payments[].card_last4` — PCI scope; F&F is not a
  payment processor.
- `items[].header.tipAmt` (per-cardholder) — aggregate-first;
  per-employee tip attribution is the operator's payroll system's
  job.
- `items[].header.employeeId` — out of scope for POS adapter; labor
  attribution lives in the labor-adapter family (Phase 8.S).
