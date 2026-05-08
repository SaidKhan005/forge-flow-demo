# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus, eventType `aloha.check.modified`.
- Notes: DST edge fixture. Aloha emits UTC with trailing Z, so the
  vendor body shape itself does not change at DST. The edge is
  entirely in the adapter's `iana_timezone_converter.toBusinessDate`
  step. The straddling pair (open before, close after the local
  gap) catches off-by-one business-date errors that otherwise hide
  for 363 days a year.
- Per `phase_7_55_time_boundary_contract.md`, restaurant-local
  timing wins; business date is the anchor; closed truth is not
  rewritten by later cycles.
