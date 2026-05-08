# Code Ops Debt Report — Open Items

**Audit date:** 2026-05-07
**Last trim:** 2026-05-07 — closed findings moved to
`docs/archive/CODE_OPS_DEBT_RESOLVED_2026-05-07.md`. This doc shows
**only what is left**.

This doc is the operational-debt sibling to the CODE_HEALTH audit:
- CODE_HEALTH = original 2026-05-06 audit + 5-wave remediation, closed 2026-05-08. Archived at `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`; residuals consolidated into `docs/POST_HARDENING_FOLLOWUPS.md` + phase docs + contracts.
- `CODE_OPS_DEBT.md` = doc-vs-code drift findings.

## Closeout summary (2026-05-07 — two sweeps)

**Original audit sweep (2026-05-07 morning).** 13-lane parallel fix
sweep dispatched. 12 PRs merged + 1 closed-redundant; ~40 of 50 audit
findings closed; all 7 P0 launch-blockers resolved. Detail:
`docs/archive/CODE_OPS_DEBT_RESOLVED_2026-05-07.md`.

**Operator-decision sweep (2026-05-07 evening).** Operator gave
decisions on the 6 remaining deferred items. 8 lanes dispatched in
parallel:
- ✅ **J#3 — Browser Use** (PR #368): rewrote runbook to clarify it's a Codex automation; no in-repo harness binary.
- ✅ **J#4 — slice-runtime-acceptance** (PR #381): contract relaxed to advisory pattern (no CI build); cross-references softened.
- ✅ **J#5 — graphify candidates** (PR #369): marked backlog under AI freeze; 503 message rewritten to surface paused-by-design.
- 🟡 **A (item 1) — session-claim resolver** (no PR yet): WIP rate-limited at 22:30Z; nothing committed; full re-dispatch needed.
- 🟡 **B#1 (item 2) — single-admin PII erasure with grace** (PR #377 draft): WIP committed migration + fresh_mfa_resolver scaffold; needs route + worker + test finish.
- 🟡 **B#5 (item 3) — server-side audit-log CSV** (PR #378 draft): 1 file +182 partial; needs filter alignment + frontend rewrite.
- 🟡 **I#1-2 + audit (item 4) — kDemoMode end-to-end** (PR #379 draft): 4 files +316 with new `demo_mode_contract.md`; needs flow-diagram completion.
- 🟡 **D (item 5) — Pub/Sub realtime** (PR #380 draft): 2 new pubsub files committed; needs main.dart wire-in + Azure cron + tests + runbook.
- ⚪ **H#8 (item 9) — first-backfill status null**: self-closes via Phase 8 framework push; no action needed.

5 lanes (N1, N2, N3, N4, N5) hit the rate-limit reset at 23:30 NDT
(2026-05-08T02:00 UTC). They're parked as draft PRs and re-dispatch
when the window opens.

**Operator decisions recorded** (durable history; the lanes act on these):

| Item | Decision |
|---|---|
| 1 (Theme A — session-claim resolver) | 1-hour MFA freshness; when stale, redirect to login + redo authenticator |
| 2 (Theme B#1 — paired-approval erasure) | Single-admin (uses item 1's resolver); reversible during grace period; PII-only scope |
| 3 (Theme B#5 — audit-log CSV) | Server-side, streamed, respects same UX filters; verify time filter is end-to-end (frontend + proxy + backend) |
| 4 (Theme I#1-2 — kDemoMode reader-side branches) | Keep the demo switch; verify it's literally a writer-side switch end-to-end on mobile; document carve-outs in CLAUDE.md |
| 5 (Theme D — Pub/Sub realtime) | Approved; constraints: simplicity + functionality first, no over-engineering, watch cost/perf |
| 6 (Theme J#3 — Browser Use) | ✅ Codex automation, not in-repo binary |
| 7 (Theme J#4 — slice-acceptance) | ✅ Relax contract; CI is expensive |
| 8 (Theme J#5 — graphify) | ✅ Backlog under AI freeze |
| 9 (Theme H#8 — first-backfill status) | Self-closes via Phase 8 push |

---

## Outstanding findings

Severity tags:

- **P0** = launch-blocking or actively wrong
- **P1** = operationally degraded; visible to first operator
- **P2** = cron-driven feature that doesn't run
- **P3** = defense-in-depth or harness theater

### Theme A — Pinned-to-`false` admin actions (2 findings)

The production admin shell hardcodes 5 admin permission gates to
`false`. Comments say they're waiting on a "session-claim resolver."
No phase doc names where the resolver lands; no slice currently
scheduled.

| Sev | Finding | Ref | Blocker |
|---|---|---|---|
| P1 | `canEditSeeded = false` (constant) | `lib/admin/admin_routes.dart:907` | needs session-claim resolver slice |
| P1 | `canResetMfa`, `canIssuePairedErasure`, `canExportAuditLog` all `const … = false` (covers 11A.14 reset-MFA-factors, paired-approval erasure, 11W.5 audit-log export) | `lib/admin/admin_routes.dart:1109-1111` | needs session-claim resolver slice |

**Decision needed:** authorize a phase doc for the session-claim
resolver. Decisions inside it: freshness window (5 min? 1 hr?
per-action different?), JWT claim shape vs session table, step-up UX
shape (modal? redirect? inline denial?).

### Theme B — Server routes that doc-claim ACCEPT but don't exist (2 findings)

3 of 5 closed via PR #344. Two remain.

| Sev | Finding | Ref | Blocker |
|---|---|---|---|
| P0 | 11A.14 paired-approval erasure has no proxy route. User-action switch hard-codes only `suspend`/`reactivate`/`soft-delete`/`reset-password`/`reset-mfa`/`cancel-mfa-removal`/`force-logout`. Zero `erase_pii` / `/erase` routes anywhere. | `tool/advisor_proxy/advisor_proxy.dart:10303` | needs contract decision (approval window, scope of erasure, reversibility, audit-trail shape) |
| P1 | 11W.5 audit-log "export" pages `/v1/auth/audit-log` 100k times client-side and renders RFC 4180 in the browser. Permission gate is widget-only theater. | `lib/operator_web/services/web_team_audit_log_gateway.dart:586-637` | needs decision on streaming vs background-job + retention |

**Decisions needed:**
- Paired-approval erasure: who pairs (two admins simultaneous? proposer + approver with window?), what gets erased (PII only? audit-log mentions? schedules they were on?), reversibility (instant or grace period?).
- Audit-log CSV: streaming response or background Cloud Run job that emails a download link? 10M-row exports — 1hr stream or async-job? Format (RFC 4180 or with JSON metadata header)? Retention on generated CSVs (single-use download links or reusable)?

### Theme D — Phase 10a real-time replay (3 findings)

| Sev | Finding | Ref | Blocker |
|---|---|---|---|
| P0 | `RealtimeReplayResolver(backlog: realtimeInProcessPublisher)` reads in-process 256-entry ring buffer of the same pod. Cross-pod reconnect after Cloud Run restart returns `replay_truncated`. | `tool/advisor_proxy/main.dart:399-449` | paired with Pub/Sub wiring below |
| P1 | `PUBSUB_REALTIME_ENABLED` flag exists; publisher path is `_unwiredPubsubMessagePublisher` `throw StateError(…)`. **Pub/Sub adapter genuinely not wired despite Phase 10a.1 ACCEPT.** | `tool/advisor_proxy/main.dart:1185-1196` | needs Cloud Pub/Sub topic provisioning + IAM (operator-blocked); 30-min code wire-up after that |
| P3 | Bounded `event_outbox` retention sweep at 03:00 UTC ships in `202605051000_…` alongside legacy 09:00 UTC cron from `202605050200`. On Azure split-DB topology both DO blocks emit NOTICE-and-return when applied to `forgeflow`, requiring manual `cron.schedule_in_database(..., 'forgeflow')` runbook step. | `db/migrations/202605051000_phase_10a_3_outbox_retention_sweep.sql:280-324` | runbook step today; needs ops to either run the manual schedule or land a follow-up migration that targets the correct DB |

**Decisions needed:**
- Provision Cloud Pub/Sub topic for `forge-flow-production1`.
- Grant Cloud Run service account publish + subscribe.
- Pick retention (5 min? 1 hr? 24 hr? — affects cost + recovery window).
- Pick subscriber model (each pod separate subscriber → message processed once across pods, or each pod a separate subscriber → fan-out).

### Theme H — Mobile↔server-truth: first-backfill status null (1 finding)

8 of 9 closed via PR #340. One remains.

| Sev | Finding | Ref | Blocker |
|---|---|---|---|
| P1 | `fetchFirstBackfillStatus` returns `{first_backfill_status: null}` 200 when no row exists. Conflates "no first-connect ever started" with "first-connect job genuinely missing/lost." | `tool/advisor_proxy/proxy_bootstrap.dart:2102-2137` + `lib/services/sync/http_sync_proxy_client.dart:281-296` | owned by Phase 8 framework finishing push (intentionally excluded from CODE_OPS_DEBT scope); will close when that lane updates the route shape |

**No decision needed from you** — this naturally closes when the Phase 8
framework push touches the route shape. Tracked here for visibility.

### Theme I — `kDemoMode` reader-side branches (2 findings)

2 of 4 closed via parallel master slice. Two remain.

| Sev | Finding | Ref | Blocker |
|---|---|---|---|
| P1 | `AppDataStatusService.evaluate` branches on `bool.fromEnvironment('kDemoMode')` at READ time, returning a different `AppDataStatus.demo()` shape vs `.current()`. | `lib/services/app_data_status_service.dart:16,136` | needs UX call (probably intentional demo experience; status differs because demo is intentionally frozen-in-time) |
| P1 | Login screen branches on `kDemoMode || FORGE_FLOW_DEMO_MODE` to render an extra "demo operator sign-in" button. | `lib/screens/auth/login_screen.dart:17-19` | needs UX call (button is useful for walkthroughs; removing breaks demo flavor) |

**Decision needed:** for each, "remove the branch" (strict Hard Promise
#2 compliance) or "keep it, document why it's exempt" (carve-out in
CLAUDE.md). If "keep," add a comment + note in CLAUDE.md so future
audits don't re-flag.

### Theme J — Acceptance harness theater (1 finding remaining; J#3 + J#4 + J#5 all closed 2026-05-07)

2 of 5 closed via PR #341 (smokes + Secret Manager). J#3 closed via PR #368 (Browser Use runbook rewritten — Codex-driven, out-of-repo). J#4 closed by operator decision (slice-runtime-acceptance relaxed to advisory pattern). J#5 closed by operator decision (graphify-candidates marked backlog under AI freeze).

| Sev | Finding | Ref | Status |
|---|---|---|---|
| ~~P3~~ CLOSED 2026-05-07 | Browser Use runbook described manual click-path workflow as if Forge & Flow owned a harness binary. Operator decision: Browser Use is invoked via Codex (out-of-repo), not by anything in this tree. Runbook renamed + rewritten. | `runbooks/browser_use_codex_acceptance_workflow.md` (was `browser_use_acceptance_harness_runbook.md`) | closed — PR #368 |
| ~~P3~~ CLOSED 2026-05-07 | ~~`slice_runtime_acceptance_contract.md` claims acceptance gate for every runtime slice; no CI enforcement.~~ **Closed by operator decision — enforcement intentionally relaxed; contract is now advisory.** Contract softened from "must" to "should/recommended"; cross-references in `CLAUDE.md`, `PROJECT_TRACKER.md`, `docs/CODEX_PROMPT_GENERATION_STANDARD.md` updated to mark it advisory (CI cost discipline). | `docs/contracts/slice_runtime_acceptance_contract.md` | closed — operator decision |
| ~~P3~~ CLOSED 2026-05-07 | 11A.3.x graphify routes 503 when bundle isn't on disk. _Closed by operator decision: marked backlog under AI freeze; will return when AI unpauses. Proxy 503 message rewritten to surface paused-by-design; see `PROJECT_TRACKER.md` "Paused" + `phase_11A_operations_console_plan.md` `11A.3.x` Status header._ | `tool/advisor_proxy/advisor_proxy.dart:12747,12824` | closed — PR #369 |

**Decisions needed:** for each remaining open item, "build the real
version" or "delete the doc that promises it." Both are valid. What's
not valid is keeping the promise without the implementation.

---

## What's NOT in this doc (excluded scope)

- Anything in the CODE_HEALTH archive's Closed / Deferred / Out-of-scope / Addendum sections (`docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`).
- The Phase 8 framework finishing pushes (vendor-credential broker,
  sink production binder, OAuth refresh worker, per-vendor OAuth
  descriptors, `8.framework.*`, `8.gap-*`, `8.transport.*`,
  `8.spine-bridge-sink-fanout.*`, etc.).

---

## Status & maintenance

**Status:** 7 outstanding findings across 5 themes. Closed findings
(~40 of 50 from the original audit, plus Theme J#4 + J#5 closed
2026-05-07 by operator decision) live in
`docs/archive/CODE_OPS_DEBT_RESOLVED_2026-05-07.md` (audit-batch
closeouts) and inline above (later operator-decision closeouts).

**To act on an outstanding finding:** make the operator decision called
out in the "Blocker" column, then dispatch a fix lane the same way the
2026-05-07 sweep did (see archive for the lane shapes).

**Cross-references:**
- `docs/archive/CODE_OPS_DEBT_RESOLVED_2026-05-07.md` — closed findings + 13-lane scoreboard.
- `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md` — original 2026-05-06 audit + 5-wave remediation closeout (2026-05-08). Active CODE_HEALTH residuals are now in `docs/POST_HARDENING_FOLLOWUPS.md` + phase 11a decision register + phase 8 spine bridge plan + auth permission key catalog.
- `docs/_execution/2026-05-05_v1_launch_punchlist.md` — operator-blocked V1 launch items.
- `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items from the 2026-05-02 deep audit.
- `PROJECT_TRACKER.md` — routing.
- `CLAUDE.md` — Hard Promises (this audit found violations of #2; closed via parallel slice).
