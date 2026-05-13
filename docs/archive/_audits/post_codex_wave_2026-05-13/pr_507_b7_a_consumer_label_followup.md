# PR #507 Follow-Up — B7.a Consumer Label Fix (Option A)

**Slice:** B7.a follow-up (orchestrator-fix-by-default)
**Authority anchor:** `docs/_audits/post_codex_wave/pr_507_b7_a_invite_scope_fix_audit.md` Option A; UX writing standard (`memory/project_ux_writing_standard.md`); operator approve-all 2026-05-12 (Option A explicit).
**Gate:** `auto` (UX label only; no schema/proxy/auth touch)

## What changed

PR #507 renamed the emitted audit event `'auth.invite_revoked'` → `'invite.cancel'` but left three consumer locations referencing the old name. This follow-up adds the missing `case 'invite.cancel'` to both display-label switches and updates the parity test mapping. Both the legacy `'auth.invite_revoked'` and the new `'invite.cancel'` now map to the operator-facing label **"Invite cancelled"** so historic audit rows keep their nice label and new ones get it too.

## Files touched

| File | Change |
|---|---|
| `lib/operator_web/services/web_team_audit_log_gateway.dart` | `'auth.invite_revoked'` → `"Invite cancelled"`; add `case 'invite.cancel'` → `"Invite cancelled"` |
| `lib/services/auth/auth_operations_gateway.dart` | same pattern (mobile parity label resolver) |
| `test/operator_web/screens/audit_log_screen_test.dart` | parity-mapping fixture updated: `'auth.invite_revoked'` → `'Invite cancelled'`; new entry `'invite.cancel'` → `'Invite cancelled'` |

## Why "Invite cancelled" (not "Invite revoked")

The slice doc B7.a chose "cancel" as the operator-facing verb (Cancel CTA, `invite.cancel` event, `'Cancel invite'` modal title). The label should match that vocabulary. UX writing standard requires single-vocabulary surfaces — every place the operator sees this action should say "cancel", not mix "revoke" / "cancel". Mapping the legacy event to "Invite cancelled" too keeps historic rows consistent with what the operator now sees in the UI.

## Verification

- `dart analyze lib/operator_web/services/web_team_audit_log_gateway.dart lib/services/auth/auth_operations_gateway.dart test/operator_web/screens/audit_log_screen_test.dart` → **No issues found.**
- `flutter test test/operator_web/screens/audit_log_screen_test.dart` → **12/12 pass** (includes the parity contract test `auth.* action labels match mobile AuthEventLabels mappings`).
- `flutter test test/services/auth/repository_auth_operations_gateway_test.dart` → **1/1 pass** (the new `invite.cancel` emitter test PR #507 added).

## Verdict

**approve-for-merge** (orchestrator self-merge per audit-first-then-pr-then-merge doctrine + operator pre-approval of Option A).
