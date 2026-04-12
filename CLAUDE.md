# CLAUDE.md

Short repo guidance for Claude Code.

## Read First

Use these as active authority:

- `PROJECT_TRACKER.md`
- `docs/DATA_ALIGNMENT_TRACKER.md`
- any explicitly referenced active phase doc

Treat `docs/archive/**` as historical/reference material unless the prompt explicitly points there.

## Workflow

- Codex plans, verifies, and updates tracker truth.
- Claude implements scoped prompts, runs focused tests, and reports back.
- Do not broaden scope.
- Do not mark phases complete or update tracker truth during implementation runs unless the active handoff loop below says to.

### Implementation Review Loop

When the user pastes an `Execution Report` after a Claude implementation run:

1. Treat it as a review handoff.
2. Do a codebase check unless the user explicitly asks for tests to be rerun.
3. Review the changed files and the nearby runtime seams, not just the files named in the report.
4. If issues are found:
   - return findings first
   - then generate the follow-up prompt for the same slice
5. If no issues are found:
   - update tracker truth:
     - `PROJECT_TRACKER.md`
     - `docs/DATA_ALIGNMENT_TRACKER.md`
     - the active phase implementation doc
   - then generate the next prompt
6. Ignore stale pasted findings when the current code no longer matches them.
7. Keep the loop mechanical:
   - Claude implements and reports
   - Codex reviews
   - if clean, Codex advances trackers and prompts
   - if not clean, Codex supplies the next follow-up prompt

## Architecture Rules

- `LaborModel` is the single formula source.
- `ActiveTargetProfile` is the runtime standards projection of the current `TargetCycle`.
- `TargetCycle` locks standards for 60 days.
- `WeeklyPlanSnapshot` locks the current week for comparison surfaces.
- `MeridianConfig` is a compatibility/default bridge, not runtime authority.
- Do not mix source facts with derived metrics.
- Keep vendor DTOs/adapters out of UI code.

## Current Architecture Direction

### North Star Flow

```text
Canonical Operational Facts
-> 60-Day Benchmark Snapshot
-> TargetCycle
-> ActiveTargetProfile + rolling DemandForecastContext
-> SchedulePlan
-> WeeklyPlanSnapshot
-> Shift
-> Variance
-> History
-> Learn
```

### Ownership

- `TargetCycle` = locked 60-day standards
- `ActiveTargetProfile` = runtime standards projection of `TargetCycle`
- `DemandForecastContext` = rolling forecast demand
- `SchedulePlan` = standards + demand + weekly day-allocation logic
- `WeeklyPlanSnapshot` = locked weekly operating plan

### Locked vs Rolling

- Standards lock on a 60-day `TargetCycle`.
- Demand rolls from:
  - 60-day baseline
  - fixed 3-week recent trend
- No manager forecast adjustments in this architecture cut.
- Weekly plan auto-generates and auto-locks at week start.
- Variance and History compare against the locked `WeeklyPlanSnapshot`.

### Day-Allocation Guardrail

- Start from the 60-day day-of-week baseline share.
- Lightly blend in the fixed 3-week recent trend.
- Keep weekly spread stable; do not let it feel random.
- Reconcile daily rows exactly back to the weekly total.

### UX Guardrails

- No intended manager-facing UX change in Benchmark, Schedule, History, or Learn.
- Keep Benchmark as the target override surface.
- Keep Schedule as the current week's plan surface.
- No draft/publish workflow in the UI.
- Use passive visibility only when important automation needs surfacing.

### Restaurant Logic Authority

- Business week defaults to Monday-Sunday, but restaurant can change it in Settings.
- Business-date authority should come from restaurant settings:
  - timezone
  - opening/closing times
  - rollover behavior

## Testing

- Prefer focused test runs over `flutter test`.
- Run the smallest set of tests that proves the requested seam.
- If the prompt says not to rerun tests, do a codebase check instead.

### Core Test Suite

When the prompt requires a full verification pass, run:

```
flutter test test/schedule_plan_resolver_test.dart test/schedule_plan_read_service_test.dart test/baseline_manager_screen_test.dart test/current_state_alignment_test.dart test/target_consistency_opz_test.dart
```

Always also run `dart analyze` before reporting back.

## Session Context

- Memory index: `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/MEMORY.md`
- Knowledge graph: `graphify-out/graph.json` — entity/relationship data (auto-updated on commits via post-commit hook)
- Graph report: `graphify-out/GRAPH_REPORT.md` — community clusters, key concepts, audit trail

## Post-Phase Compact Rule

After delivering each Execution Report for a completed sub-phase (e.g., 7.55l.7a, 7.55l.7b), run `/compact` to free context for the next prompt. Do not ask permission — just compact after the report is delivered.

## Session Handoff Rule

Before ending any session (or when the user says "wrap up", "done", "that's it", etc.), update `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/session_handoff.md` with:
- **Last Updated**: today's date + what phase/prompt was worked on
- **What Completed This Session**: files changed, key decisions, tests that passed
- **Current Test Count**: total passing tests from the required test runs
- **What Comes Next**: next prompt or pending work
- **Key Files Reference**: any files the next session should read first

Do not ask permission — just update it as part of wrapping up.

## Flavors

- Forge & Flow: `lib/main_forgeflow.dart`
- Barrio: `lib/main_barrio.dart`
