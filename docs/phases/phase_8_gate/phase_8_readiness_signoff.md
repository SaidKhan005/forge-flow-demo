# Phase 8 Readiness Signoff

## Gate Purpose

Phase 8 adds live POS and labor adapters. This gate exists to confirm the app is aligned enough that Phase 8 can focus on connector transport and vendor field mapping, not another internal state-boundary rewrite.

## What Is Structurally Complete From 7.5 / 7.51

- 7.5a: Restaurant scope, SQLite bootstrap split, DAOs, repository implementations, additive migration/backfill, fixture replay import tracking, DatabaseHelper compatibility delegation.
- 7.5b: Active target profile persistence, immutable target profile versions, locked historical target truth on closed shifts and week rollups, explicit WTD target injection.
- 7.5c: Open/current-state models and persistence, Shift and Zone status hero read from repository-backed state, Variance Full Week reads from merged current-week state, fixture replay drives all aligned read paths.
- 7.51a: Variance Full Week closed-shift detail reads locked shift targets instead of current BaselineData. Override does not rewrite closed history.
- 7.51b: App-shell propagation moved off BaselineData.revision onto persisted ActiveTargetProfileNotifier. Remaining BaselineData usage explicitly classified as temporary compatibility bridge.
- 7.51d: Schedule visible surface migrated to injected active-target values. App data status service covers no-data, stale, failed, historical-only, and current. Compatibility bridge scope frozen. Projected/open Variance surfaces use active target profile. Shift empty-state renders truthfully. Connector config persistence boundary complete. Clear All Data actually clears.
- 7.51e: 28-file Flutter corpus rerun completed â€” all passed at that time.

## Current Evidence Summary

| Evidence Category | Status |
| --- | --- |
| Fixture replay drives aligned read surfaces | Code and test evidence exists |
| Locked historical target truth on closed shifts | Code and test evidence exists |
| Override does not rewrite closed history | Code and test evidence exists |
| Active target propagation off BaselineData.revision | Code and test evidence exists |
| Projected/open Variance uses active target profile | Code and test evidence exists |
| Shift empty-state renders truthfully | Code and test evidence exists |
| Connector config persistence boundary | Code and test evidence exists |
| Clear All Data actually clears | Code evidence exists |
| Written POS vendor capability profile | Checked in - vendor selection is TBD |
| Written labor vendor capability profile | Checked in - vendor selection is TBD |
| Source ownership matrix | Checked in |
| Replay readiness matrix | Checked in - all scenarios proven; runtime read-path independence verified end-to-end (7.55n.13) |
| Runnable Flutter test execution | Restored (7.55n.13) â€” key SQLite-backed proof files re-verified: replay_integrity 22/22, current_state_alignment 35/35, mock_replay_scenario 34/34, app_data_status 9/9, shift_dashboard_notifier 8/8 |
| Vendor live-data capability audit | Completed (7.55n.12) - official-doc-backed; see vendor_live_data_capability_matrix.md |

## Gate Checklist

| # | Gate Item | Status |
| --- | --- | --- |
| 1 | Fixture replay drives aligned app read surfaces without direct screen-level demo constants | Yes |
| 2 | Variance Full Week closed detail uses locked target truth | Yes |
| 3 | Active-target propagation no longer depends on BaselineData.revision | Yes |
| 4 | Projected/open Variance surfaces use active target profile, not static config | Yes |
| 5 | Shift tab renders truthful empty state when no open snapshot exists | Yes |
| 6 | Connector config persistence boundary (model, table, repo, DAO) exists | Yes |
| 7 | Clear All Data actually clears operational data without reseeding | Yes |
| 8 | Written POS vendor capability profile exists | Yes (vendor TBD) |
| 9 | Written labor vendor capability profile exists | Yes (vendor TBD) |
| 10 | Source-ownership matrix exists | Yes |
| 11 | Compatibility bridge scope frozen and documented | Yes |
| 12 | Replay-readiness scenarios have deterministic test evidence | Yes â€” all scenarios proven including end-to-end SQLite-backed proof (schema gap fixed in 7.55n.13) |
| 13 | Schedule visible surface uses injected active-target values | Yes |
| 14 | App data status service covers no-data, stale, failed, historical-only, and current | Yes |
| 15 | Variance banner uses WeekData theoretical labor %, not MeridianConfig | Yes |
| 16 | POS vendor selected and capability profile completed | No |
| 17 | Labor vendor selected and capability profile completed | No |
| 18 | SQLite-backed proof files re-verified | Yes (7.55n.13) â€” replay_integrity 22/22, current_state_alignment 35/35, mock_replay_scenario 34/34, app_data_status 9/9, shift_dashboard_notifier 8/8 |
| 19 | Phase 8 can start from onboarding/adapter transport work, not another boundary rewrite | Yes - structurally ready |
| 20 | Vendor live-data capability audit completed with official-doc evidence | Yes (7.55n.12) |

## Exact Blockers

1. **POS vendor selection TBD** â€” The POS capability profile is checked in but marked TBD for vendor name and all vendor-specific fields. Connector implementation cannot start until a vendor is selected. The live-data audit (7.55n.12) provides official-doc evidence to inform this decision.
2. **Labor vendor selection TBD** â€” Same as POS. The labor capability profile is checked in but vendor-specific fields are unknown.

## Resolved Blockers

3. **~~`snapshot_blended_wage` schema column gap~~** â€” Fixed in 7.55n.13 (V20 migration). The column is now present in both the CREATE TABLE and the upgrade path. All previously blocked SQLite-backed tests now pass. The replay_integrity_audit_test groups A, B, and E are restored and verified.

## Live-Data Capability Audit (7.55n.12)

A vendor-by-vendor live-data capability audit has been completed using
official vendor documentation. The audit covers Toast, Square, Clover
(POS) and 7shifts (labor) across webhooks, polling, rate limits,
intraday sales, covers, timestamps, labor data, and close/finalization
signals.

See:
- `docs/phases/phase_8_gate/vendor_live_data_capability_matrix.md` â€” side-by-side matrix
- `docs/archive/phases/7_55n/phase_7_55n_12_vendor_live_data_capability_audit.md` â€” analysis + product implications

This audit provides evidence for vendor selection but does not force a
decision. The vendor profiles above remain TBD until selection is made.

## Next Actions to Clear Blockers

1. Select the first POS vendor. Fill in the vendor-specific fields in docs/phases/phase_8_gate/vendor_capability_profile_pos.md. The live-data audit (7.55n.12) provides official-doc evidence to inform this decision.
2. Select the first labor vendor. Fill in the vendor-specific fields in docs/phases/phase_8_gate/vendor_capability_profile_labor.md.
3. After both are resolved, update this signoff to mark the gate as fully passed.

## Gate Decision

**Blocked on vendor selection only.**

All structural app alignment is complete. All replay-proof evidence has
been restored and re-verified (7.55n.13). The app-side canonical input
model, import tracking, connector config persistence boundary, adapter
boundary, freshness architecture, and write/import propagation contract
are all ready to receive connector work.

The remaining blocker is vendor selection:

- **POS vendor** â€” vendor capability profiles are checked in but marked
  TBD. The live-data audit (7.55n.12) provides official-doc-backed
  evidence to inform selection. Toast is the strongest candidate for the
  manager-live Shift use case.
- **Labor vendor** â€” same. 7shifts is the strongest candidate for
  finalization signal and per-punch wage data.

Phase 8 connector implementation can begin as soon as vendors are
selected and their capability profiles are filled in with real
vendor-specific fields.
