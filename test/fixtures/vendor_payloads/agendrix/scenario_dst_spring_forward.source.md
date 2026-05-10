# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: DST spring-forward edge for an Agendrix-bound location operating
  in `America/Toronto` (the Quebec/Ontario operator base — Agendrix is
  Montreal-headquartered and the per-vendor adapter does NFC normalization
  for French accents per `agendrix_labor_adapter.dart`
  `_normalizeToNfc`).

  On 2026-03-08 the local clock skips from 01:59:59 to 03:00:00;
  the local window 02:00:00–02:59:59 does not exist. Vendor sends UTC
  (explicit `Z` per `agendrix.asUtc` policy) so the over-the-wire
  payload itself is unambiguous. The pressure point is the
  business-date computation:
  `iana_timezone_converter.toBusinessDate(shift_start, 'America/Toronto')`.

  - First row: `start_time = 2026-03-08T06:00Z` resolves to
    01:00 EST (-05:00) local — pre-DST. `business_date = 2026-03-08`.
  - Second row: `start_time = 2026-03-08T13:00Z` resolves to
    09:00 EDT (-04:00) local — post-DST. `business_date = 2026-03-08`.

  Both rows must persist with `business_date = 2026-03-08` (operator
  business day is location-local; the time-zone offset rotated mid-day
  but the business-date anchor did not). Phase 2 adapter harness
  asserts that the `iana_timezone_converter` produces the same
  business-date for both rows despite straddling the offset rotation,
  per `docs/contracts/phase_7_55_time_boundary_contract.md`.
