# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Documented minimal time-entry shape — only the required
  identifiers + timestamps the adapter consumes (`id`, `user_id`,
  `start_time`, `end_time`, `updated_at`); the `position` key is
  entirely omitted (vs `sparse_no_role.json` which sends `position: null`).
  Proves the adapter tolerates BOTH absent and explicit-null
  optional keys per `field_mapping.md` Forbidden-fields list (privacy
  fields like `user.first_name`, `user.email`, `notes` may simply be
  absent in real responses).
