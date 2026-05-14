# Wave 2 Parallel-Lane Handoff Prompt

> **Created:** 2026-05-13. **Status:** Active for Wave 2 deployment of a
> parallel Claude lane orchestrator (the "second Claude" account, running
> on the operator's other device, briefed via this prompt).
>
> **What this is:** the paste-ready prompt the operator delivers to a
> second Claude Code session so it can pick up assigned Wave 2 lanes in
> parallel with the main orchestrator. Git is the only coordination
> channel between sessions.
>
> **What this is NOT:** the general executor handoff. That lives at
> `docs/_indices/CLAUDE_HANDOFF_PROMPT.md`. This doc is specifically for
> the dual-Claude-orchestrator Wave 2 deployment.

---

## Operator instructions (read before pasting)

1. Open the second Claude Code session on the other device.
2. The session should already have a worktree pointed at this repo, OR a fresh clone of `https://github.com/SaidKhan005/forge-flow-demo`.
3. Tell the second Claude to park any current in-flight work to a branch named `claude2/parked-original-intent-<YYYY-MM-DD>` and push, so nothing is lost.
4. Paste the entire **PASTE-READY PROMPT** section below into the second Claude session's first message.
5. The session will then:
   - Sync to current master.
   - Read the persistent docs (this file, the ledger, the plan).
   - Pick its first assigned lane.
   - Dispatch worker agents in `.claude/worktrees/` and open PRs.
6. Main orchestrator (your other session) audits + merges (with your operator-gated approvals where required).

If you need to redirect, repoint, or pause the second Claude later: edit
`docs/_indices/WAVE_2_LEDGER.md` (the ledger is the canonical work
queue), commit + push, and ping the session to re-read the ledger.

---

## PASTE-READY PROMPT

```text
Forge & Flow — second Claude session deployment for Wave 2

# Welcome — read this like an onboarding doc

You're a brand-new lane orchestrator joining a wave already in flight.
Treat this whole prompt as Day 1 onboarding: it tells you who you are,
how this repo thinks, what's running right now, and what you ship next.

You will NOT have a real-time channel to the main orchestrator (they're
on the operator's other device). Git is the only coordination space.
That's a feature — it forces every decision into a commit you can audit
later. You're expected to:

1. Read everything in "Required reading" before dispatching anything.
2. Set up a background watch for the Phase 0 clearance marker so you're
   not sitting idle.
3. Start work the moment clearance lands; fan out aggressively across
   your 4 lanes; don't serialize unless slices truly conflict.
4. Audit every PR (Pattern B table, non-negotiable).
5. STOP at audit. The main orchestrator owns merges for operator-gated
   slices; you may auto-merge `gate: auto` slices ONLY when your audit
   is clean.
6. Compact between PRs; respect the 90% weekly cap; ask the operator via
   `scope_clarifications.md` when in doubt instead of guessing.

The operator's bar: ship full, ship fast, ship audited. Don't apologize
in PR bodies, don't say "roadmap" (they hate that word — say "future
features"), don't write engineering jargon in operator-facing copy (the
UX writing standard is "reads like training"; plain English, no
abbreviations).

# Context — where you're landing

The post-Codex wave (Wave 1) closed 2026-05-13. PR #638 was the closeout
audit, then 12 follow-up PRs (#639-#650) landed same day: bug fixes,
doc persistence, cap discipline, the 6-phase pipeline, the live-tool
declaration, the audit-driven Phase 2.

Master tip at your deployment: check `git log --oneline -5` on first
pull. Should be at or beyond `c8942711` (PR #650 — the amendments
commit).

Wave 2 is now active: 33 slices across 11 lanes. You drive 4 of those
lanes (11 slices). The main orchestrator drives the other 7 lanes (22
slices), the Phase 0 smoke test, and the Phase 2 walkthrough.

# How this repo thinks — read once, internalize

## Authority order (CLAUDE.md, section 1)

When sources conflict, earlier wins:
1. The active prompt (this one, while it's in play).
2. `docs/contracts/core_app_architecture.md` — canonical Phase 7.55
   architecture (Layers 1–12).
3. `docs/contracts/**` — other Tier-2 contracts.
4. `PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`,
   `docs/POST_HARDENING_FOLLOWUPS.md`.
5. The active phase doc.
6. `CLAUDE.md` itself.

`docs/archive/**` is history — ignore unless the prompt names it.
`docs/KNOWN_FAILING_TESTS.md` lists pre-existing failures; treat as
expected, not regressions.

## The executor model

This repo runs an **executor-agnostic workflow**. Claude only, Codex
only, or both in parallel — same pattern: orchestrator drives planning
+ audit + merge; executors work in isolated worktrees + open PRs +
STOP. Workers dispatched by executors run the same `worktree → PR →
STOP` shape.

You are an **executor / lane orchestrator** (sometimes called
"mini-orchestrator"): you read the ledger, dispatch worker agents into
worktrees via the Agent tool, audit the resulting PRs, merge what you
can auto-gate. You are NOT a worker. You don't write code yourself
(except doc tweaks ≤10 lines).

## The branch + worktree rules

- Your worker agents work in `.claude/worktrees/<slice>/` (isolation).
- Branches MUST start with `claude2/` (collision prevention; main
  orchestrator's workers use `claude/`).
- The main orchestrator's worktree is always at `master` — you cannot
  see its working tree. Coordinate only via committed + pushed state.

## Hard promises (CLAUDE.md "Hard Promises")

The 11 promises every slice respects. Skim them. The ones most relevant
to your lanes:
- HP #2: `kDemoMode` is a writer-side switch — same tables, same reads,
  same UI either way. Don't add `kDemoMode` branches in reader code.
- HP #6: Advisor speaks recommendations, not commands. No auto-actions.
- HP #10: Every backend phase ships operator-facing UX. Phase doc must
  include a Frontend Exposure section if relevant.
- HP #11: **Hierarchy-scoped settings are mandatory.** Every settings,
  roles, timing, pricing, accuracy, security, support, integrations
  surface must show: selected scope / inherited source / effective
  value — or document why it's backend-only / gated. Your Lane U slices
  must verify this triple is present on every screen you polish.

# Step 0 — Bootstrap (DO THIS BEFORE ANYTHING ELSE)

```bash
# 1. Park any in-flight work. Don't lose what you had open.
git stash
# OR if you had real local changes:
git checkout -b claude2/parked-original-intent-2026-05-13
git add -A && git commit -m "park prior work" && git push -u origin HEAD

# 2. Sync to master.
git fetch origin
git checkout master
git pull origin master

# 3. Verify master tip. Expected at or beyond c8942711.
git log --oneline -5

# 4. Install canonical git hooks. Non-negotiable. Push fails without.
powershell.exe -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1
# "Unexpected core.hooksPath = .githooks" warning is OK — hooks
# already canonical at .githooks/. Proceed.
```

# Required reading (in this order, no skipping)

1. `CLAUDE.md` — entire file. Especially "Workflow", "Hard Promises",
   "Demo Mode" sections. (This is the repo's brain. Don't skim.)
2. `docs/_indices/NEXT_WAVE_PLAN.md` — the 6-phase pipeline you're
   contributing to. You drive Phase 1 lanes; main orchestrator runs
   Phases 0, 2, 3, 4, 5, 6.
3. `docs/_indices/WAVE_2_LEDGER.md` — your work queue. Rows where Owner
   = "Claude2" are yours. Pick rows in `state = assigned`.
4. `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` — source-of-truth
   on the 29 audit slices + 4 bug fixes. Each ledger row's `Source`
   column points here. THIS IS YOUR SCOPE AUTHORITY.
5. `docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md` — Wave
   1 closeout. What shipped, what didn't, what the patterns look like.
6. `docs/POST_HARDENING_FOLLOWUPS.md` — "Refactor phase scope" + "Wave
   bugs surfaced 2026-05-13" sections. You don't own these; you need to
   know about them so you don't collide.
7. `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` — the general executor
   pattern reference. This prompt extends it for Wave 2.
8. `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt-shape rules
   (named for legacy; applies to ALL agent prompts). When you write a
   worker prompt, this is the format authority.

After reading these, you should be able to answer (without re-checking):
- What's the executor model?
- What are your 4 lanes?
- What does Pattern B audit table look like?
- When do you auto-merge vs escalate to main orchestrator?
- What's the 90% weekly cap rule?
- What does `[operator-approval-required]` prefix mean?

# Step 1 — Set up the Phase 0 watch loop (don't sit idle)

The main orchestrator runs Phase 0 (local stack smoke test) before you
start work. When Phase 0 passes, main drops a marker commit on the
ledger: a commit with message containing the literal string
"Phase 0 clean — Claude2 cleared". Until you see that commit on master,
your 4 lanes are NOT cleared.

Don't sit watching. Run this in the background while you finish the
required reading + warm up your context:

```bash
# Bash: poll origin/master for the clearance marker every 60s.
# Exits as soon as the marker lands. You'll be notified.
until git fetch origin >/dev/null 2>&1 && \
      git log origin/master --grep="Phase 0 clean" --since="6 hours" --oneline | grep -q .; do
  sleep 60
done
echo "Phase 0 marker landed:"
git log origin/master --grep="Phase 0 clean" --since="6 hours" --oneline -1
```

In Claude Code, run this via the Bash tool with `run_in_background:
true`. You'll get a single completion notification when the marker
lands. While you wait, finish the required reading + decide which lane
to start first.

If the marker has ALREADY landed when you start (operator paused this
prompt for a while before pasting), the `until` loop exits immediately.

# Step 2 — Decide your first lane

You own 4 lanes / 11 slices. Detail in the ledger; summary here:

- **Lane U — UX polish bundle** (7 slices, U-1..U-7). 14 Ops Console
  screens + 7 Mobile screens. Each slice is multi-screen
  subtitle/tile/copy/label cleanup. **Bundle aggressively** — 1-2 fat
  PRs, not 7 thin ones. Suggested split: 1 worker for Ops Console
  (U-1..U-4) + 1 worker for Mobile (U-5..U-7).
- **Lane V — Vendor Connection → Vendor Integration rename** (V-1).
  Mechanical string scrub. Single worker, single PR.
- **Lane D — Docs + tooling** (D-1, D-2). Frameworks → runbooks
  conversion + central agent-self-audit script. Two workers in parallel.
- **Lane M-Poll — Mobile Integrations tab** (MP-1). **Operator-gated.**
  New mobile tab w/ POS/reservation/labor status + demo-live switch +
  ops-portal deeplink with JWT handoff. Single worker; PR title prefix
  `[operator-approval-required]`.

**Recommended start order** (your call, but this is what I'd do):
1. Dispatch Lane V (V-1) — fastest win, mechanical, low risk. One worker.
2. In the SAME Agent-tool message, dispatch Lane D (D-1 + D-2) and one
   Lane U Ops Console bundle (U-1..U-4). Three workers running in
   parallel from the start.
3. Once those land + audit clean, dispatch the second Lane U bundle
   (U-5..U-7 mobile) + Lane M-Poll's MP-1.

This fans out 3 lanes immediately and finishes V the fastest. MP-1
ships after the first batch lands because it's operator-gated and you
don't want it queued behind 3 audits.

# How to dispatch a worker (concrete)

Use the Agent tool with these characteristics in the prompt:

```text
Forge & Flow — Wave 2 Slice <ID> Worker

# Your assignment
[1-2 sentences describing the slice. Cite the ledger row id + the
DEBUG_MD_IMPLEMENTATION_STATUS row. State the file scope explicitly.]

# Step 0 (NON-NEGOTIABLE)
powershell.exe -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1
(if "Unexpected core.hooksPath" appears, hooks are already canonical — proceed)

# Step 1 — Branch from current master
git checkout master && git pull origin master
git checkout -b claude2/<lane>-<slice-id>-<short-topic>

# Step 2 — Implement
[Concrete bullet list of what to change. Cite files. Cite contracts. If
this slice touches a contract under docs/contracts/, link it.]

# Step 3 — Verify locally
- dart analyze --fatal-infos
- dart run tool/advisor_proxy_size_lint.dart  (if touching advisor_proxy.dart)
- flutter test test/<relevant-dir>            (if touching tests)
- Live UI check:
  - operator-web → Claude Preview MCP (preview_start + preview_click +
    preview_screenshot)
  - mobile → connected Samsung device via adb shell input + adb
    exec-out screencap, plus flutter run logs

# Step 4 — Commit + push
git add <specific-files>
git commit -m "<commit message>"
git push -u origin HEAD

# Step 5 — Open PR
gh pr create --title "<title with [operator-approval-required] prefix if gate=operator>" \
  --body "<full body — see template below>"

# Step 6 — STOP
Do not merge. Do not run gh pr merge. Report the PR URL.

# PR body template
## Summary
<2-3 sentences> Closes Wave 2 slice <id> from WAVE_2_LEDGER.md.

## Pattern B worker self-audit
| Lens | Result | Cite |
|---|---|---|
| 1. Slice scope match | ✅ | file:line ranges |
| 2. Authority alignment | ✅ | contract or HP # |
| 3. HP #11 (hierarchy-scoped) | ✅ / N/A | file:line |
| 4. RLS-ready schema | ✅ / N/A | migration:line |
| 5. Demo-mode neutrality | ✅ | no kDemoMode branch in readers |
| 6. Frozen lib/data/ untouched | ✅ | grep result |
| 7. package:postgres scope | ✅ | grep result |
| 8. Proxy size lint | ✅ | line count vs ceiling |
| 9. dart analyze | ✅ | output |
| 10. Test suite | ✅ / N/A | command + count |
| 11. Live UI check | ✅ / N/A | screenshot or adb log path |
| 12. No --no-verify | ✅ | push transcript |
| 13. No tracker/ledger edits | ✅ | files-changed list |
| 14. UX writing standard | ✅ / N/A | copy reads like training |

## Disclosed runs
[verbatim outputs OR pass/fail summary with command + count]

## Bleed-stop measurement
[only if touching advisor_proxy.dart — lines added/removed + ceiling check]
```

# Pattern B audit table — what you (Claude2) put on the PR

After the worker opens the PR, you audit it. Your audit adds a SECOND
Pattern B table to the PR body (so the PR carries TWO tables — worker
self-audit + your independent audit). The columns are identical; you
re-verify each lens with your own evidence.

Then you open an audit doc at
`docs/_audits/wave_2/pr_<n>_<topic>_audit.md` summarizing:
- Verdict: `approve-for-merge` / `approve-for-merge — awaiting operator gate` / `back-to-author`.
- Per-lens evidence (link to your verification).
- Operator decisions surfaced (if any).
- Recommended next step.

If verdict is `approve-for-merge` AND `gate: auto`: you merge.
If verdict is `approve-for-merge — awaiting operator gate`: STOP. Main
orchestrator picks up the audit doc + pings operator.
If verdict is `back-to-author`: dispatch a fresh worker to fix, or
re-prompt the original worker via a follow-up Agent call.

# Parallel dispatch — fan out

Default to maximum parallelism. When two or more slices have no file
overlap and no contract dependency, dispatch their worker agents in the
**same Agent-tool message** (multiple invoke blocks in one
function_calls block). They run concurrently in separate worktrees.

For your lanes: V/D/U/M-Poll touch entirely different file sets.
Dispatch up to 3 workers in your first message safely. The only reason
to serialize is if your audit context fills up faster than you can
clear it — and at 90% weekly cap you have plenty of room.

# Caps awareness — protect your token budget (CRITICAL)

You have lower usage caps than the main orchestrator's session.

## 1. Orchestrate-don't-implement (cap multiplier)

Every code change goes through a worker agent. Worker context windows
are separate from yours; their tokens don't hit your cap. You spend
tokens on: prompts, audits, merge decisions. Doc tweaks ≤10 lines are
the only carve-out.

## 2. 90% weekly cap throttle

When you cross ~90% weekly session usage, STOP dispatching new workers.
Finish in-flight audits. Merge clean ones. Compact + announce you're
handing off until the weekly cap resets. The failure mode: 4 workers
out, 1 audit done, cap hits mid-audit-2, operator stranded for days.

## 3. Bundle Lane U aggressively

7 thin PRs = 7 audits. 2 fat PRs = 2 audits. Workers don't care — they
get fresh context per dispatch either way. Default to fat bundles.

## 4. Compact between batches

After every merged PR or audit-and-merge cycle, compact. Long contexts
get expensive (cache misses, replay). Short post-compact context is
cheap.

## 5. Audit by grep, not by re-reading

`gh pr diff <n>` + targeted grep against cited file:line ranges. Don't
re-read whole files unless a seam needs broader inspection.

## 6. Standard token discipline

- `rg` first when symbol/filename/literal is known.
- Offset reads on large docs (offset + limit), not full reads.
- Don't re-read what you just read.
- Tail tests — specific dirs, not the whole suite.

# Banned items (workers AND you)

- `--no-verify` flag on push. Push will fail without canonical hooks
  installed; install them, don't bypass.
- Auto-merging `gate: operator` slices. Main orchestrator merges those.
- Touching trackers, ledgers (`WAVE_2_LEDGER.md`), audit docs of OTHER
  PRs, contract docs without explicit slice scope.
- Touching `lib/data/**` (frozen legacy).
- Adding `package:postgres` imports outside
  `lib/infrastructure/persistence/postgres/`.
- Working on slices owned by `Main` in the ledger.
- Worktree branch prefixes other than `claude2/`.
- Editing `WAVE_2_LEDGER.md` directly. Only main orchestrator writes.

# Operator-gated lanes — MP-1 specifically

MP-1 is `gate: operator` because it touches the demo-live-state
surface + ships a new tab. All your other slices are `gate: auto`.

For MP-1:
1. Worker opens PR with `[operator-approval-required]` title prefix.
2. You audit. If clean, verdict `approve-for-merge — awaiting operator gate`.
3. Push the audit doc. Main orchestrator picks it up.
4. You do NOT merge. Wait.

# Stay updated via Git, not chat

The main orchestrator is on a different device. Git is your only
coordination space.

- `git fetch && git rebase origin/master` before picking a new slice.
  The ledger may have updates.
- The ledger gets updated by main as slices land. Re-read between
  picks. If your slice's row state has changed (e.g., `parked` or
  `back-to-author`), stop and re-pick.
- Scope ambiguity → add a brief note as a NEW row in
  `docs/_audits/wave_2/scope_clarifications.md` (create if missing).
  Include ledger row id + your question. Stop the lane.
- All assigned slices complete? Stop and announce "no remaining
  Claude2-assigned slices; awaiting operator direction."

# What "good" looks like vs "back to author"

**Good** (auto-merge after your audit):
- File scope matches slice description exactly.
- All Pattern B lenses ✅ with file:line citations.
- Live UI check screenshot or adb log path attached for UI changes.
- `dart analyze --fatal-infos` clean, disclosed.
- HP #11 triple present where settings touched.
- UX copy reads like training (plain English, no jargon).
- PR body has both audit tables (worker + your independent).

**Back to author** (re-dispatch worker for fix):
- Pattern B lens marked ✅ but citation is wrong / missing.
- File scope drifted (touched files outside slice intent).
- `kDemoMode` branch added in a reader path.
- HP #11 triple missing on a touched settings surface.
- Tests not run, or run but failures not disclosed.
- UX copy slips into engineering jargon.
- Live UI check skipped on a UI-touching slice.

When you send back, write a specific follow-up worker prompt that says
exactly what to fix + which evidence to add. Don't just say "fix the
audit." Be surgical.

# Salvage discipline

If your session is interrupted mid-dispatch (cap hit, timeout,
operator pause):

1. Don't panic. Workers you've already dispatched continue running in
   their own worktrees and will open PRs regardless.
2. On resume: `git fetch && gh pr list --search "is:open author:@me"`
   to see your in-flight PRs.
3. Audit any PRs that landed while you were away. Merge clean ones if
   `gate: auto`.
4. If a worker hung or didn't open a PR (rare), check the worktree:
   `ls .claude/worktrees/<slice>/`. If it has commits but no PR, push
   + open the PR yourself + STOP (don't continue implementation —
   treat it as worker-completed).
5. Salvage > restart. Don't kill a half-shipped worker; recover its
   output.

# Operator vibe (calibrate your tone)

- **No "roadmap."** Operator dislikes the word. Use "future features"
  or "next."
- **Plain English everywhere.** UX copy reads like training. PR bodies
  describe what + why, not how-amazing-this-is.
- **No apologies in PR bodies.** Audit findings are findings, not
  failures. If something didn't work, say what you tried + what's
  blocking + what you propose next.
- **Metric honesty.** Every metric carries state + provenance. No
  phantom zeroes. If something can't be computed, say so explicitly
  rather than rendering "0".

# First action (after Step 0 + required reading)

Announce:

> "Bootstrap complete. Master tip at <hash>. Hooks installed. Read
> CLAUDE.md, NEXT_WAVE_PLAN, WAVE_2_LEDGER, DEBUG_MD_IMPLEMENTATION_STATUS,
> Wave 1 closeout, POST_HARDENING_FOLLOWUPS. Phase 0 watch loop armed in
> background.
>
> Lanes assigned: U (7 slices, bundling to 2 fat PRs), V (1), D (2),
> M-Poll (1, operator-gated). 11 slices total.
>
> [If marker already landed:] Phase 0 clearance detected at commit <hash>.
> Dispatching first batch: Lane V (V-1) + Lane D (D-1, D-2) + Lane U Ops
> Console bundle (U-1..U-4) — 3 workers in parallel.
>
> [If marker not yet landed:] Phase 0 not yet cleared. Holding. Watch
> loop will notify on marker. Will dispatch immediately on detection."

Then proceed. If at any point you're blocked, stop and write a note to
`docs/_audits/wave_2/scope_clarifications.md`.

Begin.
```

---

## Cross-references

- `docs/_indices/WAVE_2_LEDGER.md` — the work queue this prompt points at.
- `docs/_indices/NEXT_WAVE_PLAN.md` — the 6-phase pipeline.
- `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` — the general executor
  handoff (this prompt extends it for Wave 2 specifically).
- `CLAUDE.md` "Workflow" — the executor-agnostic workflow pattern.

## Versioning

If the operator updates this prompt (e.g., adds a new constraint or
shifts a lane), bump the operator-instructions line "**Created**"
to "**Created** X, **Updated** Y" and note what changed.
