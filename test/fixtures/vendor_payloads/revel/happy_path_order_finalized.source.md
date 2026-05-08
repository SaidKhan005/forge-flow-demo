# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03 (matches `documentedPerRevelV1.api_version` in `lib/integrations/pos/revel_pos_adapter.dart`)
- Endpoint: webhook subscription `order.finalized` — `POST {f&f_webhook_url}` envelope `{"order": <order row>}`
- Notes:
  - Vendor Revel is partner-only per `docs/integrations/revel/partnership_status.md`. Public docs at the developer portal are limited; field shape was sourced from the public webhooks page + the verbatim adapter test fixture
    `test/integrations/pos/fixtures/revel_webhook_fixture.dart` (constant `revelOrderFinalizedPayload`,
    cited 2026-05-03 retrieval against the same vendor doc URL).
  - Header set sourced from `docs/integrations/revel/webhook_signature.md` (`X-Revel-Signature` + `X-Revel-Event-Type` + `X-Revel-Event-Id` + `X-Revel-Instance`) and `documentedPerRevelV1` adapter constants (`event_type_header`, `event_id_header`, `message_id_header`, `establishment_id_header`).
  - Signature value is illustrative HMAC-SHA1 hex (lowercase) per `webhook_signature.md`; the corpus does not include the signing-secret round-trip.
  - Field mapping `order.number_of_people` (int covers), `order.created_date` / `order.updated_date` (ISO 8601 UTC), `order.final_total` (string-decimal dollars), `order.id` (int) all per `docs/integrations/revel/field_mapping.md`.
