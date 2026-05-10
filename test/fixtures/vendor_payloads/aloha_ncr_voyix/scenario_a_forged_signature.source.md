# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus delivery; signature header
  `NCR-Webhook-Signature` per `webhook_signature.md`.
- Notes: Adversarial scenario A from
  `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`.
  Body is the documented `aloha.check.modified` shape; signature is
  a known-bad base64 placeholder. Phase 2 harness asserts the
  framework's `InboundWebhookHandler` rejects the request before any
  fact write reaches the sink.
- Defense: `aloha_ncr_voyix_webhook_signature_verifier.dart` uses
  `constantTimeBytesEquals` so the forged signature also exercises
  the timing-oracle protection.
