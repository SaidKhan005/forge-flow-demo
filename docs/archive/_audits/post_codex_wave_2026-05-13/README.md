# Post-Codex Wave — Archived Audit Docs

> Archived 2026-05-13 as part of housekeeping after the wave closed via
> PR #638 + follow-ups #639/#640/#641/#642/#643. 84 files moved here from
> `docs/_audits/post_codex_wave/` (which retains the 12 still-live files:
> the C-12 closeout, the 9 dimensional wave audits, and the
> `wave_completion_deep_audit_2026_05_13.md`).
>
> These files are frozen historical artifacts. They preserve full per-PR
> audit trails for every merge in the wave. Internal sibling cross-references
> (`docs/_audits/post_codex_wave/pr_X` → `docs/_audits/post_codex_wave/pr_Y`)
> were NOT rewritten when files moved — the relative shape is preserved
> and any reader inside this archive can navigate by ls / path swap.
>
> Live wave summary: `docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`.
> Next-wave plan: `docs/_indices/NEXT_WAVE_PLAN.md`.

## Per-PR audits (77)

Naming convention: `pr_<N>_<slice>_audit.md`. Numbered chronologically with
the PR number on GitHub. Each contains the orchestrator's Pattern B
executor audit + the worker's self-audit + verification evidence at merge
time.

`pr_473_b3_retroactive_audit.md` through
`pr_636_c_7_adaptive_2fa_button_audit.md` — plus
`pr_b_pr_a_rollup_audit.md` (multi-slice rollup audit).

(Run `ls docs/archive/_audits/post_codex_wave_2026-05-13/pr_*.md` for the
full enumeration.)

## Investigation reports (3)

| File | Scope |
|---|---|
| `c_1_ecdsa_pubkey_gap_investigation.md` | Confirmed env-var-first interpretation for C-1's SendGrid Event Webhook pubkey; C-1b queued conditionally if rotation becomes P0 post-launch |
| `test_proxy_5_failures_investigation.md` | Reframed B2.3's "5 test failures in test/proxy/" disclosure — actual picture was 2 stale snapshots / 3 cases / 2 files; fix shipped via PR #610 |
| `orchestrator_bundle_33_b10_1_fallout.md` | B10.1 fallout cleanup per A3.4 worker disclosures — bleed-stop ceiling raised 19,071 → 19,600; B10.1 carry-forward bare-catch typed at line 14109 |

## Housekeeping sweeps (2)

| File | Scope |
|---|---|
| `final_housekeeping_sweep_2026_05_13.md` | Bundle 26 staging sweep — `docs/_indices/` doc trim + `CLAUDE_HANDOFF_PROMPT.md` + `CODEX_HANDOFF_PROMPT.md` refinements + the live audit README created (now superseded by the 2026-05-13 archive sweep that produced this directory) |
| `followups_doc_drift_cleanup_2026_05_13.md` | 3 mechanical fixes to `docs/POST_HARDENING_FOLLOWUPS.md` via PR #558 |

## Draft artifacts (1)

| File | Scope |
|---|---|
| `wave_closeout_checklist_DRAFT.md` | DRAFT — operator-approved closeout sequence launchpad (visual-test surface map + HP audit + migration apply queue + sign-off chain); merged to master 2026-05-13 via PR #597 and leaned to current state via PR #613. Kept for history. |

## Evidence files (1)

| File | Scope |
|---|---|
| `pr_476_smoke_run_evidence.txt` | Verbatim smoke-run output captured at PR #476 audit time |

## Why archived

Per CLAUDE.md "Phase Doc Hygiene": *"Closed phase docs retire to
docs/archive/phases/ within a week."* Same principle applied to wave
audit docs once the closeout doc (`c_12_lane_c_closeout_audit.md`)
synthesized them and the wave was officially CLOSED. The kept-live
files are the ones that retain forward-looking utility (institutional
knowledge for refactor phase, Production1 apply prep, doc-drift
mitigation).
