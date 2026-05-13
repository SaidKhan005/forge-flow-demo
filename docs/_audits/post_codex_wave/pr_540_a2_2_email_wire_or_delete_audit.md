# PR #540 Audit — A2.2 Email Pipeline Wire-or-Delete

**Slice:** A2.2 (Lane A — code health)
**Owner:** Codex executor
**Branch:** `codex/a2-2-email-wire-delete`
**Base:** `master`
**Gate:** `operator` per ledger + explicit `[operator-approval-required]` title prefix (email is operator-visible behavior)
**Size:** 55 additions / 100 deletions / 7 files
**Chunking:** light variant (small surface, focused delete pass)
**Dependency:** A2.1 merged ✓

## Pattern B compliance

PR body contains BOTH the worker self-audit and the executor independent audit tables. All 14 lenses populated with file:line citations on most rows. Worker discloses a post-send-back state on Lens 14 ("Clean after send-back: inventory and A2 audit anchor updated"). Acceptable Pattern B compliance.

## Verdict

**approve-pending-operator** — escalating per Gate=operator + email is operator-visible behavior. Audit clean; gate is the operator-visible-behavior policy.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Worker's "no runtime callers" claim**: outside the registry definitions in `email_template_renderer.dart`, nothing in `lib/`, `tool/`, or `test/` references the deleted IDs | ✓ — Grep for `EmailTemplateIds\.(operatorAdminInvite\|passwordResetRequest)\|operator_admin_invite\.md\|password_reset_request\.md` returns only the registry entries themselves at `lib/services/email/email_template_renderer.dart:179` and `:181` (the subject map being deleted) plus the renderer test at `test/services/email/email_template_renderer_test.dart:134, 140, 156` (the test currently asserts the registry contents; PR updates it). Zero production consumers. Wire-or-delete decision is correct |
| **Firebase wires the live flows** — password reset + admin invite | ✓ — `Grep "FirebaseAuth.*sendPasswordResetEmail\|sendPasswordResetEmail\|action-link"` returns 6 files in `lib/services/auth/`: `repository_auth_operations_gateway.dart`, `proxy_password_reset_gateway.dart`, `password_reset_request_gateway.dart`, `firebase_auth_runtime_bindings.dart`, `firebase_auth_client_sdk.dart`, `firebase_admin_auth_client.dart`. Firebase Identity Platform action-link email is the live path |
| **2 markdown templates deleted, 2 subject-registry entries removed, 1 stale B3 hook TODO comment cleaned, 2 audit-doc anchors updated** | ✓ — diff name-status: `tool/advisor_proxy/email_templates/operator_admin_invite.md` (deleted), `tool/advisor_proxy/email_templates/password_reset_request.md` (deleted), `lib/services/email/email_template_renderer.dart` (registry entries removed), `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart` (B3 TODO comment cleanup), `docs/_audits/code_health/c_email_notification_scenario_inventory.md` + `a2_scaffold_inventory.md` (audit-doc updates) |
| **Test coverage updated** — renderer test asserts 10 templates and the deleted IDs are absent | ✓ — `test/services/email/email_template_renderer_test.dart:270-273` per worker disclosure; test pass disclosed: `flutter test test/services/email/email_template_renderer_test.dart ... → 21 passed` |
| **Admin SendGrid test fixture preserved** (uses `operator_invite_first_admin` directly as a connectivity probe) | ✓ — worker explicitly preserves `operator_invite_first_admin.md` and its `EmailTemplateIds.operatorInviteFirstAdmin` because `tool/advisor_proxy/admin_email_routes.dart:229, :246` uses it. Worker honored the "wire" half of wire-or-delete |
| **Cross-lane discipline** — Codex executor explicitly did NOT touch Claude-owned Lane C planning docs even though they "discuss a broader draft option that would delete `operator_invite_first_admin`" | ✓ — disclosed in PR body cross-lane note; lane discipline preserved |
| **`dart analyze` clean** on touched Dart files | ✓ — disclosed |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **Pre-push hooks clean, no `--no-verify`** | ✓ — `postgres_import_lint` ran clean |
| **A2.2 doctrine alignment** | ✓ — `lib/services/email/email_template_renderer.dart` registry shrinks from 12 entries to 10; templates left in repo all have wired senders (admin invite via `admin_email_routes`, vendor alerts, MFA notice, etc.). Worker's "evidence matches implementation" framing is the right wire-or-delete outcome |

## Operator-decision rationale

Per CLAUDE.md "Agent-Led Slices" durable rule:
> *"Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict."*

A2.2 isn't directly auth/RLS/schema/proxy, but emails are **operator-visible behavior** (password reset emails, admin invite emails). The slice is correctly tagged `Gate=operator` because:

1. Operator should confirm: the dormant templates being removed are NOT shadow emails an operator might have expected to see. (They're not — the live flows use Firebase action-link emails. The templates were leftover from an earlier design.)
2. The template catalog is operator-facing in support/audit contexts (`c_email_notification_scenario_inventory.md` is the inventory). Removing entries from the catalog needs an operator-aligned story.

## Recommendation

**approve-for-merge.** The wire-or-delete logic is clean:
- Both deleted templates are confirmed dormant (no production consumers, Firebase wires the live flows)
- Operator-visible behavior is unchanged — same emails reach users via the same Firebase path
- Catalog now matches implementation (worker's "evidence matches implementation" framing)
- Tests are updated; 21/21 pass
- Cross-lane discipline preserved (Codex didn't touch Claude's planning docs)

If approved, I will merge + update the ledger (A2.2 → merged).

## Authority anchors verified

- `docs/_execution/lane_a_code_health/03_execution_slices.md` "Slice A2.2 — Email Pipeline Wire-Or-Delete" (scope matches)
- `docs/_audits/code_health/a2_scaffold_inventory.md` (audit anchor that prompted the slice)
- `docs/_audits/code_health/c_email_notification_scenario_inventory.md` (Lane C inventory cross-reference)
- `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` Lens 14 (docs hygiene)

## Findings

None blocking.

## Status

Awaiting operator approval.
