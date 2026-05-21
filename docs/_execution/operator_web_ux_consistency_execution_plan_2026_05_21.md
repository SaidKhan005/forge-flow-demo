# Operator Web UX Consistency Execution Plan

Date: 2026-05-21

## Goal

Make Operator Web feel like one clean product surface, using only the product
changes named in the operator brain dump:

- One premium tile and widget style.
- One consistent text, spacing, menu, and popup style.
- No normal settings task should open a full-screen popup.
- Business timing owns timing edits.
- Business Account keeps timing as simple read-only handoffs.
- Locations gets the same polish level as the rest of Operator Web.
- Roles and permissions become scope-aware instead of only business-wide.

## Explicit Scope

- Operator Web only.
- Admin Web is not part of this pass.
- Mobile is not part of this pass.
- Data Accuracy remains location-focused.
- Vendor Integrations remains location-focused.
- Logo remains business-level unless the operator later changes that decision.
- Do not invent new product features beyond the operator list.

## Current Code Audit

| Area | Current code checked | Finding | Required action |
|---|---|---|---|
| Shared visual system | `lib/operator_web/screens/**`, `lib/operator_web/widgets/**` | Tiles, cards, banners, dialogs, and buttons are locally styled in many screens. Dialogs use a mix of `Dialog`, `AlertDialog`, and one-off layouts. | Create or reuse one Operator Web style pattern for tiles, popups, section headers, info buttons, and compact banners. Apply it only to the surfaces in this plan. |
| Top scope banner | `lib/operator_web/widgets/web_app_shell.dart`, `lib/operator_web/widgets/hierarchy_map_picker.dart` | The top scope dropdown/banner already replaced most page-level hierarchy clutter. | Preserve this direction. Do not bring back page-level hierarchy cards unless the operator explicitly asks. |
| Business setup name | `lib/operator_web/router/operator_web_router.dart`, `lib/operator_web/screens/business_setup_screen.dart` | User-facing labels still say `Business setup`. | Rename visible Operator Web labels to `Business timing setup`. Update tests. |
| Business setup actions | `lib/operator_web/screens/business_setup_screen.dart` | Buttons still show `Edit time settings` and `Schedule future timing`. The safe popup still exists. | Remove or consolidate these actions into the clearer timing/service-period editing path requested by the operator. |
| Timezone ownership | `lib/operator_web/screens/account_screen.dart`, `lib/operator_web/screens/business_timing_editor_screen.dart` | Account still owns the editable timezone form. Business Timing still says timezone is read-only and tells the user to change it in Business Account. | Move timezone editing into Business Timing. Business Account should show timezone and week timing as read-only links/handoffs into Business Timing. |
| Region/District account edits | `lib/operator_web/screens/account_screen.dart`, `lib/operator_web/services/web_account_gateway.dart` | Account has org-unit override plumbing for Brand/Region/District style scopes, and source metadata tests exist. UX still needs to match the operator decision. | Allow relevant account settings at Region/District/Brand scopes: contact, currency, locale, timezone. Keep logo business-level. |
| Business Timing service periods | `lib/operator_web/widgets/service_period_editor.dart`, `lib/operator_web/screens/business_timing_editor_screen.dart` | `Stable key` is operator-editable. Start/end fields already have nearby 15-minute copy, but the overall widget is busy. Short label, sort order, weekday chips, helper copy, and key field create clutter. | Hide or auto-fill stable keys. Keep needed period fields, simplify layout, keep 15-minute guidance close to start/end, and move deeper explanation behind info buttons. |
| My Account | `lib/operator_web/screens/my_account_screen.dart` | Phone still appears. Profile/security/recent sign-in sections carry long inline explanations. Active Sessions is fully embedded. There is a `View audit log` button. | Clean profile tile, reconsider/remove phone from visible profile, move long explanations behind info buttons, make Active Sessions a small link/summary, and keep one Audit Log section near the bottom. |
| Team Members | `lib/operator_web/screens/members_screen.dart` | Removed users skip the normal edit action path, which can make row structure feel inconsistent. Invite/edit dialogs use their own layouts. | Keep removed-user rows aligned with active rows. Standardize member popups with the shared Operator Web dialog style. |
| Roles and Permissions | `lib/operator_web/router/operator_web_router.dart`, `lib/operator_web/screens/roles_screen.dart`, `lib/operator_web/services/web_team_roles_gateway.dart`, `db/migrations/*user_roles*` | Backend schema already has operator-wide, org-unit, and location role scope support. The Operator Web role editor is still mounted with `RoleScope.business`, so the active UX behaves business-wide. Permission Explainer is still visible. | Make Roles and Permissions scope-aware in the active Operator Web flow. Confirm plain-English permission copy, then remove or hide Permission Explainer from normal UX if redundant. |
| Audit Logs | `lib/operator_web/screens/audit_log_screen.dart`, `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart` | Visible Audit Log still uses `Actor` language, still shows audit chain status, and still opens the default date range picker. Separate hierarchy pane is now stale as visible UX but still exists in code/tests. CSV export is wired through scoped query in the current page. | Rename visible `Actor` language to `Team member`. Replace full-screen date range behavior with compact standard popup. Keep CSV exporting the scoped log. Decide whether audit chain status stays visible or moves behind an info/details area. Remove stale visible hierarchy-filter assumptions from code/tests if safe. |
| Data Accuracy | `lib/operator_web/screens/data_accuracy_screen.dart`, `lib/operator_web/screens/wage_authority_screen.dart` | Page is not ordered as Labor, Covers, Data Freshness. Wage role add/edit is inline. Data Accuracy remains location-focused. | Reorder into Labor, Covers, Data Freshness. Turn labor role add/edit into standard popups. Keep location-focused scope. |
| Vendor Integrations | `lib/operator_web/screens/vendor_connections_screen.dart`, router location handoff | Vendor Integrations is location-focused and now follows top scope handoff. | Keep location-focused. Only apply shared tile/menu/popup style consistency where the current surface feels older. |
| Notifications | `lib/operator_web/screens/settings_notifications_screen.dart`, `lib/domain/models/notification_event_catalog.dart` | Screen still shows `Coming soon`, `Always on`, `Inbox`, Phone/Email/Inbox channels. Preferences are per user and per scope in storage comments. | Explain or implement `Coming soon` only when current backend wiring allows it. Keep visible copy simple. Put deeper details behind info buttons. Clarify `Inbox` and that preferences are per logged-in person unless a later product decision changes that. |
| Locations | `lib/operator_web/screens/hierarchy_screen.dart` | Locations is the hierarchy/location management screen. It has its own card and dialog style. | Polish Locations UX so list/tree, location cards, add/rename/move flows, empty states, buttons, and popups match the rest of Operator Web. |

## Stale Items To Avoid Rebuilding

- Do not bring back separate page-level hierarchy maps.
- Do not bring back duplicate `Where this applies` cards on every page.
- Do not build a second demo mode.
- Do not broaden Data Accuracy or Vendor Integrations beyond location-focused editing.

## Execution Order

### Wave 0 - Baseline Audit And Style Inventory

Purpose:

- Take fresh screenshots or browser notes of the real Operator Web demo.
- Inventory tiles, widgets, popups, menus, date range behavior, and info buttons.
- Confirm exact stale code paths before editing.

Files likely read:

- `lib/operator_web/router/operator_web_router.dart`
- `lib/operator_web/widgets/web_app_shell.dart`
- `lib/operator_web/widgets/hierarchy_map_picker.dart`
- `lib/operator_web/screens/account_screen.dart`
- `lib/operator_web/screens/business_setup_screen.dart`
- `lib/operator_web/screens/business_timing_editor_screen.dart`
- `lib/operator_web/widgets/service_period_editor.dart`
- `lib/operator_web/screens/my_account_screen.dart`
- `lib/operator_web/screens/members_screen.dart`
- `lib/operator_web/screens/roles_screen.dart`
- `lib/operator_web/screens/audit_log_screen.dart`
- `lib/operator_web/screens/data_accuracy_screen.dart`
- `lib/operator_web/screens/wage_authority_screen.dart`
- `lib/operator_web/screens/settings_notifications_screen.dart`
- `lib/operator_web/screens/hierarchy_screen.dart`
- `lib/operator_web/screens/vendor_connections_screen.dart`

Acceptance:

- A short audit note lists which visible surfaces are stale, active, or blocked.
- No code changes yet except a doc note if needed.

### Wave 1 - Shared Operator Web UX Foundation

Purpose:

- Make one reusable Operator Web pattern for:
  - Tile/card surfaces.
  - Section headers.
  - Compact info buttons.
  - Standard popup/dialog shell.
  - Standard compact date range popup pattern.
  - Standard success/error/warning banners.

Rules:

- Keep the existing product colors and typography direction.
- Do not redesign the app shell from scratch.
- Do not change backend behavior.

Why this is first:

- Every later surface depends on this consistency work.
- This wave should be serialized before parallel work starts.

Acceptance:

- Shared style primitives exist or existing primitives are clearly reused.
- At least one safe screen proves the pattern.
- Widget tests lock the standard dialog/tile behavior.

### Wave 2 - Business Timing And Business Account

Purpose:

- Rename `Business setup` to `Business timing setup`.
- Move editable timezone into Business Timing.
- Make Business Account timing/week/timezone read-only handoffs.
- Clean up service periods.
- Keep Region/District/Brand account edits for contact, currency, locale, and timezone.
- Keep logo business-level.

Files likely touched:

- `lib/operator_web/router/operator_web_router.dart`
- `lib/operator_web/screens/account_screen.dart`
- `lib/operator_web/screens/business_setup_screen.dart`
- `lib/operator_web/screens/business_timing_editor_screen.dart`
- `lib/operator_web/widgets/service_period_editor.dart`
- `lib/operator_web/services/web_account_gateway.dart`
- `lib/operator_web/services/web_business_timing_gateway.dart`
- Related tests under `test/operator_web/screens/**` and `test/operator_web/services/**`

Backend/gateway check:

- Verify whether current Business Timing write contracts already carry timezone for the selected scope.
- If they do, wire it in.
- If they do not, stop and document the exact missing route/body field before adding controls.

Acceptance:

- Business Timing Setup owns all timing edits.
- Account only links/hands off timing edits.
- Source wording updates after save.
- Stable key is no longer operator-managed.
- Service period UI is cleaner and still supports existing period metadata.

### Wave 3 - My Account And Team Members

Purpose:

- Clean My Account profile and security sections.
- Move long explanations behind info buttons.
- Make Active Sessions a summary/link instead of a full embedded management surface.
- Keep one Audit Log section near the bottom.
- Fix removed-user row alignment.
- Standardize invite/edit/member confirmation popups.

Files likely touched:

- `lib/operator_web/screens/my_account_screen.dart`
- `lib/operator_web/screens/members_screen.dart`
- `lib/operator_web/screens/invite_member_dialog.dart`
- `lib/operator_web/screens/edit_member_dialog.dart`
- `lib/operator_web/screens/edit_self_profile_dialog.dart`
- Related tests under `test/operator_web/screens/**`

Acceptance:

- My Account is shorter and cleaner without losing reachable security flows.
- Team member rows align across active, suspended, dormant, and removed states.
- Member dialogs match the standard popup style.

### Wave 4 - Scoped Roles And Permissions

Purpose:

- Make Roles and Permissions scope-aware in Operator Web.
- Stop treating the active editor as only business-wide.
- Use the selected top scope where it fits the role grant/edit flow.
- Confirm whether Permission Explainer is redundant now that permissions are plain English.

Files likely touched:

- `lib/operator_web/router/operator_web_router.dart`
- `lib/operator_web/screens/roles_screen.dart`
- `lib/operator_web/screens/permission_explainer_screen.dart`
- `lib/operator_web/services/web_team_roles_gateway.dart`
- `lib/operator_web/services/demo_team_roles_gateway.dart`
- `lib/auth/permission_key_metadata.dart`
- Existing `user_roles` repository, route, and migration tests if write wiring needs adjustment.

Backend/gateway check:

- Confirm current routes can create and edit role grants at business, org-unit, and location scopes.
- Confirm audit logs record the chosen scope.
- Confirm forbidden states for users outside a scope.

Acceptance:

- A manager can be scoped to a Region/District/Location without receiving whole-business access.
- UI makes the role scope clear without adding hierarchy clutter.
- Permission Explainer is hidden or de-emphasized only if role copy is already plain English.

### Wave 5 - Audit Logs

Purpose:

- Change user-facing `Actor` wording to `Team member`.
- Keep the top scope dropdown as the hierarchy filter.
- Replace full-screen date range picker with the standard compact popup.
- Keep scoped CSV export.
- Decide with the operator whether audit chain status remains visible or moves behind info/details.

Files likely touched:

- `lib/operator_web/screens/audit_log_screen.dart`
- `lib/operator_web/widgets/audit_log_row.dart`
- `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart` only if removing stale visible code is safe.
- `test/operator_web/screens/audit_log_screen_test.dart`
- `test/operator_web/screens/audit_log_integrity_badge_test.dart`
- `test/operator_web/services/web_team_audit_log_gateway_test.dart`

Acceptance:

- User-facing copy says Team member.
- Date range change is compact.
- CSV still exports the actual scoped log.
- No separate hierarchy filter returns to the page.

### Wave 6 - Data Accuracy And Labor Role Popups

Purpose:

- Reorder Data Accuracy as:
  1. Labor
  2. Covers
  3. Data Freshness
- Keep Data Accuracy location-focused.
- Convert labor role add/edit to standard popups.

Files likely touched:

- `lib/operator_web/screens/data_accuracy_screen.dart`
- `lib/operator_web/screens/wage_authority_screen.dart`
- `lib/operator_web/widgets/wage_source_toggle.dart`
- `lib/operator_web/widgets/covers_source_toggle.dart`
- Related tests under `test/operator_web/screens/**` and `test/operator_web/widgets/**`

Acceptance:

- Labor settings read as one grouped area.
- Covers settings read as one grouped area.
- Data freshness reads as one grouped area.
- Add/edit labor role uses the standard popup style.

### Wave 7 - Notifications

Purpose:

- Clarify `Coming soon`, `Always on`, `Inbox`, Phone, and Email.
- Implement any `Coming soon` item only if backend emitter and preference route already exist.
- Keep deeper implementation notes behind info buttons.
- Confirm preferences are per logged-in person.

Files likely touched:

- `lib/operator_web/screens/settings_notifications_screen.dart`
- `lib/domain/models/notification_event_catalog.dart`
- `lib/operator_web/services/operator_web_notification_preferences_gateway_provider.dart`
- `test/operator_web/screens/settings_notifications_screen_test.dart`
- `test/proxy/operator_routes_notification_preferences_test.dart`

Acceptance:

- Visible copy is simple.
- Inbox is understandable.
- Coming-soon rows are either real, removed, or honestly explained.
- User/person scoping is clear.

### Wave 8 - Locations UX

Purpose:

- Make Locations visually consistent with the rest of Operator Web.
- Improve location cards/tree, actions, empty states, and add/rename/move popups.

Files likely touched:

- `lib/operator_web/screens/hierarchy_screen.dart`
- `lib/operator_web/services/web_team_hierarchy_gateway.dart`
- `lib/operator_web/widgets/hierarchy_tree_visualization.dart`
- `test/operator_web/screens/hierarchy_screen_test.dart`
- `test/operator_web/widgets/hierarchy_tree_visualization_test.dart`

Acceptance:

- Locations feels like the same product as the updated Account, Timing, Audit Log, and Data Accuracy surfaces.
- Existing add/rename/move behavior remains intact.
- Read-only roles still see a clear view-only state.

### Wave 9 - Final Cross-Surface QA

Purpose:

- Sweep all touched Operator Web routes in the demo runtime.
- Confirm the top scope banner remains the only main scope control.
- Confirm no full-screen settings popup remains for normal settings tasks.
- Confirm no duplicate hierarchy cards return.

Required checks:

- `dart run tool/ux_em_dash_lint.dart`
- `dart analyze` on touched files and tests.
- Focused `flutter test` for every touched Operator Web screen/service/widget.
- `git diff --check`
- Production-shaped Operator Web demo build or README demo preview command.
- Browser sweep of:
  - Business Account
  - Business Timing Setup
  - Locations
  - My Account
  - Team Members
  - Roles and Permissions
  - Audit Log
  - Data Accuracy
  - Vendor Integrations
  - Notifications

## Parallel Execution Rules

- Wave 1 is serialized because it touches shared style.
- Wave 2 is serialized because Account, Business Timing, and router labels overlap.
- Wave 4 is serialized because roles, permissions, auth scope, and audit behavior are sensitive.
- After Wave 1 lands, Waves 3, 5, 6, 7, and 8 can run in parallel only if their file ownership stays disjoint.
- No worker updates trackers.
- No worker merges its own PR.
- Every worker uses a dedicated worktree and branch.
- The orchestrator audits each PR diff before merge.

## Decision Stops

These are not implementation choices to invent:

- Audit chain status: operator still needs to decide whether normal users should see it or whether it belongs behind info/details.
- Notifications `Coming soon`: implement only if the emitter and route already exist. Otherwise explain honestly.
- Phone on My Account: operator questioned whether it is needed. Treat as a UX removal/simplification candidate, but do not remove backend fields unless explicitly requested.

## Handoff Prompt For New Session

```text
Use the Forge & Flow repo workflow.

I am retiring the previous session. Continue from the landed plan:
docs/_execution/operator_web_ux_consistency_execution_plan_2026_05_21.md

Plain English summary:
- Operator Web only.
- Do not touch Admin Web or mobile.
- Do not invent features outside the brain dump captured in the plan.
- The goal is one clean Operator Web UX system: consistent tiles, spacing, text, menus, popups, info buttons, and no full-screen settings popups.
- Business Timing Setup should own timing edits, including timezone.
- Business Account should show timing/week/timezone as simple read-only handoffs into Business Timing.
- Locations UX needs to be polished to match the rest of Operator Web.
- Roles and Permissions need real scope support instead of only global/business-wide behavior.
- Data Accuracy and Vendor Integrations stay location-focused.
- Logo stays business-level.

Start by reading:
- CLAUDE.md
- PROJECT_TRACKER.md
- docs/_execution/operator_web_ux_consistency_execution_plan_2026_05_21.md
- runbooks/ux_adjustment_runbook.md
- runbooks/feature_implementation_lens_audit_runbook.md
- docs/CODEX_PROMPT_GENERATION_STANDARD.md

Workflow:
1. Keep the shared checkout on master.
2. Use dedicated worktrees and codex/* branches.
3. Start with Wave 0 audit from the plan.
4. Then execute Wave 1 shared Operator Web UX foundation first.
5. Do not parallelize until Wave 1 lands.
6. For later waves, split workers only when file ownership is disjoint.
7. Workers commit, push, open PR, and stop.
8. The main session audits each diff before merge.
9. Run focused Flutter tests, dart analyze, ux em-dash lint, git diff --check, and browser QA for the touched Operator Web routes.
10. Merge only after the repo-standard audit is clean.

Important product boundaries:
- No page-level hierarchy maps/cards should come back.
- The top scope dropdown/banner remains the main scope control.
- Do not create another demo mode.
- Do not widen Data Accuracy or Vendor Integrations beyond location-focused editing.
- Do not make product decisions for audit chain visibility or notification coming-soon wiring without surfacing the exact finding first.
```
