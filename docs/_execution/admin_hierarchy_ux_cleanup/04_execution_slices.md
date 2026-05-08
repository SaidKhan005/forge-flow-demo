# Execution Slices

## Branching Rule

All code changes must happen in `.codex_worktrees` worktrees on `codex/`
branches. Slice 0 is shared and must merge first. After Slice 0, parallel work
is allowed only where write ownership is disjoint.

Each slice closes with:

- targeted tests for touched files
- Flutter analyze where UI code changed
- Browser Use check when UI changes are visible
- commit on the slice branch
- push and PR
- review and merge gate

## Slice 0 - Shared Hierarchy Workspace Seam

Goal: remove the setup popup model and create the shared scope workspace.

Ownership:

- `lib/admin/admin_route_handoff.dart`
- `lib/admin/admin_shell.dart`
- shared widgets under `lib/admin/widgets/`
- setup route wiring in `lib/admin/admin_routes.dart`
- setup tile routing in `lib/admin/screens/operator_location_admin_screen.dart`

Work:

- Create reusable setup workspace widget with scope pane and function pane/tab.
- Move hierarchy selection into the shared workspace.
- Route setup tiles directly using current selected scope.
- Default to business scope when no hierarchy row is selected.
- Remove setup usage of `AdminHierarchyScopePrompt`.
- Keep legacy prompt widget only if non-setup callers still need it.
- Resolve `support-operator-view`: delete the stale handoff path or register it
  as an explicit hidden route so route fallback is never accidental.

Tests:

- Business setup tile click does not open scope prompt.
- Selected business/org-unit/location is carried to Data Accuracy, Polling,
  People/Access/Roles, Security/Audit/Sessions, Support Logs, Integrations, and
  Timing.
- `Show all` replacement opens all businesses collapsed in the scope pane.

Merge gate:

- Must merge before any other slice that rewires setup screens.

## Slice 1 - Business Accounts Launcher And Header Cleanup

Goal: make Business Accounts match the new command-center IA.

Ownership:

- `lib/admin/screens/operator_location_admin_screen.dart`
- focused tests under `test/admin/`

Work:

- Remove Business Accounts subtitle.
- Make New Business larger/more dominant.
- Move Account Profile action to the business profile widget.
- Simplify selected scope summary.
- Group setup buttons by Operations, People, and Safety/Support tones.
- Remove noisy setup tile values.
- Make setup buttons visibly clickable.

Tests:

- Widget tests for header, account profile action placement, simplified scope
  labels, and tile grouping.
- Browser Use pass for Business Accounts desktop and mobile widths.

## Slice 2 - Hierarchy Management Completion

Goal: expose backend-supported hierarchy lifecycle honestly.

Ownership:

- `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart`
- `tool/advisor_proxy/advisor_proxy.dart`
- hierarchy repositories/services as needed
- Business Accounts hierarchy panel
- hierarchy gateway/proxy tests

Work:

- Add proxy route for org-unit move or document why backend cannot support it.
- Implement HTTP `moveOrgUnit`.
- Add Business Accounts controls for moving locations between org units.
- Add Business Accounts controls for moving org units when backend support lands.
- Keep confirmations and admin reasons for move actions.
- Hide technical ltree label entry behind auto-generated labels or advanced
  details.

Tests:

- Proxy route tests for org-unit move.
- HTTP gateway test no longer expects 501.
- Business Accounts widget tests for location move and org-unit move.
- Regression test for preventing self/descendant org-unit moves.

## Slice 3 - Shared Scope Pane For Setup Screens

Goal: convert all filter/search setup surfaces to the shared split/tab model.

Ownership:

- shared setup workspace widgets
- setup screen constructors/handoff wiring
- route tests

Work:

- Add business/org-unit/location hierarchy search.
- All businesses collapsed when no selected business exists.
- Selected business and scope expanded when launched from Business Accounts.
- Replace per-screen `Change scope` and `Show all` controls.
- Standardize filter bar styling.

Tests:

- Desktop split view.
- Mobile two-tab view.
- Browser back/route switch preserves selected scope.
- Fresh route with no scope starts at all businesses collapsed.
- Hidden route handoffs either resolve to a real hidden route or are removed.

## Slice 4 - Covers And Wage Data Accuracy

Goal: implement the requested Data Accuracy UX without pretending scoped writes
exist.

Ownership:

- `lib/admin/screens/per_location_data_accuracy_screen.dart`
- `lib/admin/widgets/per_location_data_accuracy_table.dart`
- `lib/admin/widgets/data_accuracy_audit_history_panel.dart`
- `lib/admin/services/data_accuracy_admin_gateway.dart`
- proxy/API only if actor enrichment is needed

Work:

- Rename screen and route label to `Covers and Wage Data Accuracy`.
- Remove top stat widget and old subtitle.
- Add vendor filter and sort controls.
- Reorganize content into Covers, Wage, Logs.
- Move Walk-ins into Covers.
- Use hierarchy pane for business/org-unit/location filtering.
- For business/org-unit scopes, show rollups and disable writes unless scoped
  schema is approved.
- Show actor name and role in logs.

Tests:

- Widget tests for rename, removed stats, vendor filter, sorting, and block
  organization.
- Safe mutation tests for location-only covers/wage/walk-in edits.
- Audit actor display tests.

Decision gate:

- Scoped business/org-unit edits require schema/resolver approval.

## Slice 5 - Polling Setup

Goal: rename and make polling tier/cost work understandable.

Ownership:

- `lib/admin/screens/polling_and_pricing_admin_screen.dart`
- polling widgets under `lib/admin/widgets/`
- `lib/admin/services/data_accuracy_admin_gateway.dart`
- proxy/data layer only if calculator persistence changes API

Work:

- Rename route/screen to `Polling Setup`.
- Remove top stat widget and dense subtitle.
- Rewrite About widget.
- Rename Standard display to Regular where product wants that label.
- Add poll-only vendor filter.
- Add cost calculator with manual override.
- Explain default tier behavior when no assignment exists.
- Keep business/org-unit edits read-only unless scoped schema is approved.

Tests:

- Widget tests for rename, vendor filter, calculator math, manual override,
  and default tier label.
- Gateway/proxy tests for cost-basis body shape if API changes.
- Safe mutation tests for location tier assignment and change request handling.

Decision gate:

- Calculator inputs and whether to persist calculated or overridden cost.

## Slice 6 - People, Access, Roles

Goal: reduce raw permission/session language and align scope UX.

Ownership:

- `lib/admin/screens/members_admin_screen.dart`
- `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart`
- role/permission widgets and tests

Work:

- Remove visible members stat strip.
- Render human permission names first.
- Move raw permission keys into tooltip/details.
- Improve active session copy and layout.
- Align filters with shared setup style.
- Make hierarchy scope context first-class.

Tests:

- Members screen no longer renders visible members stat.
- Permission catalog renders human labels and still exposes raw keys in details.
- Session rows are human-readable and force logout remains gated.

## Slice 7 - Security, Audit, Support Logs

Goal: make safety/support surfaces understandable and consistent.

Ownership:

- `lib/admin/screens/audited_support_actions_admin_screen.dart`
- `lib/admin/screens/debug_console_admin_screen.dart`
- audited support gateway models if actor enrichment changes

Work:

- Group security actions by intent.
- Audit all log screens for actor name + role.
- Decide and implement actor identity policy: denormalized actor display fields,
  read-time identity joins, or deliberate generic labels.
- Clarify Support Logs tab names and explanations.
- Wire or intentionally disable Relationship help and Account help.
- Align filter styling with shared workspace.
- Keep client-side `location_ids` org-unit expansion bounded, or add a native
  support-log hierarchy filter.

Tests:

- Security action grouping widget tests.
- Actor display tests across audit/support/data/polling logs.
- Support Logs unavailable-state tests for unwired tabs.
- Support Logs org-unit filter tests for multi-location branches.

## Slice 8 - Connected Services And Vendor Integrations

Goal: split service health from per-location vendor setup and make status live.

Ownership:

- `lib/admin/screens/integration_admin_screen.dart`
- `lib/admin/services/integration_admin_gateway.dart`
- `lib/admin/screens/vendor_connections/vendor_connections_admin_mount.dart`
- `lib/integrations/ui/vendor_connections/`
- proxy route if live health source changes

Work:

- Add descriptions for Service Access and Shared Services.
- Group vendor catalog by POS, Labor, Reservation.
- Replace static `Documented` status with live status or explicit pending-live
  state.
- Keep new key plaintext one-time reveal only.
- Remove scope prompt from vendor setup path.
- Tie integration unlock state to vendor lifecycle and health.

Tests:

- Connected Services grouping and status tests.
- One-time reveal tests still pass.
- Vendor setup no-popup scope tests.

Decision gate:

- Source of truth and refresh cadence for live vendor health.

## Slice 9 - System, Launch, Knowledge Polish

Goal: remove code language from system and AI admin surfaces.

Ownership:

- `lib/admin/admin_routes.dart`
- `lib/admin/screens/health_admin_screen.dart`
- `lib/admin/screens/observability_admin_screen.dart`
- `lib/admin/screens/feature_flags_admin_screen.dart`
- `lib/admin/screens/corpus_admin_screen.dart`

Work:

- System Health: define Advisor data, App service, Ecosystem, and service
  checks in plain English.
- System Metrics: move/rename to AI Metrics if confirmed.
- Keep big central run buttons; remove duplicate middle widgets where present.
- Launch Controls: hide raw control IDs from primary UI.
- Knowledge Base: hide source files/hashes from primary UI.
- Relationship Review: simplify states and next actions.

Tests:

- Route/nav tests for System Metrics/AI Metrics decision.
- Plain-English label snapshots/widget assertions.
- Browser Use pass for Health, Metrics, Launch Controls, Knowledge Base.

Decision gate:

- Whether System Metrics belongs under AI.

## Slice 10 - Cross-Surface QA And Final Audit

Goal: prove the implementation matches this plan and the original overhaul docs
where they still apply.

Ownership:

- verification docs/evidence only unless audit finds defects

Work:

- Run targeted tests from every slice.
- Run `flutter analyze`.
- Run Browser Use on cache-bust URLs.
- Run performance framework.
- Run UX framework.
- Run mobile/web/admin E2E framework where applicable.
- Produce final audit JSON/evidence bundle.

Merge gate:

- All slice PRs merged to `master`.
- Browser evidence attached.
- Residual product decisions listed.
