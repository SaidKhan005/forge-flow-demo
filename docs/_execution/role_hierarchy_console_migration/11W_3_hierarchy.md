# Codex Execution Prompt — `11W.3` Hierarchy

## Block 1 — Human Context

Plain English: Migrate the mobile Settings → Org Hierarchy into the Operator Web Console at `/locations`. Operator senior roles can view the org-unit tree (regions / districts / locations), move locations between org-units, create / edit / suspend org-units and locations. Floor managers see read-only hierarchy.

Lane: `11W.3` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11W-3-hierarchy` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` § `11W.3` Hierarchy
- `docs/phases/phase_9/phase_9_auth_plan.md` (hierarchy-touches-grants posture for the gating decision)

Current issue:
- Operators have no web surface for org-tree management. Mobile Org Hierarchy screen exists but is too thin for desktop multi-region edits.

Human prerequisites:
- Setup/access needed: none — Phase 9 backend routes are live.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build the `11W.3` Hierarchy surface end-to-end against `/v1/auth/team/org-units` and `/v1/auth/team/locations/:id`.

Files to modify:
- `lib/operator_web/services/web_team_hierarchy_gateway.dart` — NEW. `package:http`-backed gateway. List org-units + locations for current operator. Create / patch / suspend org-unit. Create / patch / suspend location. Move location to a different org-unit. Move org-unit under a different parent (cycle prevention server-side).
- `lib/operator_web/services/demo_web_team_hierarchy_gateway.dart` — NEW. In-memory backed by `demo_team_fixtures.dart` (extends fixtures shipped by `11W.1`).
- `lib/operator_web/screens/hierarchy_screen.dart` — NEW. Two-pane layout: left = org-tree expandable rows (sorted alphabetically per parity contract), right = detail pane for the selected node (org-unit metadata + locations list) or location detail (timezone, business_day_rollover_hour, primary indicator).
- `lib/operator_web/widgets/org_unit_tree_view.dart` — NEW. Recursive tree widget with expand/collapse. Drag-and-drop or button-driven move. Cycle prevention client-side as a UX hint (server is authoritative). Read-only mode toggle for floor managers.
- `lib/operator_web/widgets/location_card.dart` — NEW. Reusable card for location summary (name, timezone chip, primary chip, suspended badge if applicable). Used in detail pane and in the move-target picker.
- `lib/operator_web/screens/create_org_unit_dialog.dart` — NEW. Modal for create-org-unit (name + parent_org_unit_id picker). Idempotency key minted in dialog state.
- `lib/operator_web/screens/edit_location_dialog.dart` — NEW. Modal for edit-location (name + IANA timezone picker + business_day_rollover_hour). Reuses 11A.1's IANA picker if web-compatible, otherwise re-implements.
- `lib/operator_web/router/operator_web_router.dart` — EDIT. Add `kOperatorWebNavHierarchy` constant + nav item.
- `lib/main_operator_web.dart` — EDIT. Add `_resolveTeamHierarchyGateway` resolver.
- `test/operator_web/hierarchy_screen_test.dart` — NEW. Widget tests covering: tree renders sorted alphabetically; floor manager renders read-only (no move buttons, no create); cycle-prevention UX hint renders before server round-trip; idempotency key flows through move action.
- `test/operator_web/web_team_hierarchy_gateway_test.dart` — NEW. Unit tests covering HTTP shape + cycle-prevention server error mapping (`validation_failed/cycle_detected`).
- `docs/_walkthroughs/11W.3.md` — NEW.

Files to leave alone:
- `lib/screens/settings/settings_org_hierarchy_section.dart` — mobile reference. Read-only.
- `tool/advisor_proxy/advisor_proxy.dart` — backend route handlers exist.
- `lib/admin/screens/operator_location_admin_screen.dart` — 11A.1 surface; reuse IANA picker pattern only if web-compatible.

Hard constraints:
- Do not update trackers / commit / drift scope.
- Do not import `dart:io` / `sqflite`.
- Do not introduce new backend routes.
- Move semantics gate on `team.roles.assign` per parity contract (hierarchy-touches-grants).
- Validation copy verbatim from parity contract § Hierarchy.
- For live work, name-only preflight first.

Implementation tasks:
1. Read `lib/screens/settings/settings_org_hierarchy_section.dart` to extract `TeamOrgUnitEntry`, `TeamOrgLocationEntry`, `TeamOrgHierarchyLoadState` model shapes. Confirm they're web-safe (pure-logic services) and reuse them.
2. Read backend route handlers for `adminAuthOrgUnitsPath` + `adminAuthLocationsPrefix` (find operator self-service equivalents).
3. Read 11A.1 IANA picker (`lib/admin/screens/operator_location_admin_screen.dart` IANA timezone selection logic) and verify web-compatibility before reusing.
4. Build gateway + demo gateway.
5. Build screens + widgets.
6. Wire nav + gateway resolver.
7. Tests + walkthrough.
8. Local web build.

Required tests:
- `flutter analyze --fatal-infos <touched paths>`
- `flutter test test/operator_web/hierarchy_screen_test.dart test/operator_web/web_team_hierarchy_gateway_test.dart`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] Parity contract § Hierarchy: tree shape, move semantics gated on `team.roles.assign`, alphabetical display order, read-only for floor manager / supervisor, validation copy verbatim.
- [ ] Cycle prevention: client UX hint + server `validation_failed/cycle_detected` mapping.
- [ ] Idempotency keys minted in dialog/screen state, single mint per action.
- [ ] No `dart:io` / `sqflite` imports; web build succeeds.
- [ ] `11W.3` walkthrough at `docs/_walkthroughs/11W.3.md` at the `7.58.UX.5` bar.
- [ ] No tracker changes, no commits, no scope drift.
- [ ] Pair with `11A.13` Hierarchy tab — both must hit ACCEPT before either merges.

Report using the standard execution report.
