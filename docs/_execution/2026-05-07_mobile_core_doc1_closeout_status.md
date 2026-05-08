# Mobile Core Doc 1 Closeout Status

Date: 2026-05-07
Baseline: `origin/master` at `932d46f5`
Primary contract:
`docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`

## Covered On Master

| Doc 1 path | Status | Evidence |
| --- | --- | --- |
| First connection backfill | Accepted under fixture proof | `docs/_execution/2026-05-06_8_first_connection_backfill_proof.md` |
| Closed shift server truth | Accepted under first-connect and timing provenance proofs | `lib/services/integration/canonical_fact_post_commit_projector.dart`; `docs/_walkthroughs/8.timing-provenance-closed.md` |
| Live shift projector | Accepted under fixture proof | `lib/services/integration/open_shift_snapshot_projector.dart`; `test/services/integration/open_shift_snapshot_projector_test.dart` |
| Star selection and target truth | Accepted under fixture proof | `docs/_execution/2026-05-06_8_star_target_truth_proof.md` |
| Weekly plan server truth | Merged via PR #226 | `docs/_execution/2026-05-07_weekly_plan_server_truth_mobile_proof.md` |
| Location-level mobile scope selector | Merged via PR #236 | `docs/_execution/2026-05-07_mobile_business_scope_selector_proof.md` |
| Base data accuracy operator-web live sync | Accepted under focused proof | `docs/_execution/2026-05-07_operator_web_data_accuracy_live_sync_proof.md` |
| Push preflight guardrail | Accepted as code/config preflight only | `docs/_execution/2026-05-07_mobile_push_preflight_proof.md` |
| Simulated first-connect/device flow | Accepted as simulated proof only | `docs/_execution/2026-05-07_mobile_core_connected_device_simulated_e2e_proof.md` |

## Doc 1 Status — closed for V1 2026-05-08

All non-operator-blocked Doc 1 items are closed. Detail in the
admin/web setting sync closeout doc (`2026-05-07_admin_web_setting_sync_closeout.md`).

| Gap | Status | Reference |
| --- | --- | --- |
| Admin/web business-control setting sync inventory | **closed** | `docs/_execution/2026-05-07_admin_web_setting_sync_closeout.md` |
| Timing web/admin live parity | **closed 2026-05-08** | PR [#398](https://github.com/SaidKhan005/forge-flow-demo/pull/398) |
| Keyed data accuracy admin/operator write surface | **closed 2026-05-08** | PR [#393](https://github.com/SaidKhan005/forge-flow-demo/pull/393) |
| Wage/role admin/operator-web write proof | **closed 2026-05-08** | PR [#391](https://github.com/SaidKhan005/forge-flow-demo/pull/391) |
| Group/region/company scope rollup truth | **backlog** | New server primitive; defer behind an explicit phase doc when operator priority shifts. Mobile location-level scope is sufficient for V1. |
| Connected-device E2E proof | **closed 2026-05-08 (emulator simulation)** | Pixel 5 / Android 14 emulator built `app-forgeflow-debug.apk` and ran the full UI tour: Shift "locked plan unavailable" empty state, Plan empty state with reasons, Variance whole-week + daypart toggle (with WEEK-TO-DATE vs PLAN data), Benchmark/Star Shifts 60-day data + CPLH range/target + Choose Star Shifts CTA, Settings W3.A 3-tab shape, hamburger location scope drawer. Screens: `.claude/screenshots_doc1_emu/01_initial_load.png` through `09_variance_daypart.png`. Live-vendor proof remains operator-blocked. |
| Live provider proof per vendor | unchanged | operator-blocked on sandbox creds |
| Push notification delivery proof | unchanged | operator-blocked on staging Firebase apply |
| Larger pressure suite | unchanged | owned by `cutover.0b.tier-m-perf-gate` |

## Next Execution Order

1. Doc 1 is no longer the bottleneck for V1 launch path — operator-blocked
   items are the remaining gates.
2. When the trio sandbox creds land, run the live `8.<vendor>.live.sandbox`
   slices for the connected-device live-vendor proof.
3. Group/region/company rollup truth: author as its own phase doc when an
   operator decision drives it. The mobile foundation
   (location-level scope + permission-scoped expansion) is in place to receive
   server rollup snapshots without UI rework.

## Contract Guardrails

- Mobile remains a cache.
- Mobile must not become the durable owner of selected stars, target cycles,
  active profiles, weekly plans, business-scope access, or admin settings.
- No duplicate mobile cache tables.
- No push notification proof or huge pressure suite in this sprint.
