# Backend Surface UX Audit Additions

Date: 2026-05-06

Branch: `codex/backend-surface-ux-audit-additions`

Worktree: `.codex_worktrees/backend-surface-ux-audit-additions`

Base: `origin/master` at `f7b2a6ad20045d905d15056fbb03baa3a18ec133`

First audit baseline: `1060a2d5e29e21edaacd2a6cf96ef19b84c507ac`

Backup branch before the fast-forward: `codex/backup/backend-surface-ux-audit-additions-20260506-045132`

Main checkout note: the primary repo checkout stayed on `master`; this work was done in the worktree above.

## Scope

This pass audited additions that landed after the first backend surface audit:

- mobile push routes, token and outbox tables, sender and dispatcher plan
- business timing tables, resolver, open shift snapshots, and live Shift implications
- Operator Web account, business setup, members, roles, hierarchy, sessions, audit log, security, vendor connections, data accuracy, onboarding, forbidden, loading, empty, and error states
- F&F Operations Console members, roles, hierarchy, sessions, support actions, operators, locations, timing affordances, data accuracy, feature flags, debug, health, and observability
- vendor lifecycle for 17 implemented adapters plus Aloha sink fanout
- realtime, health, support, debug, and observability tripwires

Guardrails applied:

- no production deploy
- no shared staging deploy before preview
- no write smoke against the preview because it used staging secrets
- no invented UI for backend capabilities that are not routed, wired, or complete
- documented backend-only, gated, incomplete, and intentionally unsurfaced items

## Backend Inventory

Mobile push:

- Routes exist in `tool/advisor_proxy/advisor_proxy.dart`: `/v1/auth/mobile/push-token/register`, `/v1/auth/mobile/push-token/revoke`, and `/v1/auth/mobile/push/test`.
- Persistence is covered by `mobile_push_tokens` and `mobile_push_outbox`.
- Sender and safe payload construction are covered by the FCM HTTP v1 sender tests.
- Route and repository tests prove token material is not echoed and plaintext token storage is avoided.
- Runtime proof is still gated by Firebase credentials, device tokens, and staging-safe approval before using `/v1/auth/mobile/push/test`, because that route can send a real push.

Business timing and live Shift:

- Schema exists for `business_timing_profiles`, `business_timing_service_periods`, `business_timing_audit_events`, and `open_shift_snapshots`.
- `BusinessTimingProfileResolver` and repository tests cover inheritance, validation, audit write shape, and open shift snapshot storage.
- The phase plan still marks the projector and production proxy read/write routes incomplete. No write UI was added.
- Current Operator Web Business setup and admin location timing affordances remain safe display shells until routed live writes exist.

Operator Web team self-service:

- Existing backend auth operation handlers support users, invites, roles, hierarchy, own sessions, audit log, and security routes.
- The shipped route names were admin-prefixed for several self-service gateways. This pass added `/v1/auth/team/*` aliases over the existing backend handler and moved operator-web gateways to those self-service paths.
- Team-wide sessions listing is still not backed by a proxy route. The live source intentionally throws a clear `team_sessions_not_routed` error instead of falling back to demo data.

F&F Operations Console:

- Members, invites, roles, hierarchy, sessions, audited support actions, data accuracy, feature flags, debug, health, and observability are routed and tested.
- `ff_support` read-only behavior is preserved by existing route and screen tests.
- A missing Permission Explainer catalog description for `admin.users.reset_mfa_factors` was surfaced by the full operator-web suite and fixed with the verbatim migration copy.

Vendor lifecycle:

- The backend adapter inventory is 17 implemented adapters: 7 POS, 4 reservation, and 6 labor.
- The adapter registries and vendor capability index prove the implemented adapters exist and remain in the documented lifecycle.
- The live operator-web vendor picker no longer collapses the catalog to three production-credentialed vendors. It now uses the same canonical catalog as the admin picker so documented adapters show accurate lifecycle and disabled connect state.
- Notify-me and vendor availability email handoff remain documented only unless the backend handoff is proven routed.

Health, debug, observability:

- Event outbox, health envelope, feature flag, debug console, and observability route tests pass.
- Mobile push queue health should remain an observability candidate only where producers expose backed metrics.
- Heavy automatic polling was not added.

## Frontend Inventory

Operator Web surfaces:

- `Members`, `Roles`, `Permission Explainer`, `Locations and hierarchy`, `Sessions`, `Audit Log`, and `Security` all have focused widget or gateway tests.
- The live Firebase source now supplies real web gateways for team users, roles, hierarchy, own sessions, audit log, and security.
- `Account`, `Business setup`, `Vendor connections`, and `Data Accuracy` were audited but not expanded beyond backed capabilities.
- Loading, empty, error, forbidden, and onboarding states remain covered by the existing operator-web tests.

F&F Operations Console surfaces:

- `Members + Invites`, `Roles + Hierarchy + Sessions`, `Audited Support Actions`, `Data Accuracy`, `Feature flags`, `Debug`, `Health`, and `Observability` are covered by `test/admin`.
- The admin shell read-only corpus route test was hardened to scroll the nav item into view before tapping it, preserving the `ff_support` read-only assertion.

## Gap Matrix

| Capability | API, service, or repository path | Current UX surface | Missing or incomplete UX | Role or permission | Mutation risk | Test coverage | Performance risk | Preview or runtime proof needed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Mobile push register and revoke | `/v1/auth/mobile/push-token/register`, `/v1/auth/mobile/push-token/revoke`, `MobilePushTokensRepository` | Mobile runtime token coordinator, no admin/operator console control | No web status or token management surface | Authenticated mobile user | Token secrecy, revocation scope | Route, repository, coordinator tests pass | Low UI risk, dispatch queue proof pending | Device token and Firebase sender proof in preview-only or approved staging |
| Mobile push test send | `/v1/auth/mobile/push/test`, FCM sender | No console button | Intentionally not surfaced because it can send real pushes | Authenticated mobile user, staging gate | Real notification send | Sender and route tests pass | Low UI risk | Requires exact action-time approval and safe token |
| Mobile push outbox health | `mobile_push_outbox`, outbox producers | Health has event outbox tripwires | No dedicated push queue health unless producer exists | F&F admin read | Read-only | Outbox producer tests pass | Avoid extra polling | Add only after producer emits backed metric |
| Business timing profiles | `BusinessTimingProfilesRepository`, `BusinessTimingProfileResolver` | Operator Business setup and admin location timing display shells | No live write forms or audited profile editor | Operator owner/admin, F&F admin for admin surface | Timing writes affect service-period math | Resolver and migration tests pass | Low if read-only | Needs routed read/write proxy and preview data mode |
| Open shift snapshots | `OpenShiftSnapshotsRepository`, `open_shift_snapshots` | Shift fallback/unavailable states only | No projector-backed live Shift selector yet | Operator shift access | Snapshot accuracy | Repository and migration tests pass | Medium if polled often | Projector plus live proxy route proof |
| Operator team users self-service | `/v1/auth/team/users`, `/v1/auth/team/invites` aliases | Members screen, live gateway | None for backed user/invite actions | `team.users.*` | User state changes need idempotency | Operator-web, route, role tests pass | Bounded table tests pass | Preview auth credentials for authenticated smoke |
| Operator roles self-service | `/v1/auth/team/roles`, `/v1/auth/team/role-grants` aliases | Roles and editor, live gateway | None for backed role actions | `team.roles.*` | Role grants affect access | Operator-web and route tests pass | Low, no polling added | Preview auth credentials for authenticated smoke |
| Operator hierarchy self-service | `/v1/auth/team/org-units`, `/v1/auth/team/locations/*` aliases | Locations and hierarchy, live gateway | None for backed hierarchy actions | `team.roles.assign` and hierarchy grants | Location moves affect scope | Operator-web and route tests pass | Low | Preview auth credentials for authenticated smoke |
| Operator sessions | Own sessions route through `WebTeamSessionsGatewayLive` | Sessions screen | Team-wide sessions are not routed live | Own user for own sessions, team admin for team-wide | Session revocation | Operator-web session tests pass | Low | Add backend route before live team-wide list |
| Operator audit log | Team audit log gateway | Audit Log screen | No extra exports beyond backed gateway | `team.audit_log.*` | Export requires idempotency and audit | Operator-web suite passes | Low, manual refresh | Preview auth credentials |
| Operator security | Security gateway | Security screen | No unbacked MFA reset beyond existing flow | Own user, `team.users.reset_mfa` for team member flow | MFA recovery | Operator-web suite passes | Low | Preview auth credentials |
| Admin Permission Explainer | `PermissionKeys.all`, migration catalog | Admin and operator explainers | Missing `admin.users.reset_mfa_factors` copy fixed | Read-only catalog | None | Operator-web and admin tests pass | None | Local tests sufficient |
| Vendor lifecycle catalog | `InMemoryVendorConnectionsGateway.vendorCatalog`, adapter registries | Admin and operator vendor pickers | Notify-me email handoff still not proven routed | `integrations.configure` to connect, view for browse | Connect disabled for documented vendors | Vendor UI and adapter tests pass | Low | Authenticated preview smoke for picker when credentials exist |
| Data accuracy service-period settings | Data accuracy repositories and admin routes | Admin and operator data accuracy screens | Service-period-keyed contract not fully routed in current UX | F&F admin writes, `ff_support` read-only | Data override writes | Admin, repository, proxy tests pass | Avoid heavy polling | Add only when contract route shape lands |
| Feature flags | Admin feature flag routes and gateway | Admin feature flags | No operator self-service surface | F&F admin | Destructive toggles | Admin and proxy tests pass | Idempotency and concurrency covered | Preview write smoke needs approval |
| Debug console | Admin debug routes and gateway | Admin debug console | No mobile/operator debug UI | F&F admin/support | Sensitive logs | Admin tests pass | Live tail bounded | Read-only preview with auth credentials |
| Health and observability | `/readyz`, health envelope, observability gateway | Admin health and observability | No mobile push dedicated metric until producer exists | F&F admin/support read | Read-only | Admin and proxy tests pass | Enforced perf probe passed | Preview `/readyz` and perf JSON captured |

## Implemented Surfaces

1. Added operator self-service auth operation aliases in `tool/advisor_proxy/advisor_proxy.dart`.
   - `/v1/auth/team/invites`
   - `/v1/auth/team/users`
   - `/v1/auth/team/roles`
   - `/v1/auth/team/role-grants`
   - `/v1/auth/team/org-units`
   - `/v1/auth/team/locations/{location_id}/org-unit`

2. Moved operator-web team users, roles, and hierarchy gateways to `/v1/auth/team/*`.

3. Expanded auth operation CORS methods to include `PATCH` and `DELETE` for the self-service aliases.

4. Wired the live Firebase operator-web source to real web gateways for:
   - team users
   - team roles
   - team hierarchy
   - own sessions
   - audit log
   - security

5. Kept team-wide session listing intentionally unsurfaced in live mode by returning a clear not-routed error instead of demo data.

6. Updated the live operator-web vendor catalog to use the canonical 17-adapter lifecycle catalog, keeping documented adapters visible but not connectable.

7. Added the missing Permission Explainer description for `admin.users.reset_mfa_factors` from the additive migration text.

8. Hardened the admin `ff_support` corpus read-only shell test so it scrolls the nav item into view before tapping.

## Intentionally Unsurfaced

- Mobile push status and test-send UI: backend exists, but runtime proof needs Firebase/device token safety. The test route can send real pushes.
- Mobile push queue health: only surface after a producer emits a backed push queue metric.
- Business timing write UI: repository and schema exist, but the phase plan still marks live proxy timing routes, open-shift projector, and audited write UI incomplete.
- Live Shift service-period selector backed by open snapshots: not surfaced until projector and route proof land.
- Data accuracy service-period-keyed settings: current UX remains on the shipped shape until the amended contract is routed.
- Vendor notify-me email handoff: not surfaced as a live handoff because backend routing was not verified.
- Connect flows for documented or sandbox-only vendor adapters: not promoted. Lifecycle state remains visible and connect remains disabled.
- Team-wide operator sessions in live mode: not routed, so the live source does not fake team session data.
- Mobile APK build: not run because this pass did not change mobile push client code. Mobile push unit, route, sender, and repository tests were run.
- Shared staging and production: not deployed.

## Verification

Local checks:

- `flutter analyze`: pass
- `flutter test test\operator_web`: pass, 260 tests
- `flutter test test\admin`: pass, 349 tests
- Mobile push, business timing, data accuracy, health, feature flags, observability, Aloha sink, and vendor status slice:
  `flutter test test\proxy_auth_operations_route_grants_test.dart test\proxy\mobile_push_routes_test.dart test\db\mobile_push_notifications_migration_test.dart test\db\mobile_push_repositories_test.dart test\mobile_push_notification_service_test.dart test\services\mobile_push_sender_test.dart test\business_timing_profile_resolver_test.dart test\phase_business_timing_live_postgres_test.dart test\admin\feature_flags_admin_gateway_test.dart test\admin\debug_console_admin_gateway_test.dart test\admin\health_admin_gateway_test.dart test\admin\observability_admin_screen_test.dart test\admin\data_accuracy_live_wiring_test.dart test\services\data_accuracy\data_accuracy_settings_repository_test.dart test\services\data_accuracy\data_accuracy_migration_test.dart test\services\data_accuracy\forge_flow_polling_tier_repository_test.dart test\proxy\feature_flags_concurrency_test.dart test\proxy\feature_flags_idempotency_test.dart test\proxy\data_accuracy_admin_routes_test.dart test\proxy\advisor_proxy_health_envelope_test.dart test\proxy\health_producers\outbox_producers_test.dart test\infrastructure\persistence\postgres\aloha_ncr_voyix_pos_postgres_sink_test.dart test\tool\advisor_proxy\vendor_admin_status_catalog_test.dart`: pass, 203 tests
- Vendor adapter registry and sink slice:
  `flutter test test\tool\advisor_proxy\pos_adapter_registry_test.dart test\tool\advisor_proxy\reservation_adapter_registry_test.dart test\tool\advisor_proxy\labor_adapter_registry_test.dart test\tool\advisor_proxy\vendor_capability_index_test.dart test\integration\vendor_timestamp_sanity_test.dart test\services\integration\canonical_sink_contract_test.dart test\infrastructure\persistence\postgres\oracle_micros_simphony_postgres_sink_test.dart test\infrastructure\persistence\postgres\libro_postgres_sink_test.dart test\infrastructure\persistence\postgres\quickbooks_time_postgres_sink_test.dart test\integrations\labor\push_operations_labor_adapter_test.dart`: pass, 84 tests
- Role and auth behavior slice:
  `flutter test test\admin\forge_admin_role_check_test.dart test\admin_auth_gate_test.dart test\role_admin_live_binding_test.dart test\proxy_auth_operations_route_test.dart test\proxy_auth_operations_gateway_test.dart test\proxy_auth_operations_gateway_grants_test.dart test\users_repository_team_users_grants_test.dart test\users_repository_actor_resolution_test.dart test\operator_web\operator_web_router_test.dart test\operator_web\screens\members_screen_test.dart test\operator_web\screens\roles_screen_test.dart test\operator_web\screens\hierarchy_screen_test.dart test\operator_web\screens\sessions_screen_test.dart test\operator_web\screens\security_screen_test.dart`: pass, 231 tests
- Auth CORS alias slice:
  `flutter test test\proxy\auth_cors_routes_test.dart`: pass, 3 tests
- Admin web build:
  `flutter build web --release --target=lib\main_admin.dart --dart-define=ADMIN_PROXY_BASE_URI=https://preview-proxy.example.invalid --dart-define=ADMIN_DEMO_AUTH=false --pwa-strategy=none`: pass
- Operator web build:
  `flutter build web --release --target=lib\main_operator_web.dart --output=build\operator_web --dart-define=OPERATOR_WEB_PROXY_BASE_URI=https://preview-proxy.example.invalid --dart-define=OPERATOR_WEB_DEMO_AUTH=false --pwa-strategy=none`: pass

Migration status:

- No migrations were changed.
- Mobile push and business timing migration tests passed.
- Migration drift and cutoff fix commands were not required.

Preview runtime:

- Preview deploy command:
  `powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 -PreviewName backend-surface-additions -SkipApiEnable -SkipSecretManagerSync`
- Database mode: `forge-flow-staging-` secrets, runtime-isolated preview with shared staging data. Browser smoke was read-only.
- Admin URL:
  `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app`
- Proxy URL:
  `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app`
- Admin revision:
  `forge-flow-preview-backend-surface-additions-admin-00001-lth`
- Proxy revision:
  `forge-flow-preview-backend-surface-additions-proxy-00002-m6s`
- Admin traffic:
  `forge-flow-preview-backend-surface-additions-admin-00001-lth / 100%`
- Proxy traffic:
  `forge-flow-preview-backend-surface-additions-proxy-00002-m6s / 100%`
- Proxy `/readyz`: 200
- Admin-origin CORS preflight: 204

Operator-web preview:

- Deploy command:
  `powershell -ExecutionPolicy Bypass -File scripts\deploy_operator_web.ps1 -Service forge-flow-preview-backend-surface-additions-operator-web -ProxyBaseUri https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app -SkipApiEnable`
- Operator-web URL:
  `https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app`
- Operator-web revision:
  `forge-flow-preview-backend-surface-additions-operator-00001-nmw`
- Operator-web traffic:
  `forge-flow-preview-backend-surface-additions-operator-00001-nmw / 100%`

Performance evidence:

- Command:
  `dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-admin-00001-lth --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00002-m6s --label=backend-surface-additions-preview --write-json=build\perf_gate\backend_surface_additions_preview.json`
- Result: pass with enforced budgets.
- JSON path: `build\perf_gate\backend_surface_additions_preview.json`
- Probe summary:
  - `admin_index_c1`: 200 for 10 requests, p95 338.9 ms
  - `admin_index_c4`: 200 for 20 requests, p95 190.9 ms
  - `admin_mainjs_gzip_c4`: 200 for 20 requests, p95 1288.1 ms
  - `proxy_readyz_c1`: 200 for 10 requests, p95 218.5 ms
  - `proxy_readyz_c4`: 200 for 20 requests, p95 204.7 ms

Browser Use evidence:

- Opened cache-busted preview admin URL:
  `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app/?cache_bust=backend-surface-additions-20260506`
- Admin page title observed:
  `Forge & Flow Admin Console`
- Browser logs showed Firebase core, auth, and messaging initialization.
- Opened cache-busted preview operator-web URL:
  `https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app/?cache_bust=backend-surface-additions-20260506`
- Operator-web page title observed:
  `Forge & Flow - Operator Web Console`
- Authenticated screen smoke was not performed because the preview uses live Firebase auth and no action-time credentials were provided. No write actions were submitted.
- The in-app Browser snapshot exposed Flutter's accessibility bootstrap only, so local widget tests and preview readiness/performance checks are the screen-level evidence for the gated surfaces.

## Residual Risks

- Authenticated Browser smoke for admin and operator-web still needs preview-safe credentials.
- Preview used staging secrets, so write workflows were not exercised in browser.
- `/v1/auth/team/*` aliases still pass through the existing auth operation handler. That keeps behavior backed by real code, but it does not split the handler into a separate self-service module yet.
- Team-wide session listing remains a backend route gap.
- Mobile push test send remains gated by Firebase/device proof and exact write approval.
- Business timing and open-shift snapshot UI should stay read-only until projector plus live proxy routes land.
- Data accuracy service-period-keyed settings need routed contract proof before surfacing.
- Vendor notify-me email handoff should stay unsurfaced until the backend route or email event is verified.
- No shared staging or production deployment was performed.
