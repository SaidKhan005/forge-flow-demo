# Audit — PR #1301: P2 join proxy_request_stats into the read projection

Date: 2026-05-24
PR: #1301 · branch `claude/support-logs-p2-read-projection` · base `master`
Slice: P2 (Support logs redesign §12 — read projection)
Category: **PROXY read-path → gated. Merge needs explicit operator approval.**
Changed: 5 files, +720/-22 — `proxy_bootstrap.dart` (+137/-22) + `RequestLogEntry` model (+57) + gateway (+29) + 2 test files (+519).

## Build provenance

Agent committed + pushed the branch but was interrupted at the PR-open step (no PR, no
completion report). Work was complete + pushed (safe). Orchestrator inspected the pushed
branch, independently verified, opened the PR, and audited.

## Verdict: CLEAN — approve-for-merge pending operator gate

## Reviewed (read the actual diff)

- **Projection JOIN** (both `_debugRequestProjectionSql` and `_debugRequestBaseSelect`):
  `LEFT JOIN public.proxy_request_stats prs ON (operator_id, location_id, request_id)` —
  the tenant-leading key, documented 1:1 (P1b idempotent).
- **Honest coalesce:** `status = coalesce(prs.result_status, <derived unknown/success>)`,
  `latency_ms = coalesce(prs.latency_ms, <derived row-lifetime>)` — prefers the REAL P1b
  values, falls back to the derived ledger values so the wire keys stay populated.
- **Honest nulls (Metric Honesty Doctrine):** new keys `provider` / `model_id` /
  `prompt_token_count` / `completion_token_count` / `cost_usd` / `actor_user_id` emitted ONLY
  when the stats row matched, via null-preserving `_adminIntOrNull` / `_adminDoubleOrNull` /
  `_adminStringOrNull` (never phantom 0). Failed / pre-P1b / non-LLM requests → null rich
  stats + derived `unknown` status.
- **actor_user_id returned as uuid only** — no users/roles JOIN, no PII stored; name/role
  resolution deferred to P3 (screen, via members lookup), as specified.
- `RequestLogEntry` carries the new nullable fields; `fromJson`/`toJson` round-trip omitting
  null keys; demo fixtures exercise both populated and null-telemetry paths.

## Independently verified

| Check | Result |
|---|---|
| `dart analyze` (models + gateway + proxy_bootstrap) | No issues |
| touched suites (`admin_debug_console_routes` + `debug_console_admin_gateway`) | 42 pass |
| scope | projection + route tests + model + gateway + demo only; NO screen/migration/write-path/users-join |
| GitHub mergeable | (confirm at merge) |

On approval: merge, then `tool/verify_pr_landed.sh 1301 proxy_request_stats`.
