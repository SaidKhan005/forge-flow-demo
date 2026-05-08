# Codex Prompt And Review Standard

Status: Active
Updated: 2026-05-03

This file defines the shared prompt style and review loop. Keep it lean.

## Operating Loop

1. Graph refresh runs.
2. Claude uses the fresh graph to propose the next prompts.
3. Claude implements in scoped parallel worktrees.
4. Codex reviews code against the prompt, contracts, phase docs, and tests.
5. Claude fixes findings; Codex reviews again.
6. When Codex approves, Codex updates trackers/docs.
7. Only after docs are current, Claude is asked to perform git actions.

Codex does not move tracker truth ahead of repo truth. Claude does not commit,
push, merge, or update trackers unless explicitly asked after Codex approval.

## Authority

Read only what the slice needs:

- `PROJECT_TRACKER.md` for routing and gates.
- `CLAUDE.md` for durable repo rules.
- The active phase doc under `docs/phases/**`.
- At most one relevant contract under `docs/contracts/**`.
- `docs/contracts/slice_runtime_acceptance_contract.md` for runtime-exposed
  slices (advisory pattern, not CI-enforced).
- `docs/PERFORMANCE_FRAMEWORK.md` for performance, scale, mobile
  responsiveness, web-console timing, load, polling, health, or bundle-size
  work.
- `docs/UX_ADJUSTMENT_FRAMEWORK.md` for UX polish, copy, navigation, button,
  modal, filter, tooltip, browser-tab, and no-regression admin-console polish.
- `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` for broad
  feature work, settings work, route/schema changes, runtime-exposed behavior,
  or any implementation where hidden plumbing may matter.

Avoid archived docs unless explicitly named. Keep `PROJECT_TRACKER.md` and
`CLAUDE.md` pointer-only; put detail in phase docs, contracts, runbooks, or
`docs/_execution/**`.

## Prompt Shape

Every Claude execution prompt uses the same two-block shape:

```text
## Block 1 - Human Context

Plain English: <1-3 sentences>

Lane: <slice-id> - worktree <.claude/worktrees/<lane>> on branch <branch>
off master @ <short-sha>.

Authority:
- <3 entries max>

Current issue:
- <what this slice must solve>

Human prerequisites:
- Setup/access needed: <none, or exact blocker>
- Decision needed: <none, or exact decision>

## Block 2 - Claude Paste

Task:
- <implementation / review-fix / audit / doc-hygiene / live preflight>

Files to modify:
- <path - region/method when file is large>

Files to leave alone:
- <only when a carve-out matters>

Hard constraints:
- Do not update trackers.
- Do not commit unless explicitly asked.
- Stay inside scope.
- For live work, run name-only preflight first and stop with BLOCKED on miss.

Implementation tasks:
1. <checkable task>

Required tests:
- <smallest sufficient analyze/test commands>

Acceptance criteria:
- [ ] <repo-verifiable criterion>

Report using the standard execution report.
```

Use repo-root-relative paths. For files over 500 lines, name the region,
method, or class. Do not paste phase-doc weight into prompts.

## Walkthrough Specificity (operator-facing slices)

A walkthrough is **not** "demo-mode walkthrough green." A walkthrough is a
numbered click-path with expected visual states at each step, named widgets,
and named values. If your slice ships an operator-facing surface, your
walkthrough must be a click-path Codex (or you) can follow without reading
the code. Bar set by `docs/_walkthroughs/7.58.UX.5.md`.

Required elements per walkthrough:

- Demo-mode start condition (date, week, business state).
- Numbered steps, each naming the user action ("tap X", "long-press Y").
- Expected visual state per step ("card flips green", "badge reads 'live'",
  "MetricCardNotYetAvailable widget renders").
- Named widget references when behavior depends on a specific widget.
- Named value expectations when behavior depends on a specific number, label,
  or state ("CPLH state = `live`, provenance = `vendor_lightspeed_lsk`").

Codex returns `FOLLOW-UP NEEDED` if the walkthrough is vague (e.g., references
the standard without giving the click-path), missing expected states, or skips
a non-trivial UX surface introduced by the slice.

## Vendor Adapter Slices (Phase 8 / 8R / 8.S)

Vendor adapter slices have a stricter shape than ordinary slices. Each
slice ships in **one PR** that performs three steps:

1. **Online API check** — verify the vendor's developer documentation
   is current; capture URL + retrieval date.
2. **Framework engineering** — implement the adapter against the
   documented API shape; bind to every framework seam in
   `docs/contracts/vendor_adapter_slice_contract.md`.
3. **Docs synthesis** — populate `docs/integrations/<vendor_id>/`
   with the 6-file doc pack per
   `docs/contracts/per_vendor_doc_pack_contract.md`.

The prompt's Authority block MUST cite both contracts. A slice that
ships steps 1+2 but skips step 3 is `FOLLOW-UP NEEDED`.

The prompt's acceptance criteria MUST cite the specific verdict gates
in `vendor_adapter_slice_contract.md`:
- All 6 mandatory framework calls present and tested.
- Zero banned items (V1 lean cut 2 list).
- Per-vendor doc pack populated (6 files; cite source URLs).
- Walkthrough at click-path bar (7.58.UX.5 reference).
- Lifecycle = `documented` set on `VendorCapabilityProfile`.

The slice's walkthrough at `docs/_walkthroughs/<slice-id>.md` MUST
cover the anchor scenarios from
`docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` Walkthrough
section (forged signature, malformed payload, future-dated event,
OAuth near-expiry).

`*.live.sandbox` and `*.live.prod` follow-up slices are separate prompts
fired individually when sandbox / production credentials arrive. They
promote lifecycle and fill in `live_verification_checklist.md`. They
are NEVER bundled into the engineering slice.

## Runtime Work

If a slice exposes runtime behavior, browser/admin/operator UX, migrations,
health metrics, packaged artifacts, vendor/AI calls, workflows, or cutover
evidence, the prompt should reach for the relevant checks from
`docs/contracts/slice_runtime_acceptance_contract.md` (advisory pattern,
not CI-enforced — reviewer judgment).

If a slice is performance-sensitive or asks for performance optimization, the
prompt must also include the measurement, behavior-preservation, runtime-proof,
and reporting loop from `docs/PERFORMANCE_FRAMEWORK.md`.

If a slice changes visible UX copy, layout, tab structure, filters, keys,
tooltips, buttons, modals, browser metadata, or admin/operator console polish,
the prompt must also include the behavior-preservation, browser-loop, and
reporting rules from `docs/UX_ADJUSTMENT_FRAMEWORK.md`.

Minimum acceptance path:

- branch code exists
- runtime artifacts are packaged
- deployed/runtime path is named when applicable
- real browser origin is named for QA when applicable
- health producer/runbook truth is not faked
- migration drift scanner runs after migration changes
- expensive diagnostics are manual, scoped, and measured

## Parallel Worktrees

Parallel work is allowed only when file ownership is disjoint.

- One lane owns its `Files to modify`.
- Shared seams are serialized unless the prompt states the integration rule.
- UX slices add walkthrough evidence under `docs/_walkthroughs/<slice-id>.md`
  or in the execution report.
- Main chat stays read-only across active worktrees except for coordination
  and Codex-owned tracker/doc updates after approval.

## Codex Review

Codex reviews the diff, not just the report.

Check:

- changed files match scope
- required tests are present and credible
- contracts/phase docs are satisfied
- runtime acceptance gates are satisfied when applicable
- walkthrough evidence exists for UX-exposing slices
- no unauthorized tracker/doc/git action occurred

Verdicts:

- `ACCEPT`: code satisfies prompt and gates.
- `FOLLOW-UP NEEDED`: bounded fix required.
- `REJECT`: unsafe, wrong direction, or materially out of scope.

Rerun tests only when evidence is missing, risky, or doubtful. Prefer targeted
reruns.

## Docs After Approval

After `ACCEPT`, Codex updates docs before Claude is asked for git actions.

Update only what changed:

- `PROJECT_TRACKER.md` for routing/current queue/hard gates.
- Active phase doc for slice status and next work.
- Contracts/runbooks when their authority changed.
- `docs/POST_HARDENING_FOLLOWUPS.md` or archive when backlog changed.
- `docs/_execution/**` for audit reports and durable evidence.

Archive resolved detail. Do not duplicate it in trackers.

## Git Handoff

Claude git actions happen only after:

- Codex approval
- tracker/doc updates are complete
- migration/docs drift checks are clean when relevant
- the user asks for the git action

Execution prompts say: `Do not commit unless explicitly asked.`

## Execution Report

Claude reports:

```text
## Execution Report - <slice-id>

Files changed
- <path>: <brief change>

Tests run
- <command>: <result>

Acceptance criteria
- [x] <criterion>

Scope check
- No tracker changes: yes/no
- No unauthorized commits: yes/no
- Links updated: yes/no, if docs changed

Walkthrough evidence
- <required for UX slices, otherwise omit>

Blockers
- <none or exact blocker>

Status
- complete / follow-up needed
```

## Anti-Patterns

- Re-prompting stale findings without checking current code.
- Asking for secrets in chat.
- Letting Claude make product, security, cost, or live-infra decisions.
- Reading archived docs for ordinary slice work.
- Running live commands before name-only preflight.
- Advancing tracker truth before Codex verifies repo truth.
- Two parallel lanes editing the same file without a serialization rule.
