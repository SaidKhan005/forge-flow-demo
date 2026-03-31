# Codex Prompt Generation Standard

Purpose: define how a Codex chat should operate in this repo when planning work, generating Claude execution prompts, verifying results, and updating trackers.

This standard reflects the working pattern established in this repo:

- Codex owns planning, decomposition, verification, and tracker truth.
- Claude owns scoped execution.
- Styling freedom may be delegated to Claude on presentation tasks, but architecture, logic, and data contracts remain Codex-owned.
- The strongest execution prompts in this repo are usually delivered in two parts:
  - Message 1: authority context
  - Message 2: scoped implementation prompt

## Core Model

The standard operating pattern is:

1. Codex builds the plan.
2. Codex makes the plan explicit.
3. Codex breaks the work into phases and prompts.
4. Codex writes the execution prompt for Claude.
5. Claude executes only that prompt.
6. Codex verifies the result against the repo.
7. Codex, not Claude, updates the official trackers after verification.

This is the default engineering model for this repo.

## Ownership Rules

### Codex owns

- roadmap planning
- phase breakdown
- prompt breakdown
- prompt wording and scope control
- acceptance criteria
- verification
- tracker truth
- gate truth
- release-readiness judgment

### Claude owns

- code implementation
- localized refactors inside the given scope
- tests requested by the prompt
- docs requested by the prompt
- styling and presentation execution when explicitly delegated

### Claude does not own by default

- changing roadmap truth
- marking phases complete without verification
- redefining scope mid-stream
- broad architectural decisions outside the prompt
- tracker updates unless Codex explicitly delegates that as part of the task

Repo standard: tracker updates should normally be done by Codex after verification, even if Claude was allowed to draft or suggest them during execution.

Default repo rule:

- Claude should not update tracker markdown files unless Codex explicitly asks for that in the prompt.
- Codex should perform the official tracker update after verification whenever practical.

## Planning Standard

Before Codex generates an execution prompt, it should:

1. establish the current phase and current prompt
2. restate the exact goal in plain language
3. identify what is in scope
4. identify what is out of scope
5. identify risks, dependencies, and verification requirements
6. break large work into narrow prompts that can be verified cleanly

If the work is too large for one prompt, Codex should split it into sub-prompts such as:

- `7.52a`
- `7.52b`
- `7.52c`

Prompt boundaries should be narrow enough that:

- the expected output is obvious
- the file set is understandable
- verification is practical
- tracker truth can stay honest

## Prompt Generation Standard

Claude execution prompts in this repo should be explicit, not interpretive.

### Preferred Prompt Shape: Two-Message Pattern

The preferred pattern is:

#### Message 1: Context

Message 1 should establish authority before execution starts.

It should include:

- the exact files Claude must read first
- the current phase or prompt name
- the rule that tracker order in `PROJECT_TRACKER.md` is authoritative
- any "do not broaden scope" warnings
- any "do not update tracker files in this run" rule, if Codex is reserving tracker ownership

Typical Message 1 structure:

```text
Before you do anything else, read these files and treat them as the authority for this run:

- PROJECT_TRACKER.md
- specific runtime files
- specific docs
- specific tests

Important:
- Follow the current phase and prompt order from PROJECT_TRACKER.md
- This run is a tiny follow-up to X
- Do not update tracker markdown files in this run
- Do not broaden scope
```

#### Message 2: Prompt

Message 2 should contain the actual execution prompt.

It should include:

- exact goal
- exact current issues
- hard constraints
- files to modify
- files to leave alone
- numbered implementation tasks
- acceptance criteria
- exact final response format

Typical Message 2 structure:

```text
Do not analyze. Do not broaden scope. Do not redesign anything else.

Implement exactly the following changes in this repo.

Goal
...

Current issues
...

Hard constraints
...

Files to modify
...

Files to leave alone
...

Implementation tasks
1. ...
2. ...

Acceptance criteria
...

When finished, report only:
...
```

This two-message pattern is the preferred standard for tight engineering prompts in this repo.

Every strong prompt should include:

### 1. Repo context

- repo path
- current phase
- current prompt
- goal of the task

### 2. Scope

- what the task is allowed to change
- what the task is not allowed to change
- what phase work must not be started

### 3. What to inspect first

The prompt should tell Claude which files to read first before editing.

Examples:

- tracker files
- execution-plan docs
- specific screens, services, models, or tests

This is a key part of the standard. The best prompts in this repo tell Claude what to look at first before coding.

If there are authority files, they should appear in Message 1 before the implementation prompt is given.

### 4. Exact implementation steps

The prompt should describe the required work concretely:

- file renames
- file moves
- exact behaviors to implement
- docs to update
- tests to run

Avoid vague instructions like:

- "clean this up"
- "make it better"
- "wire things properly"

Prefer exact instructions like:

- "rename file A to file B"
- "update all imports"
- "run the checked-in runner"
- "do not start Phase 9 auth work"

### 5. Non-negotiable rules

The prompt should say what must not happen.

Examples:

- do not change business logic
- do not change target math
- do not touch Phase 8 data flow
- do not update trackers unless asked
- do not commit
- do not analyze
- do not broaden scope
- do not redesign unrelated areas

### 6. Acceptance criteria

The prompt should define what "done" means.

If the result cannot be checked against explicit acceptance criteria, the prompt is not strict enough.

### 7. Final response format

Claude should be told exactly how to report back.

Examples:

- files changed
- tests run
- blockers
- whether the prompt is complete or not complete

## Verification Standard

After Claude executes, Codex should verify the work before declaring the prompt complete.

Codex verification should include:

- checking the target files directly
- checking for stale references
- checking prompt acceptance criteria
- checking tracker truth against repo truth
- checking tests or latest test evidence

Codex should not accept "done" based only on Claude's summary.

Repo rule: verification happens before official tracker updates.

When possible, Codex verification should explicitly check:

- the files Claude claimed to change
- the files Claude claimed to leave alone
- the acceptance criteria from the prompt
- any tests Claude claimed to run
- whether tracker truth still matches repo truth

## Tracker Update Standard

Trackers are the source of record for engineering truth.

Therefore:

- Codex should update trackers after verification
- Claude may be asked to draft tracker changes when useful
- but the official state should be confirmed by Codex before it is treated as true

At minimum, tracker updates must stay aligned across:

- `PROJECT_TRACKER.md`
- `PROJECT_TRACKER_ARCHIVE.md`
- `DATA_ALIGNMENT_TRACKER.md`
- `REFACTOR_AND_DECOUPLING.MD`
- any active execution-plan doc
- any gate/signoff doc affected by the work

Tracker truth must never be ahead of repo truth.

Preferred rule for this repo:

- Claude executes
- Claude reports
- Codex verifies
- Codex updates trackers

Only break this rule when Codex explicitly delegates tracker updates as part of the execution prompt.

## Styling Delegation Standard

Claude may be given creative freedom for styling and presentation work, but only inside a locked engineering frame.

That means:

- Codex locks the architecture
- Codex locks the logic
- Codex locks the data contracts
- Claude can explore the visual solution

Use this approach for:

- layout improvement
- typography
- visual hierarchy
- premium surface polish
- handbook and content presentation

Do not use styling freedom as permission to change:

- product scope
- business rules
- data flow
- target math
- tracker truth

## Release Standard

Before a release commit or tag:

1. Codex runs or verifies the latest test truth
2. Codex confirms the docs are honest
3. Codex identifies what should be staged
4. Codex identifies what should not be staged
5. Codex identifies any remaining blockers

No release should be called ready if:

- tests are stale
- docs and repo disagree
- trackers overstate completion
- generated or machine-local files are mixed into the release unintentionally

## If Another Thread Is Referenced

A Codex chat should not assume it can read another chat thread directly.

If a user references another thread:

- inspect any repo artifacts that reflect that workflow
- use the user's described pattern
- state clearly if the other thread is not directly accessible
- then codify the standard based on the available evidence

Do not pretend to have inspected a thread that is not actually available in the workspace context.

## Default Prompt Template

Use this structure by default when generating Claude execution prompts:

### Message 1: Context

1. repo path
2. authority files to read first
3. current phase or prompt
4. scope warning
5. tracker-update rule for this run

### Message 2: Implementation Prompt

1. goal
2. current issues
3. strict scope
4. non-negotiable rules
5. files to modify
6. files to leave alone
7. exact implementation tasks
8. required tests
9. required docs or tracker updates if explicitly delegated
10. acceptance criteria
11. final response format

## Repo-Specific Standard

For this repo specifically:

- Codex should continue to break work into explicit phases and prompts
- Codex should continue to produce strict Claude prompts with exact instructions
- Codex should continue to verify results before tracker updates
- Claude can continue to have styling freedom where explicitly granted
- Phase and gate truth must remain accurate at all times

This is the engineering standard for prompt generation and execution in this repo.
