# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed`
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
- Notes: future-dated scenario for binding C. Mirrors the
  `adpFutureDatedTimeEvent` constant in
  `test/integrations/labor/fixtures/adp_punches_fixture.dart` —
  reads ~60 days into the future relative to `now_for_test`. The
  framework's vendor-timestamp sanity hook fires (rule:
  `opened_in_future`), the adapter calls `command.sanityHook` which
  returns false, the row is dropped, and a `sanity_log` row is
  written. No canonical fact persisted. Partner-only sourcing.
