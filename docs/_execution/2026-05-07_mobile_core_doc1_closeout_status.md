# Mobile Core Doc 1 Closeout Status

Date: 2026-05-07
Baseline: `origin/master` at `537d5319`
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

## Remaining Doc 1 Work

| Gap | Next slice | Why it remains |
| --- | --- | --- |
| Admin/web business-control setting sync inventory | Closed by `docs/_execution/2026-05-07_admin_web_setting_sync_closeout.md` | Inventory is complete as documentation/tracker truth; remaining timing, keyed data accuracy, wage/role, rollup, and operator-blocked proof items are split out in the closeout truth table. |
| Group/region/company scope rollup truth | `8.business-scope-rollup-truth` | PR #236 intentionally enables location switching only. Higher scopes are listed but not switchable until server rollup snapshots exist. |
| Physical connected-device E2E proof | `8.connected-device-e2e-smoke` | Simulated proof is documented; final acceptance still requires a physical or emulator device bound to the real proxy/mobile SQLite flow. |
| Live provider proof | `8.<vendor>.live.sandbox` per vendor | Requires sandbox/live credentials and operator approval. |
| Push notification delivery proof | `8.push-notification-connected-device-proof` | Code/config preflight is documented; staging Firebase apply, controlled send, and device foreground/background proof remain operator-gated. |
| Larger pressure suite | `cutover.0b.tier-m-perf-gate` | Explicitly not a blocker for this sprint; belongs to cutover. |

## Next Execution Order

1. Use `docs/_execution/2026-05-07_admin_web_setting_sync_closeout.md`
   as the admin/web setting sync truth table.
2. Patch any non-operator-blocked partials as narrow remediation slices.
3. Plan group/region/company rollup truth as a separate server-rollup sprint.
4. Leave connected-device, live-provider, push, and pressure proof on their
   operator-gated tracks.

## Contract Guardrails

- Mobile remains a cache.
- Mobile must not become the durable owner of selected stars, target cycles,
  active profiles, weekly plans, business-scope access, or admin settings.
- No duplicate mobile cache tables.
- No push notification proof or huge pressure suite in this sprint.
