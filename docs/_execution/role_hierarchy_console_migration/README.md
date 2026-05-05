# Role / Hierarchy Console Migration — Execution Pack

**Created:** 2026-05-05
**Owner:** Vanessa (sequencing) + Claude (prep) + Codex (review)
**Block:** Self-Service Parity (`11W.1`–`11W.6`) + Cross-Operator Parity (`11A.12`/`13`/`14`)
**Trigger:** Phase 7 + Phase 10 close
**Status:** Prompts drafted, paused until trigger fires

This directory holds the 9 Codex execution prompts + the parallel-execution runbook for the role / hierarchy console migration block. Every slice ships in its own worktree against its own branch; the pairs (`11W.1` + `11A.12`, `11W.2`+`11W.3` + `11A.13`, `11W.5`+`11W.6` + `11A.14`) land together per the parity contract.

## Files in this pack

- `README.md` (this file) — pack index + how to use
- `parallel_execution_runbook.md` — worktree names, branches, file-ownership map, serialization rules, kickoff order, integration-lane handling
- `11W_1_members.md` — Codex prompt for `11W.1` Members
- `11W_2_roles.md` — Codex prompt for `11W.2` Roles + Permission Explainer + custom-role builder
- `11W_3_hierarchy.md` — Codex prompt for `11W.3` Hierarchy
- `11W_4_sessions.md` — Codex prompt for `11W.4` Sessions
- `11W_5_audit_log.md` — Codex prompt for `11W.5` Audit Log
- `11W_6_security.md` — Codex prompt for `11W.6` Security
- `11A_12_members_admin.md` — Codex prompt for `11A.12` Members + Invites parity (cross-operator)
- `11A_13_roles_hierarchy_sessions_admin.md` — Codex prompt for `11A.13` Roles + Hierarchy + Sessions inspect (cross-operator)
- `11A_14_audited_support_actions.md` — Codex prompt for `11A.14` Audited support actions

## Authority order (every prompt cites this)

1. The active prompt in this directory
2. `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (parity contract — binding)
3. `docs/contracts/auth_permission_key_catalog.md` (permission key catalog — frozen)
4. `docs/contracts/slice_runtime_acceptance_contract.md` (runtime acceptance gates)
5. The active phase doc (`docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` for 11W slices, `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` for 11A slices)
6. `CLAUDE.md`

## How to kick off

1. Verify Phase 7 + Phase 10 close — both phases marked complete in `PROJECT_TRACKER.md`.
2. Run `parallel_execution_runbook.md` § Kickoff order.
3. Spin worktrees in waves per the runbook. Wave 1 = `11W.1` + `11A.12` (Members pair). Wave 2 = `11W.2` + `11W.3` + `11A.13` (Roles + Hierarchy + Sessions inspect). Wave 3 = `11W.4` + `11W.5` + `11W.6` + `11A.14` (Sessions + Audit + Security + Support actions).
4. Each worktree runs its own prompt. Codex reviews per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.
5. After both members of a pair (or all members of a wave) hit `ACCEPT`, the integration lane (separate worktree) lands the gateway-resolver wiring in `lib/main_operator_web.dart` + `lib/main_admin.dart` and the nav-item registration in `lib/operator_web/router/operator_web_router.dart` for the wave.
6. After integration lane lands, Codex updates trackers + closes the wave.

## Hard rules

- No slice ships without its pair partner. If `11W.1` is `ACCEPT` but `11A.12` is `FOLLOW-UP NEEDED`, neither merges.
- No slice introduces a new backend route. Only `11A.14` adds a new permission key (additive migration). If a slice prompt needs a new route, STOP and update the parity contract first.
- No slice imports `dart:io` or `sqflite` from any file reachable from the web entry points.
- No slice paraphrases the catalog `description` text in the Permission Explainer.
- No slice mints idempotency keys in the gateway — minting is the screen layer's job per the 11A.1 pattern.

## Walkthrough bar

Every slice ships a click-path walkthrough at `docs/_walkthroughs/<slice-id>.md` matching the bar set by `docs/_walkthroughs/7.58.UX.5.md`: numbered steps, named widgets, named values, expected visual states. Vague walkthroughs return `FOLLOW-UP NEEDED`.
