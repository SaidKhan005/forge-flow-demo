# Feature Lens Audit

Feature: Admin Hierarchy UX Cleanup
Branch: `codex/admin-ux-implementation-lens-plan`
Source commit: `ac1193dc`
Audit date: 2026-05-08

## Lens Findings

| Lens | Code or doc checked | Finding | Required action |
|---|---|---|---|
| Branch, authority, scope | `PROJECT_TRACKER.md`, `CLAUDE.md`, existing overhaul docs, this worktree | Existing overhaul docs still describe a popup-first scope prompt. Current product direction rejects that interaction. | Treat this plan as the current execution authority for UX cleanup. Leave old docs as historical context unless implementation PRs update them. |
| Product and journey | `lib/admin/screens/operator_location_admin_screen.dart:1436`, `:1467`, `:1575` | Setup tiles open a scope dialog before routing. This conflicts with "select hierarchy level, then select business function." | Remove setup popup path. Route tiles with the selected hierarchy scope; default to business scope when nothing else is selected. |
| IA and navigation | `lib/admin/admin_shell.dart:71`, `lib/admin/admin_route_handoff.dart:95`, `lib/admin/admin_routes.dart:428` | Shell and handoff can carry hierarchy scope, but setup screens each own local scope/prompt behavior. | Introduce shared setup workspace/scope controller so hierarchy selection and route handoff behave the same on every function. |
| IA and navigation | `lib/admin/admin_routes.dart:181`, `lib/admin/admin_routes.dart:568`, `lib/admin/admin_shell.dart:55` | `support-operator-view` is retained as a builder/constant but is not in the route table. Unknown route ids fall back to the first route. | Either remove this hidden route path or register an explicit hidden route so handoff cannot silently land on Business Accounts. |
| Data model and RLS | `db/migrations/202605050000_phase_8_data_accuracy_settings.sql:56`, `:140` | Data accuracy settings and polling tier assignments are per `(operator_id, location_id)` only. | Product must choose: ship business/org-unit read-only rollups first, or add scoped settings/assignment schema and resolvers. |
| Hierarchy data model | `db/migrations/202604280002_phase_9_0sigma_c_org_units.sql:93`, `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql:26` | Org units, location parent pointers, ltree paths, org-unit role grants, and effective location cache exist. | Reuse this backend shape in the shared hierarchy selector and scope filtering. Do not create a parallel hierarchy model. |
| Repository/service | `lib/services/data_accuracy/data_accuracy_settings_repository.dart`, `lib/services/data_accuracy/forge_flow_polling_tier_repository.dart:53` | Repositories write location-only rows. Polling assignment history closes and inserts per location only. | Add hierarchy resolver/repository work only after product approves scoped settings. Otherwise keep edits disabled outside location scope. |
| Proxy/gateway contracts | `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart:554`, `tool/advisor_proxy/advisor_proxy.dart:11491` | Proxy supports org hierarchy list/create and location move. HTTP gateway intentionally throws 501 for org-unit move. | Add proxy route and gateway support for org-unit move before surfacing that action in Business Accounts. |
| Auth, roles, scope | `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql:101`, `lib/admin/screens/members_admin_screen.dart:535` | Member role grant override supports `operator_wide`, `org_unit`, and `location`. | Reuse these scopes in the split workspace. Make human labels first-class; keep raw keys secondary or hidden. |
| Lifecycle/destructive | `lib/admin/screens/operator_location_admin_screen.dart:2121`, `test/admin/screens/roles_hierarchy_sessions_admin_screen_test.dart:170` | Location edit/primary/delete exists in Business Accounts; move controls exist in Roles/Hierarchy/Sessions tests, not Business Accounts. | Add move location and move org-unit controls to the Business Accounts hierarchy panel once gateway/proxy support is complete. |
| UX/accessibility | `lib/admin/screens/operator_location_admin_screen.dart:1524`, `:1575`, `lib/admin/widgets/admin_hierarchy_scope_prompt.dart:177` | The setup widget shows noisy scope chips and tiles show state words such as Review, Ready, Editable, Read-only, Business default, and Location required. | Reduce launcher labels to selected scope and scope applicability. Make setup tiles visibly clickable and grouped by product category. |
| Performance/loading | `lib/admin/screens/per_location_data_accuracy_screen.dart:126`, `lib/admin/screens/polling_and_pricing_admin_screen.dart:135` | Data Accuracy/Polling load full cross-operator rows, then filter locally. Org-unit expansion is not available locally. | Shared split workspace should load hierarchy once per selected business and pass descendant location ids to function screens. Avoid repeated full scans on tab switches. |
| Performance/loading | `lib/admin/screens/debug_console_admin_screen.dart:163`, `lib/admin/services/debug_console_admin_gateway.dart:120`, `tool/advisor_proxy/advisor_proxy.dart:15309` | Support Logs can send `location_ids`, but org-unit scope is resolved client-side before the proxy call. There is no native `org_unit_id` support-log filter. | Keep this as an explicit bounded behavior or add a server-side hierarchy scope resolver with performance tests for large operators. |
| Tests/builds/browser | `test/admin/data_accuracy_polling_hierarchy_scope_screen_test.dart`, `test/admin/widgets/admin_hierarchy_scope_prompt_test.dart`, `test/admin/screens/roles_hierarchy_sessions_admin_screen_test.dart` | Tests protect the old prompt behavior and location-only policy. | Update tests with the new no-popup rule, shared split workspace, hierarchy routing, and safe mutation workflows. |
| Observability/audit/support | `lib/admin/widgets/data_accuracy_audit_history_panel.dart:252`, `lib/admin/services/audited_support_actions_admin_gateway.dart:222`, `tool/advisor_proxy/advisor_proxy.dart:17214` | Security/audit rows include actor display fields, but Data Accuracy/Polling audit events only expose id/kind and collapse to "Admin user". Some auth-event projections synthesize `F&F admin` / `Team member` with blank email. | Decide privacy policy, then either denormalize actor display/role at write time or join/enrich at read time. |
| Docs/prompt hygiene | Existing `docs/_execution/admin_hierarchy_settings_overhaul/*` | Old docs are useful for plumbing history but now conflict with product direction. | New implementation prompts must reference this plan and explicitly prohibit popup scope selection. |

## Explicit Non-Gaps

- `AdminHierarchyScopeIntent` already represents business, org-unit, and location
  scope, including route cache keys and display labels.
- Business Accounts already tracks `selectedHierarchyScope` and defaults to a
  business scope when an operator is selected.
- Admin shell route handoff already carries hierarchy scope to hidden setup
  routes.
- The database already stores org units and location parent org units.
- Member role grant override already supports org-unit scoped grants.
- Vendor Connections already has a per-location widget model grouped by POS,
  Labor, and Reservation for the location setup surface.

## Decision Stops

- Data Accuracy and Polling cannot honestly become editable at business or
  org-unit scope without new scoped settings/assignment schema and resolver
  rules.
- Org-unit move cannot ship in production until the proxy and HTTP gateway both
  support it.
- "System metrics is AI" needs product confirmation before moving the nav item
  under AI and renaming it AI Metrics.
- Connected Services live health needs a source of truth and cadence: adapter
  registry health, connector rows, worker sync logs, or a new health endpoint.
- Support Workspace needs a route decision: remove it fully, or keep a hidden
  route entry that cannot silently fall back.
- Polling cost calculator inputs need product approval before writes become
  authoritative: request volume, vendor price, cadence, locations, retries,
  cached/webhook share, and safety margin.
