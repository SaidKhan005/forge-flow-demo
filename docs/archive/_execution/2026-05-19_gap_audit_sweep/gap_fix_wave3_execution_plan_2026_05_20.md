# Gap Fix Wave 3 Execution Plan - 2026-05-20

## Goal

Close the next two executable audit gaps without expanding product scope:

- Business Timing routes must only accept writes the server actually applies.
- Admin Observability retry rows must say whether a retry is ready, waiting, claimed, or dead-lettered.

## Gap 1 - Business Timing Route Truth

App example:

- If Operator Web sends "move this profile to another location" or "change this profile timezone" in a profile PATCH, the current route can accept the request even though the repository does not apply those fields.
- That makes the app look like it saved a setting when it did not.

Fix plan:

- Keep profile create behavior as-is because create still needs the full profile envelope.
- On operator profile PATCH, reject immutable fields instead of silently accepting them:
  - `scopeKind`
  - `scopeId`
  - `ianaTimezone`
- On admin profile PATCH, do the same, because admin uses the same repository gateway.
- Leave real timezone edits on the dedicated location/account override routes.
- Add route tests so future changes cannot reintroduce the silent-save behavior.

## Gap 2 - Projection Retry Claimability Labels

App example:

- Admin Observability shows recent retry rows.
- A row can be pending but not ready yet if `next_attempt_at` is in the future.
- A row can be running/claimed and should not look like support can manually pick it up.

Fix plan:

- Add compact server fields that describe retry state in plain terms.
- Mark a row claimable only when it is pending or a stale running row, not completed, not dead-lettered, and due now.
- Show a small admin label such as Ready, Waiting, Claimed, Dead-lettered, or Completed.
- Keep the screen compact; this is an admin truth label, not a new operator warning workflow.
- Update tests and demo data.

## Product Decisions Intentionally Left Alone

- Mobile Covers Setup remains simple usage; full setup stays in Operator Web.
- Default provenance labels stay deferred to avoid clutter.
- Operator-facing retry warnings stay deferred until the product wants that surface.

## Execution Method

- Main checkout stays on `master`.
- Work happens in `C:\Git Local Repos\forge_flow_demo\.codex_worktrees\gap-fix-wave3`.
- I own the plan, Business Timing route truth, integration, verification, PR, gate, merge, and landed verification.
- Worker A owns projection retry claimability labeling files only.
