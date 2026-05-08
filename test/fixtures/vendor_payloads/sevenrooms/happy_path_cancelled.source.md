# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: `GET /2_2/reservations` (incremental polling shape) / `reservation.cancelled` webhook event
- Notes: Guest-cancelled reservation carrying `cancellation_time` instead of arrival/seat/depart transitions. Per `field_mapping.md`, `cancellation_time` parses into `status_transitions.cancelled` on the canonical record. The webhook event filter list in `docs/integrations/sevenrooms/webhook_signature.md` lists `reservation.cancelled` alongside `reservation.created` / `reservation.updated`.
