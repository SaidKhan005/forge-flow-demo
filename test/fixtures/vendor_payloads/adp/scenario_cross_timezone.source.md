# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed`
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
- Notes: cross-timezone scenario for a Vancouver-local location
  with ADP's UTC wire shape. The shift opens 19:30 PDT on
  2026-05-04 and closes 01:00 PDT on 2026-05-05 — calendar-day
  rollover happens on the wire shape (UTC) but the local
  business_date stays `2026-05-04` for the closing-shift portion
  (per `docs/contracts/phase_7_55_time_boundary_contract.md`,
  business_date is anchored to the location's
  `restaurant_local_tz`, not the wire-shape timezone). The Phase 2
  harness MUST verify the read layer's business_date deriver
  resolves to America/Vancouver and not to UTC. Partner-only
  sourcing.
