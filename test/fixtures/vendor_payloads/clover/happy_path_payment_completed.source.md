# Source

- URL: https://docs.clover.com/dev/docs/webhooks
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: Inbound webhook delivery (auto-registered via
  `POST /v3/apps/{aId}/webhooks` per
  `docs/integrations/clover/webhook_signature.md`).
- Event type: `P:` prefix in `objectId` is Clover's documented
  identifier for **Payments** events (per the event-type-key table on
  the webhooks doc page).
- Notes: Clover's webhook envelope carries only the object id, NOT the
  full payment body. Per
  `docs/integrations/clover/api_consumed.md` and
  `lib/integrations/pos/clover_pos_adapter.dart`
  (`handleWebhook`), the adapter hydrates by calling
  `GET /v3/merchants/{mId}/orders/{orderId}` (the order the payment
  belongs to is fetched, since F&F only writes order-level canonical
  facts). This fixture matches the vendor's documented webhook shape
  verbatim — Phase 2 harness asserts the adapter rejects an unknown
  prefix and accepts `P:` by routing to the order hydration path.
- Headers (HTTP transport — not part of the JSON body):
    - `X-Clover-Auth-Signature: <<TEST_HMAC_SECRET>>`
      (HMAC-SHA256 base64; verifier in
      `lib/integrations/pos/clover_webhook_signature_verifier.dart`)
    - `X-Clover-Auth-Timestamp: 1777750980`
      (Unix epoch seconds; replay tolerance 24h per
      `kInboundWebhookReplayCeiling` in
      `lib/services/integration/inbound_webhook_handler.dart`)
- Outcome (Phase 2 harness): adapter accepts the envelope, calls
  `CloverApiClient.getOrder` for the parent order, writes one
  canonical fact.
