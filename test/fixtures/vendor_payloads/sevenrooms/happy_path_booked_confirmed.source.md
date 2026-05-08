# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: `GET /2_2/reservations` (incremental polling shape)
- Notes: Standard `BOOKED` reservation as published in the Airship integration partner guide. Field shapes (`id`, `arrival_time` ISO-8601 with offset, `party_size` int, `status` UPPERCASE enum, `last_updated_at` ISO-8601 UTC) match the field-mapping table at `docs/integrations/sevenrooms/field_mapping.md`. Forbidden fields (`guest.*`, `client_id`, `notes`, `internal_notes`) are kept in the payload with `IGNORED` placeholders so the adapter's parse path exercises ignored-field behavior. Vendor identity / contact details are NEVER passed downstream — see `field_mapping.md` "Forbidden fields".
