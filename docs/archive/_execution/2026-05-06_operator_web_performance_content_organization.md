# Operator Web Performance And Content Organization Pass

Date: 2026-05-06
Worktree: `C:\Git Local Repos\forge_flow_demo\.codex_worktrees\operator-web-full-verification`
Branch: `codex/operator-web-performance-content-organization`

## Source And Preview

- Worktree start commit: `f347cab10763f8a0742cae0370ae42c39925d73d`.
- `origin/master` at start of this pass was `f347cab1`; during verification it advanced through `02072b11`, `d12eda81`, and finally `5ee7ee95`.
- Runtime deploy commit: `6385f869f42393911670b7dfe5039ec885c2c99b`, rebased on `origin/master` commit `5ee7ee95`.
- Closeout documentation was amended after the runtime deploy; the final pushed branch commit is recorded on the PR.

Baseline preview before this pass:

| Surface | URL | Revision | Traffic |
| --- | --- | --- | --- |
| Operator web | `https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-operator-00013-z5g` | 100% |
| Preview proxy | `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-proxy-00050-znm` | 100% |

Database mode: the preview proxy is backed by `forge-flow-staging-` Secret Manager values, including staging Postgres and Firebase secrets. Live destructive checks are therefore constrained; the full button and mutation sweep for this pass ran against the local demo-auth build with routed, in-memory operator gateways.

## UX Research Basis

- NN/g card-sorting guidance frames category grouping as a way to expose users' mental models and refine information architecture.
- NN/g tree-testing guidance recommends validating labels/categories against findability and task completion, not internal implementation ownership.
- GOV.UK user-needs guidance says service architecture and content should be based on action-oriented user tasks.
- GOV.UK content-design guidance emphasizes plain English and helping users find what they need quickly.
- Material Design list guidance recommends logical ordering and switching to card-style presentation when dense rows carry more than a few lines of content.

Resulting operator-web pattern:

- Keep the existing top-level task tabs: Business, People & access, Data & integrations.
- Start each route with a small status summary so operators can scan state before reading details.
- Split route bodies into named sections that match the task: setup, sources, fallback, monitoring, members, roles, active sessions, history.
- Keep tables for wide screens, but switch cramped operational rows to compact cards when columns stop being readable.
- Keep copy short, parallel, and specific; do not surface fake writes for backend functionality that is not routed.

## Framework Checklist

UX Adjustment Framework:

- Setup flow, account shell, business setup, business timing, roles, permission explainer, state copy, dialogs, mobile-width layouts, and human-readable labels were reviewed.
- Added route-level summary strips across account, business setup, members, roles, locations, sessions, security, audit log, vendor connections, and data accuracy.
- Reworked Members narrow layout into readable member cards with the same action menu.
- Reworked Audit Log narrow rows so timestamp, actor, target, and payload actions stack cleanly instead of wrapping letter by letter.
- Tightened Data Accuracy into Sources, Fallback entries, and Monitoring sections with explicit retry on vendor context load failure.

Performance Framework:

- Login now starts account-info and permission-snapshot reads in parallel after the session login ledger call.
- Sessions now starts own-session and team-session reads in parallel when the role can view team sessions.
- Added stale-load generation guards to route loaders where quick switching or filter changes could let old async results overwrite fresh state.
- Confirmed no new polling, unbounded list rendering, or repeated navigation loops were introduced.
- Enforced perf probe passed locally with gzip transfer semantics at `build\perf_gate\operator_web_perf_content_final_local_gzip.json`.

Mobile Web Console E2E Framework:

- Browser Use full click sweep ran with fresh localhost origins and cache-bust URLs because the in-app Browser Use policy blocked automation of the external Cloud Run URL.
- The sweep covered safe read-only flows and local demo mutations for setup, locations, members, roles, security, sessions, audit log, vendor connections, and data accuracy.
- Mobile notification tap behavior was not replayed because mobile push source was not touched and no live notification session was available; proxy mobile push tests passed.

## Route Evidence

Browser evidence root:

`build\reports\operator_web_perf_content_browser_2026-05-06T2303Z`

Manifest:

`build\reports\operator_web_perf_content_browser_2026-05-06T2303Z\browser_evidence_manifest.json`

The manifest records 69 screenshots and zero page console warnings/errors for the final local demo sweep.

| Route or flow | Evidence |
| --- | --- |
| Sign-in and setup | `00_shell_business_account.png`, onboarding screenshots captured in manifest |
| Account setup and My account | `03_my_account.png`, `03a_my_account_enroll_mfa.png`, `03c_my_account_backup_codes.png`, `03e_my_account_change_password_dialog.png`, `03g_my_account_terms_dialog.png` |
| Business setup and timing | `01_business_setup.png`, `01a_business_setup_edit_timing.png`, `01b_business_setup_schedule_timing.png` |
| Members | `04_members_compact_cards.png`, `04a_members_invite_dialog.png`, `04c_members_invite_created.png`, `04d_members_row_actions.png`, `04f_members_suspend_confirmed.png`, `04h_members_reactivate_confirmed.png`, `04j_members_reset_password_sent.png`, `04l_members_reset_mfa_started.png`, `04n_members_remove_done.png` |
| Roles and Permission Explainer | `05_roles.png`, `05a_roles_permission_explainer.png`, `05b_roles_new_role_dialog.png`, `05f_roles_custom_role_created.png`, `05i_roles_delete_done.png` |
| Locations and hierarchy | `02_locations_hierarchy.png`, `02a_locations_add_child_dialog.png`, `02b_locations_add_child_created.png`, `02e_locations_move_done.png` |
| Sessions | `07_sessions.png`, `07a_sessions_sign_out_confirm.png`, `07b_sessions_sign_out_done.png` |
| Audit Log | `08_audit_log.png`, `08a_audit_export.png`, `08c_audit_entries_compact_fixed.png`, `08d_audit_payload_and_copy.png` |
| Security and MFA | `06_security.png`, `06a_security_add_authenticator.png`, `06c_security_authenticator_added.png`, `06e_security_remove_authenticator_scheduled.png`, `06f_security_cancel_removal_done.png` |
| Vendor connections | `09_vendor_connections.png`, `09a_vendor_choose_pos.png`, `09b_vendor_pos_selected.png` |
| Data Accuracy | `10_data_accuracy.png`, `10a_data_accuracy_options.png`, `10b_data_accuracy_save_reachable.png`, `10d_data_accuracy_tier_request_sent.png` |

## Bugs Found And Fixed

1. Post-login profile hydration performed account-info and permission-snapshot reads sequentially. Fixed by starting both reads together after the session login ledger call.
2. Sessions loaded own and team sessions sequentially. Fixed by starting both reads together and preserving the existing inline team-session fallback behavior.
3. Multiple route loaders could accept stale async responses after quick route switches, refreshes, or audit filter changes. Added generation guards to ignore old results.
4. Members rendered as cramped table columns at the tested app-shell width. Fixed with a compact card layout below the table breakpoint.
5. Audit Log rows wrapped key text one character at a time on narrow widths. Fixed with a compact stacked row layout.
6. Data Accuracy vendor-context load failure lacked an explicit retry path. Added visible retry copy and action.
7. Preview stack deployment could drop the existing operator-web origin from proxy CORS during admin/proxy redeploy. Fixed `scripts\deploy_preview_stack.ps1` to include the existing operator service origin and smoke `/v1/auth/account` preflight when that service exists.

## Gated Or Intentionally Unsurfaced Items

- Business timing write actions remain honest gated dialogs where the backend route is not live.
- Vendor choices that are not wired remain disabled or gated instead of pretending to connect.
- `location_manager` and other restricted roles remain read-only where the role contract requires it.
- Live preview uses staging-backed secrets; full mutating Browser Use verification was kept in local demo-auth mode for this pass.
- Mobile push source was not touched, so the APK debug build gate was not required.

## Verification Before Preview Deploy

Commands run:

```powershell
flutter analyze lib\operator_web test\operator_web
flutter test test\operator_web
flutter test test\proxy\operator_auth_integrations_routes_test.dart test\proxy\operator_account_routes_test.dart test\proxy\operator_business_timing_routes_test.dart test\proxy\data_accuracy_admin_routes_test.dart test\proxy_auth_operations_route_test.dart test\proxy_auth_operations_route_grants_test.dart test\proxy\auth_cors_routes_test.dart test\proxy\advisor_proxy_health_envelope_test.dart test\admin\observability_admin_screen_test.dart test\admin\health_admin_screen_test.dart test\proxy\mobile_push_routes_test.dart
flutter build web --release --target=lib\main_operator_web.dart --dart-define=OPERATOR_WEB_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --output=build\operator_web_release_verify
dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=http://127.0.0.1:8184 --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=local-demo-f347cab1-final-gzip --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00046-d8j --label=operator-web-perf-content-final-local-gzip --write-json=build\perf_gate\operator_web_perf_content_final_local_gzip.json
```

Post-rebase commands:

```powershell
flutter analyze lib\operator_web test\operator_web
flutter test test\operator_web
flutter test test\proxy\operator_auth_integrations_routes_test.dart test\proxy\operator_account_routes_test.dart test\proxy\operator_business_timing_routes_test.dart test\proxy\data_accuracy_admin_routes_test.dart test\proxy_auth_operations_route_test.dart test\proxy_auth_operations_route_grants_test.dart test\proxy\auth_cors_routes_test.dart test\proxy\advisor_proxy_health_envelope_test.dart test\admin\observability_admin_screen_test.dart test\admin\health_admin_screen_test.dart test\proxy\mobile_push_routes_test.dart
flutter build web --release --target=lib\main_operator_web.dart --dart-define=OPERATOR_WEB_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --output=build\operator_web_release_verify
```

Results:

- `flutter analyze lib\operator_web test\operator_web`: pass.
- `flutter test test\operator_web`: pass, 332 tests.
- Relevant proxy/admin route tests: pass, 155 tests.
- Release operator web build: pass.
- Local gzip performance probe: pass.
- Post-rebase scoped analyze: pass.
- Post-rebase operator-web suite: pass, 332 tests.
- Post-rebase proxy/admin route suite: pass, 155 tests.
- Post-rebase release operator web build: pass.

Local final performance highlights:

| Probe | Baseline preview | Final local gzip |
| --- | --- | --- |
| `admin_index_c1` p95 | 268.2 ms | 48.6 ms |
| `admin_index_c4` p95 | 173.2 ms | 26.1 ms |
| `admin_mainjs_gzip_c4` p95 | 1097.6 ms, 987856 bytes | 235.3 ms, 927765 bytes |
| `proxy_readyz_c1` p95 | 177.4 ms | 200.0 ms |
| `proxy_readyz_c4` p95 | 184.3 ms | 181.7 ms |

The local-vs-remote timing comparison is directional only because the final probe was served from localhost with gzip. The byte reduction is still useful because both probes measure gzipped transfer bytes.

## Final Preview Deploy

Commands:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 -PreviewName backend-surface-additions -SkipApiEnable -SkipSecretManagerSync
powershell -ExecutionPolicy Bypass -File scripts\deploy_staging_proxy.ps1 -Project forge-flow-staging -Region northamerica-northeast2 -Service forge-flow-preview-backend-surface-additions-proxy -ServiceAccount forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com -SecretPrefix forge-flow-staging- -ProxyBaseUriEnvVarName FORGE_FLOW_PREVIEW_BACKEND_SURFACE_ADDITIONS_PROXY_BASE_URI -ProxyEnvironment preview-backend-surface-additions -MinInstances 0 -VpcConnector ff-staging-proxy-egress -VpcEgress all-traffic -AdminCorsAllowedOrigins "https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app,https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app" -SkipApiEnable -SkipSecretManagerSync
powershell -ExecutionPolicy Bypass -File scripts\deploy_operator_web.ps1 -Service forge-flow-preview-backend-surface-additions-operator-web -ProxyBaseUri https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app -SkipApiEnable
dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-operator-00014-227 --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00056-5rb --label=operator-web-perf-content-preview-final --write-json=build\perf_gate\operator_web_perf_content_preview_final.json
```

The preview stack deploy completed proxy/admin deploys but its final CORS smoke failed with `cors_origin_not_allowed`; this pass patched the wrapper and corrected the live proxy CORS with the explicit operator/admin origins before the operator-web deploy. The final operator deploy script then reported operator-web CORS preflight `204`.

| Surface | Service | URL | Revision | Traffic |
| --- | --- | --- | --- | --- |
| Operator web | `forge-flow-preview-backend-surface-additions-operator-web` | `https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-operator-00014-227` | 100% |
| Preview proxy | `forge-flow-preview-backend-surface-additions-proxy` | `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-proxy-00056-5rb` | 100% |
| Preview admin | `forge-flow-preview-backend-surface-additions-admin` | `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-admin-00020-6dk` | 100% |

Final proxy CORS includes:

- `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app`
- `https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app`
- `https://forge-flow-staging.firebaseapp.com`
- `https://forge-flow-staging.web.app`

Final enforced performance JSON:

`build\perf_gate\operator_web_perf_content_preview_final.json`

Final remote performance highlights:

| Probe | Result |
| --- | --- |
| `admin_index_c1` | p95 289.3 ms, 0% errors |
| `admin_index_c4` | p95 179.0 ms, 0% errors |
| `admin_mainjs_gzip_c4` | p95 1101.1 ms, 991397 bytes, 0% errors |
| `proxy_readyz_c1` | p95 196.9 ms, 0% errors |
| `proxy_readyz_c4` | p95 211.6 ms, 0% errors |

All enforced budgets passed. The live bundle is slightly larger than the previous preview baseline because the pass added summary strips and compact row/card UI, but it remains under the `1,250,000` byte budget. The meaningful runtime gains are in login/session request parallelism and stale-response suppression during repeated navigation.

## Residual Risks

- Browser Use automation of the external Cloud Run URL was blocked by policy; full click evidence for this pass is local demo-auth evidence.
- Live staging-backed mutation replay was intentionally not repeated for every destructive action in this pass.
- Cloud Run proxy labels still report the older persisted `source_commit=855d1f0b`; the final branch commit and deployed source tarball are recorded above because the current proxy deploy script does not refresh that label.
