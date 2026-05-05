# Codex Execution Prompt — `11A.12` Members + Invites Parity (Cross-Operator)

## Block 1 — Human Context

Plain English: F&F Operations Console gets cross-operator member view + invite admin. F&F super-admin or `ff_support` picks an operator, sees that operator's member list with the same filter set as `11W.1` Members, and can perform support actions including soft-delete restore and role grant overrides. Every write writes the F&F admin's UID to `created_by/updated_by` and includes a mandatory `admin_reason`.

Lane: `11A.12` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11A-12-members-admin` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` § `11A.12` Members + Invites parity (cross-operator)
- `docs/contracts/auth_permission_key_catalog.md` § `admin.*`

Current issue:
- F&F support has no console view of operator members. Today escalations require shell access. This slice ships the cross-operator parity admin surface.

Human prerequisites:
- Setup/access needed: none — `/v1/admin/auth/users`, `/v1/admin/auth/invites`, `/v1/admin/auth/role-grants` routes are live with `forge_admin` Postgres role grants.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build `11A.12` Members + Invites parity end-to-end against existing `/v1/admin/auth/*` routes.

Files to modify:
- `lib/admin/services/members_admin_gateway.dart` — NEW. `package:http`-backed admin gateway. List operators with member counts (reuses `OperatorPickerScreen` flow from existing `lib/admin/screens/operator_picker_screen.dart`). For a chosen operator: list members with the same filter set as `11W.1`, suspend / reactivate / soft-delete / restore-soft-deleted / reset-password / reset-MFA / force-logout / override-role-grant. Every mutation requires `adminReason` (mandatory free-form string).
- `lib/admin/services/demo_members_admin_gateway.dart` — NEW. In-memory backed by an admin-side fixture set (3 demo operators each with the same shape as the operator-web fixtures, so cross-operator UI is exercisable).
- `lib/admin/screens/members_admin_screen.dart` — NEW. After operator-picker, mirror layout of `11W.1` Members but with admin actions. Banner at top: "Acting on behalf of <operator name> — every action is audited." `Admin reason` field required for every write modal.
- `lib/admin/screens/invite_member_admin_dialog.dart` — NEW. Admin-side invite modal. Same fields as `11W.1` invite dialog plus `admin_reason`.
- `lib/admin/admin_routes.dart` — EDIT. Add route `kAdminRouteMembers` and wire to `MembersAdminScreen`.
- `lib/main_admin.dart` — EDIT. Add `_resolveMembersAdminGateway` resolver matching the existing `_resolveOperatorLocationGateway` pattern. Pass into `AdminConsoleServicesScope`.
- `test/admin/members_admin_screen_test.dart` — NEW. Widget tests covering: operator-picker → members list flow, filter set parity with `11W.1`, `admin_reason` required for every write modal (form rejects submit without it), audit-row shape on demo gateway includes `actor_kind='forge_admin'` + `admin_reason`, restore-soft-deleted action visible only here (not on `11W.1`).
- `test/admin/members_admin_gateway_test.dart` — NEW. Unit tests for HTTP shapes + bearer + idempotency + error mapping + admin_reason header propagation.
- `docs/_walkthroughs/11A.12.md` — NEW.

Files to leave alone:
- `lib/admin/screens/operator_picker_screen.dart` — reused as-is. Do not modify.
- `lib/admin/services/operator_location_admin_gateway.dart` — 11A.1 surface; copy the gateway pattern but do not modify.
- `tool/advisor_proxy/advisor_proxy.dart` — backend exists.

Hard constraints:
- Standard set.
- `admin_reason` field is mandatory on every mutation; both client validation AND server reject without it.
- F&F admin writes audit with `actor_kind='forge_admin'` + the reason; do NOT impersonate operator user.
- Idempotency keys minted in dialog state.
- For live work, name-only preflight first.

Implementation tasks:
1. Read `lib/admin/services/operator_location_admin_gateway.dart` to copy the gateway pattern (HTTP + in-memory + bearer + timeout).
2. Read `lib/admin/screens/operator_picker_screen.dart` to wire the picker → screen handoff.
3. Read backend handlers for `adminAuthUsersPath`, `adminAuthInvitesPath`, `adminAuthRoleGrantsPath` route shapes including the `admin_reason` requirement and the response shape for `forge_admin`-actor writes.
4. Build admin gateway + demo gateway.
5. Build admin screen + invite dialog. Reuse the row + filter render helpers from `11W.1` if a shared widget exists; otherwise re-render here.
6. Wire route + gateway resolver in `lib/main_admin.dart` and `lib/admin/admin_routes.dart`.
7. Tests + walkthrough.
8. Local web build: `flutter build web -t lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true --pwa-strategy=none`.

Required tests:
- `flutter analyze --fatal-infos <touched paths>`
- `flutter test test/admin/members_admin_screen_test.dart test/admin/members_admin_gateway_test.dart`
- `flutter build web -t lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] Parity contract § Members + Invites filter set + row actions + admin-only restore/override.
- [ ] Parity contract § Audit-row shape: every mutation writes `actor_kind='forge_admin'` + `admin_reason`.
- [ ] Parity contract § Idempotency keys: minted in dialog state.
- [ ] Operator-picker handoff works end-to-end in demo mode.
- [ ] Admin web build succeeds.
- [ ] `11A.12` walkthrough at `docs/_walkthroughs/11A.12.md` at the `7.58.UX.5` bar.
- [ ] No tracker changes, no commits, no scope drift.
- [ ] Pair with `11W.1` — both must hit ACCEPT before either merges per parity contract.

Report using the standard execution report.
