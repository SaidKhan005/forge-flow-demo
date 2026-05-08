# Source

- URL: https://sevenrooms.com/platform/integrations-apis/ (mentions reservation webhook integration)
- Fallback URL: https://www.redcatht.com/helpcentre/seven-rooms-integration ("operates via Webhook API where SevenRooms provide details of reservations")
- Internal contract: docs/integrations/sevenrooms/webhook_signature.md
- Retrieved: 2026-05-08
- API version: partner webhook delivery contract documented at `v2_2_2026_05`
- Endpoint: inbound webhook (operator-pasted F&F URL); event filter `reservation.created` / `reservation.updated` / `reservation.cancelled`
- Notes: SevenRooms' partner webhook signature mechanism is account-rep-gated; the publicly fetched portion of the docs does not enumerate the exact algorithm. Per `webhook_signature.md`, the verifier is built against the documented partner-API pattern: HMAC-SHA256 over the raw request body, hex (lowercase), header name `X-SevenRooms-Signature`. Timestamp header `X-SevenRooms-Timestamp` (Unix epoch seconds), 24h replay tolerance per V1 lean cut 2 (`kInboundWebhookReplayCeiling` in `lib/services/integration/inbound_webhook_handler.dart`). The 64-char all-zero signature is a structurally valid hex string of the right length but cannot be the HMAC of any non-empty body under any real key, so the constant-time compare deterministically rejects.
