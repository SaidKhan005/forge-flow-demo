# ADP Workforce Now / Workforce Manager — Webhook Signature

**Vendor ID**: `adp`
**Source documentation**: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
(public ADP developer-portal API catalog. Event-subscription /
signature envelope is gated on the ADP Marketplace Developer
Participation Agreement; see `partnership_status.md`.)
**Retrieval date**: 2026-05-04

> **Every section in this file is an assumption to verify in
> `8.S.ADP.live.sandbox`.** ADP's exact signature header name,
> encoding, signed-payload byte sequence, and replay envelope land
> in the partner doc that the DPA gates. The verifier is engineered
> against `HMAC-SHA256` over the raw request body, base64-encoded,
> in the `ADP-Signature` header — the partner industry-standard
> shape. EVERY parameter is flagged for live diff in
> `8.S.ADP.live.sandbox`; mismatches become bounded fixes (not slice
> rebuilds) per `docs/contracts/vendor_adapter_slice_contract.md`.

---

## Algorithm

`HMAC-SHA256` — assumption.

Cite vendor doc:
<https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>

The framework's `constantTimeBytesEquals` helper does the compare so
a timing oracle cannot leak the digest byte-by-byte. Implementation
in `lib/integrations/labor/adp_webhook_signature_verifier.dart`.

---

## Signed payload

Raw HTTP request body bytes — assumption.

The proxy hands the verifier the verbatim bytes from the request
pipeline; NO JSON re-serialization between the proxy and the
verifier. JSON re-serialization is the silent breakage that
historically loses ADP webhook validation when a proxy reformats
unicode escapes or whitespace.

The verifier signature value covers ONLY the body. Some vendors
sign body + timestamp; ADP's documented shape signs body alone and
exposes the timestamp in a sibling header (see "Timestamp header").
Live diff verifies.

---

## Encoding

`base64` — assumption.

Standard base64 (RFC 4648), no URL-safe variant. The verifier
strips whitespace and decodes via Dart's `base64.decode`; bad
encoding returns `WebhookSignatureVerification(valid: false,
failureReason: 'ADP-Signature is not valid base64')`.

Case sensitivity: standard base64 is case-sensitive; the verifier
compares decoded bytes, not the encoded string.

---

## Header name

`ADP-Signature` — assumption (lower-cased on the wire as
`adp-signature`; the verifier matches case-insensitively).

---

## Timestamp header

`ADP-Signature-Timestamp` — assumption.

Format: Unix epoch seconds (string-encoded integer). The verifier
parses via `int.tryParse`; bad parse returns
`WebhookSignatureVerification(valid: false, failureReason:
'ADP-Signature-Timestamp not parseable as unix epoch seconds')`.

When present, the framework's 24h replay ceiling
(`kInboundWebhookReplayCeiling`) enforces against this header. When
absent (some vendors omit the timestamp on the first delivery and
include it only on retries), the verifier returns
`timestamp: null` and the idempotency UNIQUE on
`(vendor_id, operator_id, vendor_event_id)` is the duplicate-write
defense for legitimate retries (per V1 lean cut 2 — strict 5-minute
window stays deleted).

---

## Replay tolerance

24 hours per V1 lean cut 2 (the framework constant
`kInboundWebhookReplayCeiling = Duration(hours: 24)`). ADP retries
historically extend up to a day after a temporary outage; a tighter
window would misclassify legitimate retries as replays.

`webhook_signature.md` does not redeclare the constant; the
framework constant is canonical.

---

## Constant-time compare

The verifier uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart`:

```dart
bool constantTimeBytesEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
```

Length-mismatch returns `false` immediately; otherwise XOR-
accumulates so total time depends only on length, not content. The
verifier file is
`lib/integrations/labor/adp_webhook_signature_verifier.dart`; the
slice's banned-items grep test pins it.

---

## Auto-register endpoint

`POST /core/v1/event-subscriptions` — assumption.

Body (assumed envelope):

```json
{
  "subscriber_url": "https://proxy.example/v1/webhooks/{operator}/{location}/adp",
  "events": ["time.timeEvent.modify"],
  "secret": "<operator-owned signing secret>"
}
```

Returns the vendor-issued subscription id (stored in
`connector_connection.metadata.event_subscription_id`). Disconnect
calls `DELETE /core/v1/event-subscriptions/{id}`.

The signing secret round-trips through ADP's partner portal; the
adapter hands ciphertext to the gateway and never touches plaintext
beyond the in-memory hop. KMS-style at-rest encryption is a
post-launch concern (V1 lean cut 2 — no KMS code path at V1; the
banned-items grep test pins this).

---

## Manual paste fallback

Not currently planned. ADP Marketplace event subscriptions auto-
register; if the partner doc reveals a manual-paste alternative the
adapter switches `webhookSupport` from `autoRegister` to
`manualPaste` and exposes the operator-facing portal copy here.
Today the capability profile declares `autoRegister`.

---

## How the live slice diffs this file

The `8.S.ADP.live.sandbox` slice produces one observed sandbox
webhook delivery (manually triggered via the partner portal's "Send
test event" surface) and asserts:

1. Signature header name matches `kAdpSignatureHeader`.
2. Encoding decodes via `base64.decode`.
3. Algorithm matches HMAC-SHA256 against the raw body bytes.
4. Optional timestamp header matches `kAdpTimestampHeader`.
5. Replay tolerance ≥ 24h.
6. Auto-register endpoint succeeded at connect time.

Mismatches become bounded fixes:

1. Update the constants in
   `lib/integrations/labor/adp_webhook_signature_verifier.dart`.
2. Update this `webhook_signature.md` table.
3. Update the relevant test fixture so the signature-reject test
   uses the new shape.

No slice rebuild required.
