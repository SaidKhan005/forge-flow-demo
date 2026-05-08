# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Cross-timezone resolver fixture. Combines:
    * a Vancouver-local `business_date` boundary (the bound F&F location
      is in `America/Vancouver`, PDT = -07:00 in mid-April), with
    * a UTC timestamp that decodes to the prior local calendar date in
      Toronto and the prior local calendar date in Vancouver — but at
      different local clock times.

  `start_time = 2026-04-15T03:00Z`:
    * Toronto (EDT, -04:00) local → `2026-04-14T23:00:00` (April 14)
    * Vancouver (PDT, -07:00) local → `2026-04-14T20:00:00` (April 14)

  Both zones agree on `business_date = 2026-04-14` for this `start_time`.
  The pressure on the resolver is to choose the LOCATION-bound zone
  (`America/Vancouver`) over the COMPANY-bound zone the operator's
  Agendrix portal advertises (`America/Toronto`) — the operator-wide
  grant covers both zones (per `oauth_shape.md` `grantScope =
  operatorWide`), but business-date is location-scoped per the
  Phase 7.55 time-boundary contract.

  Phase 2 adapter harness asserts:
  `business_date == 2026-04-14`, computed via
  `iana_timezone_converter.toBusinessDate(shift_start, 'America/Vancouver')`,
  NOT 2026-04-15 (which the naive UTC-floor would emit). The harness
  also pins `connector_location_binding.iana_timezone =
  'America/Vancouver'` for the location row so the resolver picks up
  the right zone.
