# Audit — PR #1326: P1b.2 failure/timeout telemetry

Date: 2026-05-25
PR: #1326 · branch `claude/support-logs-p1b2-recover` · base `master`
Slice: P1b.2 (Support logs redesign §12 — failure/timeout telemetry follow-up)
Category: **PROXY hot-path → gated. Merge needs explicit operator approval.**
Changed: 5 files, +474/-18 — `tool/advisor_proxy/advisor_proxy.dart` + 4 test files.

## Build provenance (recovery)

The build agent was interrupted; the repo auto-janitor rescued its WIP to
`rescue/janitor/p1b2-failure-telemetry-20260525-042222`. The orchestrator materialized the
rescued files onto a clean worktree off current `origin/master`, independently verified, and
opened the PR. (Two false starts first: a leftover branch-name collision, then a `--stat`-
abbreviated wrong path — both resolved. `git diff` range views misbehaved due to line-ending
normalization, so verification was done by materializing + testing rather than diff-reading.)

## Verdict: CLEAN — approve-for-merge pending operator gate

## What it does
Adds `PostgresProxyAccountingStore.recordRequestStats(...)` — writes ONE `proxy_request_stats`
row with the given `result_status` in its OWN tenant transaction (the failure path never
reaches `completeRequest`'s transaction). Wired into the proxy failure/timeout 503/504 bail
paths: `result_status='error'`/`'timeout'`, measured latency, actor uid, usage_class,
honest-null model/tokens. The P1b success path is unchanged (still folded into the completion
transaction — no extra round-trip on the common path).

## Independently verified
| Check | Result |
|---|---|
| `dart analyze tool/advisor_proxy/advisor_proxy.dart` | No issues |
| proxy suites (`advisor_proxy_usage_and_migrations` + `advisor_proxy_http_and_admin_routes`) | 179+ pass |
| new test "P1b.2 — recordRequestStats writes the failure row in its OWN [tx] … error/timeout" | present + passing (asserts `result_status='error'`) |
| no silent revert | confirmed: `6ff95613` is an ancestor of master AND no master commit touched `advisor_proxy.dart` since it (the +120/-18 stat inflation was line-ending noise, not content) |
| scope | proxy + proxy tests only; no migration / screen / data-contract change |

## Observation (non-blocking)
The failure write uses a SEPARATE transaction (one extra DB write on the rarer failure path).
Acceptable: failures are uncommon and the request already paid for the LLM call; the common
success path keeps P1b's no-extra-round-trip. A future optimization could batch it, not needed.

On approval: merge, then `tool/verify_pr_landed.sh 1326 recordRequestStats`. After merge, the
`rescue/janitor/p1b2-…` branch can be deleted (work is now on the PR branch).
