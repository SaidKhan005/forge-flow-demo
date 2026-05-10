# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Documented `time_entries[]` row shape for a completed punch.
  Field paths mirror `documented_per_agendrix_v2` at
  `test/integrations/labor/fixtures/agendrix_punches_fixture.dart` and
  `docs/integrations/agendrix/field_mapping.md`. The `next_cursor` envelope
  field reflects the documented cursor pagination ("server-issued cursor
  token; empty cursor = end of listing" per `api_consumed.md`).
  Response is poll-only — Agendrix does not document a webhook delivery
  surface as of the 2026-05-04 retrieval.
