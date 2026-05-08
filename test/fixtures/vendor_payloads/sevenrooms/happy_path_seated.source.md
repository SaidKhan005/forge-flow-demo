# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: `GET /2_2/reservations` (incremental polling shape) / `reservation.updated` webhook event
- Notes: Reservation transitioned to `SEATED` after the guest checked in. Per `field_mapping.md`, `arrived_time` and `seated_time` are optional ISO-8601 transition timestamps (venue-local with offset), parsed into `status_transitions.arrived` / `status_transitions.seated` on the canonical record. Per `oauth_shape.md` Ambiguity calls — per-status transition timestamp presence is not enumerated in the publicly fetched docs; the `8R.SR.live.sandbox` slice will verify which statuses carry which timestamps on real deliveries. The Airship guide enumerates the `SEATED` status string under the partner-API status enum.
