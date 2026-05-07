# Admin/Web Setting Sync Inventory

Date: 2026-05-07
Baseline: `origin/master` at `78534a46`

Primary contract:
`docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`

Supporting authority:
- `PROJECT_TRACKER.md`
- `docs/contracts/integration_spine_architecture_contract.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/data_accuracy_settings_contract.md`
- `docs/contracts/mobile_core_star_target_truth_contract.md`
- `docs/contracts/mobile_core_weekly_plan_server_truth_contract.md`
- `docs/contracts/mobile_core_business_scope_contract.md`

## Scope

This audit closes Doc 1 item:

`Admin/web settings sync to mobile where they affect behavior.`

The audit checked the admin and operator-web setting surfaces that can change
mobile calculation, bucketing, freshness, or interpretation. It then compared
those surfaces with the server-owned proxy routes and mobile sync/cache paths.

Mobile remains a read model. No mobile write authority was added.

## Inventory

| Setting family | Admin/operator owner | Mobile mirror path | Status |
| --- | --- | --- | --- |
| Business timing, week start, dayparts, service periods | Server `business_timing_profiles` and `business_timing_service_periods`; operator web timing editor writes through `WebBusinessTimingGateway` when live auth supplies it | `/v1/operators/:operatorId/locations/:locationId/timing/resolved`, parsed by `HttpSyncProxyClient.fetchResolvedTimingConfig`, saved through `RestaurantTimingConfigRepository` | Covered for location scope. Closed rows keep saved timing provenance; future timing edits do not rewrite old rows. |
| Legacy data accuracy settings: covers source, wage source, walk-in handling | Server `data_accuracy_settings`; admin Data Accuracy overrides write through `DataAccuracyAdminGateway` | `/data_accuracy_settings`, parsed into `DataAccuracySettingsSnapshot`, exposed on sync result/latest getter | Covered as server-owned mobile-readable state. Mobile does not persist this as owner truth. |
| Keyed service-period data accuracy settings | Server `data_accuracy_service_period_settings` | `/data_accuracy_service_period_settings`, parsed into `DataAccuracyServicePeriodSetting`, exposed on sync result/latest getter | Covered as server-owned mobile-readable state. Keyed admin/operator write parity is a console follow-up, not a mobile-source gap. |
| Wage role rows and job-code mapping | Server `wage_role_rows` | `/wage_role_rows`, parsed by `HttpSyncProxyClient`, replaced into mobile SQLite `wage_role_rows` cache | Covered. Mobile cache is read-only and scope-isolated. |
| Reservation demand/walk-in settings | Server fields on `data_accuracy_settings` | Same `/data_accuracy_settings` route; integration aggregation reads durable server truth | Covered. Mobile mirrors the setting for display/explanation parity and never calculates authoritative closed truth from local edits. |
| Polling tier assignment and cadence | Server `forge_flow_polling_tier_assignment`; admin Polling & Pricing writes assignments | `/polling_tier_assignment`, parsed into `ForgeFlowPollingTierAssignmentSnapshot` | Covered as mobile-readable freshness context. Operator web request-change flow is separate from mobile core truth. |
| Selected stars, target cycles, active target profile | Server selected-star/target tables and routes | `/selected_star_shift_decisions`, `/target_cycles`, `/active_target_profiles`, mirrored into mobile cache | Covered by the star/target truth proof. Mobile is a cache/read model. |
| Weekly plan snapshots and forecast context | Server `weekly_plan_snapshots` and `forecast_contexts` | `/weekly_plan_snapshots`, `/forecast_contexts`; forecast context is embedded into the existing weekly plan SQLite cache | Covered by weekly-plan proof plus forecast-context cache follow-up. No duplicate forecast table was introduced. |
| Location-level business scope/access | Server scope routes and hierarchy/access grants | `/v1/users/:userId/business_scopes`, active-scope cache, sync cancellation/rebase, cross-scope wipe | Covered for location scope. Group/region/company rollup truth remains separate. |
| Feature flags, account/team/security/support settings | Admin/operator console management surfaces | Auth/session/scope/runtime routes where applicable | Not Doc 1 mobile-calculation settings unless they change one of the server-owned operational tables above. |

## Code Evidence

- Mobile route dispatcher:
  `tool/advisor_proxy/advisor_proxy.dart`
  `tool/advisor_proxy/proxy_bootstrap.dart`
- Mobile HTTP client:
  `lib/services/sync/http_sync_proxy_client.dart`
- Mobile sync orchestrator:
  `lib/services/sync/postgres_shift_record_to_mobile_sync.dart`
- Timing cache:
  `lib/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart`
- Wage-role cache:
  `lib/infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart`
- Weekly-plan and forecast-context cache:
  `lib/infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart`
- Business-scope selector/cache:
  `lib/state/restaurant_scope_notifier.dart`
  `lib/infrastructure/persistence/sqlite/repositories/sqlite_active_scope_repository.dart`

## Findings

No remaining location-level mobile read/sync gap was found for Doc 1
admin/web settings that affect mobile behavior.

The audit did find console-side follow-ups:
- Operator-web Data Accuracy edits still depend on a live save hook; admin
  Data Accuracy overrides are wired through the admin gateway.
- Keyed service-period Data Accuracy write UI parity is still a console lane.
- Wage-role row editing/import ownership should be documented in the console or
  integration ownership lane.
- Group/region/company views still need server rollup truth before mobile can
  switch into those scopes.

These are not reasons to make mobile the source of truth. Mobile should keep
pulling the server-owned rows listed above.

While running the targeted gate, current `origin/master` exposed a small
analyzer blocker in `PostgresAdminRequestIdempotencyStore`: the production
store had not implemented the admin idempotency orphan-reclaim methods added by
the TTL migration contract. This branch adds those concrete Postgres overrides
using the same predicate documented by the migration, and patches the focused
test harness so Flutter's fake `HttpClient` override does not mask the local
HTTP server used by the test.

## UX Compatibility Note

Admin and operator-console UX-only changes are safe alongside the mobile core
logic as long as they do not rename, remove, or change the semantics of the
server tables/routes listed in this inventory.

If a UX change modifies timing, data accuracy, wage roles, polling assignment,
target/profile, weekly-plan, forecast-context, or scope write behavior, the
mobile contract requires the server-owned route shape and invalidation/sync
behavior to be preserved or explicitly migrated.

## Verification

This was a read-only audit and documentation closeout. The proof relies on the
accepted focused suites from the underlying slices:

- `docs/_execution/2026-05-07_mobile_data_accuracy_service_period_sync_proof.md`
- `docs/_execution/2026-05-07_mobile_reservation_demand_settings_sync_proof.md`
- `docs/_execution/2026-05-07_mobile_wage_role_rows_sync_proof.md`
- `docs/_execution/2026-05-07_weekly_plan_server_truth_mobile_proof.md`
- `docs/_execution/2026-05-07_mobile_business_scope_selector_proof.md`
- `docs/_execution/2026-05-07_mobile_business_scope_invalidation_proof.md`

Closeout commands for this audit branch:

```powershell
dart analyze lib\services\sync\http_sync_proxy_client.dart lib\services\sync\postgres_shift_record_to_mobile_sync.dart tool\advisor_proxy\advisor_proxy.dart tool\advisor_proxy\proxy_bootstrap.dart
flutter test test\tool\advisor_proxy\admin_idempotency_reclaim_test.dart
dart run tool\migration_drift_scanner.dart --fix --strict-docs
dart run tool\migration_cutoff_lint.dart
git diff --check
```

## Remaining Doc 1 Work

- `8.business-scope-rollup-truth`: server rollup truth for
  group/region/company scopes.
- `8.connected-device-e2e-smoke`: operator/device gated.
- `8.<vendor>.live.sandbox`: vendor credential and sandbox/live gated.
- `8.push-notification-connected-device-proof`: explicitly out of this sprint.
- `cutover.0b.tier-m-perf-gate`: larger pressure proof, not a mobile core
  blocker.
