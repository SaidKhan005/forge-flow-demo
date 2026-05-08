# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: `GET /2_2/reservations` (incremental polling shape)
- Notes: Minimal-shape reservation — only the 6 fields the adapter requires (`id`, `venue_id`, `arrival_time`, `party_size`, `status`, `last_updated_at`) per `field_mapping.md` Source field → canonical field. No optional transition timestamps, no `guest` block, no `notes`. Guest contact fields (phone, email) are forbidden by the adapter regardless — see `field_mapping.md` Forbidden fields — so "no phone" is not an interesting carve-out for SevenRooms; "no optional transitions, no guest block" is the genuine sparse case. The adapter must accept this payload and project a canonical record with an empty `status_transitions` map.
