# Phase 7.55m.2 — Mock Replay Drift Contract

Updated: 2026-04-12
Owner: Claude implementation
Status: Implemented (7.55m.2a category clarification completed)

## What This Slice Adds

An explicit contract for mock replay date advance, classifying every
affected surface into one of two categories:

1. **Replay-stable locked artifacts** — persisted once, survive replay
   advance unchanged.
2. **Replay-regenerated scenario data** — cleared and rebuilt from the
   deterministic seed on every replay advance.

The distinction matters because a skimming reader could otherwise assume
that `shift_records` or `week_records` survive replay advance as locked
truth. They do not — they are regenerated scenario data.

## Core Rule

Replay advance is a planning-anchor move that re-simulates operational
state for a new "today."

- **Replay-stable locked artifacts** survive unchanged.
- **Replay-regenerated scenario data** is cleared and rebuilt coherently
  from the deterministic seed.
- **Live planning surfaces** re-resolve from the new anchor on read.

In production architecture, closed actuals accumulate as real preserved
truth. But mock replay reseed is not normal production accumulation — it
is a scenario re-simulation path that rebuilds operational tables from
scratch for the new simulated date.

## Surface Classification

### 1. Replay-stable locked artifacts

These surfaces are persisted and intentionally NOT cleared by
`reseedMockReplayForBusinessDate`. They survive same-week and cross-week
replay advance unchanged.

| Surface | Lock rule | Enforcement |
|---|---|---|
| `WeeklyPlanSnapshot` | Once generated for a week key, returned unchanged on subsequent reads | `weekly_plan_snapshots` table not cleared by replay reseed; `getCurrentWeekSnapshot()` checks existing by week key first |
| `TargetCycle` | Once created and active, returned unchanged unless expired (60-day auto-refresh) | `target_cycles` table not cleared by replay reseed |
| `ActiveTargetProfile` from cycle | Not overwritten when a preserved active cycle exists | Conditional preservation in `reseedMockReplayForBusinessDate` (7.55l.6b3) |
| `BenchmarkSelectionSummary` | Tied to the active cycle; survives replay advance | `benchmark_selection_summaries` table not cleared by replay reseed |

### 2. Replay-regenerated scenario data

These surfaces are cleared and rebuilt from
`MockIntegrationReplaySeed.generateForDate()` on every replay advance.
The data changes because the simulated "today" changed — the 8-week
historical window slides, the current week shifts, and the
open/projected snapshot moves. This is correct mock behavior, not drift.

**These tables are NOT locked truth. They are regenerated scenario data.**

| Surface | What happens on replay advance |
|---|---|
| `shift_records` | Deleted and regenerated — 8 historical weeks + current week slide with the new anchor date |
| `week_records` | Deleted and regenerated — the historical window shifts forward |
| `open_shift_snapshots` | Deleted and regenerated for the new scenario date/daypart |
| `reservation_book_snapshots` | Deleted and regenerated for the new scenario date/daypart |
| `baseline_selected_records` | Cleared (manager selections don't carry across reseed) |
| `target_profile_versions` | Cleared (shift-close provenance rebuilds from reseed) |
| `import_runs`, `raw_import_records`, `sync_watermarks` | Cleared (integration bookkeeping resets) |

### 3. Live planning surfaces (re-resolve on read)

These surfaces intentionally re-resolve from the current planning anchor
each time they are read. They are not persisted artifacts — they are
computed live.

| Surface | Why it moves |
|---|---|
| Planning-anchor date (`BusinessDateAuthorityService`) | The anchor IS the mock replay date |
| `DemandForecastContext` (live) | 60-day + 21-day windows slide with the anchor |
| `getCurrentWeeklyPlan()` live path | Re-resolves from live demand + profile + weights |
| Distribution weights | 60-day + 21-day cover windows slide with the anchor |
| Baseline candidate window | 60-day window slides with the anchor |
| Shift dashboard | Reads from regenerated open-shift snapshots |

## Cross-Week Advance Rules

When replay advance crosses a week boundary (e.g., Sunday -> Monday):

1. The **prior week's locked `WeeklyPlanSnapshot`** survives in the
   `weekly_plan_snapshots` table (replay-stable).
2. A **new current-week snapshot** is generated on first access for the
   new week (different week key -> no existing snapshot found -> generation).
3. The **prior week's `TargetCycle`** survives unless it has expired
   (60-day window).
4. If the cycle window still covers the new week, the **same cycle** is
   reused for the new week's snapshot.
5. `shift_records` and `week_records` are **regenerated** — the prior
   current week now appears as a closed historical week in the
   regenerated seed, but this is a fresh simulation, not a preserved
   row from the previous reseed.

## Same-Week Advance Rules

When replay advance stays within the same business week
(e.g., Friday -> Saturday):

1. The **current-week locked `WeeklyPlanSnapshot`** is reused unchanged
   (same week key -> existing snapshot found -> returned as-is).
2. The **`TargetCycle`** is reused unchanged (still active).
3. The **`ActiveTargetProfile`** is preserved (not overwritten when cycle
   exists).
4. `shift_records` and `week_records` are **regenerated** — the current
   week now has more closed shifts and fewer projected shifts, and the
   historical window shifts by one day.
5. Live planning surfaces (demand, live schedule plan, distribution
   weights) re-resolve from the new anchor date.

## What Is NOT In This Contract

- **Real live clock behavior** — the Shift screen still shows static
  time; live ticking remains Phase 8 / 10.5 work.
- **Restaurant-configurable week start** — still deferred.
- **Manager forecast adjustments** — not in the first architecture cut.
- **Draft/publish workflow** — no draft state exists.
- **Daypart-level locking** — row-scope semantics remain `7.55k`.

## Relationship to `reseedMockReplayForBusinessDate`

The current `SqliteDatabase.reseedMockReplayForBusinessDate` method
(as of 7.55l.6b2/6b3 + 7.55m.2a) enforces the two-category split:

```text
Replay-regenerated scenario data (cleared and rebuilt):
  shift_records, week_records, baseline_selected_records,
  import_runs, raw_import_records, sync_watermarks,
  target_profile_versions, open_shift_snapshots,
  reservation_book_snapshots

Replay-stable locked artifacts (NOT cleared):
  target_cycles, weekly_plan_snapshots,
  active_target_profiles (when preserved cycle exists),
  benchmark_selection_summaries, restaurant_locations,
  mock_replay_state
```

## Test Coverage

Replay-stable locked artifacts proven stable:
- Same-week replay advance does not rewrite locked WeeklyPlanSnapshot
- Same-week replay advance does not rewrite TargetCycle
- Same-week replay advance does not rewrite ActiveTargetProfile
- Cycle-linked BenchmarkSelectionSummary survives replay advance
- Cross-week replay advance preserves the prior week's locked snapshot
- Cross-week replay advance does not mutate the prior week's snapshot row

Replay-regenerated scenario data proven to regenerate:
- shift_records current-week week id changes after cross-week replay advance
- week_records historical window slides after cross-week replay advance
- Regenerated data is coherent with the new simulated date

Live planning surfaces proven to move:
- DemandForecastContext anchor changes with replay advance
- Live getCurrentWeeklyPlan still resolves after advance
- Baseline candidates reflect new anchor window after advance
- New-week advance generates new snapshot for the new week
