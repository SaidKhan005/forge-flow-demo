# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed` (Team Time Cards v2 — Pay Data extension)
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
  with a `pay_data` extension block; analogous shape to the WFN /
  WFM `payDataInput` payload referenced in the developer-portal
  catalog
- Notes: WFM-shape worker (`workAssignment.jobTitle` instead of
  `worker.position.position_title`) — exercises the canonicalizer's
  WFM fall-back per `docs/integrations/adp/field_mapping.md`. The
  `pay_data.*` block is documented for live-diff visibility but is
  NOT consumed by V1 — the doc pack lists `worker.compensation.*`
  and pay-rate fields under "Forbidden fields" and the slice writes
  `wage_source = vendor` only. Partner-only sourcing.
