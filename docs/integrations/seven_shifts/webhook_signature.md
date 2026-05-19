# 7shifts — Webhook Signature

**Vendor ID**: `seven_shifts`
**Source documentation**: <https://developers.7shifts.com/reference/webhooks>
**Retrieval date**: 2026-05-04

7shifts is the **only** scheduling vendor in F&F's INTEGRATE set with
autoRegister webhooks for schedule + punch + payroll-period events.
The webhook auto-registration endpoint is gated on the **Gourmet**
pricing tier per <https://www.7shifts.com/pricing>; operators on
lower tiers receive polling-only sync. See `api_consumed.md` for the
plan-tier detection flow that enforces the gate.

---

## Algorithm

`HMAC-SHA256`

The verifier
(`lib/integrations/labor/seven_shifts_webhook_signature_verifier.dart`)
computes the digest with `Hmac(sha256, utf8.encode(signingSecret))`
over the raw body bytes.

Cite vendor doc: <https://developers.7shifts.com/reference/webhooks>

---

## Signed payload

What bytes is the HMAC computed over? **Raw body** — the verbatim
request body bytes 7shifts hands the proxy. No JSON re-serialization
between the proxy and the verifier; the framework hands the verifier
the raw bytes via `WebhookSignatureVerifier.verify(rawBody: ...)`.

---

## Encoding

`base64`

Case sensitivity: standard base64 (case-sensitive). The verifier
uses `dart:convert` `base64.decode` which rejects malformed strings
with a `FormatException` → `WebhookSignatureVerification.valid =
false` with `failureReason: 'X-7Shifts-Hmac-SHA256 is not valid
base64'`.

---

## Header name

Exact header the signature arrives in: `X-7Shifts-Hmac-SHA256` —
constant declared as `kSevenShiftsSignatureHeader` in the verifier
file (lower-cased per the framework's header normalization).

---

## Timestamp header

Header that carries the signing timestamp:

- **Header name**: `X-7Shifts-Timestamp`
- **Format**: Unix epoch seconds (assumption — verify in
  `8.S.7S.live.sandbox`).
- **Replay tolerance**: 24h per V1 lean cut 2 (see
  `lib/services/integration/inbound_webhook_handler.dart`
  `kInboundWebhookReplayCeiling`).

When the vendor does NOT include a timestamp in the signed payload
(verifier returns `WebhookSignatureVerification.timestamp == null`),
the framework's 24h ceiling is bypassed for that event and the
duplicate-write defense rests on the idempotency UNIQUE on
`inbound_webhook_idempotency(vendor_id, operator_id,
vendor_event_id)`. Banned per V1 lean cut 2: a stricter 5-minute
replay window. Vendor retry windows commonly exceed 5 minutes; the
24h ceiling + idempotency UNIQUE is the correct pairing.

---

## Constant-time compare

Adapter uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` to avoid
timing oracles.

Verifier file:
`lib/integrations/labor/seven_shifts_webhook_signature_verifier.dart`

---

## Auto-register endpoint

(Gourmet plan only — see `api_consumed.md` "Webhook gating".)

The vendor API endpoint the adapter calls to register the F&F webhook
URL:

- **Method + path**: `POST /v2/company/{company_id}/webhooks`
- **Body**: `{"url": "<f&f webhook url>", "events": [<event_list>]}`
- **Returns**: webhook id (stored in
  `connector_connection.metadata.webhook_id`)

Events the adapter subscribes to (full list in
`kSevenShiftsSubscribedWebhookEvents`):

- `time_punch.created` — punch lifecycle (start/edit/delete) keeps
  canonical punch facts fresh between polling ticks.
- `time_punch.edited`
- `time_punch.deleted`
- `shift.created` — schedule lifecycle (planned shifts).
- `shift.updated`
- `shift.deleted`
- **`payroll_period.closed`** — load-bearing for Phase 7.58 Primary
  Driver audit. Adapter's `handleWebhook` parses the event's
  `payroll_period.closed_at` instant and writes it to the canonical
  `payroll_period_closed_at` row via
  `_gateway.writePayrollPeriodClosedFact(...)`. Verified by Test 8 in
  `test/integrations/labor/seven_shifts_labor_adapter_test.dart`.

---

## Manual paste instructions

N/A — autoRegister on Gourmet plan; polling-only on lower tiers (no
manual paste path). If a future API change forces manual portal
pasting, this section becomes:

```
1. In your 7shifts admin portal, go to Settings → Integrations → Webhooks.
2. Click "Add webhook URL."
3. Paste: <f&f webhook url>
4. Set event filter: time_punch.*, shift.*, payroll_period.closed.
5. Copy the signing secret 7shifts shows you, then paste it back in
   F&F to confirm.
```

The framework supports `manualPaste` natively; only the capability
profile (`VendorCapabilityProfile.webhookSupport`) and this section
change.

---

## Plan-tier fallback (Gourmet vs lower tiers)

The capability profile declares `webhookSupport: autoRegister` —
that's the **maximum** capability the adapter offers. Runtime
behavior depends on the operator's plan tier:

| Tier | Webhook auto-register | Polling | Operator-facing note |
|---|---|---|---|
| Gourmet | ✅ — `registerWebhook()` invoked on connect | Runs alongside webhooks for resilience | None |
| The Works / Appetizer / Entree | ❌ — skipped | Sole sync path | `kSevenShiftsNonGourmetNote` in `TestConnectionResult.note` |

The fallback is logged via the existing `connector_sync_log`
machinery — no new rotation surface, no new alert path. Verified by
the slice's plan-tier fallback test (Test 9) and walked through in
`docs/_walkthroughs/8.S.7S.md`.
