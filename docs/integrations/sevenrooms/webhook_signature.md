# SevenRooms — Webhook Signature

**Vendor ID**: `sevenrooms`
**Source documentation**:
- Marketing overview (mentions reservation webhook integration):
  <https://sevenrooms.com/platform/integrations-apis/>
- Partner API portal (account-rep gated):
  <https://api-docs.sevenrooms.com/>
- Partner integration confirmations:
  - Redcat help center: <https://www.redcatht.com/helpcentre/seven-rooms-integration>
    ("operates via Webhook API where SevenRooms provide details of
    reservations")

**Retrieval date**: 2026-05-04

The SevenRooms partner webhook reference is account-rep-gated; the
publicly-fetched portion of the docs does not enumerate the signature
mechanism. The verifier is built against the documented partner-API
pattern: HMAC-SHA256 over the raw request body, hex-encoded
signature in `X-SevenRooms-Signature`. The exact header name +
encoding live in the Ambiguity calls below; the `8R.SR.live.sandbox`
slice will diff observed vs documented and adjust if needed.

---

## Algorithm

`HMAC-SHA256`.

Documented partner-API pattern. Confirmed against the family of
hospitality-vendor webhook conventions; verify on first signed
sandbox delivery.

---

## Signed payload

`raw body`. The verifier computes the digest over the request body
bytes verbatim. The framework's `InboundWebhookHandler.dispatch`
preserves the raw bytes through the request pipeline (no JSON
re-serialization before HMAC).

---

## Encoding

`hex (lowercase)`.

Case sensitivity: yes — uppercase hex is rejected. The verifier
documents the contract strictly; `8R.SR.live.sandbox` will confirm
casing on real webhook deliveries.

---

## Header name

`X-SevenRooms-Signature` (case-insensitive on the wire; the framework
lowercases all incoming headers before lookup).

The verifier reads `headers['x-sevenrooms-signature']` per the
framework's lowercase-key convention.

---

## Timestamp header

Header that carries the signing timestamp:

- **Header name**: `X-SevenRooms-Timestamp`
- **Format**: Unix epoch (seconds)
- **Replay tolerance**: 24 hours per V1 lean cut 2 (see
  `lib/services/integration/inbound_webhook_handler.dart`
  `kInboundWebhookReplayCeiling`).

If the vendor delivery does not include this header, the verifier
returns valid without a timestamp; the framework's replay defense
becomes a no-op for that delivery (idempotency UNIQUE on
`(vendor_id, operator_id, vendor_event_id)` still prevents
double-write).

---

## Constant-time compare

The adapter uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` to avoid
timing oracles. The implementation lives in
`lib/integrations/reservation/sevenrooms_webhook_signature_verifier.dart`
(class `SevenRoomsWebhookSignatureVerifier`). Tests:
- Tampered HMAC rejection: `test/integrations/reservation/sevenrooms_reservation_adapter_test.dart`
  group `SevenRoomsReservationAdapter` test "signature reject".
- Replay window 24h: `test/integrations/reservation/sevenrooms_reservation_adapter_test.dart`
  group `SevenRoomsReservationAdapter` test "replay window".

---

## Auto-register endpoint

N/A — SevenRooms webhook delivery is `manualPaste`. The adapter
does NOT call any vendor endpoint on connect to register a webhook
subscription. The `SevenRoomsWebhookClient.subscribe` seam exists in
the source so the adapter test can assert that it is never invoked
(see test "manualPaste: connect does NOT auto-register a webhook
subscription").

---

## Manual paste instructions

Operator-facing copy the admin widget renders alongside the F&F
webhook URL and signing secret. Reads as if training the operator as
they use it (per `memory/project_ux_writing_standard.md`).

The flow is one-way at registration (operator → SevenRooms portal),
then one-way back (SevenRooms portal → F&F) with the signing secret.

```
1. Open your SevenRooms admin portal in a new tab.
2. Go to Settings → Integrations.
3. Click "Add webhook URL."
4. Paste this URL into the "Webhook URL" field:

   <f&f webhook url>

5. In the "Event filter" picker, check:
   - reservation.created
   - reservation.updated
   - reservation.cancelled

6. Click "Save." SevenRooms will show you a signing secret on the
   confirmation screen — it looks like a long random string.

7. Copy the signing secret and paste it back here in F&F to confirm
   the connection. Once you save, F&F will start verifying every
   inbound reservation update from SevenRooms with that secret.

If SevenRooms doesn't show a signing secret on the confirmation
screen, ask your SevenRooms account rep — partner webhooks always
have one, but it's sometimes hidden behind an extra portal step.
```

The webhook URL F&F surfaces is per-connection (carries the
connection_id in the path) so the framework can route inbound
deliveries to the correct `(operator_id, location_id)` binding
without the operator having to think about it.

---

## Ambiguity calls

The `8R.SR.live.sandbox` slice MUST verify these first:

- **Exact header name**: documented as `X-SevenRooms-Signature` based
  on the partner-API pattern; sandbox-observed value may differ. If
  observed differs, the fix is a one-line constant change in
  `sevenrooms_webhook_signature_verifier.dart`
  (`kSevenRoomsSignatureHeader`).
- **Whether timestamp is part of the signed payload**: documented as
  raw-body-only HMAC. If sandbox shows a `<timestamp>.<body>`
  concatenation pattern (Stripe-style), the verifier needs a small
  patch to prepend the timestamp before HMAC.
- **Encoding casing**: documented as lowercase hex; if observed value
  is uppercase or base64, relax the parser.
- **Event filter labels**: documented as `reservation.created` /
  `reservation.updated` / `reservation.cancelled`; sandbox portal
  may use slightly different labels (`reservation_created` snake_case
  vs dot.case). The manual-paste instructions copy needs a one-line
  update if so.
