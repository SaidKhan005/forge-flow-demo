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
- 7.51e: 28-file Flutter corpus rerun completed — all passed. Gate blocked on vendor selection only.

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
| Replay readiness matrix | Checked in - all scenarios have deterministic evidence |
| Runnable Flutter test execution | Completed — 28 test files, all passed, re-verified post-7.52c via scripts/run_phase8_gate_tests.ps1 -ContinueOnFailure |

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
| 12 | Replay-readiness scenarios have deterministic test evidence | Yes |
| 13 | Schedule visible surface uses injected active-target values | Yes |
| 14 | App data status service covers no-data, stale, failed, historical-only, and current | Yes |
| 15 | Variance banner uses WeekData theoretical labor %, not MeridianConfig | Yes |
| 16 | POS vendor selected and capability profile completed | No |
| 17 | Labor vendor selected and capability profile completed | No |
| 18 | Current 28-file Flutter corpus rerun recorded from docs/phase_8_gate/test_execution_manifest.md | Yes — 28/28 passed (re-verified post-7.52c) |
| 19 | Phase 8 can start from onboarding/adapter transport work, not another boundary rewrite | Yes - structurally ready |

## Exact Blockers

1. POS vendor selection TBD — The POS capability profile is checked in but marked TBD for vendor name and all vendor-specific fields. Connector implementation cannot start until a vendor is selected.
2. Labor vendor selection TBD — Same as POS. The labor capability profile is checked in but vendor-specific fields are unknown.

## Next Actions to Clear Blockers

1. Select the first POS vendor. Fill in the vendor-specific fields in docs/phase_8_gate/vendor_capability_profile_pos.md.
2. Select the first labor vendor. Fill in the vendor-specific fields in docs/phase_8_gate/vendor_capability_profile_labor.md.
3. After both are resolved, update this signoff to mark the gate as fully passed.

## Gate Decision

Blocked on vendor selection only. All structural app alignment is complete. All non-vendor code issues from the final audit are closed. Written gate artifacts are checked in. Replay readiness scenarios all have real evidence. The full 28-file Flutter test corpus has been run and all files pass (re-verified post-7.52c file renames).

Phase 8 must remain blocked until both POS and labor vendors are selected and their capability profiles are filled in with real vendor-specific fields. The app-side canonical input model, import tracking, connector config persistence boundary, and adapter boundary are ready to receive connector work as soon as vendors are chosen.