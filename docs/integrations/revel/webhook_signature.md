# Revel Systems — Webhook Signature

**Vendor ID**: `revel`
**Source documentation**: <https://developer.revelsystems.com/revelsystems/docs/webhooks>
**Retrieval date**: 2026-05-03

---

## Algorithm

`HMAC-SHA1`

Cite vendor doc: <https://developer.revelsystems.com/revelsystems/docs/webhooks> —
"we create a hash-based message authentication code (HMAC) using the
SHA-1 algorithm and your secret key".

The framework contract
(`docs/contracts/per_vendor_doc_pack_contract.md`) lists `HMAC-SHA256`
as the modern default; Revel signs with SHA-1. The verifier uses
SHA-1 because the vendor pins it; constant-time compare still applies
(timing-oracle defense is independent of digest width).

---

## Signed payload

`raw body` — the request body bytes verbatim, not concatenated with a
timestamp or any header. Revel's documented Python example:

```python
import hmac
from hashlib import sha1
signature = hmac.new(secret.encode('utf-8'),
                    request_body.encode('utf-8'),
                    sha1).hexdigest()
```

The adapter MUST preserve the raw body bytes through the request
pipeline — no JSON re-serialization between the proxy and the
verifier (the framework's `kInboundWebhookReplayCeiling` design and
the verifier's `rawBody: Uint8List` parameter both assume this).

---

## Encoding

`hex (lowercase)`

Case sensitivity: technically the adapter could compare
case-insensitively, but Python's `.hexdigest()` always emits
lowercase and Revel's docs only show lowercase examples. The
verifier (`lib/integrations/pos/revel_webhook_signature_verifier.dart`)
decodes hex to bytes before comparing, so case differences are
handled by the byte-level compare regardless of input case.

---

## Header name

`X-Revel-Signature` (proxy lower-cases on receipt, so the verifier
reads `headers['x-revel-signature']`).

---

## Timestamp header

**Header name**: none — Revel does not bind a timestamp into the
signed payload.

**Format**: n/a.

**Replay tolerance**: 24h per V1 lean cut 2 (the framework constant
`kInboundWebhookReplayCeiling` in
`lib/services/integration/inbound_webhook_handler.dart` stays at 24h
unconditionally). Because the verifier returns
`WebhookSignatureVerification.timestamp = null`, the framework
**skips** the per-event signed-timestamp check; the duplicate-write
defense is the idempotency UNIQUE on
`inbound_webhook_idempotency(vendor_id, operator_id, vendor_event_id)`.

This is a deliberate adapter decision documented at slice ship — not
a contract violation. The contract reads "Adapter uses 24h tolerance
per V1 lean cut 2; document if this vendor needs a tighter window
for any reason." Revel doesn't sign one at all, so the question of
tolerance is moot for this surface.

---

## Constant-time compare

The verifier uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` to avoid
timing oracles. The signing-secret bytes themselves are never
compared directly — the verifier HMACs the raw body, compares the
result against the decoded `X-Revel-Signature` bytes, and bails on
length mismatch before content comparison.

Verifier file:
`lib/integrations/pos/revel_webhook_signature_verifier.dart`.

---

## Auto-register endpoint

Revel exposes a webhook subscription endpoint that accepts the F&F
webhook URL + the events to subscribe to + the signing secret. The
adapter calls it from `connect()` so first-connect operators do not
need to paste anything into the Revel admin portal.

- **Method + path**: `POST {webhook_subscription_path}` — exact path
  pinned at sandbox-verification time (`*.live.sandbox` fills in the
  field-mapping diff). Until then, the adapter's
  [RevelTransport.registerWebhook] signature accepts whatever path
  the live transport implementation supplies.
- **Body**: `{"url": "<f&f webhook url>",
  "events": ["order.finalized"], "signing_secret": "<operator-issued>"}`.
- **Returns**: subscription id (stored in
  `connector_connection.metadata.webhook_subscription_id`).

Events the adapter subscribes to:

- `order.finalized` — primary canonical-fact source. Fired when an
  order completes (closes) at the Revel POS. Payload envelope shape:
  `{"order": <order row>}` (see `revelOrderFinalizedPayload` in
  `test/integrations/pos/fixtures/revel_webhook_fixture.dart`).

Events the adapter does NOT subscribe to (the operator can still
inspect them via `/external/message-log` if needed but they don't
flow into F&F canonical facts):

- `customer.created` / `customer.updated` — guest PII; out of scope.
- `rewardcard.created` — out of scope at V1.
- `inout.stock` — inventory; out of scope at V1.
- `menu.updated` — out of scope.
- `timesheet.created` / `timesheet.updated` / `timesheet.deleted`
  — labor data flows through scheduling vendors.
- `app.integration.changed` — operator-facing in the Revel admin;
  not consumed by F&F.

---

## Manual paste instructions

N/A — the adapter auto-registers the subscription on first connect
(`webhookSupport: VendorWebhookSupport.autoRegister`). The connect
flow does not ask the operator to paste a webhook URL or signing
secret.

The signing secret round-trips through the Revel admin portal as
part of subscription creation: F&F generates a per-connection secret
in the proxy at connect time, hands it to Revel via
`registerWebhook`, and persists the encrypted ciphertext in
`vendor_credentials.metadata`. The verifier reads the same secret
back from the gateway on every inbound webhook.
