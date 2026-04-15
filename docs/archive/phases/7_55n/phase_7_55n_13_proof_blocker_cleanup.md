# Phase 7.55n.13 - Proof / Blocker Cleanup

Updated: 2026-04-13
Owner: Claude implementation
Status: Landed

## Goal

Clear the remaining proof blocker so the repo can honestly re-run the
SQLite-backed freshness / replay proof and update the Phase 8 gate docs
from actual current evidence.

## Scope

- In: `snapshot_blended_wage` schema gap fix (CREATE TABLE + V20
  migration), restore skipped replay-proof tests, re-run all blocked
  SQLite-backed proof files, update gate docs from real evidence
- Out: unrelated schema cleanup, UI changes, test rewrites for other
  reasons, new architecture

## What The Blocker Was

`ShiftRecord.toMap()` writes `snapshot_blended_wage` to the map used for
SQLite INSERT operations. But the `shift_records` CREATE TABLE statement
did not include a `snapshot_blended_wage` column. This caused every
`reseedDemo()` call to fail with a SQLite column-not-found error,
blocking all SQLite-backed tests that depend on seeded operational data.

The field itself is legitimate — it stores the blended wage from
`OpenShiftSnapshot` for open/projected rows. It was added to the model
and serialization but never added to the table schema.

## What Landed

1. **Schema fix**: Added `snapshot_blended_wage REAL` to the
   `shift_records` CREATE TABLE (fresh DB creation path).

2. **V20 migration**: Added `_migrateToV20()` that conditionally adds
   the column via `ALTER TABLE` for existing databases. Schema version
   bumped from 19 to 20.

3. **Test restoration**: Unskipped groups A, B, and E in
   `test/replay_integrity_audit_test.dart`. These groups contain real
   assertions that were blocked only by the schema gap.

4. **Proof rerun**: All previously blocked SQLite-backed tests now pass:
   - `replay_integrity_audit_test.dart`: 22/22 (was 15/15 + 7 skipped)
   - `current_state_alignment_test.dart`: 35/35
   - `mock_replay_scenario_test.dart`: 34/34
   - `app_data_status_test.dart`: 9/9
   - `shift_dashboard_notifier_test.dart`: 8/8

5. **Gate doc updates**: `replay_readiness_matrix.md` and
   `phase_8_readiness_signoff.md` updated from actual rerun evidence.
   The schema gap blocker is now resolved. The gate is blocked on vendor
   selection only.

## Touched Seams

| File | What changed |
|---|---|
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | Schema version 19 → 20. Added `snapshot_blended_wage REAL` to `shift_records` CREATE TABLE. Added `_migrateToV20()` with conditional ALTER TABLE. |
| `test/replay_integrity_audit_test.dart` | Unskipped groups A, B, E. Updated file header to reflect all groups proven. |
| `docs/phases/phase_8_gate/replay_readiness_matrix.md` | Runtime read-path independence upgraded from "Partially proven" to "Proven". Runnable Flutter Proof upgraded from "Previously completed, currently blocked" to "Restored (7.55n.13)" with rerun counts. |
| `docs/phases/phase_8_gate/phase_8_readiness_signoff.md` | Evidence summary, checklist rows #12 and #18, blockers, and gate decision all updated from actual rerun evidence. Schema gap moved to "Resolved Blockers". Gate decision now "Blocked on vendor selection only". |

## Remaining Gaps

- **Vendor selection** still TBD (POS and labor). This is not a proof
  blocker — it is a business decision.
- **Full 28-file corpus rerun** not re-executed in this slice. The 5
  highest-signal SQLite-backed files were re-verified. The remaining
  files (widget tests, pure logic tests) were not affected by the
  schema gap and did not need re-verification.
- **Full timezone conversion** still deferred (documented in 7.55n.10).
