# Codex Prompt Generation Standard

How Codex and Claude operate together in this repo.

## Before You Generate a Prompt (Preflight)

Run this preflight before **every** prompt you generate — not just the
first in a session. Each execution-cycle iteration starts here. This is
the Codex-side equivalent of Claude auto-loading `CLAUDE.md` at session
start: the harness does not enforce it; the workflow does.

Read these before drafting the prompt, in order:

1. `PROJECT_TRACKER.md` — current phase, next slice, sequencing
2. The active slice's planning doc in `docs/phases/**` — exactly one doc
3. `CLAUDE.md` — what Claude already auto-loads; do not duplicate
4. This doc's `Authority Loading Budget` and `Prompt Shape` sections

Conditional, only when the slice domain applies:

5. One contract doc in `docs/contracts/` (timing / architecture /
   cycle-plan ownership). Never more than one.

Then self-audit the generated prompt against this checklist:

- [ ] Message 1 authority list (excluding `PROJECT_TRACKER.md`) ≤ 3 entries
- [ ] At most 1 prior-slice phase doc is loaded
- [ ] No contract + plain-English companion pair loaded together
- [ ] Every file over 500 lines has a method- or region-level qualifier
- [ ] Message 2 has no "Architecture authority" restatement
- [ ] Message 2 has no "Why this slice exists" narrative if the phase
      doc / drift table covers it
- [ ] No "only if touched" files appear in Message 1
- [ ] Message 2 body ≤ 60 lines

If any item fails, fix the prompt before sending. Checklist failure is
a prompt defect, not an optional improvement. Claude will call out
defects in the execution report's Blockers section rather than silently
absorbing them.

## Ownership

### Codex owns

- Roadmap, phase breakdown, prompt scoping
- Acceptance criteria and verification
- Tracker truth (`PROJECT_TRACKER.md`, `DATA_ALIGNMENT_TRACKER.md`, archive trackers)
- Gate truth and release-readiness judgment

### Claude owns

- Code implementation within the given scope
- Localized refactors inside the given scope
- Tests requested by the prompt
- Docs requested by the prompt
- Styling and presentation when explicitly delegated

### Standing rules

- Claude does not update tracker markdown files unless Codex explicitly asks.
- Claude does not broaden scope, start other-phase work, or redefine architecture.
- Codex updates trackers after verification, not before.
- Tracker truth must never be ahead of repo truth.

## Prompt Shape: Two-Message Pattern

### Message 1 - Context

Establishes authority before execution starts.

```text
Repo root: [absolute repo root]

Before you do anything else, read these files and treat them as the authority for this run:

- PROJECT_TRACKER.md
- [specific runtime files]
- [specific docs]
- [specific tests]

Important:
- Follow the current phase and prompt order from PROJECT_TRACKER.md
- This run is [scope description]
- Do not update tracker markdown files in this run
- Do not broaden scope
```

Claude also has `CLAUDE.md` loaded automatically. It carries architecture rules, the core test suite, session context, and the handoff rule. Message 1 does not need to repeat those.

Prefer repo-root-relative paths after the first line instead of repeating the absolute root on every file path.

## Authority Loading Budget

Default to the smallest authority set that can still keep the slice honest.

### Tiered loading

- Always load:
  - `PROJECT_TRACKER.md`
- Add only when the slice actually depends on them:
  - `docs/contracts/phase_7_55_time_boundary_contract.md` for timing / date / business-date work
  - `docs/contracts/phase_7_55_architecture_contract.md` for ownership / truth / downstream-surface work
  - `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md` for cycle / benchmark / plan ownership work
  - `docs/DATA_ALIGNMENT_TRACKER.md` for alignment-heavy or integration-readiness slices
- Do not load `docs/CODEX_PROMPT_GENERATION_STANDARD.md` in execution prompts unless the work is about workflow itself.

### Prior-slice doc rule

Load the most recent prior-slice doc only when it contains a drift table,
schema delta, or live constraint that the current slice explicitly depends
on. Do not load prior-slice docs "for context." If the prior slice is
accepted and tracker truth already captures its outcome, do not load the
phase doc at all.

Maximum prior-slice docs in Message 1: 1. No exceptions.

### Companion-doc rule

When loading a contract doc, do not also load its plain-English companion.
`phase_7_55_architecture_contract.md` and
`phase_7_55_plain_english_architecture.md` are redundant as a pair. Load
one or the other. Prefer the contract doc.

### Optional file rule

- Do not include "only if touched" files in Message 1.
- Do not preload optional tests in Message 1.
- Add optional files to Message 2 only, under `Files to modify`, when they are genuinely in play.
- Message 1 authority list (excluding `PROJECT_TRACKER.md`) must name 3 or fewer files. If you need a 4th, drop the one that is least slice-critical first.

### Narrow file targeting

When possible, point Claude at methods or regions instead of giant files.

Examples:

- `sqlite_database.dart - _seedDemoDataFromReplay() only`
- `variance_report.dart - WTD table + Full Week projection UI only`
- `shift_service.dart - locked/current WTD builders only`

This is preferred to listing a whole large file with no guidance.

For files over 500 lines, method-level or region-level scoping is **required**,
not preferred. Example:

- `shift_service.dart - _buildWeekRecord + closeShift callsite only`
- `sqlite_database.dart - week_records CREATE TABLE + migration pattern only`

Listing a file over 500 lines with no region qualifier is a prompt defect.

### Review finding hygiene

- Do not carry resolved findings forward into a new prompt.
- If a finding is already closed in repo truth, drop it from the next prompt entirely.
- Only keep live findings that still constrain the next slice.

### Message 2 - Implementation Prompt

```text
Goal
[exact goal]

Current issues
[what's broken or missing]

Hard constraints
- Do not change business logic, target math, or labor formulas (unless that is the goal)
- Do not add live POS/labor/reservation transport
- Do not commit unless explicitly asked

Files to modify
[list]

Files to leave alone
[list]

Implementation tasks
1. ...
2. ...

Required tests
[specific test files or "core test suite" per CLAUDE.md]

Acceptance criteria
- [ ] [explicit, checkable item]
- [ ] [explicit, checkable item]

When finished, report using the standard report format below.
```

`Hard constraints` should always appear near the top of Message 2, before file lists or implementation detail.

Keep `Files to leave alone` short. Name only the most tempting or high-risk files that must stay untouched.

### Message 2 body budget

Do not restate content already present in `CLAUDE.md` or in an authority
file loaded in Message 1. Specifically prohibited in Message 2:

- An "Architecture authority" section listing models already documented in
  `CLAUDE.md`'s Architecture Guardrails
- A "Why this slice exists" narrative when the active phase doc or prior-
  slice drift table already covers it
- An "Important" section repeating phase-order, tracker, or scope rules
  already in `CLAUDE.md`

If you feel the temptation to add any of these, check `CLAUDE.md` first.
If it is there, omit it from Message 2.

Target: 60 lines or fewer for a normal implementation slice.

## Phase-Doc Budget

New phase docs should stay compact at the top.

Preferred top structure:

1. Goal
2. Scope
3. Touched readers/writers or touched runtime seams
4. Remaining gaps

Keep that opening section tight. Push design rationale, historical narrative, and long examples into a later `### Details` section so Claude can skip it unless needed.

## Execution Cycle

This is the full cycle - Codex steps marked (C), Claude steps marked (CL).
Every iteration restarts at step 1.

1. **(C) Preflight** — re-read this doc's `Before You Generate a Prompt` section.
2. **(C)** Build plan, break into phases and prompts
3. **(C)** Write two-message execution prompt
4. **(CL)** Read authority files, implement scoped changes
5. **(CL)** Run required tests (`dart analyze` + focused test files or core suite)
6. **(CL)** Self-review the diff before reporting - check for scope creep, stale references, missed acceptance criteria
7. **(CL)** Report back using the standard report format
8. **(C)** Verify against repo (not just Claude's summary)
9. **(C)** Update trackers after verification
10. **(C)** If the slice is accepted and the user has not paused or pivoted, **return to step 1** and generate the next prompt from updated tracker truth.

Codex should not rerun Claude's test suite by default. Prefer Claude's reported
test evidence unless a rerun is needed to complete verification honestly.

Graphify is commit-time only in this workflow. Do not include graphify steps in
execution prompts or execution reports.

If the user pivots into architecture, docs structure, or workflow cleanup:

- stop automatic next-prompt generation
- consolidate the active authority/docs first
- resume prompt sequencing only after the workflow/docs state is clear again

If the slice is **FOLLOW-UP NEEDED** or **REJECT**:

- keep the current slice active
- do not advance tracker phase order
- do not generate the next prompt yet

### When to skip step 5

- Step 5 (review): Skip only for trivial single-file fixes.

## Report Format

Claude should report in this exact structure:

```text
## Execution Report - [Prompt ID]

### Files changed
- [file]: [what changed]

### Files left alone
- [file]: [confirmed untouched]

### Tests run
- [test file]: [pass count] passed
- dart analyze: [result]

### Acceptance criteria
- [ ] or [x] [criterion from the prompt]

### Scope check
- No tracker changes: [yes/no]
- No other-phase work: [yes/no]
- No unauthorized commits: [yes/no]
- Links updated: [yes/no] (only if docs moved or doc links changed)

### Blockers
- [any blockers, or "none"]

### Status
[complete / follow-up needed]
```

## Verification Standard

After Claude reports, Codex verifies by:

- Checking the target files directly (not just Claude's summary)
- Confirming acceptance criteria against actual file content
- Checking that files claimed "left alone" are actually unchanged
- Confirming tests or latest test evidence
- Checking tracker truth still matches repo truth

Codex does not need to rerun tests unless one of these is true:

- the user explicitly asks for a rerun
- Claude's report is missing test evidence
- the reported test scope does not match the prompt's required tests
- repo truth makes the reported result doubtful
- a required suite is still likely to be red after the claimed change

When Codex reruns tests, prefer the smallest targeted rerun needed to resolve
the verification question.

Verdicts: **ACCEPT** / **FOLLOW-UP NEEDED** / **REJECT**

For accepted slices, prefer recording acceptance in the active phase doc or parent plan doc status line when that doc is touched anyway.

### Git verification hygiene

Do not use `git stash` during verification runs. Stashing causes the SDK to
re-inject full-file contents as system reminders for every stashed file,
which can burn thousands of tokens on a single verification check.

Prefer:

- `git diff HEAD -- <file>` to inspect a single file's changes
- `git log -p --follow -n1 -- <file>` for last-commit evidence
- `git status` to confirm untouched files

These cover the read-only checks the verification standard actually needs.

## Planning Standard

Before generating a prompt, Codex should:

1. Establish current phase and prompt from `PROJECT_TRACKER.md`
2. Restate the exact goal
3. Identify in-scope vs out-of-scope
4. Identify risks, dependencies, and verification requirements
5. Break large work into sub-prompts (e.g., `7.52a`, `7.52b`, `7.52c`)

Prompt boundaries should be narrow enough that the expected output is obvious, the file set is understandable, and verification is practical.

When a prompt is getting heavy, cut repetition before cutting guardrails:

1. shorten authority loading
2. switch to repo-root-relative paths
3. collapse repeated issue/context wording
4. group closely related acceptance criteria

Do not cut:

- tracker-first phase control
- hard constraints
- required tests
- explicit acceptance criteria
- repo verification before tracker updates

## Styling Delegation

Claude may have creative freedom for visual/presentation work, but only inside a locked engineering frame:

- Codex locks architecture, logic, and data contracts
- Claude explores the visual solution
- This is not permission to change scope, business rules, data flow, or target math
