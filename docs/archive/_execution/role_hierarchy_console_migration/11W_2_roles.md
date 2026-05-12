# Codex Execution Prompt — `11W.2` Roles + Permission Explainer + Custom-Role Builder

## Block 1 — Human Context

Plain English: Migrate the mobile Settings → Roles + Permission Explainer + custom-role editor into the Operator Web Console at `/roles`. Operator senior roles can view seeded + custom roles, browse the Permission Explainer (catalog of 97 keys across 9 categories), and build custom operator-scoped roles by selecting permissions from the frozen catalog.

Lane: `11W.2` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11W-2-roles` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/contracts/auth_permission_key_catalog.md` (frozen permission catalog — render verbatim)
- `docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` § `11W.2` Roles

Current issue:
- Operators have no web surface for role management. Mobile Roles screen exists but is too thin for desktop multi-role custom-role design work. This slice ships the web parity surface.

Human prerequisites:
- Setup/access needed: none — Phase 9 backend routes (`/v1/auth/team/roles`, `/v1/auth/team/role-grants`) are live.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build the `11W.2` Roles surface end-to-end against existing Phase 9 self-service routes. Bind every behavior to the parity contract; no scope drift.

Files to modify:
- `lib/operator_web/services/web_team_roles_gateway.dart` — NEW. `package:http`-backed HTTP gateway for `/v1/auth/team/roles` + `/v1/auth/team/role-grants` (list seeded + custom roles for current operator, create custom role, patch custom role, delete custom role, assign role grant, revoke role grant). Bearer token from auth source.
- `lib/operator_web/services/demo_web_team_roles_gateway.dart` — NEW. In-memory impl backed by `lib/operator_web/services/demo_team_fixtures.dart` (extends fixtures shipped by `11W.1`).
- `lib/operator_web/screens/roles_screen.dart` — NEW. Two-pane layout: left = role list (seeded badge + custom badge), right = role detail (permissions assigned, members assigned). Top bar: `Create custom role` button gated on `team.roles.create_custom`.
- `lib/operator_web/screens/custom_role_editor_screen.dart` — NEW. Full-screen editor for create + patch flows. Form: name + description + permission picker (multi-select tree). Idempotency key minted in screen state.
- `lib/operator_web/screens/permission_explainer_screen.dart` — NEW. Read-only catalog view. Renders all 9 categories in the locked order from the parity contract (`product.*` → `forgeflow.*` → `barrio.*` → `admin.*` → `team.*` → `billing.*` → `integration.*` → `integrations.*` → `workflow.*`). Description copy verbatim from `docs/contracts/auth_permission_key_catalog.md` table. MFA-required keys render with a 🔒 chip + tooltip "Requires multi-factor authentication."
- `lib/operator_web/widgets/permission_picker_tree.dart` — NEW. Multi-select tree widget reused by both the custom-role editor and the explainer (in read-only mode for the explainer).
- `lib/operator_web/router/operator_web_router.dart` — EDIT. Add `kOperatorWebNavRoles` constant + nav item (after Members, before Hierarchy/Sessions/Audit/Security as those land). Add sub-routes for `/roles/explainer` and `/roles/custom/:id?`.
- `lib/main_operator_web.dart` — EDIT. Add `_resolveTeamRolesGateway` resolver matching the 11A.1 pattern.
- `test/operator_web/roles_screen_test.dart` — NEW. Widget tests covering: seeded roles render read-only (no edit affordance), custom-role create flow, permission gate (operator_manager sees no `Create custom role` button), MFA chip rendered for `requires_mfa=true` keys.
- `test/operator_web/permission_explainer_screen_test.dart` — NEW. Widget tests covering: 9 categories in locked order, every catalog key from `permission_keys.dart` `PermissionKeys.all` rendered exactly once, description text matches catalog source.
- `test/operator_web/web_team_roles_gateway_test.dart` — NEW. Unit tests covering: HTTP shape, idempotency, error mapping, frozen-catalog rejection (`validation_failed/permission_key_unknown` when client-side somehow submits an unknown key).
- `docs/_walkthroughs/11W.2.md` — NEW.

Files to leave alone:
- `lib/auth/permission_keys.dart` — frozen constants. Read but do not modify.
- `db/migrations/` — no migration in this slice.
- `lib/screens/settings/settings_role_editor.dart`, `settings_custom_roles_section.dart`, `settings_permission_explainer.dart` — mobile sections reused as reference.

Hard constraints:
- Do not update trackers.
- Do not commit unless explicitly asked.
- Stay inside scope.
- Do not paraphrase any catalog `description` text — verbatim or fix the catalog source.
- Do not import `dart:io` / `sqflite`.
- Do not introduce new permission keys; if you think you need one, STOP and report.
- Do not introduce new backend routes.
- For live work, run name-only preflight first.

Implementation tasks:
1. Read `lib/screens/settings/settings_permission_explainer.dart` + `settings_custom_roles_section.dart` + `settings_role_editor.dart` to understand the mobile rendering pattern.
2. Read `lib/auth/permission_keys.dart` `PermissionKeys.all` set + `requiresMfa` set. Confirm count matches the catalog (97 keys, 7 MFA-required).
3. Read `docs/contracts/auth_permission_key_catalog.md` § Categories to extract the locked render order + description text. Plan the explainer renderer to read from a single source of truth — propose either (a) parsing the markdown at build-time into a generated Dart constant, or (b) hand-mirrored Dart constants kept in sync via a test that diffs the Dart against the markdown. Choose the approach that minimizes drift; document why in the gateway file header.
4. Read `tool/advisor_proxy/advisor_proxy.dart` route handlers for `adminAuthRolesPath` + `adminAuthRoleGrantsPath` and the operator self-service equivalents (`/v1/auth/team/roles`, `/v1/auth/team/role-grants`). Confirm route shapes.
5. Build the gateway + demo gateway against the abstract pattern from `lib/admin/services/operator_location_admin_gateway.dart`.
6. Build the three screens + the permission picker tree widget. Re-use widget structure from the mobile sections where it ports cleanly.
7. Wire nav + gateway resolver.
8. Write tests + walkthrough.
9. Verify local web build.

Required tests:
- `flutter analyze --fatal-infos <touched paths>`
- `flutter test test/operator_web/roles_screen_test.dart test/operator_web/permission_explainer_screen_test.dart test/operator_web/web_team_roles_gateway_test.dart`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] Parity contract § Roles + Permission Explainer: 9 categories rendered in locked order; every catalog key rendered exactly once; description copy verbatim from catalog source.
- [ ] Seeded roles render read-only; `Create custom role` button gated on `team.roles.create_custom`.
- [ ] Custom-role builder validates against `PermissionKeys.all`; client-side rejects unknown keys; server-side returns `validation_failed/permission_key_unknown` if bypassed.
- [ ] MFA-required keys render with 🔒 chip + tooltip per parity contract.
- [ ] Idempotency keys minted in screen state, single mint per user action.
- [ ] No `dart:io` / `sqflite` imports; web build succeeds.
- [ ] `11W.2` walkthrough at `docs/_walkthroughs/11W.2.md` at the `7.58.UX.5` bar.
- [ ] No tracker changes, no commits, no scope drift.
- [ ] Pair with `11A.13` Roles tab — both must hit ACCEPT before either merges.

Report using the standard execution report.
