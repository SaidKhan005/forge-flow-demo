# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed` (Team Time Cards v2 / Time Events v2)
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`;
  smallest legal envelope the canonicalizer accepts
- Notes: bare-minimum envelope — strips event metadata (`event_id`,
  `event_name`, `event_action`, `breaks`, `status`) so the slice can
  prove the canonicalizer reads ONLY the documented six rows in
  `documentedPerAdpV1FieldMapping` and nothing else. Every field
  present here MUST be present for the canonicalizer to write a
  fact; remove any one of them and the canonicalizer returns null.
  Partner-only sourcing — see
  `docs/integrations/adp/partnership_status.md`.
