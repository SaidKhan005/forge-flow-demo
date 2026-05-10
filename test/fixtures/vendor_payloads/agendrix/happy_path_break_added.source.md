# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Documented optional `breaks[]` nested array on a `time_entries[]`
  row. Per `field_mapping.md`, V1 adapter does not yet consume the
  `breaks[]` shape (out of scope at slice ship); fixture exists so the
  Phase 2 adapter harness can prove unknown-field tolerance — the
  adapter must NOT crash when the vendor returns the documented optional
  field but should emit a single canonical fact (per the documented
  field-mapping rows) without any break-derived columns.
