# Codex Prompt Generation Standard

How Codex and Claude operate together in this repo.

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

### Message 1 — Context

Establishes authority before execution starts.

```text
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

Claude also has `CLAUDE.md` loaded automatically — it carries architecture rules, the core test suite, session context, and the handoff rule. Message 1 does not need to repeat those.

### Message 2 — Implementation Prompt

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

`Hard constraints` should always appear near the top of Message 2, before file
lists or implementation detail.

## Execution Cycle

This is the full cycle — Codex steps marked (C), Claude steps marked (CL).

1. **(C)** Build plan, break into phases and prompts
2. **(C)** Write two-message execution prompt
3. **(CL)** Read authority files, implement scoped changes
4. **(CL)** Run required tests (`dart analyze` + focused test files or core suite)
5. **(CL)** Self-review the diff before reporting — check for scope creep, stale references, missed acceptance criteria
6. **(CL)** If structural code changes were made, run `/graphify . --update` to keep the knowledge graph current
7. **(CL)** Report back using the standard report format
8. **(C)** Verify against repo (not just Claude's summary)
9. **(C)** Update trackers after verification

If the user pivots into architecture, docs structure, or workflow cleanup:

- stop automatic next-prompt generation
- consolidate the active authority/docs first
- resume prompt sequencing only after the workflow/docs state is clear again

### When to skip steps 5–6

- Step 5 (review): Skip only for trivial single-file fixes.
- Step 6 (graphify): Skip for test-only changes or doc-only changes. The post-commit hook will catch it on commit regardless.

## Report Format

Claude should report in this exact structure:

```text
## Execution Report — [Prompt ID]

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

Verdicts: **ACCEPT** / **FOLLOW-UP NEEDED** / **REJECT**

For accepted slices, prefer recording acceptance in the active phase doc or
parent plan doc status line when that doc is touched anyway.

## Planning Standard

Before generating a prompt, Codex should:

1. Establish current phase and prompt from `PROJECT_TRACKER.md`
2. Restate the exact goal
3. Identify in-scope vs out-of-scope
4. Identify risks, dependencies, and verification requirements
5. Break large work into sub-prompts (e.g., `7.52a`, `7.52b`, `7.52c`)

Prompt boundaries should be narrow enough that the expected output is obvious, the file set is understandable, and verification is practical.

## Styling Delegation

Claude may have creative freedom for visual/presentation work, but only inside a locked engineering frame:

- Codex locks architecture, logic, and data contracts
- Claude explores the visual solution
- This is not permission to change scope, business rules, data flow, or target math
