# Phase 9.1a - Identity Provider Decision Gate

**Status:** CLOSED - decisions locked 2026-04-26.
**Slice type:** audit / decision gate.

This doc records the two identity-provider decisions left open by the
staging Firebase setup. It supersedes the earlier open-options version.

## Current Setup Truth

| Surface | State |
| --- | --- |
| Firebase staging project (`forge-flow-staging`) | PRESENT |
| Identity Platform tier | ENABLED |
| Email/password sign-in | ENABLED |
| Phone/SMS auth | DISABLED |
| TOTP MFA | ENABLED |
| Admin SDK service-account smoke | PASSED |
| 9.0 auth schema | APPLIED on staging + Production1 |
| Passkeys / WebAuthn | No first-party Firebase / Identity Platform provider surface found in official docs/config |
| Email action callback URI | `https://admin.forgeflow.app/__/auth/action` |

## Decision 1 - Passkeys

**Decision:** Launch Phase 9 with email/password + TOTP. Passkeys are a future
follow-up, not a launch gate, unless Firebase / Identity Platform exposes an
official supported WebAuthn/passkey path before cutover.

**Guardrail:** Do not build custom WebAuthn in the 9.1 runtime wiring slice.
The 9.0 `mfa_factors.factor_type='passkey'` schema remains as
forward-compatible storage.

**Official source basis:**

- Identity Platform authentication concepts list email/password, phone,
  federated providers, OIDC/SAML, and custom auth integration; no first-party
  WebAuthn/passkey provider is listed:
  `https://cloud.google.com/identity-platform/docs/concepts-authentication`.
- Identity Platform TOTP MFA is documented as a supported MFA factor:
  `https://cloud.google.com/identity-platform/docs/admin/enabling-totp-mfa`.

## Decision 2 - Auth Emails

**Decision:** Use Firebase action links with branded Forge & Flow web pages.
Firebase keeps secure action-code handling; Forge & Flow owns the visible
invite, password reset, email verification, and related action pages.

**Guardrail:** Built-in Firebase subject/body template customization is not a
launch blocker. Do not introduce a full custom SMTP / transactional-email
vendor in the 9.1 verifier slice unless a later prompt explicitly scopes it.

**Official source basis:**

- Firebase custom email action handlers are the documented path for branded
  action-code pages:
  `https://firebase.google.com/docs/auth/custom-email-handler`.
- Firebase Admin SDK email action links are the documented path for generating
  secure links for custom email/page flows:
  `https://firebase.google.com/docs/auth/admin/email-action-links`.

## Decision 3 - iOS Verification

**Decision:** Windows-side proxy/runtime wiring may proceed. Xcode scheme,
Podfile, and iOS config verification can be deferred to a paired macOS session
and must be reported honestly when still pending.

## Next Runtime Wiring Scope

The next `9.1` implementation slice may wire:

- `RealProxyJwtVerifier`
- Firebase JWT / JWKS verification
- `firebase_uid -> users -> operator/location/status` tenant resolution
- `auth_events_audit` writes
- branded Firebase action-link handler pages

It must not wire custom WebAuthn/passkeys.
