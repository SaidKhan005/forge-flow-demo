# Admin/Web Setting Sync Closeout

Date: 2026-05-07
Baseline: `origin/master` at `932d46f5`
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

## Remaining Narrow Remediation Slices — closed 2026-05-08

| # | Slice | Status | PR |
|---|---|---|---|
| 1 | Timing web/admin live parity | **closed** — operator-web hydrates live server truth; editor receives resolved profile state; admin override routes added with `admin_reason` audit gate; outbox/invalidation listener wired | [#398](https://github.com/SaidKhan005/forge-flow-demo/pull/398) |
| 2 | Keyed data accuracy admin/operator write surface | **closed** — operator-web `KeyedServicePeriodAccuracyCard` round-trips through scoped PATCH; admin per-row override with `admin.data_accuracy.service_period_override` audit; proxy validator hardened | [#393](https://github.com/SaidKhan005/forge-flow-demo/pull/393) |
| 3 | Wage/role editor and write proof | **closed** — operator-web `WageAuthorityScreen` + audit fan-out (Hard Contract 7); cross-device read-after-write proof shipped; admin override deferred to a follow-up if support cases need it | [#391](https://github.com/SaidKhan005/forge-flow-demo/pull/391) |
| 4 | Group/region/company rollup truth | **backlog** — explicitly deferred per the `no core app logic change` guardrail. Mobile location-level scope is sufficient for V1; rollup snapshots are a new server-side primitive that should be planned in its own phase doc when an operator decision lands. | n/a |
| 5 | Operator-blocked proof gates | unchanged | n/a |
|   | a. Connected-device E2E proof | **closed (simulated, on-emulator)** — Pixel 5 / Android 14 emulator built `app-forgeflow-debug.apk` and ran the full surface tour: Shift "locked plan unavailable" empty state, Plan weekly plan empty state with reasons, Variance whole-week + daypart toggle with full WEEK-TO-DATE vs PLAN data, Benchmark/Star Shifts 60-day data + CPLH range/target + Choose Star Shifts CTA, Settings W3.A 3-tab shape, hamburger location scope drawer. Screens at `.claude/screenshots_doc1_emu/`. Live-vendor proof remains operator-blocked. | n/a |
|   | b. Per-vendor live-provider proof | unchanged — operator-blocked on sandbox creds (Lightspeed K-Series, Libro, QuickBooks Time) | n/a |
|   | c. Push notification staging/production proof | unchanged — operator-blocked on staging Firebase apply | n/a |
|   | d. Tier-M cutover pressure suite | unchanged — owned by `cutover.0b.tier-m-perf-gate` | n/a |

## Carry-overs from CODE_OPS_DEBT — also closed 2026-05-08

| # | Carry-over | Status | PR |
|---|---|---|---|
| 1 | Frontend listener for `redirect_uri` payload on `mfa_freshness_required` 403 | **closed** — admin shell + operator-web 401-handlers consume the redirect, sign out, and route back through Firebase Auth | [#392](https://github.com/SaidKhan005/forge-flow-demo/pull/392) |
| 2 | Visible grace-window countdown chip during 24h PII-erasure grace window | **closed** — `_GraceWindowChip` + reverse-erasure affordance, 1-min Timer.periodic, deterministic widget tests | [#389](https://github.com/SaidKhan005/forge-flow-demo/pull/389) |
| 3 | Restaurant-local IANA-tz `business_date` for PII erasure | **closed** — `PiiBusinessDateResolver` with shared `IanaTimezoneConverter`; UTC fallback preserved as known-safe | [#390](https://github.com/SaidKhan005/forge-flow-demo/pull/390) |
| 4 | Theme H#8 first-backfill status null shape | **transferred** to `docs/phases/phase_8/phase_8_spine_bridge_plan.md` § "Deferred from CODE_HEALTH remediation" → "`fetchFirstBackfillStatus` null-shape conflation" (closes when the Phase 8 framework lane next touches the route) | n/a |

## Build-rot repair landed in the same wave

PR [#397](https://github.com/SaidKhan005/forge-flow-demo/pull/397) restored
`lib/screens/settings_screen.dart` to its post-PR-#324 (W3.A 3-tab) shape after
PR #337 had silently re-introduced 520+ lines of dead code referencing files
PR #324 deleted (`settings/settings_audit_log_section.dart`,
`settings/settings_custom_roles_section.dart`,
`settings/settings_org_hierarchy_section.dart`,
`team/team_settings_section.dart`). Without this repair, `flutter build apk
--debug` fails for the ForgeFlow flavor; the connected-device E2E proof would
have been blocked. Net: **+97 / −617 lines, single file.**

## Tracker Impact

- Remove `audit.admin-web-setting-sync` from the tracker as an open discovery lane.
- Doc 1 is now **closed** for V1 — no remaining engineering blockers.
- The only Doc 1 work that remains is Phase-8-rolling vendor live proof
  (Wave 1 trio + Wave D rolling), which is rolling and explicitly does NOT
  block V1 launch.
- Group/region/company rollup truth is on the backlog and should be authored
  as its own phase doc when operator priority shifts.
