# Tock — Webhook Signature

**Vendor ID**: `tock`
**Source documentation**:
<https://api.exploretock.com/docs/latest/reservation.html>
+ Tock Premium-tier developer portal (gated; engineering captures the
documented signing scheme below and `*.live.sandbox` verifies)
**Retrieval date**: 2026-05-04

---

## Algorithm

`HMAC-SHA256`

Cite vendor doc:
<https://api.exploretock.com/docs/latest/reservation.html>

---

## Signed payload

`raw body`

The HMAC is computed over the raw HTTP body bytes verbatim. JSON
re-serialization breaks the signature; the framework's webhook route
preserves the raw bytes through to the verifier — see
`InboundWebhookHandler.dispatch` in
[lib/services/integration/inbound_webhook_handler.dart](../../../lib/services/integration/inbound_webhook_handler.dart).

The adapter MUST NOT call `jsonEncode` on the parsed payload before
re-running HMAC verification (the verifier already runs upstream of
the adapter; this note is for the framework rather than the adapter
itself).

---

## Encoding

`hex` (lowercase). Case sensitivity: yes.

The verifier hex-decodes the `X-Tock-Signature` header value and
compares the bytes against the locally-computed HMAC bytes via
`constantTimeBytesEquals` from
[lib/services/integration/inbound_webhook_handler.dart](../../../lib/services/integration/inbound_webhook_handler.dart).

> **Ambiguity note.** Tock's public reservation reference does not
> document the exact encoding (hex vs base64). Engineering selects
> lowercase hex per industry-typical conventions documented on the
> gated Premium-tier developer portal; the `8R.TC.live.sandbox`
> slice diffs observed signature shape and treats a base64 observation
> as a bounded fix (not a slice rebuild).

---

## Header name

`X-Tock-Signature` (case-insensitive lookup at the framework layer;
the verifier uses the lower-cased key `x-tock-signature` per the
framework convention).

---

## Timestamp header

- **Header name**: `X-Tock-Webhook-Timestamp`
- **Format**: Unix epoch seconds.
- **Replay tolerance**: 24h per V1 lean cut 2 (the framework's
  `kInboundWebhookReplayCeiling` in
  [lib/services/integration/inbound_webhook_handler.dart](../../../lib/services/integration/inbound_webhook_handler.dart)).
  The strict 5-minute Stripe-style window is explicitly NOT used —
  vendor retry windows commonly exceed 5 minutes and the idempotency
  UNIQUE on `(vendor_id, operator_id, vendor_event_id)` already
  prevents double-write of legitimate retries.

When the timestamp header is absent (Tock configures it per
subscription; some Premium-tier accounts may omit it), the verifier
returns `null` for the timestamp and the framework skips replay
defense for that event. Idempotency UNIQUE remains the backstop.

---

## Constant-time compare

The verifier uses `constantTimeBytesEquals` from
[lib/services/integration/inbound_webhook_handler.dart](../../../lib/services/integration/inbound_webhook_handler.dart)
to avoid timing oracles.

Verifier file:
[lib/integrations/reservation/tock_webhook_signature_verifier.dart](../../../lib/integrations/reservation/tock_webhook_signature_verifier.dart)

---

## Auto-register endpoint

N/A — Tock requires `webhookSupport = manualPaste`. See next section.

---

## Manual paste instructions

Operators copy the F&F webhook URL + signing secret from the F&F
admin's vendor connections widget and paste them into the Tock
Premium-tier dashboard. The exact copy operators see in F&F follows
the UX writing standard (`memory/project_ux_writing_standard.md`):
brief inline explainers, plain English, no engineering jargon.

The F&F admin shows the operator:

> **Connect Tock — manual paste required**
>
> Tock asks you to paste the webhook URL and the signing secret into
> your Tock dashboard. We need both so Tock can tell us about
> reservation changes the moment they happen, and so we can prove the
> message really came from Tock.
>
> 1. **Sign in to your Tock dashboard** at
>    <https://www.exploretock.com> using the account that owns this
>    business.
> 2. Open **Settings → Integrations → Webhooks** in the Tock dashboard
>    sidebar.
> 3. Click **Add webhook**. In the **URL** field, paste the address
>    we generated for you below.
>    - **Webhook URL** (copy this):
>      `<F&F renders the operator-scoped webhook URL here>`
> 4. Tock will ask you to choose a **signing secret**. Copy the secret
>    we generated for you below — Tock requires you to paste it in
>    once and will never show it again.
>    - **Signing secret** (copy this):
>      `<F&F renders the per-connection signing secret here>`
> 5. In **Events to subscribe**, tick **Reservation updates** (and
>    any other reservation-related events your Tock plan exposes).
> 6. Click **Save webhook** in Tock.
> 7. Come back to F&F and tap **I've pasted both — verify**. We'll
>    confirm by waiting for the first signed message from Tock; this
>    usually takes under a minute.
>
> **You only do this once per location.** If Tock asks you to rotate
> the secret later, F&F will generate a new one and walk you through
> the same steps.

The operator's vendor row reads **"Connecting (webhook pending)"** in
F&F until the first signed webhook arrives; once a verified signature
lands, the row flips to **Connected** and the dashboard chrome drops
the corresponding "vendor connecting" pill.

Codex grades: the verifier implementation in
[lib/integrations/reservation/tock_webhook_signature_verifier.dart](../../../lib/integrations/reservation/tock_webhook_signature_verifier.dart)
matches every parameter documented above.
