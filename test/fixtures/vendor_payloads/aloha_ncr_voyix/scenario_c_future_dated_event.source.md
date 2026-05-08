# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus, eventType `aloha.check.modified`.
- Notes: Adversarial scenario C. Mirror of the `p2-check-future`
  entry already in
  `test/integrations/pos/fixtures/aloha_ncr_voyix_orders_fixture.dart`
  (`alohaNcrVoyixBackfillPage2Checks`). Body shape is canonical
  except every timestamp is 73 years out. Sanity hook (timestamp
  guard) drops the event and writes a `sanity_log` row before the
  sink writes any canonical fact. Phase 2 assertion: sanity_log
  count increments by 1; canonical fact count does not change.
