# Spec — Live Onboarding Server Slice (closes G24/G3) + cross-surface finding G66

**Date:** 2026-05-16 · master @ `9680d7d2` · companion client PR #832 (`456a8b75`, NOT merged).

## OPERATOR DECISIONS — 2026-05-16 (binding)
- **Q1 = Firebase reset-email; DELETE magic-link.** Adopt the existing production reset-email model. Remove magic-link route/gateway/const + the #832 client custom-token path.
- **Q2/G66 scope = confirmed** (cross-surface incl. mobile; agent building S1).
- **Q3 = recommended default** (catch data-integrity `StateError` → audit+continue; propagate infra exceptions). Pending operator sign-off at the G66 PR merge.
- **Q4/Q5/Q7 = ToS DROPPED FOR NOW ("overkill for now").** **S2 (ToS routes) is cut.** No `/v1/auth/tos/*`, no login-time ToS gate, no mobile ToS. The operator-web `acceptTos`/`OperatorWebAcceptingTos` step is **removed/short-circuited**, NOT wired to a server route. This defers the `operator_self_served_tos_contract.md` / Phase 9.8 clickwrap — recorded as a deliberate product deferral (revisit before any compliance/legal gate is required).
- **Q6 = moot** while ToS is deferred (no version seed needed).

**Revised slice plan:** S1 (G66 activation — in build) + **S3′** = magic-link removal + #832 client reworked onto the Firebase reset-email path with the ToS step omitted (keep #832's MFA wiring). S2 cut. Net: closing G24/G3 = S1 + S3′ only.

## Executive finding — the model is wrong, not just unwired
PR #832 wired operator-web to a magic-link + `firebase_custom_token` model. Verified: **production never implemented and structurally cannot support that model.**
- `FirebaseAdminAuthClient` (`firebase_admin_auth_client.dart:73-142`) has **no custom-token mint**. Nothing can produce the `firebase_custom_token` #832's client depends on.
- Production invite = **Firebase password-reset email**, not a magic link: `createInvite` (`repository_auth_operations_gateway.dart:631-689`) creates the user, stores only a SHA-256 hash (plaintext token discarded, never emailed), then `sendPasswordResetEmail`. Confirmed by `invited_user_activation_repository.dart:1-7`.
- Recommendation: **option (b)** — adopt Firebase reset-email as the canonical model; **delete** the magic-link route + gateway + client custom-token path. Lower-risk, contract-aligned, matches mobile.

## NEW finding G66 (cross-surface, highest priority) — invite activation decorator unwired
`InvitedUserActivationLedgerWriter` (flips `users.status` invited→active, stamps `auth_invites.accepted_at` at first login) is **never constructed in production**. `proxy_bootstrap.dart:1295-1297` wires the bare `RepositoryAuthSessionLedgerWriter`. Zero non-test references to the decorator/`InvitedUserActivationRepository` in `tool/` or `lib/`. **Consequence: every live invitee — mobile AND operator-web — who completes the reset email and signs in is NEVER activated; `users.status` stays `'invited'` forever.** This is the true production blocker behind G24/G3 Gap #2 and it is cross-surface (mobile too), not operator-web-only. Highest-priority fix.

## Per-gap root cause
- **Gap 1 (magic-link unbound):** route `advisor_proxy.dart:10776-10856` 503s when gateway null; no impl exists anywhere; built on the rejected custom-token model. → **delete**, don't bind.
- **Gap 2 (no password-SET route):** not needed. Production = Firebase reset page. Real blocker = G66 (unwired activation decorator).
- **Gap 3 (no `/v1/auth/tos/*`):** storage already exists (`db/migrations/202605040100_phase_9_8_tos_versions.sql` → `tos_versions`, `tos_acceptances` with RLS); contract `operator_self_served_tos_contract.md`; client state + screen exist. Build 2 routes + a login-time gate.

## Recommended design
- **S1 (highest priority, ~1 file):** wire `InvitedUserActivationLedgerWriter` as a decorator around `RepositoryAuthSessionLedgerWriter` in `proxy_bootstrap.dart:1295`. Idempotent (no-ops when status≠invited). **Q3 (auth-critical):** on `StateError` (invited-but-no-open-invite / 0-row) — block login (would 500) vs swallow-and-audit-then-continue? Rec: swallow-and-audit data-integrity StateError, propagate genuine infra exceptions. Fixes mobile + operator-web simultaneously.
- **S2 (~5-6 files):** `TosGateway` + `RepositoryTosGateway` + repos + `tos_routes.dart`: `GET /v1/auth/tos/active?scope=` (200 version / 404 `tos_version_not_seeded` / 503), `POST /v1/auth/tos/accept` (bearer-auth, server-resolved ids, re-validate active → 409 `tos_version_superseded`, idempotency-key + natural-key dedup, ip/ua server-side, audit `auth.tos_accepted`), + login-time `requires_tos_acceptance` flag (rec: extend account-info response). No migration; **ToS version seed is a hard launch prerequisite (Q6)**.
- **S3:** remove magic-link route/gateway/const; rework #832 client to Firebase-reset-email primary + wire `acceptTos` to the new route + add ToS step in `_completeCredential`. Best done as a **revision of #832 before merge** (avoid landing then deleting dead code).

Order: S1 → S2 → S3. All proxy-touching; S1 auth-critical. **No `7.58` adjacency** (auth/onboarding transport + legal record, not app logic). Can run parallel to per-daypart V1.

## Sequencing vs in-flight
- **PR #832: do NOT merge as-is** (lands a dead custom-token surface). Keep its MFA wiring + fail-closed `submitPassword` copy; discard `verifyMagicLinkToken` custom-token path + `signInWithCustomToken`; fold rework into S3.
- `9680d7d2` (admin G1/G2 ledger) orthogonal. This slice is launch-blocking, `7.58`-non-adjacent.

## Open questions for the operator
- Q1: confirm option (b) — delete magic-link, adopt Firebase reset-email.
- Q2: approve G66 (unwired activation decorator) as primary Gap-2 fix; confirm cross-surface mobile scope in.
- Q3 (auth-critical): activation-decorator failure policy (block-login vs swallow-and-audit). Rec: swallow data-integrity StateError + audit; propagate infra.
- Q4: ToS scope token — new `operator_web_onboarding` vs reuse `inbound_vendor_universal`. Rec: new.
- Q5: ToS subsequent-login gate surface — extend account-info (rec) vs new `GET /v1/auth/tos/status`.
- Q6: who seeds `tos_versions` onboarding row + from which body copy? Hard launch prerequisite.
- Q7: mobile onboarding ToS parity for V1, or operator-web-only (mobile ignores additive flag)? Rec: web-only V1, file mobile follow-up.

Source agent (read-only, resumable): `a2c05725ff8ae0672`.
