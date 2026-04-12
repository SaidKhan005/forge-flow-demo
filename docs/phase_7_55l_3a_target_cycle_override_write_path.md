# Phase 7.55l.3a - TargetCycle Override Write Path

Updated: 2026-04-11 (7.55l.3b provenance + history preservation cleanup applied)
Owner: Codex planning / tracker truth
Status: Implemented — write path only, no Benchmark UI wiring

## Purpose

Add the manager override and admin replacement cycle mutation paths so the
cycle layer can record all three provenance types:

- recommended cycle (existing from 7.55l.2a)
- manager override cycle (new in this slice)
- admin replacement cycle (new in this slice)

This is the write-path slice only. Benchmark UI/save-flow wiring into the
new cycle mutation API is deferred to avoid split-brain between
`ActiveTargetProfile` and `TargetCycle` before projection work (7.55l.4).

## What This Slice Adds

### ManagerOverrideDeniedException

A narrow domain exception thrown when the manager override is denied by
`TargetCyclePolicy` rules:

- once-per-cycle override already consumed
- business date outside the cycle's active window

No UI handling in this slice — the caller sees the exception directly.

### TargetCycleService.applyManagerOverrideCycle

Manager override write path:

1. Load or create the active cycle for the supplied business date
   (auto-refresh fires if past cycle end).
2. Check eligibility via `TargetCyclePolicy.canManagerOverride` —
   requires active window + once-per-cycle not yet consumed.
3. Deny with `ManagerOverrideDeniedException` if ineligible.
4. Re-prime `BaselineData` for the business date's 60-day window.
5. Resolve wages fresh via `WageStandardContextService`.
6. Build fresh locked standards via `buildActiveTargetProfileFromBaseline`.
7. Deactivate all active cycles for the restaurant.
8. Write replacement cycle row with:
   - same effective window as the prior cycle
   - calibration window recalibrated to the actual rebuild date's
     60-day window (`[businessDate - 59, businessDate]`)
   - `source = managerOverride`
   - `managerOverrideUsed = true`
   - `managerOverrideAt` set to current UTC timestamp
   - fresh locked standards from current app truth

### TargetCycleService.applyAdminReplacementCycle

Admin replacement write path:

1. Load or create the active cycle for the supplied business date.
2. No eligibility check — admin can replace regardless of prior
   manager override usage.
3. Same fresh-build sequence as manager override
   (re-prime, resolve wages, build standards).
4. Deactivate all active cycles for the restaurant.
5. Write replacement cycle row with:
   - same effective window as the prior cycle
   - calibration window recalibrated to the actual rebuild date's
     60-day window (`[businessDate - 59, businessDate]`)
   - `source = adminReplacement`
   - `adminReplacedAt` set to current UTC timestamp
   - prior `managerOverrideUsed` and `managerOverrideAt` preserved
     as historical metadata
   - fresh locked standards from current app truth

### Shared _writeReplacementCycle Helper

Both override and replacement paths share a private helper that handles
the common sequence: re-prime baseline context, resolve wages, build
standards, deactivate old cycles, construct and write the replacement row.

## Replacement Semantics

### Effective Window Preservation + Calibration Recalibration

Both manager override and admin replacement preserve the current cycle's
effective window (the 60-day target window remains unchanged). However,
the calibration window is recalibrated to match the actual benchmark
window used to rebuild the replacement's locked standards:

- `calibrationWindowEnd = businessDate` (the date the replacement was built)
- `calibrationWindowStart = businessDate - 59`

This ensures provenance honesty: the stored calibration metadata matches
the actual data window that produced the standards, rather than preserving
a stale prior window whose data was not used.

### One-Active-Per-Restaurant

Enforced the same way as recommended cycles: bulk deactivation of all
active rows before writing the new replacement. Old cycle rows are
retained as historical (deactivated, not deleted).

### Cycle ID Convention

Recommended cycles use the business date in the ID. Replacement cycles
use a UTC timestamp (milliseconds since epoch) to ensure every
replacement row gets a unique ID, even for repeated same-day
replacements:

- Recommended: `{restaurantId}_cycle_{yyyyMMdd}`
- Manager override: `{restaurantId}_manager_override_{utcMillis}`
- Admin replacement: `{restaurantId}_admin_replacement_{utcMillis}`

This prevents replace-backed upsert from overwriting prior historical
rows when the same source is used on the same day.

### Standards Freshness

Replacement cycles rebuild standards from the same app-truth bridge as
recommended cycles:

1. `primeBaselineContextForDate` re-primes in-memory `BaselineData`
2. `WageStandardContextService.resolve` provides fresh wages
3. `buildActiveTargetProfileFromBaseline` reads from the primed state

This is the transitional bridge — 7.55l.4 will project the profile from
the cycle instead.

## What This Slice Does Not Do

- No Benchmark UI/save-flow wiring
- No `BaselineManagerService.saveSelection` integration
- No `ActiveTargetProfile` projection from cycle (-> 7.55l.4)
- No consumer migration (-> 7.55l.7)
- No weekly plan logic (-> 7.55l.6)
- No auth enforcement for admin replacement
- No tracker file changes

## Contract Rules Honored

From `phase_7_55_target_cycle_weekly_plan_rules.md`:

1. One active cycle per restaurant — enforced via bulk deactivation
2. Manager override once per cycle — enforced via `TargetCyclePolicy.canManagerOverride`
3. After manager override, only admin can change the target before cycle end
4. Old cycles preserved as historical rows (deactivated, not deleted)
5. Replacement standards rebuilt fresh from current app truth
6. Effective window preserved on replacement; calibration window
   recalibrated to match the actual benchmark rebuild window

## Cross-References

- Architecture rules: `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Contract doc: `docs/phase_7_55l_1_target_cycle_contract.md`
- Persistence spine: `docs/phase_7_55l_2a_target_cycle_persistence_autorefresh.md`
- TargetCycle model: `lib/domain/models/target_cycle.dart`
- TargetCyclePolicy: `lib/domain/services/target_cycle_policy.dart`
- TargetCycleService: `lib/data/target_cycle_service.dart`
