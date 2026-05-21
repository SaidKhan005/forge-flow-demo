# p5_email_scenario_loopback — email-scenario inventory loopback

**Runner:** `test/pressure/p5_email_scenario_loopback_test.dart`
(unit tests for `tool/pressure/p5_email_scenario_loopback.dart` —
Slice C-11)

**What it pressures:** the email-template scenario harness that drives
every wired notification template through a Mailosaur loopback and
catches deferred / firebase-managed paths without touching the network.
Catches regressions in subject/body matching, p95 latency math, the
inventory split (wired vs deferred vs firebase-managed), the env-gated
inert behavior when Mailosaur creds are absent, and the URL allow-list.

**Status at f0bf2702:** PASS. Hermetic unit tests; live Mailosaur
loopback is operator-driven separately.

## Inputs

- Harness env vars (read by `runEmailLoopback`):
  - `MAILOSAUR_API_KEY` (required for live loopback)
  - `MAILOSAUR_SERVER_ID` (required for live loopback)
  - `PROXY_URL` (optional; must pass `validateProxyUrl` allow-list)
  - `PROXY_ADMIN_TOKEN` (paired with PROXY_URL)
- CLI flag: `--output=<path>` writes a JSONL findings file.
- Tests use a `_ThrowingHttpClient` to prove the harness never opens
  a socket when every scenario resolves to deferred.

## What it asserts

- `subjectMatches` / `bodyMatches`: substring match across html or
  text body; empty needle list returns true; partial hit fails.
- `p95LatencyMs`: empty → 0; single → that sample; N samples → ceil-
  index percentile; unsorted input is sorted first.
- `buildSummary`: counts by outcome kind (success / deferred / failed /
  timeout) + computes p95 over success-only latencies.
- `buildScenarioLine` shape per outcome kind (`status`, `latency_ms`,
  `subject_match`, `body_match`, `reason`, `error`).
- `validateProxyUrl`: accepts preview / staging / localhost; refuses
  `app.forgeflow.app` (production) with a "production" reason string.
- `runEmailLoopback` env-gated inert: missing `MAILOSAUR_API_KEY` or
  `MAILOSAUR_SERVER_ID` → ONE `email_loopback.skipped` line, exit 0,
  never hits HTTP.
- Production-looking `PROXY_URL` → exit 2.
- `emailLoopbackInventory`: contains `operator_invite_first_admin`
  (wired); flags 3 remaining C-2 deferred drafts
  (`mfa_factor_changed_notice`, `vendor_sync_error_alert`,
  `vendor_connection_auto_disabled`); does NOT contain the C-2-Del
  deletions; B3 fanout surfaces (`backfill_complete`,
  `backfill_failed`, `audit_anchor_failure`, `vendor_now_available`)
  are wired; `firebase_*` entries flagged as firebase-managed.

## How to read the output

- Healthy hermetic run: all tests pass; emitted log lines decode
  cleanly; no real socket opened in the deferred-only path.
- Regression: any inventory drift (added / removed template) without
  updating the test's pinning expectations means the C-2 inventory
  matrix is out of sync with the harness; URL allow-list relaxation
  silently breaks the production-guard.
- Operator-driven full run writes a per-invocation JSONL to the
  `--output=` path; no committed findings file in-tree.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10; `docs/_audits/code_health/c_email_notification_scenario_inventory.md`
- Production code: `tool/pressure/p5_email_scenario_loopback.dart`
- Companion harness: `p5_push_delivery_proof_test.dart`
- Last touched: see `git log -- test/pressure/p5_email_scenario_loopback_test.dart`
