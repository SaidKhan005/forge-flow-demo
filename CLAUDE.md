# CLAUDE.md

Short repo guidance for Claude Code.

## Read First

Use these as authority:

- `PROJECT_TRACKER.md`
- `docs/DATA_ALIGNMENT_TRACKER.md`
- `docs/contracts/**`
- any active phase doc explicitly referenced in the prompt, usually under
  `docs/phases/**`

Treat `docs/archive/**` as history unless the prompt points there.

## Docs Layout

- `docs/contracts/` = active architecture rules
- `docs/phases/` = live planning lanes
- `docs/archive/` = completed / historical docs

## Workflow

- Codex plans, reviews, and updates tracker truth.
- Claude implements the scoped prompt, runs focused tests, and reports back.
- Do not broaden scope.
- Do not update trackers during implementation runs unless the handoff
  explicitly asks for it.
- If docs move or docs are touched materially, update touched links and report
  `Links updated: yes/no`.

## Review Loop

When the user pastes an `Execution Report`:

1. Treat it as a review handoff.
2. Review the changed files plus nearby runtime seams.
3. If issues exist, return findings first and keep the same slice active.
4. If clean, Codex advances trackers and the next prompt.
5. Ignore stale pasted findings if the current code no longer matches them.
6. If the user pivots into architecture, workflow, or docs cleanup, stop the
   prompt loop and consolidate instead of auto-advancing execution slices.

## Architecture Guardrails

- `LaborModel` is the formula source.
- `TargetCycle` locks 60-day standards.
- `ActiveTargetProfile` is the runtime projection of the active cycle.
- `DemandForecastContext` is rolling demand, not standards.
- `WeeklyPlanSnapshot` is the locked week-in-force comparison plan.
- Keep source facts, derived metrics, and teaching summaries separate.
- Widgets should not own source-truth or service-period bucketing rules.
- Shift stays whole-day until Phase 10.5.

## Time Guardrails

- Restaurant-local timing rules win.
- Business date is the anchor.
- Week start, business-day rollover, and service periods are restaurant-owned
  settings.
- Closed truth does not get rewritten by later cycles or later weekly plans.

See:

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`

## Testing

- Prefer focused test runs over broad suites.
- Run the smallest set that proves the seam.
- Always run `dart analyze` when the prompt requires verification.
- If the prompt says not to rerun tests, do a code review instead.

## Session Handoff

Before ending a session or when the user says to wrap up, update:

- `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/session_handoff.md`

Keep it short:

- what finished
- files changed
- tests run
- what comes next
- current doc locations if they changed

## Flavors

- Forge & Flow: `lib/main_forgeflow.dart`
- Barrio: `lib/main_barrio.dart`
