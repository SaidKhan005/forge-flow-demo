# Audit — PR #1277: P1a advisor_conversation_log correlation + 30-day retention

Date: 2026-05-24
Auditor: orchestrator (independent audit per Pattern B)
PR: #1277 · branch `claude/support-logs-p1a-conversation-log-correlation` · base `master`
Slice: P1a (Support logs telemetry groundwork) — see
`docs/archive/_execution/admin_support_logs_redesign/01_lens_audit_and_implementation_plan.md`.
Category: **SCHEMA + RLS-touching → gated. Merge needs explicit operator approval.**

## Outcome: MERGED + VERIFIED LANDED (2026-05-24)

Operator approved. Independent re-verification before merge: 3 gated lints clean
(cutoff/index/rls), migration test 18/18, `dart analyze` clean on the changed test, GitHub
`mergeStateStatus=CLEAN`. Squash-merged; `tool/verify_pr_landed.sh 1277` = VERIFIED — merge
commit `b095d2b` on origin/master, all 7 files landed, no post-merge regression, both new DB
objects (`advisor_conversation_log_purge_expired`, `advisor_conversation_log_op_loc_request_idx`)
present.

## Verdict: CLEAN — approve-for-merge pending operator gate

Changed files (7) = exactly the expected set; no scope creep into the proxy or screen:
- `db/migrations/202605241000_advisor_conversation_log_request_correlation_and_retention.sql` (new, 265 lines)
- `test/db/migrations/advisor_conversation_log_request_correlation_and_retention_test.dart` (new, 275 lines)
- `scripts/postgres_staging_setup.ps1` (cutoff bump, 1 line)
- 4 `--strict-docs` watched docs (POST_HARDENING_FOLLOWUPS, phase_11A plan, phase_9 backlog, migration-apply runbook) — minimal required bumps; `PROJECT_TRACKER.md` untouched.

## Pattern B — independent checks I ran (not just the agent's report)

| Check | Result | Evidence |
|---|---|---|
| `tool/migration_cutoff_lint.dart` | clean; cutoff = `202605241000…` (current) | re-ran in agent worktree; 154 migrations scanned |
| `tool/index_leading_column_lint.dart` | clean; new index `(operator_id, location_id, request_id)` leads with operator_id | re-ran; 91 operator-scoped tables |
| `tool/rls_policy_lint.dart` | clean; no bare `current_setting`; wrappers only | re-ran |
| PR base + diff | base=`master`; 7 files = P1a only (master already contains the #1251 b10.1 commit it rebased onto) | `gh pr view 1277` |
| Migration SQL | additive, idempotent, transaction-wrapped; reviewed line-by-line | file read |
| Migration test | 18 structural assertions; SQL-shape test (repo convention; runtime verified at staging-apply) | file read |

## Migration review (line-by-line highlights)

- **Correlation column:** `request_id uuid null`, `add column if not exists` (idempotent; propagates to all partitions). **No FK** — justified (lifecycle mismatch: legal-hold/permanent retention vs short-lived proxy ledger; CASCADE would purge legal-hold rows, SET NULL would sever the key, RESTRICT would block proxy cleanup; partition FK overhead; correlation is advisory join-for-display). Sound.
- **Column-level grant:** `grant select (request_id)` to `service_role` on parent + DEFAULT partition — correctly opts the new (non-sensitive) column into the audit-privacy column allowlist while leaving encrypted content columns omitted. Good catch by the agent.
- **Index:** `(operator_id, location_id, request_id)` — operator-leading (RLS perf discipline), verified by lint.
- **Retention purge:** new cluster-wide `advisor_conversation_log_purge_expired(retention_days=30, batch_size=1000)`. Predicate `created_at < cutoff AND legal_hold = false AND retention_class <> 'permanent'` — NEVER deletes legal-hold/permanent. `FOR UPDATE SKIP LOCKED` batched loop (CLAUDE.md: no pgmq). `SECURITY DEFINER`, `REVOKE EXECUTE FROM public` + `GRANT EXECUTE TO forge_admin` (service_role cannot call it).
- **pg_cron:** idempotent unschedule-then-reschedule; daily 03:15 UTC (off the 02:00 audit anchor + rollup ticks); graceful NOTICE + `schedule_in_database` instruction for Azure split-DB (cron metadata in maintenance DB). Mirrors `202604280010_c` topology.
- **Guardrails honored:** TIMESTAMPTZ only; no `business_date` (UI buckets by time/date, not business day); no new `CREATE POLICY` (existing wrapper-based policies cover the new column); no destructive DDL.

## Agent flags — resolved

1. **Touched 4 migration-tracking docs.** Acceptable: `--strict-docs` REQUIRES these bumps; they are tooling output, not the prohibited tracker/ledger edits. `PROJECT_TRACKER.md` correctly untouched.
2. **Rebased onto master; proxy_requests PK is single-column not composite.** Immaterial to this slice (the index is on `advisor_conversation_log`; the correlation is a plain nullable column). Re-verified clean post-rebase.

## Observations (non-blocking)

- The `SECURITY DEFINER` purge function does not set an explicit `search_path`. This is **consistent with the existing sibling** `advisor_conversation_log_purge` (also DEFINER, no search_path); both fully-qualify object refs with `public.`. Not a regression. Optional future hardening: a repo-wide pass adding `SET search_path` to DEFINER functions.

## Merge gate

Gated (schema + RLS). On operator approval: run `tool/pre_merge_gate.sh 1277`, merge, then `tool/verify_pr_landed.sh 1277` to confirm the migration actually landed on `origin/master` ("MERGED" ≠ landed).
