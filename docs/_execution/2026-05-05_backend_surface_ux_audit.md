# Backend Surface UX Audit

Date: 2026-05-05
Branch: `codex/backend-surface-ux-audit`
Base commit: `1060a2d5e29e21edaacd2a6cf96ef19b84c507ac`

## Scope

This audit compared implemented backend and proxy capabilities against the
admin and operator UX. The pass followed:

- `PROJECT_TRACKER.md`
- `docs/UX_ADJUSTMENT_FRAMEWORK.md`
- `docs/PERFORMANCE_FRAMEWORK.md`
- `docs/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`
- relevant `docs/contracts/**`
- `runbooks/admin_console_browser_qa_runbook.md`
- `runbooks/preview_environment_runbook.md`, which was absent on the base
  branch
- `scripts/deploy_preview_stack.ps1`, which was absent on the base branch
- `scripts/deploy_staging_proxy.ps1`
- `scripts/deploy_admin_console.ps1`

## Backend Inventory

Admin proxy routes and service gateways present in code:

- Auth and roles: `/v1/admin/auth/invites`,
  `/v1/admin/auth/users`, `/v1/admin/auth/roles`,
  `/v1/admin/auth/role-grants`, `/v1/admin/auth/org-units`,
  `/v1/admin/auth/locations/*`, and `/v1/admin/service-principals`.
- Operators and locations: `/v1/admin/operators` and
  `/v1/admin/locations`.
- Connected services: `/v1/admin/integrations`,
  provider rotation routes for Anthropic, Voyage, Azure DB, Gemini, and
  SendGrid, plus `/v1/admin/integrations/status`.
- Vendor connection spine: location scoped integration list,
  OAuth start/callback, key connect, test connection, disconnect, and logs
  under `/v1/admin/integrations/*`.
- Email integration test: `/v1/admin/integrations/email/test`.
- Data accuracy: rows, settings, and audit history under
  `/v1/admin/data-accuracy/*`.
- Polling and pricing: tier definitions, assignments, margin, CSV export,
  and change requests under `/v1/admin/polling-pricing/*`.
- Corpus and graph operations: corpus versions, upload, preview diff, commit,
  rollback, graph candidates, graph candidate batch commit, and AGE rebuild.
- Feature flags: `/v1/admin/feature-flags` and toggle.
- Support and debug: debug requests, request lookup, request tail, full content
  opt-ins, and `/v1/admin/observability`.
- Health and monitoring: proxy `/readyz`, `/health`, Cloud Run revision
  metadata, and the admin health and metrics surfaces.

Implemented vendor adapters found in registries:

- POS: Aloha (NCR Voyix), Clover, Lightspeed Restaurant K-Series,
  Oracle MICROS Simphony, Revel Systems, Square, and Toast.
- Reservations: Libro Reserve, OpenTable, SevenRooms, and Tock.
- Scheduling and labor: ADP Workforce Now / Workforce Manager, Agendrix,
  Humanity, Push Operations, QuickBooks Time, and 7shifts.

## Frontend Inventory

Admin and operator surfaces present in code:

- Admin shell and side nav groups for Access, Operations, Knowledge, Systems,
  and Launch.
- Operators and locations screen with support logs, data accuracy, polling and
  pricing, and location level integration access.
- Connected services screen for provider status and key rotation.
- Vendor connection mount used from the location action surface.
- Data accuracy screen and polling and pricing screen.
- Debug console and support log screen.
- Health and observability screen.
- Feature flags and launch controls screens.
- Empty, loading, and error states across the audited admin screens.
- Admin auth gate and role behavior for authenticated admin sessions.

## Gap Matrix

| Capability | API or service path | Current UX before patch | Missing UX | Role and permission | Mutation risk | Test coverage | Performance risk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Implemented vendor adapters | Adapter registries and `/v1/admin/integrations` | Connected services showed Compeat and Marketman placeholders | Full implemented adapter catalog, setup state, cadence, and covers behavior | Readable by admin roles | Read-only projection | Integration admin gateway, proxy KMS revision, vendor catalog drift test | Low, static projection |
| Location vendor setup picker | `/v1/admin/operators/:operator_id/locations/:location_id/integrations` and vendor connect routes | Demo picker showed only three vendors and treated them as connectable | Full vendor catalog, lifecycle labels, and disabled continue for non-connectable vendors | Mutating only when backend lifecycle allows and screen role permits | Prevents false connect attempts | Vendor connections widget tests | Low, bounded dialog list height |
| Operator and location mutators | `/v1/admin/operators`, `/v1/admin/locations` | Operators route did not read the admin auth source | Support role needed read-only UX with hidden mutators | `super_admin` can mutate, `ff_support` is read-only | Lower risk, mutator methods also short circuit | Operator admin tests and admin shell tests | Low, role stream only |
| Preview runtime | Deployment scripts | No preview stack wrapper on base branch | Preview first deploy wrapper using existing staging proxy and admin deploy scripts | Operator approval still required for shared staging | Preview only, no production | Script reviewed through live preview deploy | Medium operational risk, verified with revisions and readyz |
| Live vendor connect actions | Phase 8 integration route holder | Some route code exists, but production binding is not fully live for all vendors | Not surfaced as live for documented adapters | Kept read-only unless lifecycle is connectable | Avoids inventing backend readiness | Documented residual gap | Low |

## Surfaces Added Or Adjusted

- Replaced stale Connected services vendor placeholders with the implemented
  adapter catalog.
- Added a pure Dart admin vendor status catalog for the proxy so AOT proxy
  compilation stays free of Flutter imports.
- Updated the demo and setup vendor picker to show all implemented adapters
  with human-readable names and lifecycle status.
- Disabled connection flow continuation for `documented` and
  `sandboxVerified` adapter lifecycles.
- Added support-role read-only behavior to Operators and Locations, including
  hidden mutation controls and an explicit read-only banner.
- Added a preview stack deploy wrapper that deploys proxy first, deploys the
  admin console against that proxy, and updates proxy CORS to the preview admin
  origin.

## Backend Functionality Intentionally Not Surfaced

- Live connect, test, disconnect, OAuth start, and credential paste controls
  were not made available for adapters whose lifecycle is only documented or
  sandbox verified. The backend catalog does not prove production credentials
  are live, so the UX must not imply those actions are safe.
- Shared staging deployment was not run. The prompt requires preview
  acceptance before shared staging.
- Production deployment was not run.
- Backend architecture was not rewritten. The changes are projections, role
  gates, and a preview wrapper over existing deploy scripts.

## Verification

Local checks:

- `flutter analyze`: pass.
- `flutter test test\admin`: pass.
- Targeted admin, proxy, vendor adapter, and gateway tests: pass.
- `dart compile exe tool\advisor_proxy\main.dart -o build\advisor_proxy_test.exe`:
  pass. Temporary executable removed after verification.
- `flutter build web --release --target=lib\main_admin.dart
  --dart-define=ADMIN_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-audit-proxy-rf7nosnoka-pd.a.run.app`:
  pass.

Preview runtime:

- Deploy command used:
  `powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 -PreviewName backend-surface-audit -SkipApiEnable -SkipSecretManagerSync -VpcConnector ff-staging-proxy-egress -VpcEgress all-traffic`
- Admin service: `forge-flow-preview-backend-surface-audit-admin`.
- Admin revision: `forge-flow-preview-backend-surface-audit-admin-00001-6m5`.
- Admin URL:
  `https://forge-flow-preview-backend-surface-audit-admin-rf7nosnoka-pd.a.run.app`.
- Proxy service: `forge-flow-preview-backend-surface-audit-proxy`.
- Proxy revision: `forge-flow-preview-backend-surface-audit-proxy-00004-k8b`.
- Proxy URL:
  `https://forge-flow-preview-backend-surface-audit-proxy-rf7nosnoka-pd.a.run.app`.
- Both services reported latest Ready revision and 100 percent traffic.
- Proxy `/readyz`: HTTP 200 with `{"status":"ok"}`.
- Admin-origin CORS preflight to `/v1/admin/integrations`: HTTP 204 with the
  preview admin origin allowed.

Performance evidence:

- Command:
  `dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-audit-admin-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-audit-proxy-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-audit-admin-00001-6m5 --proxy-revision=forge-flow-preview-backend-surface-audit-proxy-00004-k8b --label=backend-surface-audit-preview --write-json=build\perf_gate\backend_surface_audit_preview.json`
- Result: pass with enforced budgets.
- JSON evidence: `build\perf_gate\backend_surface_audit_preview.json`.
- Main JS gzip transfer: 1,107,327 bytes, under the 1,250,000 byte budget.

Browser Use evidence:

- Browser Use was attempted against the fresh cache-busted preview admin URL.
- The Browser Use runtime blocked navigation to the Cloud Run preview URL under
  its browser security policy. No alternate browser automation or policy
  workaround was used.
- Authenticated preview screen smoke remains blocked pending an allowed Browser
  Use target or manual browser access.

Database mode:

- Preview used the default staging secret prefix, `forge-flow-staging-`.
- The verification pass stayed read-only. No staging data mutation was run.

## Residual Risks

- Authenticated Browser Use smoke for route switching, filters, large table
  scrolling, empty/loading/error states, repeated refresh, and duplicate
  request behavior still needs an allowed browser target.
- Preview shares staging data because it used staging secrets. Any future write
  test needs exact action-time approval or isolated preview Postgres secrets.
- The preview wrapper depends on existing staging deploy scripts and Cloud Run
  service naming conventions. It should be promoted to the runbook once the
  team accepts this preview workflow.
