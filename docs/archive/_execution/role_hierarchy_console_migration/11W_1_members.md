# Codex Execution Prompt — `11W.1` Members

## Block 1 — Human Context

Plain English: Migrate the mobile Settings → Team list + invite flow into the Operator Web Console at `/members`. Operator senior roles can list, filter, suspend/reactivate/soft-delete/reset-password/reset-MFA/force-logout team members, and invite new ones. Reuses the existing pure-logic team controllers; new HTTP gateway under `lib/operator_web/services/` because the mobile gateway uses `dart:io` and is not web-compatible.

Lane: `11W.1` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11W-1-members` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` § `11W.1` Members
- `docs/contracts/slice_runtime_acceptance_contract.md`

Current issue:
- Operators have no web console for team management. Mobile Team Settings exists but is too thin for desktop bulk admin work. This slice ships the web parity surface against existing Phase 9 self-service routes.

Human prerequisites:
- Setup/access needed: none — Phase 9 backend routes (`/v1/auth/team/users`, `/v1/auth/team/invites`) are live on staging.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build the `11W.1` Members surface end-to-end, demo + live, against the existing Phase 9 self-service routes. Bind every behavior to the parity contract; no scope drift.

Files to modify:
- `lib/operator_web/services/web_team_users_gateway.dart` — NEW. Web `package:http` impl of `AuthOperationsGateway` (or a focused `WebTeamUsersGateway` interface if the existing abstract is too broad — prefer reusing the existing interface if at all possible). Bearer token from `OperatorWebAuthSource.currentSession.idToken`. 30s timeout via `Duration(seconds: 30)`; do NOT import `admin_http_timeout.dart` (admin-side).
- `lib/operator_web/services/demo_team_fixtures.dart` — NEW. Shared fixture data set per parity contract § Demo-mode fixtures (1 demo operator, 3 locations, 2 org-units, 6 demo users, 1 custom role, 4 sessions, ~50 audit entries). This file is created by `11W.1` and extended by `11W.2`–`11W.6`.
- `lib/operator_web/services/demo_web_team_users_gateway.dart` — NEW. In-memory impl of the gateway interface backed by `demo_team_fixtures.dart`.
- `lib/operator_web/screens/members_screen.dart` — NEW. Desktop layout. Filter row at top (status / role / location / mfa_enrolled / search). Table body with sortable columns (last_active_at default DESC, then email ASC). Per-row action menu. Pagination cursor.
- `lib/operator_web/screens/invite_member_dialog.dart` — NEW. Modal with form (email, display_name, role_key dropdown, primary_location_id dropdown, optional org_unit_id, optional welcome_note). Idempotency key minted in dialog state, propagated through command → gateway.
- `lib/operator_web/router/operator_web_router.dart` — EDIT. Add `kOperatorWebNavMembers` constant + nav item (after `kOperatorWebNavAccount`, before `kOperatorWebNavVendorConnections`). Route the nav id to `MembersScreen`.
- `lib/main_operator_web.dart` — EDIT. Add `_resolveTeamUsersGateway(authBinding.authClient)` matching the 11A pattern (`_resolveOperatorLocationGateway`). Pass through to the app via a new scope (or extend the existing scope mechanism). The gateway is null in demo mode; the route falls back to `DemoWebTeamUsersGateway`.
- `test/operator_web/members_screen_test.dart` — NEW. Widget tests covering: filter set renders, validation copy locked per parity contract, permission gate (floor manager sees no row actions), idempotency key flows from dialog → gateway, demo fixtures render correctly.
- `test/operator_web/web_team_users_gateway_test.dart` — NEW. Unit tests covering: bearer-token attach, idempotency-key propagation, error-code mapping (`permission_denied` / `validation_failed` / `not_found`).
- `docs/_walkthroughs/11W.1.md` — NEW. Click-path walkthrough at the `7.58.UX.5` bar.

Files to leave alone:
- `lib/services/team/*.dart` — pure-logic controllers reused verbatim. Do NOT modify.
- `lib/screens/settings/*.dart` — mobile sections reused as reference. Do NOT modify.
- `lib/services/auth/proxy_auth_operations_gateway.dart` — mobile-only (uses `dart:io`). Do NOT import from web entry.
- `tool/advisor_proxy/advisor_proxy.dart` — backend route handlers exist. Do NOT modify.
- `lib/main_admin.dart` — admin entry point. Owned by `11A.12`.

Hard constraints:
- Do not update trackers.
- Do not commit unless explicitly asked.
- Stay inside scope — do NOT touch `11W.2`–`11W.6` files. The Members screen does NOT navigate to Roles / Hierarchy / Sessions / Audit / Security; those nav items land in their own slices.
- Do not import `dart:io` or `sqflite` from any file in this slice.
- Do not mint idempotency keys inside the gateway; mint in the dialog state.
- Do not paraphrase validation copy — use the locked strings from the parity contract verbatim.
- Do not introduce new backend routes; if you think you need one, STOP and report.
- For live work, run name-only preflight first and stop with BLOCKED on miss.

Implementation tasks:
1. Read `lib/screens/settings/settings_data_sections.dart` Team Settings rendering helpers + `lib/services/team/team_users_list_controller.dart` + `lib/services/team/team_invite_form_controller.dart` + `lib/services/team/team_scope_visibility_policy.dart`. Confirm the controllers and policy compile against `package:flutter/foundation.dart` only (web-safe).
2. Inspect `lib/admin/services/operator_location_admin_gateway.dart` to copy the gateway pattern (HTTP impl + in-memory demo impl + injectable bearer-token provider + injectable timeout). Replicate at `lib/operator_web/services/web_team_users_gateway.dart`.
3. Read `tool/advisor_proxy/advisor_proxy.dart` route handlers for `adminAuthUsersPath`, `adminAuthInvitesPath`, and the operator self-service equivalents (search for `/v1/auth/team`). Confirm route shapes (POST/PATCH/DELETE bodies, response shapes, error codes). Bind your gateway to those exact shapes.
4. Build `web_team_users_gateway.dart` + `demo_web_team_users_gateway.dart` against the abstract interface. Reuse `lib/services/auth/auth_operations_gateway.dart` if its surface area fits; if it's too broad, define a narrower `WebTeamUsersGateway` interface in the same file and document why.
5. Build `demo_team_fixtures.dart` per the parity contract § Demo-mode fixtures shape.
6. Build `members_screen.dart` desktop layout reusing the existing `TeamUsersListController` for filter state. Wire row-action menu items to the gateway. Permission gate: hide row actions per the parity contract permission cheat sheet (e.g., floor manager sees no row actions).
7. Build `invite_member_dialog.dart` reusing `TeamInviteFormController`. Validation copy from parity contract verbatim. Idempotency key minted as `'11W.1.invite-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xffff)}'` (matches 11A.1 pattern style).
8. Wire nav in `operator_web_router.dart`. Add the `kOperatorWebNavMembers` constant + nav item with `Icons.people_outline`. Insert position: after Account, before Vendor connections.
9. Wire gateway resolver in `main_operator_web.dart` matching the 11A.0/11A.1 pattern. Demo mode returns null; the route falls back to `DemoWebTeamUsersGateway` constructed against `demo_team_fixtures.dart`.
10. Write tests per the Files to modify list.
11. Write the walkthrough at `docs/_walkthroughs/11W.1.md` with numbered steps, named widgets (`Key`s), expected visual states, and a demo-mode start condition.
12. Verify locally: `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none` succeeds.

Required tests:
- `flutter analyze --fatal-infos lib/operator_web/services/web_team_users_gateway.dart lib/operator_web/services/demo_web_team_users_gateway.dart lib/operator_web/services/demo_team_fixtures.dart lib/operator_web/screens/members_screen.dart lib/operator_web/screens/invite_member_dialog.dart lib/main_operator_web.dart test/operator_web/members_screen_test.dart test/operator_web/web_team_users_gateway_test.dart`
- `flutter test test/operator_web/members_screen_test.dart test/operator_web/web_team_users_gateway_test.dart`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] Parity contract § Members + Invites filter set rendered exactly: status / role_key / location / mfa_enrolled / search.
- [ ] Parity contract § Members + Invites validation copy locked verbatim in `invite_member_dialog.dart`.
- [ ] Parity contract § Idempotency keys: minted in dialog state, propagated unchanged through gateway, single mint per user action verified by widget test.
- [ ] Parity contract § Web-compatibility rules: no `dart:io` / `sqflite` imports reachable from `lib/main_operator_web.dart`; web build succeeds.
- [ ] Parity contract § Permission gate cheat sheet: floor manager renders read-only members list (no row actions); operator_admin / operator_owner render full row actions.
- [ ] Parity contract § Demo-mode fixtures: `demo_team_fixtures.dart` shipped with the locked shape (1 op, 3 locs, 2 org-units, 6 users, 1 custom role, 4 sessions, ~50 audit entries).
- [ ] `11W.1` walkthrough at `docs/_walkthroughs/11W.1.md` matches the `7.58.UX.5` click-path bar.
- [ ] No tracker changes, no commits, no scope drift into `11W.2`–`11W.6`.
- [ ] Pair with `11A.12` — both must hit ACCEPT before either merges per parity contract.

Report using the standard execution report.
