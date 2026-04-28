# Codex Prompt Generation Standard

How Codex and Claude run the execution loop in this repo.

For a compact copy/paste generator built from this standard, use
`docs/CODEX_LEAN_PROMPT_GENERATOR.md`. This file remains the authority;
the lean generator is the quick-start tool.

## Operating Loop

Every prompt cycle follows this order:

1. Codex reads tracker truth and only the active doc slice it needs.
2. Codex generates a three-block prompt.
3. Claude implements only the scoped slice.
4. Claude reports files, tests, acceptance, scope, and blockers.
5. Codex verifies against repo truth, not just the report.
6. Codex updates trackers only after verification.
7. Codex generates the next prompt unless the user pauses or pivots.

If the user pivots into architecture, workflow, or docs cleanup, pause prompt
sequencing until that cleanup is handled.

## Lean Authority Law

`PROJECT_TRACKER.md` and `CLAUDE.md` must stay lean.

- `PROJECT_TRACKER.md` is a routing map: current phase, next slice, fetch map,
  hard gates, and pointers to active docs. It is not the full plan.
- `CLAUDE.md` is a guardrail map: durable repo rules and non-negotiables. It
  is not the place for per-slice execution detail.
- Per-slice detail, rationale, backlogs, acceptance history, and heavyweight
  context live in linked phase docs under `docs/phases/**`.
- Before generating a prompt, refactor context mentally into:
  tracker/CLAUDE = lean pointers and laws; linked phase docs = weight-bearing
  slice context.
- Do not paste phase-doc weight back into `PROJECT_TRACKER.md` or `CLAUDE.md`
  unless it is a durable routing rule, durable guardrail, or current hard gate.
- Prompt cycles may create temporary checkpoint/backlog docs for Claude's
  mega-prompt execution. Those docs carry transient weight until the phase
  slice accepts, then tracker truth is updated leanly.

## Preflight

Before every prompt, check:

1. `PROJECT_TRACKER.md` current / next slice lines.
2. The relevant section of one active planning doc under `docs/phases/**`.
3. `CLAUDE.md` only when guardrails may have changed.
4. This standard only when prompt shape is in question.

Add only when needed:

- One contract doc from `docs/contracts/` for contract-bound seams.
- `docs/DATA_ALIGNMENT_TRACKER.md` for alignment-heavy slices.
- `docs/KNOWN_FAILING_TESTS.md` for full or near-full test runs.

Read full files only for a phase primer, a new unfamiliar lane, or a disputed
authority question. Do not load archived docs unless the prompt explicitly
targets archive history.

## Phase Primer vs Slice Prompt

Use a long context block only when a phase opens or the architecture changes.
After that, generate delta prompts:

- `phase primer`: allowed to summarize goals, gates, and core docs.
- `normal slice`: human context block plus exact authority/files/tasks/tests.
- `review-fix`: finding, exact files, exact tests, no phase recap.

## Prompt Rules

Before sending the prompt:

- Omit `Slice type` for normal implementation prompts.
- Include `Slice type` only for `closeout-verification`,
  `closeout-with-blockers`, or `audit`.
- Visible authority list is 3 entries max and excludes stable docs by habit.
- `Plain English:` lives in Block 1 for the user, not in Claude's pasted
  prompt.
- Do not add a separate `Goal` section.
- Do not include optional / "only if touched" files.
- Files over 500 lines have method or region qualifiers.
- Blocks 2 and 3 together target 40 lines for review-fixes, 50 for normal
  slices.
- Deliver Block 1 separately as normal Markdown, then deliver Blocks 2 and 3
  together in one fenced `text` block for one-click Claude copy/paste.
- Never put Block 1 in Claude's paste block, and never split Blocks 2 and 3
  into separate paste blocks.
- Block 1 must include `Human prerequisites:` before the paste block. If the
  slice may require keys, accounts, cloud projects, CLI installs, dashboard
  setup, tokens, billing setup, or live-service access, name the exact human
  action needed and whether it blocks this slice or the next one. If none are
  needed, say `None for this slice`.
- Inside `Human prerequisites:`, also include `Decision needed for this slice:`.
  This names what the user must decide now based on documented constraints,
  gates, guardrails, blockers, live-service availability, or architecture
  trade-offs. If no decision is needed, say `No decision needed for this
  slice`. Do not let Claude implicitly decide product, infrastructure, cost,
  security, or sequencing trade-offs.
- Do not restate architecture already in `CLAUDE.md`.
- Do not move per-slice detail into `PROJECT_TRACKER.md` or `CLAUDE.md`;
  reference the active phase doc instead.
- Contract-bound slices include `Routing rules to mirror`: 2 or 3 rules max.
- Move slices include Codex's import audit and analyzer-forced follow-ups.
- Use `Files to leave alone` only for real carve-outs.
- Required tests and acceptance criteria are explicit.
- Always tell Claude: no tracker updates, no commits.

Rule failure is a prompt defect. Fix it before sending.

## Ownership

Codex owns:

- Roadmap, phase breakdown, prompt scope
- Acceptance criteria and verification
- Tracker truth
- Gate truth and release-readiness judgment

Claude owns:

- Implementation inside the scoped prompt
- Localized refactors inside scope
- Requested tests and docs
- Execution report

Standing rules:

- Claude does not update trackers unless explicitly asked.
- Claude does not broaden scope or redefine architecture.
- Codex updates trackers after verification, not before.
- Tracker truth must never be ahead of repo truth.

## Slice Prompt Blocks

Codex emits three blocks:

- **Block 1 — Human Context:** plain-English summary, important context, and
  current issue. Routing rules may appear here when useful for the user. The
  user reads this and does not paste it to Claude.
- **Block 2 - Tech Context:** authority files and hard constraints.
- **Block 3 - Tasks:** files, implementation tasks, tests, acceptance.

Block 1 always includes a `Human prerequisites:` subsection so the user knows
whether keys, accounts, cloud setup, CLI installs, dashboard setup, tokens, or
live-service access are needed before the current or next slice, and what
decision the user must make now based on documented constraints, gates,
guardrails, blockers, live-service availability, or architecture trade-offs.

Blocks 2 and 3 are the full Claude contract. Do not rely on Block 1 for
instructions Claude must follow.

Deliver this as two visual parts:

1. Block 1 appears as normal Markdown for the user. It starts with
   `Plain English:` rather than a prompt-id line.
2. Blocks 2 and 3 appear together inside one fenced `text` block. This is the
   single paste payload for Claude.

Use this shape:

## Block 1 — Human Context

Plain English: [1 to 3 concise sentences; include an example when helpful]

Important context:
- [only what helps the user understand the slice]

Current issue:
- [what is missing, stale, or broken]

Human prerequisites:
- Setup/access needed: [None for this slice, or exact
  keys/accounts/cloud/CLI/dashboard setup the human must handle; say whether it
  blocks this slice or a later slice]
- Decision needed for this slice: [No decision needed for this slice, or the
  exact user decision required by documented constraints, gates, guardrails,
  blockers, live-service availability, architecture, cost, security, or
  sequencing trade-offs; say whether it blocks this slice or a later slice]

Routing rules to mirror:
- [only when contract-bound and useful for the user; 2 or 3 rules max]

```text
## Block 2 - Tech Context

Authority files for this run:

- [specific runtime files / tests]
- [active phase doc section, only when needed]

Hard constraints
- Do not change business logic, target math, or labor formulas unless that is the goal.
- Do not add live vendor transport unless that is the goal.
- Do not update trackers.
- Do not commit unless explicitly asked.
- Run only required tests; no courtesy CLI smoke runs unless explicitly scoped.

## Block 3 - Tasks

Files to modify
- [file or file - region/method]

[Optional] Files to leave alone
- [omit unless there is a specific carve-out]

Implementation tasks
1. ...
2. ...

Required tests
- dart analyze
- [focused test files]

Acceptance criteria
- [ ] [checkable criterion]

When finished, report using the standard report format.
```

Use repo-root-relative paths. Add repo root only for external handoffs.

## Visible Authority

- Codex always reads `PROJECT_TRACKER.md`; list it in Claude prompts only
  when the slice changes tracker truth or needs a live gate checked.
- Include an active phase doc/section only when the slice needs it.
- Include at most one contract doc.
- Do not load a contract doc and its plain-English companion together.
- Do not load prior-slice docs unless the current slice depends on a live
  drift table, schema delta, or constraint from that doc.
- Do not put this standard in execution prompts unless the work is workflow.

Use graphify only for unfamiliar architecture/concept orientation. For known
symbols, imports, callsites, and filenames, use `rg`; do not add graph
pre-search hints.

## File Scoping

Use narrow file targets:

- Good: `sqlite_database_seed.dart - _seedDemoDataFromReplay() only`
- Good: `shift_service.dart - getFullWeekShifts + helper only`
- Bad: `shift_service.dart` when the file is over 500 lines

For any file over 500 lines, method or region scoping is required.

## Move Slices

Structural file-move slices are mechanical: move files, rewire imports,
no behavior change. Codex pre-computes the import audit and passes it through.
Claude does not re-grep imports unless the audit is missing or analyzer output
proves it stale.

For each moved file, list same-directory relative imports and classify each
target as `MOVES` or `STAYS`, plus the implied rewrite:

```text
Implementation tasks
1. Move <file> to <new dir>. Internal imports:
   - 'sibling_a.dart'  (MOVES with this slice): keep same-dir
   - 'sibling_b.dart'  (STAYS in <old dir>):    rewrite to '../<old dir>/sibling_b.dart'
   - '../foo/bar.dart' (cross-package, unchanged)
```

When the moved target is imported by a file that otherwise stays out of
scope, name the exact import-declaration follow-up:

```text
Implementation tasks
3. Update lib/data/target_cycle_service.dart (>500-line stayer):
   - line 55: 'baseline_manager_service.dart'             -> '../services/baseline_manager_service.dart'
   - line 56: 'baseline_selection_analytics_service.dart' -> '../services/baseline_selection_analytics_service.dart'
   - body otherwise left alone
```

Stale doc-comment path strings in leave-alone files (e.g. comments
pointing at a moved file's old path) are in scope for cleanup as long as
no behavior or assertion semantics change. The slice acceptance criteria
should call this out explicitly when known stale comments exist.

## Routing Rules

Include `Routing rules to mirror` when the slice touches:

- `TargetCycle`, `WeeklyPlanSnapshot`, or `BenchmarkSelectionSummary`
- Plan / benchmark / labor ownership
- Replay-stable artifacts
- Source facts vs derived signals
- Business date, week start, or service-period resolution

Skip it for doc-only, pure UI, or read-only verification slices unless the
verification itself is contract-bound.

## Slice Types

`implementation`

- Default. Omit the `Slice type` block. Requires focused tests.

`closeout-verification`

- Read-only verification. May update doc status if requested. Does not fix
  blockers.

`closeout-with-blockers`

- Verification plus bounded fixes. Prompt names eligible files and max blast
  radius.

`audit`

- Drift check only. Produces findings or a follow-up plan. No implementation
  changes unless explicitly scoped.

## Sub-Slices

For parent slices split into `a`, `b`, `c`:

- Track acceptance at the sub-slice level.
- Do not mark the parent slice complete until the final sub-slice satisfies
  the parent acceptance criteria.
- Generate the next prompt from the latest accepted sub-slice, not from the
  original parent description.
- Keep parent gates intact. Example: `7.57.2` cannot open until all remaining
  `7.57.1*` extraction sub-slices accept.

## Review Handoff

When Claude reports:

1. Inspect the changed files directly.
2. Confirm claimed "left alone" files are actually untouched.
3. Check acceptance criteria against repo content.
4. Confirm test evidence.
5. Run a small targeted rerun only when needed.
6. Return findings if there are issues.
7. If clean, update trackers and generate the next prompt.

Codex verifies repo truth, not report wording.

Do not use `git stash` during verification. Prefer:

- `git diff HEAD -- <file>`
- `git status --short`
- `rg` for imports/callsites
- targeted test reruns when evidence is incomplete

Verdicts:

- `ACCEPT`
- `FOLLOW-UP NEEDED`
- `REJECT`

## Test Reruns

Codex does not rerun Claude's tests by default. Rerun only when:

- The user asks.
- The report is missing test evidence.
- The reported tests do not match the prompt.
- The diff makes the report doubtful.
- A known risky seam needs local confirmation.

Prefer the smallest targeted rerun.

## In-Session Hygiene

- For known large files, read by named region or offset/limit instead of full
  file.
- When adding to an existing test file, grep for the insertion anchor first
  and offset/limit-read a window (~50 lines) around it. Full reads of
  500+ line test files are the single most expensive avoidable cost.
- Tail test output aggressively; the final pass/fail lines are usually enough.
- Batch independent reads / greps in one tool call.
- Skip courtesy CLI smokes when analyze and focused tests cover the contract.
- Keep execution reports compact. Add reviewer notes only for real surprises.
- Do not call or acknowledge TodoWrite. The prompt's task list is the source
  of truth.

## Tracker Updates

After accepting a slice:

- Update `PROJECT_TRACKER.md` current / next / hard-gate wording.
- Update `docs/DATA_ALIGNMENT_TRACKER.md` only for alignment-heavy slices.
- Do not move tracker truth ahead of repo truth.
- Do not advance the parent phase if only a sub-slice accepted.

## Commit Cadence

- Commits happen at phase close unless the user says otherwise.
- Execution prompts should say `Do not commit unless explicitly asked`.
- Do not include commit, push, or graphify steps in execution prompts.
- If Markdown changed and `graphify-out/needs_update` appears later,
  `CLAUDE.md` owns that flag workflow.

## Report Format

Claude should report:

```text
## Execution Report - [Prompt ID]

### Files changed
- [file]: [what changed]

### Files left alone
- [optional; only if a prompt listed carve-outs or something tempting was verified]

### Tests run
- dart analyze: [result]
- [test file]: [pass count] passed

### Acceptance criteria
- [x] [criterion]

### Scope check
- No tracker changes: [yes/no]
- No other-phase work: [yes/no]
- No unauthorized commits: [yes/no]
- Links updated: [yes/no, only if docs changed]

### Blockers
- [none or blocker]

### Status
[complete / follow-up needed]
```

Do not include `Out-of-scope touched: None` or similar boilerplate. Report
out-of-scope touches only when there was something to explain.

### Report Compression Rules

The fields above are the contract. Past that, default to compression:

- **Bare filenames over decorative markdown links.** `tool/x/y.dart: added
  Z` is preferred over a `[y.dart](path:line)` link unless the user is
  reviewing in a renderer that needs the link.
- **No "Notes for reviewer" section** unless something genuinely
  surprised you (a workaround, an unexpected blocker, a non-obvious
  trade-off the diff alone does not explain).
- **No "Out of scope (not touched)" list** when the prompt's hard
  constraints already covered it. The `Scope check` yes/no flags above
  are sufficient.
- **No restating slice ID inside every section.** Once in the header
  is enough; comments, test group names, and route notes can use it
  but the report itself does not need to repeat it per bullet.
- **No restating prompt language.** "I did not call live providers, I
  did not change SQLite" wastes tokens; the constraint list above
  already promised that. Flag exceptions, not compliance.

The floor: tests run, acceptance ticked, files listed with a brief
description, links to changed files (or bare paths). Cutting below this
breaks the tracker advance loop or makes review hard.

## Do Not Cut

When making prompts shorter, never cut:

- Tracker-first phase control
- Hard constraints
- Required tests
- Explicit acceptance criteria
- Repo verification before tracker updates
- No-commit / no-tracker-change instructions for Claude
