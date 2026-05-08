# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed` (Team Time Cards v2 / Time Events v2)
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
  (action = `modified`); admin-side correction to the previously
  submitted/approved punch
- Notes: same `time_event.id` as the prior two events, with
  `exit_date_time` adjusted earlier (manager edit). The `modification`
  block is documented for live-diff visibility; the canonicalizer
  ignores it. The adapter writes a new canonical fact row keyed on
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  per `docs/contracts/vendor_adapter_slice_contract.md`, so the
  modified version replaces the prior projection without losing
  history. Partner-only sourcing.
