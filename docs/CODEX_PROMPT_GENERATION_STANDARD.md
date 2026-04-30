# Codex Prompt Generation Standard

How Codex and Claude run the execution loop in this repo. One source.

## Operating Loop

End of phase → post-commit hook refreshes graph → **Claude plans**
the next phase's slices off the fresh graph → **Codex reviews** the
slice plan, drafts per-slice execution prompts, advances trackers →
parallel worktrees implement → ship via `ship-slice` prompt → audit
+ next-batch recommendation (`docs/PARALLEL_LANE_AUDIT_AND_RECOMMENDATION.md`)
→ loop.

If the user pivots into architecture, workflow, or docs cleanup,
pause prompt sequencing until that cleanup lands.

## Ownership

Codex owns:

- Slice plan **review**, per-slice execution prompts.
- Acceptance verdicts and verification.
- Tracker truth, phase-doc hygiene, contract edits.
- Gate truth and release-readiness judgment.

Claude owns:

- Phase-level slice planning off the refreshed knowledge graph
  (using `graphify` MCP: `query_graph`, `shortest_path`).
- Implementation inside a scoped slice prompt (per worktree).
- Requested tests and docs; localized refactors inside scope.
- Execution report; ship-slice mechanics.

Standing rules:

- Claude does not update trackers unless explicitly asked.
- Claude does not broaden scope or redefine architecture.
- Codex updates trackers only after repo truth is verified.
- Tracker truth must never be ahead of repo truth.

## Lean Authority Law

`PROJECT_TRACKER.md` and `CLAUDE.md` stay lean.

- `PROJECT_TRACKER.md`: routing map (current phase, next slice,
  fetch map, hard gates, pointers). Not the full plan.
- `CLAUDE.md`: durable repo rules and non-negotiables. Not per-slice
  detail.
- Per-slice detail lives in `docs/phases/**` or temporary checkpoint
  docs.
- Refactor context mentally before generating: tracker/CLAUDE = lean
  pointers and laws; phase docs = weight-bearing slice context.
- Do not paste phase-doc weight back into trackers or CLAUDE.md
  unless it is a durable routing rule, guardrail, or hard gate.

## Minimal Inputs (when generating a slice prompt)

Provide only these:

- `Current request:` what the user wants next.
- `Review findings:` paste any findings if present.
- `Latest execution report:` paste only if this follows a Claude run.
- `Known live intent:` `none`, `preflight only`, or `live smoke/apply`.

If any input is missing, inspect repo truth rather than asking. Ask
the user only when a live credential, account, billing action, or
product/security decision is actually required.

## Generator Prompt (paste into Codex)

````text
You are generating the next execution prompt for this repo.

First read:
- PROJECT_TRACKER.md sections: Active Authority, How To Fetch
  Context, Prompt Fetch Map, Now, Current Slice Queue.
- The active phase doc(s) named by PROJECT_TRACKER.md.
- docs/CODEX_PROMPT_GENERATION_STANDARD.md only if prompt shape is
  in doubt.

Then in order:
1. Recontextualize current phase + next slice from tracker truth.
2. Verify any pasted review findings against current repo before
   treating them as live. Mark stale findings as already fixed.
3. Preserve Lean Authority Law: trackers + CLAUDE.md stay lean;
   per-slice weight goes in phase docs.
4. Identify slice type: implementation, review-fix, audit,
   closeout-verification, closeout-with-blockers, live preflight,
   or live smoke/apply.
5. Identify human prerequisites: keys, accounts, CLI installs,
   cloud projects, dashboard work, billing, tokens, deployed URLs,
   smoke passwords, live-service access. Say whether each blocks
   this slice or a later slice.
6. Identify decisions the user must make now: product UX, security
   posture, cost, infrastructure, sequencing, live fallback, or
   documented gate choice. If none, say so.
7. Produce Block 1 separately as human-readable Markdown.
8. Produce Blocks 2 + 3 together in one fenced text block for
   one-click Claude paste.

Prompt rules:
- Visible authority list: 3 entries max.
- Repo-root-relative paths.
- Files over 500 lines: method/region qualifier required.
- Include exact `Files to modify` and `Files to leave alone` only
  when needed.
- Concrete tests + acceptance criteria.
- Always tell Claude: no tracker updates, no commits unless asked.
- Live work: name-only preflight first; BLOCKED report if missing.
- Tracker/doc hygiene: no logic/meaning changes unless scoped.
- Do not include Block 1 inside the Claude paste block.
- Block 1 must include a `Lane:` line (slice id, worktree path,
  branch, base sha — or "to be created" if the lane has not been
  cut yet).

Output exactly:

## Block 1 - Human Context

Plain English: ...

Lane: <slice-id> — worktree <.claude/worktrees/<lane-name>> on
branch <branch-name> off master @ <short-sha>.

Important context:
- ...

Current issue:
- ...

Human prerequisites:
- Setup/access needed: ...
- Decision needed for this slice: ...

```text
## Block 2 - Tech Context

Authority files for this run:
- ...

Hard constraints
- ...
- Do not update trackers.
- Do not commit unless explicitly asked.

## Block 3 - Tasks

Files to modify
- ...

Implementation tasks
1. ...

Required tests
- dart analyze
- ...

[For UX-exposing slices] Operator walkthrough (kDemoMode = true)
1. ...

Acceptance criteria
- [ ] ...
- [ ] [UX] Operator walkthrough completes end-to-end in demo mode

When finished, report using the standard report format.
```
````

## Parallel Lanes (Worktrees)

Codex runs one lane on `master` (planning review, prompts, tracker
truth, acceptance verdicts). Claude runs N parallel implementation
lanes in `.claude/worktrees/<lane-name>`. Multiple phases — not just
slices within a phase — may be active simultaneously.

**File ownership.** Each active lane has exclusive checkout of its
`Files to modify` for the slice's lifetime. Before emitting a
parallel prompt, Codex verifies no other active lane's `Files to
modify` overlaps. Overlap = sequence, not parallelize.

**Shared seams.** Files written by multiple slices across lanes
(e.g., screen registries, gateway files). Phase doc lists **Shared
seams across lanes** and the per-file rule. Default: serialize
lanes that touch a shared seam; first lane lands the seam
extension, later lanes rebase.

**Walkthrough evidence per lane.** UX-exposing slices commit
walkthrough evidence inside their worktree as
`docs/_walkthroughs/<slice-id>.md` or attach to the execution
report. Codex inspects worktree evidence, not master.

**Merge sequencing.** Codex declares merge order at acceptance.
First lane ships immediately. Later lanes rebase onto first lane's
merge, re-run analyze + scoped tests, then merge.

**Audit + recommendation between batches.** After a batch settles,
Claude on master runs `docs/PARALLEL_LANE_AUDIT_AND_RECOMMENDATION.md`
to confirm clean merges and propose the next parallel batch by
file-touch disjointness.

**Main-chat read-only.** When parallel worktrees are running, main
Claude chat on master is read-only across all of them — inspects
worktrees, does not edit. Tracker / memory / coordination doc
updates on master are still allowed.

## Frontend Exposure & UX Acceptance Gate

Every phase that ships operator- or admin-visible capability owes a
`Frontend Exposure` section in its phase doc. The section names:

- Operator-facing surfaces (file paths or screen names).
- Admin (`11A`) surfaces (or "None / covered elsewhere").
- The UX sub-slice family naming (`<phase>.UX.<n>` for backend-heavy
  phases; or "owned inline by existing slices" for UX-led phases).
- A demo-mode click path that proves the surface works.

Backend-heavy phases (`9`, `7.58`, `10a`, `7.61`, `8`, `8R`, `8.5`,
`9.8`, `10b`, `11b.2`) ship a `<phase>.UX.<n>` family interleaved
with backend slices. UX-led phases (`10.5`, `9.5`, `9.75`, `11A`,
`11b`, `12`) own UX inside existing sub-slice sequence.

UX-exposing slices add an `Operator walkthrough` block in Block 3
plus a walkthrough acceptance criterion. Codex returns
`FOLLOW-UP NEEDED` if walkthrough evidence is absent at review.

A phase plan that opens without `Frontend Exposure` is a prompt
defect — fix the doc before the first slice ships.

## Slice Types

- `implementation` — default. Omit `Slice type` block. Requires
  focused tests.
- `closeout-verification` — read-only verification; may update doc
  status if requested. Does not fix blockers.
- `closeout-with-blockers` — verification plus bounded fixes. Prompt
  names eligible files and max blast radius.
- `audit` — drift check only. Produces findings or follow-up plan.

For sub-slices (`a`, `b`, `c`):

- Track acceptance at sub-slice level.
- Don't mark the parent complete until the final sub-slice satisfies
  parent acceptance criteria.
- Generate next prompt from latest accepted sub-slice, not the
  original parent.

## Move Slices

Structural moves: move files, rewire imports, no behavior change.
Codex pre-computes the import audit. Claude does not re-grep imports
unless audit is missing or analyzer output proves it stale.

For each moved file, list same-directory relative imports, classify
each target as `MOVES` or `STAYS`, plus the implied rewrite. When
the moved target is imported by an out-of-scope file, name the
exact import-line follow-up in the prompt.

## Visible Authority

- Codex always reads `PROJECT_TRACKER.md`. List it in Claude prompts
  only when the slice changes tracker truth or needs a live gate.
- Include an active phase doc/section only when the slice needs it.
- At most one contract doc per prompt.
- Do not load contract + plain-English companion together.
- Do not load prior-slice docs unless the current slice depends on
  a live drift table or schema delta from them.
- Do not put this standard in execution prompts unless the work is
  workflow.
- `graphify` only for unfamiliar architecture/concept orientation.
  Known symbols/imports/filenames → use `rg`.

## Workflow Branches

**Review findings.** User pastes findings → check the exact
file/line with `rg`. If repo already has fix + tests, mark stale.
Otherwise generate review-fix prompt: finding summary, exact files,
1–2 focused tests, no phase recap.

**Live preflight / smoke.** Slice touches deployed proxy, Firebase,
Postgres, provider APIs, or cloud dashboards → prompt Claude to do
name-only prerequisite checks, never print secrets, stop with
BLOCKED if anything missing, run live mutation only after preflight,
report live mutations separately from local file changes.

**Tracker / doc hygiene.** User asks to clean docs or reduce token
usage → read tracker truth first, preserve meaning + sequence,
archive only redundant material, keep trackers + CLAUDE.md lean,
verify before/after outcome is the same, no broad rewrites of
unrelated docs.

## Review Handoff

When Claude reports:

1. Inspect changed files directly.
2. Confirm "left alone" files are actually untouched.
3. Check acceptance criteria against repo content.
4. Confirm test evidence.
4.5. UX-exposing slices: confirm walkthrough evidence (screenshot
   or text trace). Absent on a UX slice = `FOLLOW-UP NEEDED`.
5. Run small targeted reruns only when needed.
6. Return findings if there are issues.
7. If clean, advance trackers + generate next prompt.

Codex verifies repo truth, not report wording.

Avoid `git stash` during verification. Prefer `git diff HEAD --
<file>`, `git status --short`, `rg` for imports/callsites, targeted
test reruns when evidence is incomplete.

Verdicts: `ACCEPT`, `FOLLOW-UP NEEDED`, `REJECT`.

## Test Reruns

Codex does not rerun Claude's tests by default. Rerun only when:

- The user asks.
- The report is missing test evidence.
- The reported tests do not match the prompt.
- The diff makes the report doubtful.
- A known risky seam needs local confirmation.

Prefer the smallest targeted rerun.

## Tracker Updates

After accepting a slice:

- Update `PROJECT_TRACKER.md` current / next / hard-gate wording.
- Update `docs/DATA_ALIGNMENT_TRACKER.md` only for alignment-heavy
  slices.
- Do not move tracker truth ahead of repo truth.
- Do not advance the parent phase if only a sub-slice accepted.

## Commit Cadence

- Commits at phase close unless the user says otherwise.
- Execution prompts say `Do not commit unless explicitly asked`.
- Don't include commit / push / graphify steps in execution prompts.
  The ship-slice prompt owns merge mechanics; the post-commit hook
  owns graph rebuild + auto-push.

## In-Session Hygiene (Claude side)

These compound on the prompt-shape rules above; they cover Claude's
in-session token discipline.

- **Trust Block 2/3.** Open authority files only when the prompt is
  genuinely ambiguous about a concrete shape. Don't re-read trackers
  to "set context" — Block 2/3 already encoded what's needed.
- **Read with `offset` + `limit` on known-large files.** Don't
  re-read 2000-line files in full once layout is known.
- **Grep for patterns, never full-read for them.** "What does the
  existing RLS / trigger style look like?" → grep + ~30 lines of
  context, not a 300+ line migration end-to-end.
- **Grep-then-offset on large trackers.** `grep -n` for the slice
  ID, then offset-read the band(s) that hit.
- **Tail test output aggressively.** `flutter test ... | tail -5`.
- **Batch independent reads** in one tool call.
- **Skip courtesy CLI smokes** when analyze + focused tests cover
  the contract.
- **Surgical test-file reads.** Adding to a 500+ line test file →
  grep for insertion anchor, offset-read ~50 lines around it.
- **No `git stash` during verification.** It re-injects every
  stashed file as system reminders. Use `git diff HEAD --` instead.
- **Do not call or acknowledge TodoWrite.** The prompt's task list
  is the source of truth.

## Slice Prompt Block Template

Block 1 (human-readable Markdown):

```
## Block 1 - Human Context

Plain English: [1–3 concise sentences; example when helpful]

Lane: <slice-id> — worktree <.claude/worktrees/<lane-name>> on
branch <branch-name> off master @ <short-sha>.

Important context:
- ...

Current issue:
- ...

Human prerequisites:
- Setup/access needed: [None for this slice, or exact requirement;
  say whether it blocks this slice or a later slice]
- Decision needed for this slice: [No decision needed, or the exact
  decision required by documented constraints/gates/trade-offs]

Routing rules to mirror:
- [only when contract-bound; 2–3 rules max]
```

Blocks 2 + 3 (Claude's paste payload, fenced):

```text
## Block 2 - Tech Context

Authority files for this run:
- [specific runtime files / tests]
- [active phase doc section, only when needed]

Hard constraints
- [scope-specific]
- Do not update trackers.
- Do not commit unless explicitly asked.
- Run only required tests; no courtesy CLI smokes.

## Block 3 - Tasks

Files to modify
- [file or file - region/method]

[Optional] Files to leave alone
- [omit unless real carve-out]

Implementation tasks
1. ...

Required tests
- dart analyze
- [focused test files]

[For UX-exposing slices] Operator walkthrough (kDemoMode = true)
1. [exact click path]
2. [expected outcome at each step]

Acceptance criteria
- [ ] [checkable criterion]
- [ ] [UX] Operator walkthrough completes in demo mode
- [ ] [UX] Permission gating verified
- [ ] [UX] Brand styling matches lib/theme/app_theme.dart

When finished, report using the standard report format. UX slices
add a `Walkthrough evidence` line.
```

## Report Format

```text
## Execution Report - [Prompt ID]

### Files changed
- [file]: [what changed]

### Files left alone
- [optional; only if a prompt listed carve-outs]

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

**Compression rules:**

- Bare filenames > decorative markdown links unless review needs
  them.
- No "Notes for reviewer" unless something genuinely surprised you.
- No "Out of scope (not touched)" list — `Scope check` flags
  cover it.
- No restating slice ID inside every section.
- No restating prompt language ("I did not call live providers,
  I did not change SQLite") — exceptions only.
- Floor: tests run, acceptance ticked, files listed with brief
  description. Cutting below this breaks the tracker advance loop.

## Anti-Patterns

- Re-prompting already-fixed review findings.
- Asking the user for secrets in chat.
- Letting Claude infer product/security/cost decisions.
- Putting human context inside Claude's paste block.
- Reading archived docs for normal prompt generation.
- Running live commands before name-only preflight.
- Advancing tracker truth before verifying repo truth.
- Two parallel lanes touching the same file.

## Do Not Cut

When making prompts shorter, never cut:

- Tracker-first phase control.
- Hard constraints.
- Required tests.
- Explicit acceptance criteria.
- Repo verification before tracker updates.
- No-commit / no-tracker-change instructions for Claude.

## Companion Docs

- `docs/PARALLEL_LANE_AUDIT_AND_RECOMMENDATION.md` — between-batch
  audit + next-batch lane recommendation.
- `CLAUDE.md` — durable repo laws, hard promises, guardrails.
- `PROJECT_TRACKER.md` — current phase, fetch map, hard gates.
