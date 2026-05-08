# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed`
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
- Notes: DST spring-forward scenario covering the 2026-03-08
  America/Toronto transition (02:00 EST → 03:00 EDT). Because
  ADP's documented timestamp shape is UTC ISO-8601 with explicit
  `Z` per `docs/integrations/adp/field_mapping.md`, the local skip
  window does NOT translate into an ambiguous wall-clock
  representation — every UTC moment is unique. The Phase 2 harness
  MUST verify the canonical fact stores the UTC value verbatim and
  the read layer's business-date derivation
  (`docs/contracts/phase_7_55_time_boundary_contract.md`) puts the
  shift on the local business date the operator expects (here:
  business_date `2026-03-07` if the location closes after the
  shift, or `2026-03-08` if the location splits at 04:00 local).
  Partner-only sourcing — see
  `docs/integrations/adp/partnership_status.md`.
