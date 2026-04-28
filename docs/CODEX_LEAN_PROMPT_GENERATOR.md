# Codex Lean Prompt Generator

Use this when a chat needs to generate the next Claude/Codex execution prompt
without reloading the whole project history.

## What This Generator Does

- Reads tracker truth first.
- Pulls only the active phase docs needed for the next slice.
- Keeps `PROJECT_TRACKER.md` and `CLAUDE.md` lean: they point to the right
  docs and preserve durable laws; phase docs carry per-slice weight.
- Filters stale review findings against current repo content before acting.
- Separates human context from Claude's paste block.
- Names human prerequisites and user decisions before live or product work.
- Keeps prompts short enough to preserve context.

## Minimal Inputs

Provide only these:

- `Current request:` what the user wants next.
- `Review findings:` paste any findings if present.
- `Latest execution report:` paste only if this follows a Claude run.
- `Known live intent:` `none`, `preflight only`, or `live smoke/apply`.

If any input is missing, inspect local repo truth rather than asking first.
Ask the user only when a live credential, account setup, billing action, or
product/security decision is actually required.

## Generator Prompt

Copy this into Codex when you want the next prompt produced:

````text
You are generating the next execution prompt for this repo.

First read:
- PROJECT_TRACKER.md sections: Active Authority, How To Fetch Context,
  Prompt Fetch Map, Now, Current Slice Queue.
- docs/CODEX_PROMPT_GENERATION_STANDARD.md only if prompt shape is in doubt.
- The active phase doc(s) named by PROJECT_TRACKER.md for the current slice.

Then do this in order:
1. Recontextualize the current phase and next slice from tracker truth.
2. If review findings were pasted, verify each against the current repo before
   treating it as live. Mark stale findings as already fixed and do not put
   them into the Claude prompt.
3. Preserve the Lean Authority Law: PROJECT_TRACKER.md and CLAUDE.md stay lean
   and only carry routing, durable guardrails, current hard gates, and pointers.
   Put per-slice detail/backlog/acceptance weight in linked phase docs or a
   temporary checkpoint doc.
4. Identify whether this is implementation, review-fix, audit,
   closeout-verification, closeout-with-blockers, live preflight, or live
   smoke/apply.
5. Identify human prerequisites:
   - keys, accounts, CLI installs, cloud projects, dashboard work, billing,
     token exports, deployed URLs, smoke passwords, or live-service access.
   - say whether each blocks this slice or a later slice.
6. Identify decisions the user must make now:
   - product UX, security posture, cost, infrastructure, sequencing, live
     fallback, or documented gate choice.
   - if none, say no decision needed.
7. Produce Block 1 separately as human-readable Markdown.
8. Produce Blocks 2 and 3 together in one fenced text block for one-click
   Claude copy/paste.

Prompt rules:
- Keep visible authority list to 3 entries max.
- Use repo-root-relative paths.
- For files over 500 lines, specify method/region only.
- Include exact files to modify and files to leave alone only when needed.
- Include required tests and concrete acceptance criteria.
- Always tell Claude: no tracker updates and no commits unless explicitly asked.
- For live work, require name-only preflight first and stop with a BLOCKED
  report if any prerequisite is missing.
- For tracker/doc hygiene, require no logic/meaning changes unless explicitly
  scoped.
- For tracker/CLAUDE updates, keep them lean and move weight-bearing detail to
  the linked phase doc.
- Do not include Block 1 inside the Claude paste block.

Output exactly:

## Block 1 - Human Context

Plain English: ...

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
- ...

Acceptance criteria
- [ ] ...

When finished, report using the standard report format.
```
````

## Built-In Workflow Branches

### Review Findings

Use when the user pastes review findings.

1. Check the exact file/line or symbol with `rg`.
2. If the repo already has the fix and tests, tell the user it is stale.
3. If not fixed, generate a review-fix prompt with:
   - finding summary,
   - exact files,
   - one or two focused tests,
   - no phase recap.

### Live Preflight Or Smoke

Use when the slice touches deployed proxy, Firebase, Postgres, provider APIs,
or cloud dashboards.

Prompt Claude to:

- perform name-only prerequisite checks,
- never print secret values,
- stop and write a BLOCKED report if anything is missing,
- run the live mutation only after prerequisites pass,
- report live mutations separately from local file changes.

### Tracker / Doc Hygiene

Use when the user asks to clean docs or reduce token usage.

Prompt Claude to:

- read tracker truth first,
- preserve meaning and sequence,
- archive only redundant or superseded material,
- keep `PROJECT_TRACKER.md` and `CLAUDE.md` lean; linked phase docs carry
  slice detail and backlog weight,
- verify before/after outcome is the same,
- avoid broad rewrites of unrelated docs.

### After Claude Reports

Codex should verify before generating the next prompt:

- inspect changed files directly,
- check stale review findings against current code,
- confirm tests match the prompt,
- run a small targeted rerun only when needed,
- update trackers only after repo truth is verified.

## Anti-Patterns

- Re-prompting already-fixed review findings.
- Asking the user for secrets in chat.
- Letting Claude infer product/security/cost decisions.
- Putting human context inside Claude's paste block.
- Reading archived docs for normal prompt generation.
- Running live commands before name-only preflight.
- Advancing tracker truth before verifying repo truth.
