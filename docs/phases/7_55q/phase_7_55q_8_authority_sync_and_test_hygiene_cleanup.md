# Phase 7.55q.8 - Authority Sync And Test Hygiene Cleanup

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Sync the active authority docs to the landed q-lane runtime and clean up
the recently touched alignment tests so their names/comments no longer
teach retired contracts.

## Scope

- In: active tracker / alignment tracker / status ledger sync; one stale
  active q doc note corrected; one stale runtime comment corrected;
  targeted stale test naming/comment cleanup in the current-state WTD /
  boundary suites; this doc.
- Out: broad product logic changes.
- Out: large-scale test deduplication or fixture refactors.

## Why this slice exists

After `7.55q.5` through `7.55q.7` landed, the repo's live authority
files still pointed at pre-fix work:

- trackers still said `7.55q.5` was current
- the alignment tracker still parked `7.55q.6`
- the status ledger still described History as broken
- one active q doc still repeated the retired WTD "else model" fallback
- one Shift comment and one test group label still taught old target-source
  ownership

The runtime was ahead of the docs. This slice brings the authority spine
back in sync.

## What changed

### Active authority docs

- `PROJECT_TRACKER.md`
  - now shows the q-lane complete through `7.55q.8`
  - resumes `7.55o.1` as the active prompt
  - lists `7.55q.5` through `7.55q.8` in active planning docs
- `docs/DATA_ALIGNMENT_TRACKER.md`
  - now shows `7.55q` complete and `7.55o` active
  - removes the stale "q.5 current / q.6 parked" queue
- `docs/internal/status_ledger_post_7_55p_deep_check.md`
  - now reflects landed History conformance
  - closes the old Shift target-labor mismatch row
  - closes the old "Benchmark package should feed Variance" row
  - closes the blended-wage refinement row

### Active q-lane docs / comments

- `docs/phases/7_55q/phase_7_55q_3_benchmark_target_object_cleanup.md`
  - now labels the old WTD model fallback as historical drift anatomy,
    not current contract wording
- `lib/data/shift_service.dart`
  - stale inline comment now matches the landed `7.55q.4` rule:
    non-closed Full Week rows read the current active profile, not the
    snapshot-linked cycle

### Test hygiene

- `test/current_state_alignment_test.dart`
  - header comment now describes the current locked-plan + active-profile
    contract plainly
- `test/shift_boundary_resolver_test.dart`
  - stale group/header wording changed from "cycle targets" to the
    current "snapshot forecast + current active profile targets" contract

## Files touched

| File | Change |
|---|---|
| `PROJECT_TRACKER.md` | current phase / prompt / planning docs synced to landed q state |
| `docs/DATA_ALIGNMENT_TRACKER.md` | current-next-steps + phase status synced to landed q state |
| `docs/internal/status_ledger_post_7_55p_deep_check.md` | stale post-q rows corrected |
| `docs/phases/7_55q/phase_7_55q_3_benchmark_target_object_cleanup.md` | old WTD "else model" wording narrowed to historical drift context |
| `lib/data/shift_service.dart` | stale comment updated to current target-source ownership |
| `test/current_state_alignment_test.dart` | file header refreshed to current architecture wording |
| `test/shift_boundary_resolver_test.dart` | stale group/header wording refreshed |

## Remaining gaps

- This is **not** a whole-repo test refactor.
- Larger future test cleanup can still consolidate helpers, reduce
  duplication, and simplify some historical suite names.
- The next execution lane is `7.55o.1`, not another q-lane runtime fix.
