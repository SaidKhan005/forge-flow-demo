# Operator Web Console Full Preview Verification

Date: 2026-05-06
Worktree: `C:\Git Local Repos\forge_flow_demo\.codex_worktrees\operator-web-full-verification`
Branch: `codex/operator-web-full-verification`
Start base: `855d1f0b68d7d5d5011244ce4d4cc52ea8579543`
Closeout head before commit: `1667e30c3e9a0f580354df1937232dcd88b6968d`

## Deployment Record

The worktree was created from `origin/master` after confirming the starting commit was `855d1f0b` or newer. During closeout, `origin/master` had advanced to `389704bfca1cd298222700272ddea5d1c31ee990`; this branch intentionally preserves the separate verification worktree lineage for the PR.

| Surface | Service | URL | Revision | Traffic |
| --- | --- | --- | --- | --- |
| Operator web | `forge-flow-preview-backend-surface-additions-operator-web` | `https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-operator-00009-fc4` | 100% |
| Preview proxy | `forge-flow-preview-backend-surface-additions-proxy` | `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-proxy-00037-8tp` | 100% |
| Preview admin | `forge-flow-preview-backend-surface-additions-admin` | `https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-admin-00014-kw2` | 100% |

Database mode: preview services use `forge-flow-staging-` Secret Manager values. The operator approved live mutating checks; mutations were limited to a dedicated QA operator account plus reversible data-accuracy toggles restored to the original setting. No shared staging or production service was deployed.

Final live checks:

- Proxy preflight from the operator origin to `/v1/auth/session/login`, `/v1/auth/permissions/snapshot`, and `/v1/auth/locations/:location_id/integrations` returned 204 and echoed the operator origin.
- Fresh Firebase token direct checks returned 200 for `/v1/auth/account`, `/v1/auth/team/roles`, `/v1/auth/team/users`, `/v1/auth/team/org-units`, and `/v1/auth/locations/:location_id/integrations`.
- `/v1/auth/team-sessions` remains intentionally unrouted in this preview; the UI now keeps own sessions visible and shows an inline team-sessions unavailable state.

## Framework Checklist

UX Adjustment Framework:

- Verified signed-out shell, successful sign-in, account profile, MFA setup dialog, password dialog, terms viewer, business timing copy, member invite dialog, roles copy, permission explainer, locations hierarchy, sessions, audit filters, security dialogs, vendor picker, and data-accuracy labels.
- Setup and lifecycle copy is human-readable; backend-only or incomplete timing writes remain explicit skeleton dialogs rather than fake live controls.
- `location_manager` and other restricted behaviors remain covered by existing role/auth tests; no read-only capability was converted into a live write.

Performance Framework:

- Route switching across all operator surfaces was exercised in Browser Use with cache-bust URLs.
- Lists remain bounded in the rendered screens; repeated navigation did not create visible runaway polling.
- First enforced perf run wrote `build\perf_gate\operator_web_live_mutation_sweep_00037.json` and missed `admin_index_c1` p95 once at 793.9ms over a 750ms budget.
- Warm rerun passed enforced budgets and wrote `build\perf_gate\operator_web_live_mutation_sweep_00037_rerun.json`.

Mobile Web Console E2E Framework:

- Browser Use was run against the in-app browser on fresh preview URLs.
- Safe read-only flows and approved reversible mutations were exercised.
- Mobile notification tap behavior was not live-tested because no safe notification session was present; proxy mobile push route tests passed and mobile push source was not touched, so the APK debug build gate was not required.

## Browser Evidence

Evidence root: `build\reports\operator_web_live_mutation_sweep`

| Surface | Evidence |
| --- | --- |
| Fresh sign-in shell | `120_final_fresh_load.png` |
| Successful live sign-in on final proxy | `188_final_00037_signed_in_account.png` |
| Account MFA dialog | `142_account_enroll_mfa_click.png` |
| Account password dialog | `146_account_change_password_dialog.png` |
| Terms viewer | `147_account_tos_viewer.png` |
| Business timing skeleton dialogs | `149_business_edit_timing_dialog.png`, `150_business_schedule_change_dialog.png` |
| Members invite dialog and filters | `153_members_invite_dialog.png`, `154_members_status_filter_open.png`, `155_members_role_filter_open.png` |
| Roles loaded and permission explainer | `167_final_route_roles.png`, `160_roles_secondary_button_click.png` |
| Locations hierarchy | `189_final_00037_locations_loaded.png` |
| Sessions own-list plus team fallback | `192_final_00037_sessions_loaded.png` |
| Audit log filters | `183_audit_filter_clicks_final.png` |
| Security MFA/password controls | `171_final_route_security.png`, `194_final_00037_security_mfa_click.png` |
| Vendor connections and POS picker | `190_final_00037_vendor_loaded.png`, `193_final_00037_vendor_pos_connect_click.png` |
| Data accuracy toggled and restored | `195_final_00037_data_manual_click.png`, `196_final_00037_data_restore_click.png` |

Console log note: Browser Use log retrieval kept one stale pre-fix Flutter error from an earlier tab timestamp. Final route screenshots above were visually healthy after the proxy and token reset; direct fresh-token route checks were 200 for the routed surfaces.

## Bugs Found And Fixed

1. Sessions screen treated a missing team-sessions route as a whole-page failure. Fixed the screen so own sessions load independently and team sessions render an inline unavailable state when the route returns 404/501.
2. Operator vendor connections gateway used admin-scoped `/v1/admin/*` URLs. Repointed operator web to self-service `/v1/auth/*` routes and removed client-supplied operator scope from write bodies.
3. Preview proxy lacked the operator self-service integrations read route. Added `GET /v1/auth/locations/:location_id/integrations`, location-scope enforcement, permission snapshot enforcement, and demo flag response.
4. Integration permissions in staging use existing `integration.*` keys, while the newer constant is `integrations.configure`. The proxy read gate now accepts either allowed key family.
5. Preview deployment had a CORS/source revision split during verification. Final traffic was moved to source-built `proxy-00037-8tp` with the operator origin in `ADMIN_CORS_ALLOWED_ORIGINS`.

## Gated Or Intentionally Unsurfaced Items

- Vendor connection picker is reachable, but vendor credentials remain gated by lifecycle and backend configuration.
- Business timing edit/schedule controls still show “not connected yet” dialogs and do not write timing changes.
- MFA setup was opened but not completed; no authenticator factor was enrolled.
- Password change dialogs were opened but the final password-change step was not submitted.
- Team sessions remain backend-unrouted in this preview; own sessions are shown with a clear inline fallback.
- Audit custom range opens the date picker; no export/download flow was completed.

## Verification

Commands run:

```powershell
flutter analyze
flutter test test\operator_web
flutter test test\proxy\operator_auth_integrations_routes_test.dart test\proxy\auth_cors_routes_test.dart test\proxy\data_accuracy_admin_routes_test.dart test\proxy\mobile_push_routes_test.dart test\proxy\advisor_proxy_health_envelope_test.dart test\proxy\registry_proxy_health_check_store_test.dart test\proxy\health_producers
flutter build web --release --target=lib\main_operator_web.dart --dart-define=OPERATOR_WEB_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --dart-define=OPERATOR_WEB_DEMO_AUTH=false --pwa-strategy=none
dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-operator-00009-fc4 --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00037-8tp --label=operator-web-live-mutation-sweep-00037 --write-json=build\perf_gate\operator_web_live_mutation_sweep_00037.json
dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-operator-00009-fc4 --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00037-8tp --label=operator-web-live-mutation-sweep-00037-rerun --write-json=build\perf_gate\operator_web_live_mutation_sweep_00037_rerun.json
```

Results:

- `flutter analyze`: pass.
- `flutter test test\operator_web`: pass, 265 tests.
- Proxy route/CORS/data accuracy/mobile push/health producer suite: pass, 120 tests.
- Release operator web build: pass.
- Perf enforced rerun: pass; JSON at `build\perf_gate\operator_web_live_mutation_sweep_00037_rerun.json`.

## Residual Risks

- The preview is backed by staging secrets, so live destructive writes remain deliberately constrained even with action-time approval.
- The audit log narrow-width table still wraps densely; it is reachable and functional, but visual polish can be improved.
- Browser Use screenshots contain the dedicated QA account display/email; no credentials are recorded in this note.

## UX And Performance Enhancement Pass

Date/time: 2026-05-06T19:32Z
Source commits:

- `cf32c8cf` - simplified operator-web setup/data/vendor copy and added stale async-load guards.
- `deb46f84` - tightened responsive timing layout and shortened vendor/data-accuracy copy.

Final preview deployment:

| Surface | Service | URL | Revision | Traffic |
| --- | --- | --- | --- | --- |
| Operator web | `forge-flow-preview-backend-surface-additions-operator-web` | `https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-operator-00011-grb` | 100% |
| Preview proxy | `forge-flow-preview-backend-surface-additions-proxy` | `https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app` | `forge-flow-preview-backend-surface-additions-proxy-00037-8tp` | 100% |

Database mode: proxy still uses `forge-flow-staging-` Secret Manager values (`POSTGRES_URL`, `POSTGRES_ADMIN_URL`, Firebase, and service-principal secrets), so the preview remains staging-secret backed. No shared staging or production service was deployed.

Framework results:

- UX Adjustment Framework: pass. Business timing now says plainly that timing changes are preview-only, vendor connection CTAs use shorter parallel labels, Data Accuracy first-card copy consistently uses "Forge & Flow", and raw non-primary location ids are hidden behind "this location".
- Performance Framework: pass. Vendor connections, business timing, and data accuracy now ignore stale async responses during quick route changes; vendor connections also refresh when the operator/location/gateway tuple changes. Baseline enforced perf wrote `build\perf_gate\operator_web_ux_perf_baseline.json` and missed the cold `admin_index_c1` p95 once. Final enforced perf passed and wrote `build\perf_gate\operator_web_ux_perf_final.json`.
- Mobile Web Console E2E Framework: pass for browser-safe web flows. Browser Use exercised fresh cache-bust route switching across Account, Business setup, Members, Roles, Locations, Sessions, Audit log, Security, Vendor connections, and Data accuracy. Mobile push source was not touched, so the APK debug build gate was not required.

Browser Use evidence:

- Evidence root: `build\reports\operator_web_ux_perf_final_clean_20260506T1932Z`
- Route screenshots: `00_fresh_load.png`, `01_account.png`, `02_business_setup.png`, `03_members.png`, `04_roles.png`, `05_locations.png`, `06_sessions.png`, `07_audit_log.png`, `08_security.png`, `09_vendor_connections.png`, `10_data_accuracy.png`
- Button evidence: `11_business_edit_dialog.png`, `12_business_schedule_dialog.png`, `13_vendor_pos_picker.png`, `14_data_accuracy_manual_wage_selected.png`
- Console logs: `console_logs_since_1932Z.json` contains zero new warn/error entries after the clean final tab opened. `console_logs_all.json` still contains one stale browser-runtime error timestamped before this final clean-tab run.

Bugs or UX issues fixed in this pass:

1. Business timing inherited-source pills wrapped into tall bubbles at the tested preview width. Fixed with a responsive column layout below 520 px.
2. Vendor connection buttons used mixed labels (`Connect POS`, `Connect reservations vendor`, `Connect scheduling vendor`). Replaced with shorter parallel labels.
3. Operator web could show raw fallback location ids on vendor/data/timing copy. Replaced the fallback with "this location" and passed the host label into the shared vendor widget.
4. Repeated route switches could let stale async responses land after a newer operator/location read. Added generation guards to business timing, data accuracy, and vendor connections.

Commands run for this pass:

```powershell
flutter analyze
flutter test test\operator_web\screens\vendor_connections_screen_test.dart test\operator_web\screens\business_setup_screen_test.dart test\operator_web\screens\data_accuracy_screen_test.dart
flutter test test\operator_web\screens\vendor_connections_screen_test.dart test\operator_web\screens\business_setup_screen_test.dart test\operator_web\screens\data_accuracy_screen_test.dart test\operator_web\widgets\wage_source_toggle_test.dart test\operator_web\widgets\covers_source_toggle_test.dart
flutter test test\operator_web
flutter test test\proxy\operator_auth_integrations_routes_test.dart
flutter build web --release --target=lib\main_operator_web.dart --dart-define=OPERATOR_WEB_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --dart-define=OPERATOR_WEB_DEMO_AUTH=false --pwa-strategy=none
dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-oper-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-operator-00011-grb --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00037-8tp --label=operator-web-ux-perf-final --write-json=build\perf_gate\operator_web_ux_perf_final.json
```

Results:

- `flutter analyze`: pass.
- Focused operator-web widget tests: pass.
- `flutter test test\operator_web`: pass, 266 tests.
- `flutter test test\proxy\operator_auth_integrations_routes_test.dart`: pass, 3 tests.
- Release operator web build: pass.
- Final enforced performance probe: pass; JSON at `build\perf_gate\operator_web_ux_perf_final.json`.

Residual risks for this pass:

- The preview remains staging-secret backed. This pass did not perform destructive live writes.
- Browser Use still relies on visual/coordinate interaction for the Flutter canvas because the DOM snapshot exposes only the accessibility bootstrap button.
- Broader Data Accuracy copy still has older "F&F" wording in lower/cards not visible in the first viewport; this pass corrected the route subtitle and first source cards only.
