# PR #547 Audit — B9.2 My Account Active Sessions Consolidation

**Slice:** B9.2 (Lane B — Features)
**Owner:** Codex executor
**Branch:** `codex/b9-2-my-account-active-sessions`
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 61 + explicit `[operator-approval-required]` title prefix (auth-adjacent: session revoke flow + MFA freshness gate)
**Size:** 1,331 additions / 460 deletions / 5 files
**Chunking:** medium variant (operator-web only, focused IA consolidation)
**Dependency:** B9.1 merged ✓ (PR #510 sign-in-security redirect)

## Pattern B compliance

PR body contains BOTH the worker self-audit and the executor independent audit tables. All 14 lenses populated with file:line citations on every row. Worker discloses test runs in a `Verification` block: `dart analyze ... → No issues found!`, `flutter test ... → 00:04 +34: All tests passed!`, pre-push `postgres_import_lint` clean. Cross-lane note disclosed honestly. Acceptable Pattern B compliance.

## Verdict

**approve-pending-operator** — escalating per `Gate=operator` + auth-adjacent surface (My Account session revoke flow + client-side MFA freshness gate). Audit clean; gate is the policy.

## Files in scope

| File | Δ | Purpose |
|---|---|---|
| `lib/operator_web/account/operator_web_account_actions.dart` | +59 / -0 | New: thin provider seam (`signOutOtherAccountSessions`, fresh-MFA dispatch) |
| `lib/operator_web/screens/my_account_screen.dart` | +475 / -158 | 4-card IA (Profile / Security / MFA / Active Sessions); "This device" badge; confirm dialog; audit-log link on each card |
| `lib/operator_web/services/web_account_gateway.dart` | +232 / -20 | Active-sessions list parsing; revoke loop with idempotency; `_requireFreshMfaToken` client-side gate |
| `test/operator_web/screens/my_account_screen_test.dart` | +324 / -259 | Widget tests for card order, audit links, current marker, non-current revoke, disabled CTA, fresh-MFA gate |
| `test/operator_web/services/web_account_gateway_test.dart` | +241 / -23 | Gateway tests for revoke shape, idempotency, freshness rejection |

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base is `master`** (not stacked) | ✓ — `gh pr view 547 --jq '.baseRefName'` returns `master`. Mergeable=true, mergeStateStatus=CLEAN |
| **Single commit on top of current master tip** (`24f6e2c6`) | ✓ — `git log pr-547-head -3` shows `c0cf82f5` on top of `24f6e2c6` |
| **Client-side MFA freshness gate is real** at `web_account_gateway.dart:184-190` (worker's claim) | ✓ — read `_requireFreshMfaToken` decodes ID-token JWT payload, extracts `auth_time` claim, compares against `_freshMfaWindow`, throws `AccountSessionFreshMfaRequiredException` if stale. Called before every revoke at `web_account_gateway.dart:153-155` |
| **Current session is excluded from revoke** at `my_account_screen.dart:275-317` | ✓ — `otherSessionIds = _activeSessions.where((s) => s.sessionId != currentId)` filter; empty-list shows "No other active sessions to sign out" snackbar; confirm dialog has cancel + submit buttons with explicit keys |
| **Revoke body shape** at `web_account_gateway.dart:153-163` — `{session_id, reason}` per existing route contract | ✓ — `body: {'session_id': sessionId, 'reason': 'my_account.sign_out_other_sessions'}` via `_client.postJson` (which carries idempotency via `operator_web_proxy_client.dart`) |
| **Cross-lane note accuracy**: server-side `/v1/auth/session/revoke` is bearer-auth only (no RFC 9470 step-up) | ✓ — `advisor_proxy.dart:8502-8508` docstring: `/v1/auth/session/revoke -> auth-gated. Sets revoked_at for one row.` No step-up enforcement at the proxy. Worker honestly discloses this is OUT OF SCOPE for B9.2 (belongs with B11.2) |
| **No schema/RLS/migration touched** | ✓ — no `db/migrations/**`, `lib/auth/**`, RLS policy files, or `lib/data/**` in diff |
| **No proxy route added or modified** | ✓ — uses existing `/v1/auth/sessions` (read) and `/v1/auth/session/revoke` (write); no `tool/advisor_proxy/**` files in diff |
| **No mobile (`lib/screens/settings/**`) touched** | ✓ — `lib/screens/settings/settings_active_sessions_section.dart` untouched; B9.2 is operator-web only by slice scope |
| **Test coverage matches worker disclosure** (34 tests pass) | ✓ — worker disclosed `flutter test ... → 00:04 +34: All tests passed!`. Tests cover: card order, audit links, current marker badge, non-current revoke, disabled-only-current CTA, gateway idempotency, fresh-MFA gate rejection |
| **CI-dark-window discipline** — operator-web only, no high-risk surface (auth/proxy/migrations/RLS) | ✓ — local pre-push hook coverage is sufficient per `feedback_ci_dark_until_2026_06_01.md`. Worker still disclosed targeted local test runs (good practice) |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **No `--no-verify` used** | ✓ — worker disclosed `postgres_import_lint: clean` via pre-push hook |
| **B9.2 slice spec alignment** (`docs/_execution/lane_b_features/03_execution_slices.md:148-155`) | ✓ — slice asks for "consolidate active sessions card with My Account 4-card IA + step-up gating preserved within slice's existing-route scope". This PR delivers exactly that. Server-authoritative step-up correctly deferred to B11.2 |

## Operator-decision rationale

Per CLAUDE.md "Agent-Led Slices" durable rule:
> *"Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict."*

B9.2 is auth-adjacent (touches the My Account session revoke UX + adds a client-side MFA freshness gate). Although it doesn't add new auth routes or modify proxy code, the revoke flow is destructive from the operator's perspective (signs out other browsers/devices). Operator-gate per ledger row 61 is correct.

## What operator should confirm

1. **Client-side-only freshness gate is acceptable scope for B9.2.** The worker is explicit that server-side RFC 9470 step-up enforcement on `/v1/auth/session/revoke` belongs with B11.2 (or a separate proxy slice). For now, the gate is defense-in-depth at the UI layer; an attacker bypassing the client cannot bypass the bearer auth at the proxy, but they CAN call revoke directly with a stale `auth_time`. Operator should confirm this gap is acceptable until B11.2 lands.

2. **Mobile parity is intentionally untouched.** Mobile settings active-sessions section was NOT updated; B9.2 scopes to operator-web only. C-7 will handle mobile R1-pattern adaptive 2FA button parity after B9.2 + B9.3 land.

## Recommendation

**approve-for-merge.** The IA consolidation is clean:
- 4-card My Account matches the IA authority at `docs/_execution/lane_b_features/01_product_rule_and_ia.md:110-124`
- Active Sessions card uses existing routes (no proxy expansion)
- Current session correctly excluded from revoke (with empty-list and "This device" badge UX)
- Audit-log link on every card per IA spec
- Client-side freshness gate adds defense-in-depth without server-side scope creep
- 34/34 tests pass; dart analyze clean
- Cross-lane discipline preserved (no advisor_proxy or B11.2 touches)

If approved, I will merge + update the ledger (B9.2 → merged).

## Authority anchors verified

- `docs/_execution/lane_b_features/03_execution_slices.md:148-155` — Slice B9.2 spec (scope matches)
- `docs/_execution/lane_b_features/01_product_rule_and_ia.md:110-124` — 4-card IA spec (Profile/Security/MFA/Active Sessions + audit-log link)
- `docs/_indices/WAVE_EXECUTION_LEDGER.md:61` — B9.2 row, Gate=operator
- `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md:213-262` — 14-lens framework
- `tool/advisor_proxy/advisor_proxy.dart:8502-8508` — `/v1/auth/session/revoke` is bearer-auth only (confirms worker's cross-lane note)

## Findings

None blocking. One operator-decision item (acceptability of client-side-only freshness gate until B11.2 lands).

## Status

Awaiting operator approval.
