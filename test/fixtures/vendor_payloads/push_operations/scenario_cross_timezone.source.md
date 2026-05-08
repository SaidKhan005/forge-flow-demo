# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts (multi-location operator;
  one Push Operations company spanning two F&F locations on
  different timezones)
- Notes: Push Operations bearer-token grant scope is
  `operatorWide` per `oauth_shape.md` and `field_mapping.md` —
  one bearer token covers an operator's entire Push Operations
  company across locations. The pressure test simulates a
  multi-location operator (Toronto + Vancouver) where the same
  UTC `start_at = 2026-05-02T22:00:00Z`:

  - In `America/Toronto`: 18:00 local on 2026-05-02 (business
    date 2026-05-02 with 4 AM cutoff).
  - In `America/Vancouver`: 15:00 local on 2026-05-02 (business
    date 2026-05-02 with 4 AM cutoff).

  And `end_at = 2026-05-03T06:00:00Z`:

  - In `America/Toronto`: 02:00 local on 2026-05-03 — STILL on
    business date 2026-05-02 because of the 4 AM cutoff.
  - In `America/Vancouver`: 23:00 local on 2026-05-02 — also on
    business date 2026-05-02 (no overflow).

  Both shifts therefore compute `business_date = 2026-05-02` but
  via different IANA conversions. The Phase 2A harness asserts:
  1. The resolver picks the **location's** timezone, not the
     operator's HQ timezone or device clock.
  2. The two canonical fact rows have identical `business_date`
     but the operator-scoped Postgres fact rows differ on
     `(operator_id, location_id)` per the RLS-ready schema (per
     `hardening_rls_and_repository_pattern_contract.md`).
  3. The `_pressure_test_location_hint` field is a harness-only
     annotation (the real Push response does not carry a location
     hint — F&F binds shifts to F&F locations via the
     `OperatorScopedRepository` write path; the test driver
     supplies the location id).
