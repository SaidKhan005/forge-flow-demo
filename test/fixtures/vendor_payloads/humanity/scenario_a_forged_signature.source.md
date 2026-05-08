# Source

- URL: https://platform.humanity.com/v1.0/oauth2/token (token endpoint section), https://platform.humanity.com/v1.0/shifts (poll endpoint authn)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts (Authorization: Bearer ...) — 401 on invalid bearer
- Mapping rationale:
  - Humanity exposes NO webhook delivery surface (per `docs/integrations/humanity/api_consumed.md` and `docs/integrations/humanity/webhook_signature.md`). Body-signed webhook payloads do not exist for this vendor, so the binding A-F "forged signature" scenario cannot be expressed as a body-signature reject.
  - The polling auth path (OAuth 2.0 password-grant bearer token, per `api_consumed.md`) is the only point where the adapter validates vendor-presented credentials. "Forged signature" therefore maps to "invalid OAuth bearer presented on a poll request" — adapter must reject with `HumanityAuthException` (HTTP 401) per `lib/integrations/labor/humanity_labor_production_api_client.dart` lines 109-115.
- Notes:
  - The 401 response body shape (`error`, `error_description`) matches Humanity's documented OAuth 2.0 RFC-6749-style error envelope.
  - Adapter behavior: `HumanityAuthException` thrown; framework marks connection state `reconnect_required`; no canonical write; no watermark advance.
- Outcome: adapter rejects (auth failure); operator sees reconnect prompt; no row persisted.
