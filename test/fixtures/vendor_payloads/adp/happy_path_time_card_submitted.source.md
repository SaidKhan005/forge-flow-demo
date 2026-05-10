# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed` (Team Time Cards v2 / Time Events v2)
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
  (action = `submitted`); same time-event row is also returned by
  `GET /time/v2/workers/{associate_oid}/team-time-cards`
- Notes: shape mirrors the assumed envelope captured in
  `lib/integrations/labor/adp_labor_adapter.dart`
  (`documentedPerAdpV1FieldMapping`) and the test fixture
  `test/integrations/labor/fixtures/adp_punches_fixture.dart`
  (`adpSampleTimeEvent`). Every assumption is flagged
  `verify_in_live_sandbox: true` per the doc pack — partner-only
  sourcing means the partner doc pins the exact fields after the
  ADP Marketplace Developer Participation Agreement clears (see
  `docs/integrations/adp/partnership_status.md`).
