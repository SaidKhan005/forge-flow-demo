# Tock — OAuth Shape

**Vendor ID**: `tock`
**Source documentation**:
<https://api.exploretock.com/docs/latest/reservation.html>
**Retrieval date**: 2026-05-04

---

N/A — auth shape documented in [api_consumed.md](api_consumed.md).

Tock issues per-`businessId` API keys via `integrate@tockhq.com` to
Premium / Premium Unlimited tier accounts. There is no OAuth flow
documented on the public reservation reference; the adapter's
`VendorCapabilityProfile.authMode = VendorAuthMode.keyPaste` reflects
this.

The keypaste connect flow is:

1. Operator obtains the API key from Tock support
   (`integrate@tockhq.com`) under the Premium / Premium Unlimited tier
   commercial agreement.
2. Operator pastes the key + their Tock `businessId` into the F&F
   admin's vendor connections widget.
3. F&F's `TockApiClient.verifyApiKey` confirms the key is valid for
   the declared `businessId` and returns an opaque
   `TockCredentialHandle`.
4. The framework persists the key in `vendor_credentials` (HP #7 —
   plaintext never reaches Flutter); subsequent requests attach the
   key from that envelope.

Refresh / rotation semantics:

- API keys do not expire on a documented schedule. Tock revokes keys
  on commercial-relationship change (operator off-boards from Tock,
  Premium-tier downgrade, etc.). On any 401 from Tock, the adapter
  flips `connector_connection.status = 'error'`; the operator then
  re-pastes a new key.
- The `oauth_refresh_cron` does NOT run for Tock (no token to
  refresh). The framework's auto-disable path remains the same as
  the OAuth vendors at the per-status logic level.

Module disambiguation: N/A — Tock has no module split.
