# Codex Execution Prompt — `11A.13` Roles + Hierarchy + Sessions Inspect (Cross-Operator)

## Block 1 — Human Context

Plain English: F&F Operations Console gets a three-tab cross-operator inspect surface. After picking an operator, F&F admin can review that operator's role catalog (seeded + custom; edit gated on `admin.roles.edit_seeded` for seeded), org hierarchy (read-mostly, audited move), and active sessions (with cross-actor force-logout). Note `11A.1` already covers location admin edits; this slice adds the org-tree visualization and Roles + Sessions tabs.

Lane: `11A.13` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11A-13-roles-hierarchy-sessions` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` § `11A.13` Roles + Hierarchy + Sessions inspect (cross-operator)
- `docs/contracts/auth_permission_key_catalog.md` § `admin.*`

Current issue:
- F&F support has no console view of operator roles + hierarchy + sessions. Today escalations require shell access. This slice ships the cross-operator inspect surface as a single 3-tab screen.

Human prerequisites:
- Setup/access needed: none — `/v1/admin/auth/roles?operator_id=...`, `/v1/admin/auth/org-units?operator_id=...`, `/v1/admin/auth/sessions?operator_id=...` routes exist.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build the `11A.13` 3-tab inspect surface end-to-end.

Files to modify:
- `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart` — NEW. Single gateway covering all three tabs (one HTTP layer, three logical surfaces). List operator's roles (seeded + custom). Edit seeded role permissions (gated on `admin.roles.edit_seeded`, MFA-required). Create / patch / delete custom role. List operator's org-units + locations. Move org-unit / location (audited). List operator's active sessions across every user. Force-logout session (gated on `admin.session.force_logout`). Every mutation requires `adminReason`.
- `lib/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart` — NEW. Backed by the admin-side fixture set extended from `11A.12`.
- `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart` — NEW. After operator-picker, three tabs: `Roles` / `Hierarchy` / `Sessions`. Each tab mirrors the corresponding `11W.x` screen layout with admin actions added. Banner: "Acting on behalf of <operator name>." `Admin reason` modal step before every mutation.
- `lib/admin/admin_routes.dart` — EDIT. Add route `kAdminRouteRolesHierarchySessions` and wire to the screen.
- `lib/main_admin.dart` — EDIT. Add `_resolveRolesHierarchySessionsAdminGateway` resolver.
- `test/admin/roles_hierarchy_sessions_admin_screen_test.dart` — NEW. Widget tests covering: 3-tab navigation, seeded-role read-only without `admin.roles.edit_seeded`, hierarchy move requires `admin_reason`, force-logout requires `admin_reason`, force-logout self returns `cannot_revoke_self` mapping.
- `test/admin/roles_hierarchy_sessions_admin_gateway_test.dart` — NEW. Unit tests for HTTP shapes across all three surfaces.
- `docs/_walkthroughs/11A.13.md` — NEW.

Files to leave alone:
- `lib/admin/screens/operator_location_admin_screen.dart` — `11A.1` surface; do not modify (location edits stay there).
- `lib/admin/screens/operator_picker_screen.dart` — reused.
- `tool/advisor_proxy/advisor_proxy.dart` — backend exists.

Hard constraints:
- Standard set.
- `admin_reason` mandatory on every mutation.
- MFA-required on `admin.roles.edit_seeded` mutations (server enforces; client surfaces step-up).
- Single-screen 3-tab pattern, not 3 separate routes.
- For live work, name-only preflight first.

Implementation tasks:
1. Read the three peer 11W prompts to understand the surface shape parity expects.
2. Read backend handlers for `adminAuthRolesPath`, `adminAuthOrgUnitsPath`, and the admin sessions route. Confirm the `?operator_id=...` query parameter shape and `admin_reason` requirement.
3. Read existing `lib/admin/services/operator_location_admin_gateway.dart` for the gateway pattern (HTTP + in-memory + bearer + idempotency).
4. Build the consolidated gateway — all three logical surfaces share a bearer + base URI + timeout, but each surface has its own command set. Document the boundary in the file header.
5. Build the screen + 3 tabs. Reuse row/render widgets from `11W.2`/`11W.3`/`11W.4` if a shared widget location exists; otherwise re-render here. The `Admin reason` modal step is shared across all three tabs.
6. Wire route + resolver.
7. Tests + walkthrough.
8. Local web build.

Required tests:
- `flutter analyze --fatal-infos <touched paths>`
- `flutter test test/admin/roles_hierarchy_sessions_admin_screen_test.dart test/admin/roles_hierarchy_sessions_admin_gateway_test.dart`
- `flutter build web -t lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] Parity contract § Roles + Permission Explainer (admin-side: edit-seeded gated on `admin.roles.edit_seeded` + MFA).
- [ ] Parity contract § Hierarchy (admin-side: move audited with `admin_reason`).
- [ ] Parity contract § Sessions (admin-side: force-logout gated, `cannot_revoke_self` mapping).
- [ ] 3-tab single-route pattern.
- [ ] `admin_reason` mandatory on every mutation; client form rejects without it.
- [ ] Admin web build succeeds.
- [ ] `11A.13` walkthrough at `docs/_walkthroughs/11A.13.md`.
- [ ] No tracker changes, no commits, no scope drift into `11A.1` location-admin territory.
- [ ] Pair with `11W.2` + `11W.3` + `11W.4` — all four must hit ACCEPT before any merges per parity contract.

Report using the standard execution report.
