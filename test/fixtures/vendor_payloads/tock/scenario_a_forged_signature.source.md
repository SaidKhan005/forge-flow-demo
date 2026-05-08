# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Endpoint: webhook delivery to `POST /v1/webhooks/tock/{operatorId}/{locationId}`
- Verifier: `lib/integrations/reservation/tock_webhook_signature_verifier.dart`
- Signing scheme (per
  `docs/integrations/tock/webhook_signature.md`): HMAC-SHA256 over the
  raw body, lowercase-hex encoding, `X-Tock-Signature` header.
- Notes: Wrapper shape (`{transport, method, path, headers, body, _meta}`)
  is the Phase 1 convention for scenarios where signature/transport
  context matters; the `body` is a verbatim vendor reservation shape.
  The `x-tock-signature` value is a deliberately-forged 64-char hex
  string that does not equal `HMAC-SHA256(signing_secret, raw_body)`.
  Tock's public reference does not document the precise hex case
  expectation; engineering selected lowercase hex per industry
  convention and the `*.live.sandbox` slice diffs base64 vs hex as a
  bounded fix.

## Sourcing context

Public reservation reference + adapter signing-scheme definition. No
real Tock signing secret used.
