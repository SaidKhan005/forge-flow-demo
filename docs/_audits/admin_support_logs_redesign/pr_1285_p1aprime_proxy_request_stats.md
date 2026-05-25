# Audit — PR #1285: P1a' create proxy_request_stats (stats-only telemetry, 30-day retention)

Date: 2026-05-24
PR: #1285 · branch `claude/support-logs-p1aprime-stats-table` · base `master` · MERGEABLE/CLEAN
Slice: P1a' (Support logs redesign §12 — stats-only storage)
Category: **SCHEMA + RLS-touching → gated. Merge needs explicit operator approval.**

## Build provenance (transparency)

The dispatched agent twice hit transient server errors (rate-limit, then "Overloaded")
mid-build; its uncommitted worktree was cleaned. The migration + test it had drafted were
captured from the audit reads, so the orchestrator recreated them byte-faithfully in a fresh
worktree, **fixed two latent bugs the agent never ran the test to catch**, verified, and
opened the PR. So this is orchestrator-built + self-verified (not a separate agent+auditor
split). Operator merge approval is the gate.

Two latent bugs caught + fixed before commit:
1. The shape test stripped `--` comments but not `COMMENT ON … ;` statements, so the
   "no content column" assertions matched the word "content" in the table's COMMENT prose.
   Fixed the stripper to also drop `COMMENT ON` statements.
2. The migration header wrapped `202604250005_advisor_cloud_foundation.sql` across two
   lines, failing the citation check. Reflowed so the filename stays contiguous.

## Verification (independently run)

| Check | Result |
|---|---|
| `migration_drift_scanner --fix --strict-docs` | clean (cutoff → 202605241500; 4 watched docs refreshed) |
| `migration_cutoff_lint` | clean (155 migrations) |
| `index_leading_column_lint` | clean (92 operator-scoped tables; both new indexes operator-leading) |
| `rls_policy_lint` | clean (wrapper-function policy) |
| `dart analyze` (test) | no issues |
| shape test (28 assertions) | 28/28 pass |
| pre-commit migration guardrails | ran on commit, clean |
| GitHub mergeable | MERGEABLE / CLEAN |

## Contract review (migration)

- Stats-only: NO content/encrypted columns, NO `business_date`. ✓
- `actor_user_id` uuid only (no PII; render-time name/role) per `audit_attribution_contract.md`. ✓
- `request_id` correlation with **no FK** (48h proxy prune must not cascade-delete 30-day stats); composite `locations` FK `ON DELETE CASCADE` mirrors `proxy_requests`. ✓
- result_status CHECK (success/error/timeout); non-negative metric CHECKs. ✓
- Wrapper-based per-tenant RLS, operator-leading indexes. ✓
- 30-day purge: SECURITY DEFINER, `forge_admin` EXECUTE only, FOR UPDATE SKIP LOCKED, pg_cron 03:30 UTC, Azure split-DB fallback. ✓
- TIMESTAMPTZ; transaction-wrapped; idempotent DDL; additive. ✓

## Observations (non-blocking)

- service_role granted full DML (parity with `proxy_requests`); the runtime writer only
  INSERTs (P1b may INSERT-then-UPDATE an in-flight row), and the retention DELETE runs as
  `forge_admin` — so the DELETE grant to service_role is least-privilege-loose but matches
  the sibling table. Optional future tightening.
- SECURITY DEFINER function does not set `search_path` (consistent with the P1a sibling;
  all object refs are schema-qualified). Optional repo-wide hardening later.

## Verdict: CLEAN — approve-for-merge pending operator gate

On approval: merge, then `tool/verify_pr_landed.sh 1285 proxy_request_stats proxy_request_stats_purge_expired`.

## Note: P1a sunk cost

P1a's `request_id` correlation column on `advisor_conversation_log` (#1277) is now unused
(stats live in the new table). P1a's 30-day retention fix on `advisor_conversation_log`
stays valuable hygiene. No rollback needed.
