# Audit — PR #832 Live operator-web onboarding (G24 / G3, partial)

**Date:** 2026-05-16 · Branch `claude/fix-operator-web-live-onboarding-g24` · base `master` (not stacked) · PR-only diff 8 files, +685/-28.
**Independent orchestrator audit verdict: APPROVE-FOR-MERGE (for the PR's scope). G24/G3 lifecycle stays OPEN (partially closed).**

## Pattern-B (independent, verified)

| Claim | Verdict | Evidence |
|---|---|---|
| New `signInWithCustomToken` seam additive; mobile/admin byte-equivalent, never call it | CONFIRMED | iface `firebase_auth_client.dart:140`, scaffold-fail `:204`, sdk `firebase_auth_client_sdk.dart:69-87`, timeout `timeout_firebase_auth_client.dart:36-44`; only caller `firebase_operator_web_auth_source.dart:621`; 4 mobile/admin files not in diff |
| Post-redeem consumes custom token, signs in, drives state machine; prod path unchanged | CONFIRMED | `firebase_operator_web_auth_source.dart:608-639`, onboarding guard `:444-451`; prod email/pwd path defaults `onboarding:false` ⇒ byte-equivalent |
| MFA enroll/confirm wired to `/v1/auth/mfa/totp/begin`+`/confirm`; SMS demo-only; fail-closed | CONFIRMED | source `:751,778`, client `operator_web_proxy_client.dart:129-170`, proxy `advisor_proxy.dart:10975-11048` |
| BLOCKER real: no in-app password-SET route, no `/v1/auth/tos/*`; fail-closed, never Completed | CONFIRMED | only `password/change` (needs current pwd, `repository_password_change_gateway.dart:62-73`); zero `tos` route; `magicLinkRedeemGateway` unbound in `proxy_bootstrap.dart` ⇒ redeem 503s in prod (`advisor_proxy.dart:10820-10828`) |
| Idempotency stable `sha256("magic-link-redeem:<token>")` | CONFIRMED | `_stableIdempotencyKey:864-867`, call site `:589` |
| No scope creep; `permission_scope_mismatch` intact | CONFIRMED | 8 code/test files, zero tracker edits; check present `:406` |
| Tests 30/30 + 71/71; cover 4 steps | CONFIRMED | re-run green in clean worktree; analyze clean |
| Base==master, not stacked | CONFIRMED | baseRefName master, merge-base #829 |

## G24/G3 status
**Partially closed.** CLOSED: post-redeem custom-token sign-in, onboarding TOTP enroll/confirm, dead-end removal, idempotency defect on redeem. **STILL OPEN (server-side gaps, correctly disclosed as BLOCKER, require a separate server slice):**
1. In-app password-SET impossible for a live invitee (production design = Firebase reset/action-email; no proxy route; `/v1/auth/password/change` structurally cannot serve a first-timer).
2. ToS acceptance impossible — no `/v1/auth/tos/*` route exists (clickwrap UI/state built, server route never was).
3. `MagicLinkRedeemGateway` has no production binding ⇒ redeem route 503s in prod — the larger latent blocker; the wired post-redeem path is not end-to-end functional in production until bound.

Fail-closed interim is **safe**: both unimplemented methods emit calm operator-facing states, provably never reach signed-in/Completed (code path + test verified). Strictly better than master's `UnsupportedError` crash. No security regression, no false success.

## Blockers / nits
**Blockers:** none for this PR's scope. **Nits:** fail-closed tests assert `isNot(OperatorWebCompleted)` (cover "no throw" implicitly) but not the specific terminal state/copy — adequate, could be tighter.

## Disposition — SUPERSEDED 2026-05-16 by `onboarding_server_slice_spec.md`

**Original verdict (now overridden): APPROVE-FOR-MERGE.** The follow-up server-slice spec found PR #832 is built on a magic-link + `firebase_custom_token` model **production cannot honor** (`FirebaseAdminAuthClient` has no custom-token mint; production invite = Firebase reset-email). The wired post-redeem path is dead in prod.

**Revised recommendation: do NOT merge #832 as-is.** Keep its MFA enroll/confirm wiring (correct, reusable) and its fail-closed `submitPassword` copy; **discard** the `verifyMagicLinkToken` custom-token path + `signInWithCustomToken` additions; fold the rework into server-slice S3 so the dead surface never lands. Root cause of G24/G3 Gap #2 is the cross-surface finding **G66** (invite-activation decorator unwired — every live mobile + operator-web invitee is never activated). G24/G3 stays OPEN; see `onboarding_server_slice_spec.md`.
