# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`

## Notes

- 2026-03-08 is the US spring-forward Sunday; in
  `America/New_York` local clocks jump from `02:00 EST` (UTC-5)
  directly to `03:00 EDT` (UTC-4). Local times in the
  `[02:00, 03:00)` interval do not exist.
- Toast normalizes every Order timestamp to UTC with the trailing
  `Z`. `openedDate: 2026-03-08T07:30:00Z` is unambiguous on the
  wire.
- The trip-wire is the framework's `iana_timezone_converter`:
  `07:30Z` converts to `02:30 local` in the gap interval. The
  IANA library's documented behavior is to round forward to
  `03:30 EDT`. The framework's `toBusinessDate` MUST honor the
  rounded-forward time when computing the business_date bucket.
- `_test_location_iana` and `_test_local_intent` are test-side
  metadata for the Phase 2 harness; production payloads do not
  carry them.
- `1772963400` Unix epoch ≈ `2026-03-08T08:10:00Z` (close to the
  modifiedDate; webhook delivery latency is normal).

## Sourcing fallback

Reconstructed from `field_mapping.md#timestamp-shapes` (Toast UTC
convention) + `phase_8_live_pos_labor_adapter_plan.md` Scenario C
(DST fall-back ambiguity, the inverse of this scenario).

## Expected adapter behavior

- Signature verifies; sanity hook passes.
- `_canonicalize` produces canonical fact with UTC timestamps.
- `business_date` denormalization (sink-side) computes
  `2026-03-08` for the location's timezone — the gap-hour local
  rounding does NOT push the order into 2026-03-09.
- `upsertOrderFact` writes one row.

## What this scenario asserts

- IANA-backed conversion handles the spring-forward gap
  deterministically. A naive offset library that assumes UTC-5 or
  UTC-4 statically (without consulting IANA's transition table)
  would either error or compute the wrong `business_date`.
- The vendor's UTC convention removes wire-level ambiguity, but
  the location-local business_date computation still requires
  IANA — Scenario C / spring-forward is binding per the Phase 8
  acceptance criteria.
