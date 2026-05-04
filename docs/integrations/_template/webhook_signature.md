# `<vendor_display_name>` — Webhook Signature

**Vendor ID**: `<vendor_id>`
**Source documentation**: `<https://...>`
**Retrieval date**: YYYY-MM-DD

> If `webhookSupport == pollOnly`, replace this file with a single
> line: "N/A — vendor does not support webhooks per `api_consumed.md`."

---

## Algorithm

`HMAC-SHA256` | `HMAC-SHA1` | `RSA-PSS` | `<other>`

Cite vendor doc: `<URL>`

---

## Signed payload

What bytes is the HMAC computed over?

- `raw body` — request body bytes verbatim.
- `body + timestamp` — `<timestamp_header_value>.<raw body>` (Stripe-style).
- `body + headers` — vendor-specific concatenation. Document exact
  byte sequence.

Adapter MUST preserve the raw bytes through the request pipeline (no
JSON re-serialization before HMAC).

---

## Encoding

`base64` | `hex (lowercase)` | `hex (uppercase)` | `raw bytes`

Case sensitivity: `<yes / no>`

---

## Header name

Exact header the signature arrives in:

- `Toast-Signature`
- `X-Lightspeed-Signature`
- `X-Webhook-Signature-256`

---

## Timestamp header

Header that carries the signing timestamp (only required if signed
payload includes timestamp):

- **Header name**: `<X-Toast-Timestamp>`
- **Format**: `Unix epoch (seconds)` | `ISO 8601` | `<other>`
- **Replay tolerance**: 24h per V1 lean cut 2 (see
  `lib/services/integration/inbound_webhook_handler.dart`
  `kInboundWebhookReplayCeiling`).

---

## Constant-time compare

Adapter MUST use `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` (or equivalent)
to avoid timing oracles.

Verifier file: `lib/integrations/<category>/<vendor>_webhook_signature_verifier.dart`

---

## Auto-register endpoint

(For `webhookSupport = autoRegister` vendors only.)

The vendor API endpoint the adapter calls to register the F&F webhook
URL:

- **Method + path**: `POST /v1/webhooks/subscriptions`
- **Body**: `{"url": "<f&f webhook url>", "events": [<event_list>]}`
- **Returns**: subscription ID (stored in
  `connector_connection.metadata.webhook_subscription_id`)

Events the adapter subscribes to:

- `<event_name>` — purpose
- `<event_name>` — purpose

---

## Manual paste instructions

(For `webhookSupport = manualPaste` vendors only.)

Operator-facing copy that explains where to paste the URL + signing
secret in the vendor's portal. Match the UX writing standard
(`memory/project_ux_writing_standard.md`).

```
1. In your <vendor> admin portal, go to Settings → Integrations.
2. Click "Add webhook URL."
3. Paste: <f&f webhook url>
4. Set event filter: <event names>
5. Copy the signing secret <vendor> shows you, then paste it back in
   F&F to confirm.
```
