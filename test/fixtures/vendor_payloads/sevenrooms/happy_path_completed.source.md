# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: `GET /2_2/reservations/export` (60-day backfill source) / `reservation.updated` webhook event
- Notes: End-of-service `COMPLETED` reservation carrying the full triplet of optional transition timestamps — `arrived_time`, `seated_time`, `departed_time`. Per `field_mapping.md`, all three parse into `status_transitions.*` on the canonical record. The Airship + Kleene + Tenzo integration partner guides all enumerate `COMPLETED` as a terminal status. `last_updated_at` post-dates `departed_time` by ~3 minutes, modeling the vendor-side flush-back of the closeout to the partner API.
