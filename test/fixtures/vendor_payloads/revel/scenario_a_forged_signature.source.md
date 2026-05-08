# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — adversarial Scenario A (forged signature).
- Notes:
  - Body is a copy of `happy_path_order_finalized.json` (modulo identifiers). The `X-Revel-Signature` value `deadbeef…` is a hex-shaped placeholder NOT produced by HMAC-SHA1 over this raw body with the operator's signing secret — i.e. an attacker forgery.
  - Vendor docs pin HMAC-SHA1 + hex-encoded (lowercase) per `docs/integrations/revel/webhook_signature.md`. Verifier path: `lib/integrations/pos/revel_webhook_signature_verifier.dart` uses `constantTimeBytesEquals`; mismatch → `WebhookSignatureVerification(valid: false, failureReason: 'X-Revel-Signature HMAC mismatch')`.
  - Phase 2 adapter harness assertion: verifier rejects the request with 403; framework writes an `audit_logs` row; no `inbound_webhook_idempotency` row created; no canonical fact upsert.
  - Adversarial set inherited from `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` "Scenarios A-F binding".
