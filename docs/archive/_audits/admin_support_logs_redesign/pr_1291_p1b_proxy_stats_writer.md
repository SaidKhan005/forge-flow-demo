# Audit — PR #1291: P1b write proxy_request_stats on LLM completion

Date: 2026-05-24
PR: #1291 · branch `claude/support-logs-p1b-proxy-stats-writer` · base `master` · MERGEABLE/CLEAN
Slice: P1b (Support logs redesign §12 — proxy write wiring)
Category: **PROXY hot-path → gated. Merge needs explicit operator approval.**
Changed: 4 files, +617/-6 — `tool/advisor_proxy/advisor_proxy.dart` (+252) + 3 test files (+365).

## Verdict: CLEAN — approve-for-merge pending operator gate

## What I reviewed (read the actual hot-path diff)

- **No extra round-trip:** the `proxy_request_stats` INSERT is folded into the SAME tenant
  transaction as the existing `completionUpdate` on `proxy_requests`, guarded on `rows > 0`
  (so a completion matching no idempotency row never leaves an orphan stats row). Honors the
  cost doctrine.
- **Measured latency:** `requestStartedAt = clock()` anchored AFTER auth + idempotency
  validation (spans the metered work, not header parsing); `latency_ms` clamped `>= 0`.
- **Idempotent:** stats are built from `reserved.requestId` (the reservation result, real
  path only); idempotency replay early-returns at the route (`ProxyAccountingReplayed`) and
  never reaches `completeRequest`, so no replay writes a duplicate. The completeRequest doc +
  the scaffold store both updated for the new optional `stats` param.
- **Honest field population:** `actor_user_id` = `scope.userId`, null for service principals
  (uuid only, no PII, per `audit_attribution_contract.md`); `provider` via `providerFromModelId`
  (claude→anthropic, gemini/models→google, else null — no fabrication); `model_id` = the
  completion's versioned id; `model_version` null (id carries version); tokens/cost mirror the
  usage-log telemetry; `cost_usd` bound as a string like the sibling write.
- **No content; no migration; no screen/gateway/model/advisor_conversation_log changes.** Scope held.

## Independently verified

| Check | Result |
|---|---|
| `dart analyze tool/advisor_proxy/advisor_proxy.dart` | No issues |
| touched suites (`advisor_proxy_usage_and_migrations` + `advisor_proxy_http_and_admin_routes`) | **153 pass** |
| agent-reported: proxy size lint | clean (no ceiling raise) |
| agent-reported: pre-commit + pre-push hooks | passed |
| GitHub mergeable | MERGEABLE / CLEAN |

## Documented scope boundary (operator decision)

- **result_status = 'success' only.** `completeRequest` is reached only on a normal
  completion (incl. graceful cache/refusal). Provider failures + timeouts early-return
  503/504 BEFORE completion, so they write NO stats row. Effect downstream (P2 LEFT JOIN):
  failed/timed-out LLM requests still appear (from the base `proxy_requests` row) but with
  null rich stats and the derived `unknown` status — not real `error`/`timeout`. The table +
  code already support `error`/`timeout`; recording them is a clean additive follow-up
  (P1b.2) touching the 503/504 bail paths. Agent correctly flagged rather than widened scope.

## Observations (non-blocking)

- service_role retains full DML on the table (from P1a'); P1b only INSERTs. Optional future
  least-privilege tightening.

On approval: merge, then `tool/verify_pr_landed.sh 1291 proxy_request_stats ProxyRequestStats`.
