# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Same `id` as `happy_path_time_entry_completed.json` (te_412901)
  with a strictly later `updated_at` and a 15-minute `end_time` extension —
  proves the documented "monotonically non-decreasing modification cursor"
  contract from `field_mapping.md` ("Ambiguity calls — `updated_at`
  rotation"). Adapter sink upserts on
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` so the
  later `updated_at` advances the canonical `shift_end`; the earlier
  fixture's row is replaced via the UNIQUE upsert path.
