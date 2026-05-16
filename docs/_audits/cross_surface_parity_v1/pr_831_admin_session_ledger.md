# Audit — PR #831 Admin auth-session ledger parity (G1 + G2)

**Date:** 2026-05-16 · Branch `claude/admin-auth-session-ledger-parity` · base `master` (CLEAN, not stacked) · 6 files, +1515/-31.
**Independent orchestrator audit verdict: APPROVE-WITH-NITS.**

## Pattern-B (independent, verified against diff)

| Claim | Verdict | Evidence |
|---|---|---|
| G1: ledger row written BEFORE `AdminAuthAuthenticated`; sign-out closes it | CONFIRMED | `admin_auth_gate.dart:610-619` (record→set id→emit), close `:459-473` |
| Fail-closed in live; demo/share-preview null no-op; no unrecorded admin session admitted | CONFIRMED | `:620-640` (catch→signOut→Unauthenticated), null admit `:603-609`, non-admin never reaches ledger `:597-602`; sign-in/TOTP now awaited `:428,445,514,531` |
| G2: list + per-row revoke + sign-out-everywhere call proxy; sign-out-all revokes sessions AND Firebase refresh tokens | CONFIRMED | `admin_sessions_gateway.dart:245-264/227-242/266-293`; screen `my_account_admin_screen.dart:692-734,1006-1091` |
| Idempotency caller-stable reused across retries | **PARTIAL** | shared-key-per-call CONFIRMED (`admin_sessions_gateway.dart:277-288`); retry-stability NOT met — keys minted from `DateTime.now()`+counter (`admin_auth_gate.dart:643-648`, `my_account_admin_screen.dart:652-657,1246-1250`) |
| 5 proxy routes verified vs `advisor_proxy.dart` | CONFIRMED (1 doc nit) | login `:13502`, revoke `:13876`, revoke-all `:13949`, refresh-revoke-all `:12942`, sessions list `:12993`; path consts byte-match `:8492-8503` |
| No scope creep / admit + MFA-fresh logic byte-preserved | CONFIRMED | exactly 6 files; `kAdminConsoleRoles` `:53` & `session.isAdmin` `:92` unchanged; no operator_web/mobile/tracker edits |
| Tests assert fail-closed admit, demo no-op, non-admin, shared key | CONFIRMED | `admin_sessions_gateway_test.dart:243-307,106-180`; 585 admin suite green, analyze clean |
| Base==master, not stacked | CONFIRMED | `gh pr view` baseRefName master, mergeStateStatus CLEAN |

## Blockers
None. G1+G2 genuinely closed; fail-closed semantics correct.

## Nits / follow-ups (non-blocking)
- **Finding A — idempotency not retry-stable:** `_mintLedgerIdempotencyKey` / `_mintIdempotencyKey` embed `DateTime.now()`+counter ⇒ fresh key per call. PR-body "reused across retries" overstates it. Low impact: admin gateway `_send` has no auto-retry; the genuinely-needed shared-key property (both legs of `signOutEverywhere` carry the SAME key) IS satisfied (`admin_sessions_gateway.dart:277-288`). Same pattern as pre-existing sibling `HttpAdminAccountGateway` — consistent, not a new divergence. Action: trim PR-body wording OR low-priority follow-up to derive keys from a stable seed (token-hash for login, sessionId for revoke) across the admin gateway family.
- **Finding B — doc nit:** PR route table lists `/v1/auth/refresh-tokens/revoke-all` 503 as `refresh_token_revoke_unavailable`; that's only the generic-Exception fallback (`advisor_proxy.dart:12983`); typed path returns `FirebaseAdminAuthError.code`. Gateway doesn't assert on it → no contract break.

## G5 delta audit (commit `ffd2ccf6`, independent)

2 files, +229, purely additive (no deletions; G1/G2 ledger code untouched — verified in diff).
- `adminFixtureAuthBlockedInRelease(...)` logic CONFIRMED correct for the full matrix: debug→allow; release+no-fixture→allow (live path safe); release+fixture+no-opt-in→**BLOCK**; release+fixture+opt-in→allow. (`main_admin.dart`)
- Guard runs in `main()` after `ensureInitialized()` and **before** `_resolveAuthSource()`/`try` → fails closed onto existing `_AdminAuthInitFailedApp`, returns. Real release code (plain `if`/`runApp`/`return`), not an `assert`. Existing assert kept (belt-and-suspenders).
- New opt-in `ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH` defaults false; separate from existing fixture flags (correct — dev scripts/review-link deploy set those routinely). G5 genuinely closed.
- Tests: full four-way matrix + both fixture flags + live path + message copy; 6 cases pass; analyze clean.

**Verdict: APPROVE-FOR-MERGE.**

### Non-blocking operational follow-up (operator must know before merge)
The legitimate public **share-preview deploy** (`scripts/deploy_admin_console.ps1 -SharePreview`, the emailed-review-link feature) will now **fail closed** unless it passes `--dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true`. This is the intended fail-closed-by-default design, but the deploy script must be updated to pass the opt-in or the review-link feature breaks. Agent scope was code-only (correct); this is a queued deploy-script follow-up, not a code defect.

## Disposition
**APPROVE-FOR-MERGE** (G1 + G2 + G5). Operator merges (auth/proxy-critical — explicit approval required regardless of clean verdict). Follow-ups (non-blocking): (1) update `scripts/deploy_admin_console.ps1 -SharePreview` to pass `ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true`; (2) trim the idempotency wording in the PR body or open a low-priority retry-stable-key follow-up.
