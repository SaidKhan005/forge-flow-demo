# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Adversarial fixture inverting every documented type from
  `field_mapping.md`:
    * `id`        — number instead of opaque string (per `field_mapping.md`
                    Ambiguity calls — `id` opacity, the adapter coerces
                    via `id?.toString()`, but `user_id` and timestamp
                    failures below force the row to be rejected).
    * `user_id`   — null where the doc requires a string (Agendrix user id).
    * `position`  — flat string where the doc requires a nested object
                    (`{id, name}`).
    * `start_time`— non-ISO string; `DateTime.parse` throws.
    * `end_time`  — array where the doc requires a string.
    * `updated_at`— empty string; `_parseUtcInstant` returns `null`,
                    which propagates as a missing modification cursor.
    * `next_cursor` — `null` where the doc requires a string ("empty
                    string = end of listing").
  Adapter `_mapTimeEntryToCanonical` raises `FormatException` on
  `DateTime.parse('not-a-date')`; the framework's parse boundary catches
  the throw, writes `connector_sync_log` with `eventKind = parse_error`,
  and the canonical sink performs no DB write.
