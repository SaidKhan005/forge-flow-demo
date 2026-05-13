# PR #507 Audit — B7.a Invite Hierarchy-Scope Fix

**Slice:** B7.a (Lane B — features)
**Owner:** Codex executor (was held while B3 merged; unblocked now)
**Branch:** `codex/b7-a-invite-scope-fix`
**Base:** `master` (no drift)
**Gate:** `operator` (auth-critical + audit-attribution + operator-facing UX)
**Size:** 601 additions / 8 deletions / 7 files / 747 diff lines
**Chunking:** light variant (<20 files, <5K LoC; tight spot-check given auth-critical)

## Pattern B compliance

Both audit tables present in PR body ✓.

## Verdict

**approve-for-merge subject to operator approval, with one cited material finding requiring orchestrator follow-up.**

## Executor spot-checks

| Check | Outcome |
|---|---|
| Operator-web pending invite Cancel CTA + plain-English modal | ✓ — `lib/operator_web/screens/members_screen.dart:493-515,1605-1624` |
| Cancel route DELETE preserved + idempotency-key flow | ✓ — `test/operator_web/services/web_team_users_gateway_test.dart:149,501-510` |
| Permission narrowed to `team.users.invite` (reset-only users cannot cancel) | ✓ — operator-web tests at `members_screen_test.dart:494,521` |
| `affected > 0` guard prevents audit emission on no-op revoke | ✓ — `repository_auth_operations_gateway.dart:540-549` (idempotent second revoke is silent) |
| Frozen-surface `lib/auth/permission_keys.dart` untouched | ✓ |
| Demo carve-out untouched | ✓ |
| No `audit_logs` UPDATE | ✓ — INSERT-only via `_audit` |
| 105 targeted tests pass per worker output | ✓ |

## Audit-table honesty observation (informational, not blocking)

Both worker and executor audit tables cite `lib/admin/services/members_admin_gateway.dart:783` ("Non-location admin invites omit location fields") as a *finding* delivered by this PR. **The conditional `if (scopeType == 'location') { … }` at that file:line was actually shipped on 2026-05-08 by commit `8a0441af` (Admin hierarchy overhaul merge), pre-dating this wave.** This PR adds *test assertions* that lock the existing pinning behavior (regression-prevention), but does not modify the gateway production code. Audit tables read as if production code shipped here. Tests-as-regression-locks are a valid pattern; the audit-table wording just over-attributes.

Net effect: actual code-side changes in this PR are
1. operator-web Cancel CTA + permission narrow (`members_screen.dart`),
2. audit event rename (`repository_auth_operations_gateway.dart:545` flip from `'auth.invite_revoked'` → `'invite.cancel'`),
3. five test files adding 504 lines of coverage.

## MATERIAL FINDING — audit event rename creates consumer drift

**Issue:** PR renames emitted event from `'auth.invite_revoked'` → `'invite.cancel'` at `lib/services/auth/repository_auth_operations_gateway.dart:545`. **Three consumer locations still reference the OLD name:**

| File:line | What it does | Effect post-merge |
|---|---|---|
| `lib/operator_web/services/web_team_audit_log_gateway.dart:257-258` | switch case mapping `'auth.invite_revoked'` → display label `"Invite revoked"` | New `invite.cancel` events fall through to default-humanizer ("Invite cancel" or similar generic string), not a curated label |
| `lib/services/auth/auth_operations_gateway.dart:1102-1103` | same switch in the mobile audit-log label resolver | same fallthrough |
| `test/operator_web/screens/audit_log_screen_test.dart:269` | mobile-parity test mapping `'auth.invite_revoked'` → `"Invite revoked"` | test still passes (no `invite.cancel` mapping referenced) but parity assertion is now incomplete |

**Authority anchor:** UX writing standard (`memory/project_ux_writing_standard.md`) — every operator-facing label trains; falling back to a humanized raw event_type is the opposite. Slice doc B7.a literal: "Add invite.cancel audit event *if missing*" — ambiguous between "ADD as a new event" vs "RENAME existing". Worker chose RENAME; consumers must follow.

**Proposed orchestrator-fix (Option A — preferred):** add `case 'invite.cancel': return 'Invite cancelled';` to both switches; update the test mapping to include both names (historic + current). Three single-line additions in 2 files + 1 test line. Low-risk, defensive (handles both event names so historic rows keep their nice label too). Authority anchor cited above.

**Alternative (Option B):** revert the rename and emit BOTH events (or just keep `auth.invite_revoked`). More invasive; would back out part of the worker's commit.

## Cross-lane note

None.

## Recommendation to operator

1. **Approve PR #507** — Cancel CTA + idempotent revoke + tests are clean, auth-critical discipline preserved.
2. **Authorize orchestrator-fix follow-up** to apply Option A (add `'invite.cancel'` case statements to both consumer switches + test mapping). I have the fix ready.

If operator prefers Option B (revert rename), I'll send PR #507 back to Codex with that specific instruction.

## Next action

Escalate to operator. Hold the orchestrator-fix follow-up until operator decides between Option A / Option B / approve-as-is.
