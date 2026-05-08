# Full Surface Inventory

This inventory prevents the implementation from becoming a partial UX cleanup.
Every admin route, hidden handoff, and setup function below needs an explicit
implementation result and evidence row before the final audit closes.

## Global Rules For Every Surface

- Use the shared hierarchy behavior: selected business, org unit, or location is
  the current scope.
- Default to selected business scope when no hierarchy row is selected.
- If no business is selected, show all businesses collapsed in the scope pane.
- Do not use the setup scope popup.
- Hide raw IDs, hashes, permission keys, route IDs, control IDs, and provider
  internals from primary UI. Put them in advanced details only.
- Mutations must include permission checks, audit events, error handling, and
  Browser Use evidence.

## Route Inventory

| Route or surface | Current route id | Target behavior | End-to-end requirements |
|---|---|---|---|
| Business Accounts | `operators` | Command center for hierarchy selection and setup launch. | Header cleanup, New Business emphasis, profile widget action, grouped setup buttons, hierarchy move/suspend/delete controls, route handoff tests. |
| Account Profile | Setup function from Business Accounts | Profile editing lives in the top business widget, scoped to selected business. | Profile gateway validation, audit event, Browser Use edit proof. |
| Hierarchy Management | Business Accounts panel and roles hierarchy gateway | Move locations, move org units, suspend hierarchy levels, delete hierarchy levels. | Proxy routes, HTTP gateway, schema constraints, permissions, audit reasons, descendant-move guard tests. |
| Timing | Setup function from Business Accounts | Uses shared hierarchy behavior and inherits business/org-unit/location context. | Confirm timing storage/gateway, implement scoped editing or clear inherited values, test timezone/service-period edits. |
| Covers and Wage Data Accuracy | `data-accuracy` | Editable scoped overrides for covers, walk-ins, wage data, and logs. | Migration, scoped resolver, proxy/gateway writes, vendor filter, sort model, actor name/role/email, safe mutation tests. |
| Polling Setup | `polling-pricing` | Editable scoped polling tier/cost setup with calculator. | Migration, scoped resolver, default Regular tier, vendor filter, calculator, proxy/gateway writes, audit tests. |
| People, Access and Roles | `members` plus `roles-hierarchy-sessions` | Human access management with shared hierarchy context. | Remove visible-member stat, human permissions, role grants at scope, active sessions polish, permission tests. |
| Access | `roles-hierarchy-sessions` | Hierarchy, roles, and sessions remain first-class but use the shared scope model. | Role grant/revoke tests, session force-logout tests, human permission catalog. |
| Security and Audit | `audited-support-actions` | Grouped safety actions and full actor identity. | Actor identity join/denormalization, grouped actions, permission checks, audit export tests. |
| Support Logs | `debug` | Requests, Relationship help, and Account help are wired and hierarchy-aware. | Backend/proxy routes, filters, org-unit/location expansion or native scope filter, empty states, Browser Use evidence. |
| Connected Services | `integrations` | Service access, shared services, and vendor health with API-reachable status. | API reachability checks, POS/Labor/Reservation grouping, unlock state, one-time key reveal tests. |
| Vendor Integrations | Vendor setup mount | Location setup inside shared scope workspace. | Remove popup path, location-required state, health/unlock integration, credential tests. |
| Plans and Limits | `pricing` | AI plans and limits use hierarchy behavior. | Scoped limit reads/writes, human labels, raw quota details behind advanced panel, mutation tests. |
| Knowledge Base | `corpus` | Plain-English content management and relationship review. | Hide hashes/source paths by default, clearer review states, hierarchy context, publish/restore tests. |
| System Health | `health` | Hierarchy-aware health checks with plain-English Advisor data, App service, and Ecosystem groups. | Scoped check request shape, central run button, result evidence, no duplicate middle widget. |
| AI Metrics | `observability` renamed/moved | AI telemetry under the AI section, not System monitoring. | Route/nav change, hierarchy-aware filters, central run button, plain-English metric labels. |
| Launch Controls | `feature_flags` | Plain-English feature control management with hierarchy context. | Hide control IDs by default, scoped launch behavior, confirmation/audit tests. |
| Hidden Support Workspace | `support-operator-view` | Either removed or explicitly registered so handoff never falls back silently. | Route-table decision, shell fallback tests, migration of any handoffs. |
| Operator Picker Shells | `operator-picker` and embedded pickers | Replaced by shared hierarchy scope where possible. | Remove redundant choose-operator flows from setup screens, route tests. |

## Final Evidence Row Required

For each inventory row, the final evidence bundle must include:

- implemented branch/PR
- files changed
- targeted tests
- Browser Use URL and outcome
- safe mutation result when applicable
- performance/UX note
- residual risk, if any
