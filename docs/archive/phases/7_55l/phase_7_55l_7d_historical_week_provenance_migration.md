# Phase 7.55l.7d - Historical Week Provenance Wording + Read-Surface Honesty

Updated: 2026-04-11 (7.55l.7d1 cycle-era label completion)
Owner: Codex planning / tracker truth
Status: Implemented (cycle-era labels added in 7.55l.7d1)

## Purpose

Make historical-week History / Week Detail surfaces honest about
locked-target provenance so completed-week reads stop implying
generic "baseline" truth and start reflecting the cycle-era
architecture.

After 7.55l.7a through 7.55l.7c1 migrated the current-week runtime
seams, historical-week surfaces still spoke in pre-cycle language.
This slice corrects the wording and surfaces stored provenance from
`WeekRecord.targetSourceType`.

## What This Slice Adds

### Section Label Wording

`WeekDetailScreen` section label updated from:

- "WEEKLY SUMMARY vs BASELINE" → "WEEKLY SUMMARY vs LOCKED TARGETS"

This honestly reflects that completed-week comparison targets are
locked at close time, not a generic baseline.

### Provenance Label Getter

`WeekRecord.provenanceLabel` maps stored `targetSourceType` values
to readable product text. Both legacy pre-cycle and cycle-era source
types are handled:

Legacy source types:
- `system_baseline` → "60-Day Benchmark"
- `manager_override` → "Manager Override"
- `admin_replacement` → "Admin Override"

Cycle-era source types (from `TargetCycleActiveTargetProfileProjector`):
- `cycle_recommended` → "60-Day Benchmark"
- `cycle_manager_override` → "Manager Override"
- `cycle_admin_replacement` → "Admin Override"

Fallback:
- `null` or unknown → "Baseline"

Legacy and cycle-era values with the same intent share the same
user-facing label. The distinction is internal provenance only.

### Week Detail Provenance Subtitle

`WeekDetailScreen` now shows a provenance subtitle under the header:

```
Targets: 60-Day Benchmark
```

This gives the manager a clear, quiet signal about which target
source was active when the week closed.

### History Tile Provenance Hint

`WeekHistoryTile` now shows the provenance label as a subtle third
line in the left column below the shift count. This makes the
History list honest about target source without adding visual noise.

## What This Slice Does Not Do

- No SQLite schema changes
- No new persistence layer
- No historical `WeeklyPlanSnapshot` identity on these screens
- No Learn migration
- No Schedule Builder migration
- No SchedulePlan math changes
- No labor formula changes
- No demand math changes
- No manager UX workflow changes
- No tracker file changes

## Bridge Status

Historical screens now reflect locked target provenance from
`WeekRecord`. Deeper week-plan lineage (historical
`WeeklyPlanSnapshot` identity, cycle-to-week threading in the UI)
can come later if needed. This slice makes the read surfaces
honest with the data already persisted.

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Current-week variance migration: `docs/archive/phases/7_55l/phase_7_55l_7b_current_week_variance_migration.md`
- Current-week full week migration: `docs/archive/phases/7_55l/phase_7_55l_7c_current_week_full_week_migration.md`
- WeekRecord: `lib/models/week_record.dart`
- WeekDetailScreen: `lib/screens/week_detail_screen.dart`
- WeekHistoryTile: `lib/widgets/week_history_tile.dart`
