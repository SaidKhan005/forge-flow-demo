# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/shifts (published shifts surface)
- Notes: Documented `shifts[]` row shape for a published shift. Out of
  scope for V1 ingestion per `api_consumed.md` ("Additional surfaces —
  published shifts, leave, availability — land as bounded follow-ups").
  Captured here so Phase 2 adapter harness can prove the framework
  ignores non-consumed event kinds without crashing. Field paths mirror
  the time-entry shape (vendor reuses `position.name`, `start_time`,
  `end_time`, `updated_at`) per the developer portal docs.
