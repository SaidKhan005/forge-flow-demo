# Phase 9 Decision Lock - 2026-04-26

Status: LOCKED by user approval.

The user accepted the recommended Phase 9 decision set on 2026-04-26. Future
Phase 9 prompts should treat this as the decision source unless the user
explicitly reopens an item.

Update 2026-04-30: the user explicitly reopened the MFA enforcement and
recovery-code UX items. Mandatory MFA enforcement for admin-tier accounts is
deferred until post-launch stability. Recovery-code display and challenge
entry are removed from the app UX; Phase 9 ships TOTP enrollment, admin
reset/support, step-up freshness for sensitive actions, and 24-hour MFA
removal safety.

| Area | Locked Decision |
| --- | --- |
| Passkeys | Phase 9 launches with email/password + TOTP. Passkeys are future follow-up only unless Firebase / Identity Platform exposes an official supported passkey path before cutover. |
| Auth emails | Use Firebase action links with branded Forge & Flow web pages. Firebase keeps secure action-code handling; Forge & Flow owns visible pages/copy. |
| JWT verifier style | Verify Firebase ID tokens locally with Firebase public keys/JWKS; do not make a live Firebase call per normal request. |
| Revocation checks | Normal requests use local JWT verification + DB user status. Sensitive operations perform live revoked-token checks. |
| Firebase custom claims | Keep tiny claims only: `operator_id`, `is_super_admin`, `is_ff_support`, `roles_version`; Postgres remains source of truth. |
| Live Firebase smoke | Allow a live staging Firebase smoke after local verifier tests. |
| Staging auth test user | Use dedicated staging test user `auth-smoke@forgeflow.dev` unless a later prompt names a different non-human test address. |
| iOS verification | Windows-side proxy/web/Android work may proceed; Xcode/iOS verification defers to a macOS session and must be reported honestly. |
| Live RLS flip | Approve live staging RLS flip once integration tests are ready. |
| Admin bypass role | Use tightly scoped `forge_admin` BYPASSRLS role for admin paths; every bypass use must be audited. |
| MFA enforcement | Mandatory MFA enforcement for admin-tier accounts is deferred until post-launch stability. Phase 9 launches TOTP self-enrollment and admin reset/support; staff-level users do not have mandatory MFA by subscription tier; users may opt in, and sensitive actions can still require fresh auth. |
| Step-up freshness | Sensitive actions require `auth_time` freshness under 5 minutes. |
| Recovery codes | Do not expose recovery-code display or challenge entry in the app UX. Lost-authenticator support routes through admin reset / delayed removal. |
| MFA removal | MFA removal requires step-up auth plus a 24-hour delay. |
| Password rules | NIST style: 8+ minimum, allow long Unicode, no composition rules, no forced rotation unless breach evidence. |
| HIBP screening | Use Have I Been Pwned k-anonymity screening on signup and password change. |
| Cloud Armor / reCAPTCHA | Enable Cloud Armor rate limits and reCAPTCHA after repeated failures. |
| IP reputation | Start with geo/ASN/impossible-travel audit only; defer paid VPN/Tor reputation vendor. |
| Invite expiry | Invites expire after 7 days. |
| Trusted user creation | Only F&F `super_admin` can create a user without an invite. |
| GDPR erasure | Redact PII, preserve operational/audit record, require two-super-admin break-glass approval. |
| Audit retention | Keep auth/security audit logs for 7 years. |
| Operator custom roles | Operator owners can create/edit operator-scoped custom roles; seeded roles remain protected. |
| Deny rules | Support explicit deny rules; deny wins over allow. |
| F&F support scope | `ff_support` sees only assigned operators/locations; global visibility requires `super_admin`. |
| Admin console UX | Dense operational admin console: tables, filters, audit drilldowns, restrained UI. |
| CSV audit export | Allow CSV export for authorized admins; audit every export. |
