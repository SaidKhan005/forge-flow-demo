# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/labour
- Notes: Push Operations developer site is partner-gated; the public
  landing page at developers.pushoperations.com documents the v1 REST
  surface with Bearer-token auth and the `labour` / `shifts` resources.
  Field shape mirrors the documented mapping in
  `docs/integrations/push_operations/api_consumed.md` and
  `docs/integrations/push_operations/field_mapping.md` (retrieved
  2026-05-04 by the engineering slice). The labour endpoint is
  date-range paginated with a 2-day max window per
  `api_consumed.md`; the page+limit envelope is the documented
  pagination shape on the standard list endpoints (the `total` count
  appears alongside `page` + `limit` in published responses). Sourcing
  gap: the vendor portal is partner-only, so the exact response
  envelope is reconstructed from the public landing page + the
  per-vendor doc pack already retrieved on 2026-05-04 + the existing
  adapter test fixture
  `test/integrations/labor/fixtures/push_operations_punches_fixture.dart`
  which captures `documented_per_push_operations_v1`. Phase 5 should
  flag this for partner-portal escalation when sandbox credentials
  land.
