# Mobile Core Doc 1 Closeout Status

Date: 2026-05-07
Baseline: `origin/master` at `516ef285`
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

## Remaining Doc 1 Work

| Gap | Next slice | Why it remains |
| --- | --- | --- |
| Admin/web business-control setting sync inventory | `audit.admin-web-setting-sync` | Doc 1 requires timing/data-accuracy/target-related setting changes to be inventoried and then remediated where mobile behavior depends on them. |
| Group/region/company scope rollup truth | `8.business-scope-rollup-truth` | PR #236 intentionally enables location switching only. Higher scopes are listed but not switchable until server rollup snapshots exist. |
| Connected-device E2E proof | `8.connected-device-e2e-smoke` | Requires a physical or emulator device bound to the real proxy/mobile SQLite flow. |
| Live provider proof | `8.<vendor>.live.sandbox` per vendor | Requires sandbox/live credentials and operator approval. |
| Push notification proof | `8.push-notification-connected-device-proof` | Explicitly out of the current sprint; code is separate from mobile core data truth. |
| Larger pressure suite | `cutover.0b.tier-m-perf-gate` | Explicitly not a blocker for this sprint; belongs to cutover. |

## Next Execution Order

1. Run `audit.admin-web-setting-sync` first because it is code-discovery only
   and determines whether mobile has any remaining non-operator-blocked logic
   gaps.
2. If the audit finds mobile behavior gaps, patch those as narrow remediation
   slices.
3. Plan group/region/company rollup truth as a separate server-rollup sprint.
4. Leave connected-device, live-provider, push, and pressure proof on their
   operator-gated tracks.

## Contract Guardrails

- Mobile remains a cache.
- Mobile must not become the durable owner of selected stars, target cycles,
  active profiles, weekly plans, business-scope access, or admin settings.
- No duplicate mobile cache tables.
- No push notification proof or huge pressure suite in this sprint.
