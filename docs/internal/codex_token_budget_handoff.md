# Codex — Token Budget Handoff (2026-04-14)

Short, one-time note. Paste-ready to share with Codex verbatim.

---

Token-waste patterns from the 7.55q.5 run have been closed in the standard.
Before generating any future execution prompt:

1. **Re-read** the **"Before You Generate a Prompt (Preflight)"** section at
   the top of `docs/CODEX_PROMPT_GENERATION_STANDARD.md`. Every prompt, not
   just the first — the `Execution Cycle` now makes this step 1 of every
   iteration.
2. Run the 8-item checklist in that section against your draft prompt.
3. Respect the hard limits:
   - Auth list ≤ 3 files (excluding `PROJECT_TRACKER.md`)
   - Prior-slice docs ≤ 1
   - No contract + plain-English companion pair
   - Region-scope every file > 500 lines (`file.dart - method() only`)
   - Message 2 body ≤ 60 lines
4. Do not include `TodoWrite` references. Do not suggest `git stash` during
   verification.

If a prompt fails the checklist, it is a defect — fix before sending.
Claude will note defects in the execution report's `Blockers` section
rather than silently absorbing them.

---

## Why this note exists (not for Codex to re-read every time)

The 7.55q.5 prompt loaded 10 authority files, 2 uncapped 500+ line runtime
files, and several Message-2 sections that duplicated `CLAUDE.md`. The
standard already recommended tighter loading but without teeth. The rules
are now inspectable:

- Preflight section in the standard (top of file)
- Defect checklist in Claude's `feedback_token_budget.md` memory
- TodoWrite ban + 40-line handoff cap in `CLAUDE.md`
- Trimmed `session_handoff.md` (~232 → 40 lines)

Rough preventable waste per typical slice: **25K–40K tokens**. On a heavy
slice like 7.55q.5: **35K–50K**.
