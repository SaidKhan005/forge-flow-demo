# Code Gap Matrix

## Shared Scope And Routing

| Area | Current code | Gap | Action |
|---|---|---|---|
| Scope model | `lib/admin/admin_route_handoff.dart:95` | Scope intent exists and is reusable. | Keep as shared value object. Add any missing labels carefully. |
| Shell handoff | `lib/admin/admin_shell.dart:71` | Handoff keeps previous hierarchy scope between routes, but function screens still own local prompt state. | Move setup screens to a shared workspace controller/panel. |
| Hidden support route | `lib/admin/admin_routes.dart:181`, `lib/admin/admin_routes.dart:568`, `lib/admin/admin_shell.dart:55` | `support-operator-view` has a constant and builder but no `kAdminRoutes` entry; unknown route ids fall back to Business Accounts. | Remove the legacy handoff or register a hidden route entry before any setup tile targets it. |
| Scope popup | `lib/admin/widgets/admin_hierarchy_scope_prompt.dart:177` | Prompt has `Change scope` and `Show all`; it appears in several setup paths. | Stop using it for Business Setup functions. Keep only if another legacy path still needs it. |
| Setup tile click | `lib/admin/screens/operator_location_admin_screen.dart:1436` | `_promptThenRun` opens a dialog before routing. | Replace with direct route call using selected hierarchy scope. |
| Setup tile values | `lib/admin/screens/operator_location_admin_screen.dart:1575` | Tile values show Review/Ready/Location required/etc. | Replace with scope applicability labels only. |

## Business Accounts And Hierarchy

| Area | Current code | Gap | Action |
|---|---|---|---|
| Page header | `lib/admin/screens/operator_location_admin_screen.dart:276` | Subtitle should be removed and New Business should be more dominant. | Adjust header copy and button style. |
| Profile placement | `lib/admin/screens/operator_location_admin_screen.dart:1004` | Account profile is still a setup tile. | Move Account profile action to the business profile card. |
| Hierarchy selector | `lib/admin/screens/operator_location_admin_screen.dart:1842` | Selector exists and already supports business/org-unit/location selection. | Reuse this layout as the shared setup scope pane. |
| Add org unit | `lib/admin/screens/operator_location_admin_screen.dart:2024` | Add child exists, but label field exposes ltree-style constraints. | Generate labels or hide technical label by default. |
| Move location | `lib/admin/screens/operator_location_admin_screen.dart:2121` | Location rows expose edit/primary/delete but not move. | Add move location action after gateway/proxy readiness is verified. |
| Move org unit | `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart:554` | HTTP gateway throws `org_unit_move_unimplemented`. | Add proxy route, gateway method, tests, and UI. |

## Data Accuracy

| Area | Current code | Gap | Action |
|---|---|---|---|
| Route/title | `lib/admin/admin_routes.dart:321`, `lib/admin/screens/per_location_data_accuracy_screen.dart:234` | Still titled `Data accuracy`; subtitle says operator-location. | Rename to `Covers and Wage Data Accuracy` and rewrite copy. |
| Scope prompt/banner | `lib/admin/screens/per_location_data_accuracy_screen.dart:367` | Screen has inline prompt and Change Scope banner. | Replace with shared split/tab workspace. |
| Scope options | `lib/admin/screens/per_location_data_accuracy_screen.dart:293` | Scope options are built from data rows only: business + location, no org-unit tree. | Feed full hierarchy from shared scope pane or hierarchy gateway. |
| Org-unit filtering | `lib/admin/models/admin_hierarchy_settings_scope_policy.dart:67` | Org-unit `includesOperatorLocation` returns false. | Add descendant location expansion plus effective-value resolution for editable org-unit scope. |
| Summary widget | `lib/admin/screens/per_location_data_accuracy_screen.dart:403` | Top stat strip shows visible/manual/forecast rows, which user asked to remove. | Remove top strip. |
| Content structure | `lib/admin/widgets/per_location_data_accuracy_table.dart` | One table drives covers, wage, service-period edits. | Reorganize into Covers, Wage, Logs blocks. |
| Actor display | `lib/admin/widgets/data_accuracy_audit_history_panel.dart:252` | Actor label collapses to Forge & Flow admin/Admin user. No name/role/email. | Extend event model/API or enrich rows with actor display name, role, and email. |
| Schema | `db/migrations/202605050000_phase_8_data_accuracy_settings.sql:56` | Settings are per location only. | Add scoped override storage, migration, effective resolver, conflict handling, permissions, and audit history for business/org-unit/location writes. |

## Polling Setup

| Area | Current code | Gap | Action |
|---|---|---|---|
| Route/title | `lib/admin/admin_routes.dart:333`, `lib/admin/screens/polling_and_pricing_admin_screen.dart:454` | Still `Polling & pricing` with dense F&F subtitle. | Rename to `Polling Setup`, simplify copy. |
| Scope prompt/banner | `lib/admin/screens/polling_and_pricing_admin_screen.dart:85`, `:288` | Screen mirrors old popup/banner model. | Replace with shared split/tab workspace. |
| Scope options | `lib/admin/screens/polling_and_pricing_admin_screen.dart:288` | Options are business + location from assignment rows, not hierarchy tree. | Feed full hierarchy and descendant location ids. |
| Vendor filters | `lib/admin/screens/polling_and_pricing_admin_screen.dart:184` | Filters cover tier, margin, location count, business/location name only. | Add poll-only vendor filter. |
| Cost basis | `lib/admin/screens/polling_and_pricing_admin_screen.dart:338`, `:365` | UI writes monthly cost estimates directly. | Add calculator-first UI with manual override. |
| Default tier | `lib/services/data_accuracy/forge_flow_polling_tier_repository.dart:26` | Missing assignment returns null; worker fallback is test-covered elsewhere. | Make default Regular/Standard behavior visible and testable in UI. |
| Schema | `db/migrations/202605050000_phase_8_data_accuracy_settings.sql:140` | Tier assignments are per location only. | Add scoped polling assignment storage, migration, effective resolver, default Regular behavior, permissions, and audit history for business/org-unit/location writes. |

## People, Access, Roles

| Area | Current code | Gap | Action |
|---|---|---|---|
| Members summary | `lib/admin/screens/members_admin_screen.dart:986` | Visible members stat strip remains. | Remove entire visible members widget per request. |
| Grants | `lib/admin/screens/members_admin_screen.dart:535` | Role grant override supports org-unit and location scope. | Integrate with shared hierarchy context. |
| Permission chips | `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart:861` | Primary chips render raw permission keys. | Render human labels first; raw key in tooltip/details. |
| Permission catalog copy | `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart:971` | Copy says "full set of permission keys". | Rewrite for human permissions. |
| Sessions | `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart:1442` | Session UI is decent but still table/record-like. | Polish copy and grouping around person, device, place, last active, action. |

## Security, Audit, Support Logs

| Area | Current code | Gap | Action |
|---|---|---|---|
| Security action panel | `lib/admin/screens/audited_support_actions_admin_screen.dart:800` | Actions are present but not grouped by intent. | Group recovery/session/data protection/audit actions. |
| Audit actors | `lib/admin/screens/audited_support_actions_admin_screen.dart:1479` | Security audit already shows actor display name/email. | Use this as the target model for all log surfaces. |
| Support logs tabs | `lib/admin/screens/debug_console_admin_screen.dart:455` | Requests wired; Relationship help and Account help are stubs. | Wire Relationship help and Account help now, including backend/proxy routes, permissions, filters, empty states, and tests. |
| Support scope | `lib/admin/screens/debug_console_admin_screen.dart:671`, `lib/admin/services/debug_console_admin_gateway.dart:120`, `tool/advisor_proxy/advisor_proxy.dart:15309` | Org-unit scope resolves to location ids locally and the gateway can send `location_ids`, but there is no native server-side `org_unit_id` filter. | Fold into shared setup workspace and add performance proof or a native hierarchy filter route. |

## Connected Services And Vendor Integrations

| Area | Current code | Gap | Action |
|---|---|---|---|
| Global connected services | `lib/admin/screens/integration_admin_screen.dart:261` | Service Access and Shared Services have little explanatory copy. | Add short plain-English descriptions. |
| Static vendor catalog | `lib/admin/services/integration_admin_gateway.dart:356`, `tool/advisor_proxy/advisor_proxy.dart:14573` | Global status endpoint exists, but current rows mostly reflect adapter/catalog readiness rather than active per-location connection health. | Replace primary status/unlock logic with API reachability and expose the health source. |
| Per-location integrations | `lib/admin/screens/vendor_connections/vendor_connections_admin_mount.dart:161` | Location setup still auto-shows scope prompt when scope is not location. | Move into shared split/tab workspace and show "select a location" in scope pane. |
| Vendor grouping | `lib/integrations/ui/vendor_connections/vendor_connections_models.dart:20` | Models already support POS/Labor/Reservation categories. | Reuse for connected service grouping. |
| Keys | `lib/admin/screens/integration_admin_screen.dart:657` | One-time reveal exists after save. | Ensure subtitles/copy do not imply keys remain visible. |

## System, Launch, Knowledge

| Area | Current code | Gap | Action |
|---|---|---|---|
| System Health | `lib/admin/screens/health_admin_screen.dart:409`, `:701` | Main run button exists; "Service checks" still needs plain-English definition. | Keep central button, add concise explanations for Advisor data, App service, Ecosystem. |
| System Metrics | `lib/admin/admin_routes.dart:311`, `lib/admin/screens/observability_admin_screen.dart:333` | Surface is titled System metrics and mixes AI/cost/hosting language. | Move to AI as `AI Metrics`, apply hierarchy behavior, and remove code-ish request group copy from primary UI. |
| Launch Controls | `lib/admin/screens/feature_flags_admin_screen.dart:396` | Primary card shows `Control ID`. Dialog requires raw flag name. | Keep raw ID only in confirmation/details; primary UI plain English. |
| Knowledge Base | `lib/admin/screens/corpus_admin_screen.dart:1325`, `:2180` | Primary UI exposes source file and sha. | Hide technical details behind support details. Simplify relationship review states. |
| Plans and limits | `lib/admin/admin_routes.dart:256` | AI plans/limits route is in the AI section but not yet called out in the hierarchy cleanup. | Apply the shared hierarchy workspace, hide raw plan/quota internals behind advanced details, and verify scoped limit edits. |
| Actor identity policy | `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`, `tool/advisor_proxy/advisor_proxy.dart:17214` | The audit ledger stores actor ids/principals; some projections synthesize display names and blank email. | Implement full actor name, role, and email everywhere by denormalizing at write time or joining canonical identity at read time. |

## Test Gaps

| Test area | Current tests | Required updates |
|---|---|---|
| Old prompt | `test/admin/widgets/admin_hierarchy_scope_prompt_test.dart` | Keep for legacy widget only, but add tests proving setup tiles do not open it. |
| Data/Polling hierarchy | `test/admin/data_accuracy_polling_hierarchy_scope_screen_test.dart` | Rewrite around shared split/tab workspace and descendant location filtering. |
| Hierarchy management | `test/admin/screens/roles_hierarchy_sessions_admin_screen_test.dart`, `test/admin/services/roles_hierarchy_sessions_admin_gateway_test.dart` | Add Business Accounts move controls and HTTP org-unit move route/gateway tests. |
| Connected services | `test/admin/vendor_connections_admin_mount_test.dart`, `test/admin/admin_vendor_connections_gateway_test.dart` | Update no-popup scope behavior and live status grouping. |
| Browser evidence | Existing framework docs under `docs/frameworks` | Run Browser Use after each UI slice and again after final merge. |
| Full route inventory | `docs/_execution/admin_hierarchy_ux_cleanup/06_full_surface_inventory.md` | Add a final test/evidence row for every admin route and hidden handoff. |
