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
- Do not mark phases complete or update tracker truth unless explicitly asked.

## Architecture Rules

- `LaborModel` is the single formula source.
- `ActiveTargetProfile` owns current standards.
- Historical targets are locked at shift close through `TargetSnapshot`.
- `MeridianConfig` is a compatibility/default bridge, not runtime authority.
- Do not mix source facts with derived metrics.
- Keep vendor DTOs/adapters out of UI code.

## Current Architecture Direction

- `DemandForecastContext` = demand
- `ActiveTargetProfile` = standards
- `SchedulePlan` = demand + standards + distribution

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
