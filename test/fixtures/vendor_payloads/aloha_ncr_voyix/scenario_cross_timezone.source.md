# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus, eventType `aloha.check.modified`.
- Notes: Cross-timezone fixture. The vendor body itself is the
  documented Aloha shape with UTC timestamps. The edge lives in
  whether the resolver consults the location IANA timezone (per
  `phase_7_55_time_boundary_contract.md` and the `business_date`
  guardrail) or accidentally uses the UTC date. A naive
  `instant.toIso8601String().substring(0, 10)` resolver would
  pick `2026-05-05` here, which happens to be correct for Toronto
  but wrong if the same instant arrived for a Pacific site —
  hence the explicit `_location_iana_timezone` marker.
- Pair `scenario_cross_timezone.json` with the DST fixture for a
  full coverage of the resolver's decision matrix.
