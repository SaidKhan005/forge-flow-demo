# Admin/Web Setting Sync Closeout

Date: 2026-05-07
Baseline: `origin/master` at `537d5319`
Scope: Doc 1 admin/web setting sync inventory and truth closeout only.
Change type: documentation/tracker truth; no code changes.

Primary authority:

- `PROJECT_TRACKER.md`
- `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
- `docs/contracts/integration_spine_architecture_contract.md`
- `docs/phases/phase_business_timing_live/business_timing_live_plan.md`

Evidence read:

- `docs/_execution/2026-05-07_mobile_core_doc1_closeout_status.md`
- `docs/_execution/2026-05-07_mobile_star_target_projection_route_proof.md`
- `docs/_execution/2026-05-07_weekly_plan_server_truth_mobile_proof.md`
- `docs/_execution/2026-05-07_mobile_business_scope_selector_proof.md`
- `docs/_execution/2026-05-07_mobile_scope_flat_location_search_proof.md`
- `docs/_execution/2026-05-07_mobile_business_scope_invalidation_proof.md`
- `docs/_execution/2026-05-07_mobile_reservation_demand_settings_sync_proof.md`
- `docs/_execution/2026-05-07_mobile_data_accuracy_service_period_sync_proof.md`
- `docs/_execution/2026-05-07_operator_web_data_accuracy_live_sync_proof.md`
- `docs/_execution/2026-05-07_mobile_wage_role_rows_sync_proof.md`
- `docs/_execution/2026-05-07_mobile_core_connected_device_simulated_e2e_proof.md`
- `docs/_execution/2026-05-07_mobile_push_preflight_proof.md`
- `docs/_execution/2026-05-07_operator_web_contact_context_picker.md`
- `docs/_execution/2026-05-07_admin_console_business_team_access_polish.md`

## Closeout Decision

`audit.admin-web-setting-sync` is closed as an inventory/status slice. Current
master has enough proof to split Doc 1 admin/web setting sync into implemented,
partially implemented, and still future/operator-blocked work. This document
does not claim connected-device, live-provider, push, or group/region/company
rollup acceptance.

## Truth Table

| Doc 1 setting/control area | Status | Current truth | Evidence |
| --- | --- | --- | --- |
| Demo mode state | Implemented | Mobile pulls server-owned demo mode state through the operational sync surface. | `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`; `test/proxy/mobile_operational_sync_routes_test.dart`; `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart` |
| Polling tier assignment | Implemented | Mobile pulls `forge_flow_polling_tier_assignment` as a server-owned read model; mobile remains read-only. | `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`; `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart` |
| Base data accuracy settings | Implemented | Operator/admin data accuracy settings, including walk-in reservation handling, persist as server truth and flow to mobile. Operator Web now reads and writes the base settings through scoped live proxy routes instead of demo/injected settings. | `docs/_execution/2026-05-07_mobile_reservation_demand_settings_sync_proof.md`; `docs/_execution/2026-05-07_operator_web_data_accuracy_live_sync_proof.md`; `test/proxy/data_accuracy_admin_routes_test.dart`; `test/operator_web/screens/data_accuracy_screen_test.dart`; `test/operator_web/services/operator_web_data_accuracy_gateway_test.dart`; `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart` |
| Keyed data accuracy service-period settings | Partially implemented | Mobile read sync and invalidation are proven for `data_accuracy_service_period_settings`; admin/operator-web keyed write implementation was explicitly not run. | `docs/_execution/2026-05-07_mobile_data_accuracy_service_period_sync_proof.md`; `test/proxy/mobile_operational_sync_routes_test.dart`; `test/services/sync/http_sync_proxy_client_test.dart` |
| Wage source, wage mix, and role/job-code rows | Partially implemented | Server-owned `wage_role_rows` and mobile read/cache replacement are proven; admin/operator-web edit surfaces and successful write proof are not claimed. | `docs/_execution/2026-05-07_mobile_wage_role_rows_sync_proof.md`; `db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql`; `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart` |
| Selected star shifts, target cycles, and active target profiles | Implemented | Server-owned selected-star decisions, target cycle projection, active target profile projection, proxy routes, idempotency, permission handling, and mobile mirror sync are accepted. | `docs/_execution/2026-05-06_8_star_target_truth_proof.md`; `docs/_execution/2026-05-07_mobile_star_target_projection_route_proof.md`; `test/proxy/selected_star_target_routes_test.dart`; `test/services/star_target_selection_write_service_test.dart` |
| Weekly plan snapshots and forecast context | Implemented | Server-owned weekly plan snapshots and embedded forecast context cache are proven; Schedule does not silently generate production local plans on miss. | `docs/_execution/2026-05-07_weekly_plan_server_truth_mobile_proof.md`; `test/proxy/weekly_plan_routes_test.dart`; `test/services/sync/weekly_plan_sync_mirror_test.dart`; `test/schedule_plan_read_service_test.dart` |
| Resolved timing config and dayparts | Partially implemented | Mobile resolved timing read/sync exists and timing writes have operator routes, but operator-web live read hydration, admin timing override/write UI, timing-write outbox proof, and full screen consumption are not complete. | `docs/phases/phase_business_timing_live/business_timing_live_plan.md`; `tool/advisor_proxy/operator_routes.dart`; `tool/advisor_proxy/advisor_proxy.dart`; `test/proxy/operator_business_timing_routes_test.dart`; `test/services/sync/http_sync_proxy_client_test.dart` |
| Business scope access and admin org/location changes | Partially implemented | Location-level scope selection, flat location projection, drawer search, and stale-access invalidation are proven; group/region/company rollup truth remains future server work. | `docs/_execution/2026-05-07_mobile_business_scope_selector_proof.md`; `docs/_execution/2026-05-07_mobile_scope_flat_location_search_proof.md`; `docs/_execution/2026-05-07_mobile_business_scope_invalidation_proof.md`; `test/proxy/business_scope_routes_test.dart`; `test/services/sync/mobile_operational_sync_runtime_test.dart` |
| Operator Web management context | Partially implemented | Operator Web can choose business/group/location management context and routes location-scoped tabs through the selected location; business/group scopes intentionally show stops on location-only surfaces. | `docs/_execution/2026-05-07_operator_web_contact_context_picker.md`; `test/operator_web/operator_web_router_test.dart`; `test/operator_web` |
| Admin business/team/access polish | Implemented for the admin UX slice | Admin console business/team/access surfaces have verified polish and Team display-name audited write coverage; this is not a substitute for missing timing or wage-role setting editors. | `docs/_execution/2026-05-07_admin_console_business_team_access_polish.md`; `test/admin`; `test/proxy_auth_operations_route_test.dart` |
| Connected-device E2E proof | Still future/operator-blocked | Simulated first-connect/device proof is documented; final acceptance requires a physical or emulator device bound to the real proxy/mobile SQLite flow. | `docs/_execution/2026-05-07_mobile_core_connected_device_simulated_e2e_proof.md`; `docs/_execution/2026-05-07_mobile_core_doc1_closeout_status.md` |
| Live provider proof | Still future/operator-blocked | Per-vendor live proof remains gated on sandbox/live credentials and explicit operator approval. | `PROJECT_TRACKER.md`; `docs/_execution/2026-05-07_mobile_core_doc1_closeout_status.md` |
| Push notification proof | Still future/operator-blocked | Code/config preflight is documented, but staging Firebase apply, controlled send, device foreground/background proof, and production proof remain gated. | `PROJECT_TRACKER.md`; `docs/_execution/2026-05-07_mobile_push_preflight_proof.md`; `docs/_execution/2026-05-07_mobile_core_doc1_closeout_status.md` |
| Tier-M pressure suite | Still future/cutover-owned | Larger pressure proof belongs to `cutover.0b.tier-m-perf-gate`, not this admin/web setting sync closeout. | `PROJECT_TRACKER.md`; `docs/_execution/2026-05-07_mobile_core_doc1_closeout_status.md` |

## Remaining Narrow Remediation Slices

1. Timing web/admin live parity:
   - Hydrate Operator Web timing reads from live server truth instead of demo fallback.
   - Pass existing resolved/profile state into the timing editor instead of defaulting to a new profile.
   - Add or wire admin timing read/write override routes and require audit reason for support writes.
   - Prove timing write invalidation/outbox, not just mobile polling.
   - Candidate files: `lib/operator_web/auth/firebase_operator_web_auth_source.dart`, `lib/operator_web/services/business_timing_gateway.dart`, `lib/operator_web/router/operator_web_router.dart`, `lib/operator_web/screens/business_timing_editor_screen.dart`, `lib/admin/screens/operator_location_admin_screen.dart`, `tool/advisor_proxy/operator_routes.dart`, `tool/advisor_proxy/proxy_bootstrap.dart`.
   - Candidate tests: `test/operator_web/services/web_business_timing_gateway_test.dart`, `test/operator_web/screens/business_setup_screen_test.dart`, `test/operator_web/screens/business_timing_editor_screen_test.dart`, `test/admin_operator_location_screen_test.dart`, `test/proxy/operator_business_timing_routes_test.dart`.

2. Keyed data accuracy admin/operator write surface:
   - Mobile read sync is done; add or prove admin/operator-web keyed writes where service-period settings are user-facing.
   - Candidate files: `lib/operator_web/screens/data_accuracy_screen.dart`, `lib/admin/screens/per_location_data_accuracy_screen.dart`, `lib/admin/widgets/per_location_data_accuracy_table.dart`, `tool/advisor_proxy/advisor_proxy.dart`, `tool/advisor_proxy/proxy_bootstrap.dart`.
   - Candidate tests: `test/operator_web/screens/data_accuracy_screen_test.dart`, `test/proxy/data_accuracy_admin_routes_test.dart`, `test/admin/data_accuracy_admin_override_writes_audit_test.dart`.

3. Wage/role editor and write proof:
   - Server/mobile read truth is done; admin/operator-web mutation semantics remain unclaimed.
   - Candidate files: `lib/admin/**`, `lib/operator_web/**`, `tool/advisor_proxy/advisor_proxy.dart`, `tool/advisor_proxy/proxy_bootstrap.dart`, `lib/infrastructure/persistence/postgres/**`.
   - Candidate tests: `test/proxy/mobile_operational_sync_routes_test.dart`, `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart`, plus new admin/operator-web write tests when the surface exists.

4. Group/region/company rollup truth:
   - Mobile now exposes selectable locations from higher-level grants, but does not mix locations locally.
   - Server rollup snapshots are the next truth source before higher scopes become active mobile data scopes.
   - Candidate tests: `test/proxy/business_scope_routes_test.dart`, `test/services/sync/mobile_operational_sync_runtime_test.dart`, future rollup repository/proxy tests.

5. Operator-blocked proof gates:
   - Connected-device E2E proof.
   - Per-vendor live-provider proof.
   - Push notification staging/production proof.
   - Tier-M cutover pressure suite.

## Tracker Impact

The tracker should no longer list `audit.admin-web-setting-sync` as an open
discovery lane. The remaining Doc 1 work is now explicitly split into narrow
engineering follow-ups plus operator-blocked proof gates.
