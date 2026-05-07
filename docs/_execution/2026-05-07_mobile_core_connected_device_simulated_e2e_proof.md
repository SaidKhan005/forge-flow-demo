# Mobile Core Connected-Device Simulated E2E Proof

Date: 2026-05-07
Branch: `codex/doc1-connected-device-sim-proof`
Status: simulated/automated evidence map only; connected-device acceptance
remains blocked

Primary contract:

- `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`

Related closeout status:

- `docs/_execution/2026-05-07_mobile_core_doc1_closeout_status.md`

## Purpose

Doc 1 Phase 10 requires connected-device E2E proof for five mobile core paths.
This document closes as much of that proof package as possible without:

- a physical or emulator device bound to the real mobile app runtime
- live vendor credentials or live provider webhook traffic
- staging/Production1 migration apply proof
- push notification delivery proof
- screenshot/video capture from a connected handset

This is not a replacement for the operator-blocked connected-device gate. It is
an honest map from each required path to the current automated or fixture-backed
evidence, plus the substitutions still being made.

## Evidence Matrix

| Doc 1 Phase 10 path | Current automated/simulated evidence | Substitution and remaining gap |
| --- | --- | --- |
| 1. first connect -> backfill -> closed shifts -> Star candidates | `docs/_execution/2026-05-06_8_first_connection_backfill_proof.md` proves fixture connect enqueue, adapter `backfill()`, canonical writes, watermark/sync-log/demo flip seams, closed post-commit projection, mobile-visible cache shape, and one open snapshot projection. `docs/_execution/2026-05-06_8_live_and_closed_truth_proof_execution.md` proves closed triplet, closed-label stability, live projector, and proxy-to-mobile open snapshot pull through `tool/payload_harness/main.dart`. `docs/_walkthroughs/8.timing-provenance-closed.md` pins closed timing provenance. Star candidate/read-model downstream is covered by the accepted closed history/star-target proof chain in `docs/_execution/2026-05-06_8_star_target_truth_proof.md`. | Vendor connect result, adapters, sink, closed writer, open projector, and mobile cache are fixture/simulated. No live provider call, no Cloud Run worker invocation, no live Postgres apply, and no connected phone showing Star Shifts after real backfill. |
| 2. manager selection -> target cycle -> active target profile -> plan | `docs/_execution/2026-05-06_8_star_target_truth_proof.md` proves server-owned selected stars, target cycles, active profiles, profile versions, audit, proxy routes, mobile mirrors, and fixture harness. `docs/_execution/2026-05-07_mobile_star_target_projection_route_proof.md` closes the projection-route gap by posting selected-star diff first, then projecting the manager override through server truth. `docs/_execution/2026-05-07_weekly_plan_server_truth_mobile_proof.md` proves server-owned forecast contexts and weekly plan snapshots, proxy lock/read routes, mobile sync cache, embedded forecast context cache, and Schedule honesty when a server snapshot is missing. | Cross-device behavior is represented by proxy/mobile sync and repository tests, not two connected devices. Weekly plan lock/projection is automated and fixture-backed; no live manager session on one handset and second handset refresh proof was run. |
| 3. POS live event -> open snapshot -> Shift Dashboard | `docs/_execution/2026-05-06_8_live_and_closed_truth_proof_execution.md` proves canonical facts -> `OpenShiftSnapshotProjector` -> `open_shift_snapshots` and proxy -> mobile SQLite pull. `test/services/integration/open_shift_snapshot_projector_test.dart`, `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart`, and `test/services/sync/http_sync_proxy_client_test.dart` cover projector and sync parsing. Shift Dashboard/daypart consumption is pinned by `docs/_walkthroughs/10.5.0.md`, `10.5.2.md`, `10.5.3.md`, and their widget/read-service tests. | POS webhook is simulated as canonical facts/payload harness inputs. The dashboard proof is widget/read-service evidence, not a connected-device screenshot from the running mobile shell after a live POS webhook. |
| 4. admin timing change -> mobile timing config -> screen dayparts | Operator/admin timing write/read paths are covered by `test/proxy/operator_business_timing_routes_test.dart`, `test/operator_web/services/web_business_timing_gateway_test.dart`, and `test/operator_web/screens/business_timing_editor_screen_test.dart`. Mobile timing pull is covered by `test/proxy/mobile_operational_sync_routes_test.dart`, `test/services/sync/http_sync_proxy_client_test.dart`, and `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart` for `/timing/resolved`. Closed and live rows preserve timing provenance per `docs/_walkthroughs/8.timing-provenance-closed.md`. Daypart screen rendering is covered by the 10.5 walkthroughs and `test/widget/shift_dashboard_daypart_test.dart`, `test/shift_dashboard_daypart_toggle_widget_test.dart`, and `test/state/shift_service_period_notifier_test.dart`. | The admin timing change is not driven through a real browser session into a connected mobile runtime. Evidence is route/gateway/widget/sync test coverage. Real device proof still needs: change timing on web/admin, sync mobile, capture updated dayparts, and verify old closed labels do not drift. |
| 5. scope switch -> fresh data -> no leakage | `docs/_execution/2026-05-07_mobile_business_scope_selector_proof.md` proves the accessible-scope route, local active-scope SQLite repository, hamburger drawer foundation, sync cancellation, and cross-scope cache wipe. `docs/_execution/2026-05-07_mobile_scope_flat_location_search_proof.md` proves higher-level grants expand into selectable location rows without mobile rollups. `docs/_execution/2026-05-07_mobile_business_scope_invalidation_proof.md` proves stale-access invalidation for role/org/location changes. `test/services/sync/mobile_operational_sync_runtime_test.dart` covers persisted active scope proxy pulls, cancellation, cross-tenant purge, sign-out abort, and wage-role realtime invalidation. | Scope behavior is proven in notifier/runtime/proxy tests, not with a human switching locations on a connected phone. Group/region/company rollup dashboards remain out of scope until server rollup truth exists. |

## Admin/Web Business-Setting Sync Evidence

The following Doc 1 admin/web setting gaps now have focused simulated proof and
can be referenced by the connected-device follow-up:

- Selected star/target/profile projection:
  `docs/_execution/2026-05-07_mobile_star_target_projection_route_proof.md`
- Weekly plan and durable embedded forecast context:
  `docs/_execution/2026-05-07_weekly_plan_server_truth_mobile_proof.md`
- Business scope selector, flat location projection, and stale-access
  invalidation:
  `docs/_execution/2026-05-07_mobile_business_scope_selector_proof.md`
  `docs/_execution/2026-05-07_mobile_scope_flat_location_search_proof.md`
  `docs/_execution/2026-05-07_mobile_business_scope_invalidation_proof.md`
- Data accuracy service-period settings:
  `docs/_execution/2026-05-07_mobile_data_accuracy_service_period_sync_proof.md`
- Reservation demand / walk-in settings:
  `docs/_execution/2026-05-07_mobile_reservation_demand_settings_sync_proof.md`
- Wage source / wage mix / role rows:
  `docs/_execution/2026-05-07_mobile_wage_role_rows_sync_proof.md`

## Branch-Local Verification

Run in this worktree on 2026-05-07:

```powershell
flutter test tool\first_connection_backfill_harness\main.dart
flutter test test\services\sync\mobile_operational_sync_runtime_test.dart
```

Results:

- First-connection harness: PASS. Fixture summary reported
  `connect_jobs_enqueued: 1`, `dispatched_jobs: 3`,
  `canonical_facts_written: 5`, `demo_flips: 3`,
  `closed_rows_mobile_visible: 1`, and `open_snapshots_projected: 1`.
- Mobile operational sync runtime: PASS, 8 tests. Covered active-scope proxy
  rebase, in-flight cancellation, prior-tenant purge, sign-out abort, singleton
  override reset, wage-role realtime invalidation, and abort cooperation.

## Explicitly Not Proved

The following remain blocked and must not be represented as accepted by this
document:

- Connected physical/emulator device running the production mobile app against
  the real proxy and real mobile SQLite store.
- Live vendor OAuth/key-paste connection using vendor credentials.
- Live provider webhook/POS event.
- Cloud Run first-connect worker invocation.
- Live staging/Production1 Postgres migration apply.
- Push notification registration or delivery.
- Screenshot/video evidence per screen.
- Group/region/company rollup dashboard proof.

## Connected-Device Follow-Up Checklist

When the operator-blocked environment is available, run one narrow device proof
that records logs or screenshots for:

1. Connect a sandbox/live provider, wait for first backfill, open mobile History
   and Star Shifts, and confirm closed rows/candidates are no longer demo-only.
2. Select stars on device A or one session, sync device B or a second session,
   and confirm selected stars, target cycle, active target profile, and Schedule
   locked plan are server-sourced.
3. Send a live POS event, pull mobile sync, and capture Shift Dashboard live
   state from `open_shift_snapshots`.
4. Change timing/dayparts on web/admin, pull mobile sync, and capture new
   daypart config while old closed rows keep saved timing labels.
5. Switch accessible locations in the mobile drawer, confirm sync cancellation
   and fresh pull, then verify prior-scope data is absent from dashboard,
   Variance, History, Plan, and Star Shifts.

