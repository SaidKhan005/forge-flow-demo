# CLAUDE.md

Short repo guidance for Claude Code.

## Read First

Use these as authority:

- `PROJECT_TRACKER.md`
- `docs/DATA_ALIGNMENT_TRACKER.md`
- `docs/contracts/**`
- `docs/KNOWN_FAILING_TESTS.md` — pre-existing failures, not in scope by default
- any active phase doc explicitly referenced in the prompt, usually under
  `docs/phases/**`

Treat `docs/archive/**` as history unless the prompt points there.

## Knowledge Graph Flag

If `graphify-out/needs_update` exists, the doc-side knowledge graph is
behind the committed Markdown. **Run `/graphify --update` as the FIRST
action in the next user turn**, before responding to the user's actual
request. This is a narrow, explicit relaxation of the "do not run
graphify mid-session" rule (Commits & Push) — bounded to the per-commit
incremental refresh only, never to the full `/graphify .` rebuild.

Acknowledge the refresh briefly so the user knows what's happening
(e.g. "Refreshing the doc graph from your last commit...") and can
interrupt if they have a time-critical request. `/graphify --update`
clears the flag automatically on success. Doc-heavy updates can take a
minute or two — do not promise a specific time in the acknowledgement.

The flag file itself lists which `.md` files changed since the last
`--update`, if you need to know what is being re-extracted.

## Use the Graph Before Grepping

A unified `graphify` MCP server is registered in `.mcp.json` and exposes
both code structure (Dart AST over `lib/`) and doc concepts (semantic
extraction over `docs/` + root `.md`). Tools:
`mcp__graphify__get_neighbors`, `__shortest_path`, `__god_nodes`,
`__query_graph`, `__get_node`, `__get_community`, `__graph_stats`.

Prefer graph queries over Glob/Grep when:

- finding callers / dependents of a function or class (`get_neighbors`)
- tracing how two concepts connect (`shortest_path`)
- locating which contract bullet covers a topic (`query_graph` over the
  doc corpus, returns concept nodes with `source_file` + `source_location`)
- orienting in an unfamiliar phase lane before opening files

Fall back to Glob/Grep when the graph returns nothing useful or the
seam is too new to be in the graph yet (e.g. a function added in this
session before any commit).

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
- Do not use TodoWrite. It is not available in this workflow and generates
  system-reminder noise. Track implementation tasks inline from the prompt's
  task list only.

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
- Shift's whole-day view is authoritative; Phase 10.5 adds an additive
  daypart view alongside it without replacing whole-day.

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
- Pre-existing failures listed in `docs/KNOWN_FAILING_TESTS.md` are not in
  scope unless the slice names them. If a test in that list still fails,
  treat it as expected, not a regression.

## Commits & Push

- Commits happen at phase close, not slice close.
- Per-slice no-commit is the default. Wait for explicit user instruction
  before creating a commit.
- Push is automatic on commit. The graphify post-commit hook does two
  things: (1) AST-rebuilds the code graph when code files changed (no
  LLM, includes Dart since graphify 0.4.x), and (2) writes
  `graphify-out/needs_update` when Markdown changed. Doc graph rebuilds
  use LLM subagents and are user-initiated via `/graphify --update` —
  the hook only flags them, never runs them.
- Do not run graphify mid-session.

## Session Handoff

Before ending a session or when the user says to wrap up, update:

- `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/session_handoff.md`

Keep it short:

- what finished
- files changed
- tests run
- what comes next
- current doc locations if they changed

Hard cap: the file must stay under **40 lines total**. "What Completed" =
last accepted slice only. Prior slices are tracker truth in
`PROJECT_TRACKER.md`, not handoff truth — do not duplicate them here.

## Flavors

- Forge & Flow: `lib/main_forgeflow.dart`
- Barrio: `lib/main_barrio.dart`
