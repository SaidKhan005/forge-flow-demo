# Hardening — Observability Baseline Contract

> **Status (2026-05-02):** Closed. Shipped commit `6a955b0` (PR #48).
> Contract is retained as historical authority. Voyage and Secret Manager
> per-call timeouts were not landed as explicit constants in this slice;
> Postgres acquire fail-closed at boot covers the DB blast radius. Any
> future tightening is a delta against this contract, not an open item.


Updated: 2026-05-02
Owner: HARD-G (observability sprint)
Status: Active authority

## Why This Exists

Today's proxy emits unstructured stdout, has no correlation IDs, no
outbound-call timeouts on Postgres / Firebase / HIBP, no documented
rollback procedure, and the KMS lane router silently falls back to a
stub when `GCP_PROJECT_ID` is unset in production. This contract sets
the *baseline* — enough observability and reliability discipline to
diagnose, time-bound, and recover from incidents pre-launch. Full
OpenTelemetry, Prometheus, dashboards, and alert rules ride later
phases (E.2).

Handoff between:

- `tool/advisor_proxy/main.dart` — startup diagnostic block, log emission.
- `tool/advisor_proxy/proxy_bootstrap.dart` — KMS lane router, outbound
  client initialization.
- `lib/infrastructure/persistence/postgres/` — Postgres client timeouts.
- `lib/services/auth/password_change_gateway.dart` — HIBP fetch timeout.
- `docs/runbooks/proxy_rollback_runbook.md` — new file.

Disagreement rule: this contract wins for log shape, correlation ID
header name, timeout values, and KMS startup behavior.

## In Scope

| Item | In | Out |
|------|-----|-----|
| Structured (JSON) logs with correlation IDs | yes | log shipping/sink (Cloud Logging picks up stdout) |
| Outbound timeouts on Postgres, Firebase, HIBP | yes | retry/backoff strategy (later phase) |
| KMS startup misconfig warning + fail-closed in prod | yes | KMS rotation procedures |
| Rollback runbook documenting Cloud Run revision + DB | yes | automated rollback tooling |

Out of scope: `/metrics` Prometheus endpoint, OpenTelemetry traces,
Cloud Monitoring alert rules, dashboards, log-based metrics, error-tracking
SaaS — all Phase E.2.

## Required — Structured Logging

A new module `tool/advisor_proxy/log.dart` (or equivalent) exposes:

- `log(level, event, fields)` — emits one JSON object per call to stdout.
- Required envelope fields:

```json
{
  "ts": "2026-05-02T...Z",        // RFC3339 UTC
  "severity": "INFO|WARN|ERROR",  // Cloud Logging severity
  "event": "request.complete",    // dotted lowercase
  "correlation_id": "uuid-v4",    // from request header or generated
  "request_id": "uuid-v4",        // per request
  "operator_id": "<uuid>|null",   // when bound
  "fields": { ... }               // event-specific, sanitized
}
```

- `correlation_id` is read from the `X-Correlation-Id` request header if
  present and well-formed (UUID v4); otherwise generated.
- Returned to the client in the same response header.
- Every `routeRequest` invocation creates a `request_id`. Both IDs thread
  through to outbound LLM, Postgres, Firebase, and HIBP calls (added to
  client `User-Agent` for LLM and Firebase; logged for Postgres/HIBP).

Sensitive fields **never** logged: passwords, recovery codes, raw
prompts, raw vendor payloads beyond status code, JWT bodies, TOTP
secrets, MFA codes, full email addresses (use sha256 hash if needed).

`startup` events emit at boot:

- `startup.config_resolved` (one line per major bound, e.g.
  `firebase: live`, `postgres: live`, `gemini_slot_enabled: false`).
- `startup.complete` once `routeRequest` is wired.
- `startup.failed` on any bootstrap error, with exit code.

Replace existing `stdout.writeln(...)` and `stderr.writeln(...)` calls in
`main.dart` and proxy paths with the new log call. Plain text remains
acceptable for human-readable startup banner before JSON logging is
initialized; once initialized, all events go through the log module.

## Required — Outbound Timeouts

Every outbound I/O call must wrap in `.timeout(Duration)`. Defaults:

| Surface | Timeout | Action on timeout |
|---------|---------|-------------------|
| Postgres query (per statement) | 5 s | rethrow as `dependency_timeout`; log `severity: ERROR` |
| Postgres acquire-connection | 10 s | exit 78 at startup; rethrow at request time |
| Firebase admin SDK (verify, mint) | 10 s | rethrow as `dependency_timeout`; log |
| HIBP (password breach check) | 15 s | treat as `unknown` (fail-open for password check; current behavior) |
| Anthropic | already enforced (30 s, see existing) | unchanged |
| Voyage embed/rerank | 20 s | rethrow as `dependency_timeout` |
| GCP Secret Manager | 10 s | exit 78 at startup |

Configuration values live in `lib/infrastructure/persistence/postgres/postgres_executor.dart`
(Postgres) and per-client init sites (Firebase, HIBP, Voyage). Default
values are constants in code; future tuning rides config injection.

Timeouts that elapse during a request emit a `request.dependency_timeout`
log event with `surface`, `operation`, and `elapsed_ms` fields. The
response returned to the client follows the existing error envelope
shape with `error: "dependency_timeout"`.

## Required — KMS Startup Behavior

Replace the current silent stub fallback at
`tool/advisor_proxy/proxy_bootstrap.dart:2650`:

When building `KmsProvider`, read `PROXY_ENVIRONMENT`:

- If `PROXY_ENVIRONMENT == 'prod'`:
  - All three of `GCP_PROJECT_ID`, `CLOUD_RUN_REGION`,
    `CLOUD_RUN_SERVICE_NAME` must be set, AND a feature flag
    `kms_real_provider_enabled` must be `true`.
  - Otherwise: log `severity: ERROR`, `event: startup.kms_misconfigured`,
    `fields: {missing: [...]}`, and **exit 78**.
- If `PROXY_ENVIRONMENT == 'staging'` or `'dev'`:
  - Missing vars → log `severity: WARN`,
    `event: startup.kms_stub_active` and continue with stub provider
    (current scaffold behavior preserved for non-prod).

Document this gating in
`docs/contracts/hardening_production_wiring_contract.md` if cross-cut is
needed; this contract owns the KMS-specific check.

## Required — Rollback Runbook

New file: `docs/runbooks/proxy_rollback_runbook.md`. Required sections:

1. **When to rollback** — symptom triage (5xx spike, audit-chain hash
   mismatch, breaker-open sustained, login lockout false positives).
2. **Cloud Run revision rollback** — `gcloud run services
   update-traffic <service> --to-revisions <PREV>=100` with prereqs and
   how to find the prior revision.
3. **Feature flag rollback** — toggling kill-switch flags
   (`audit_logs_cutover_enabled`, `kms_real_provider_enabled`,
   `cache_telemetry_v2`, `gemini_secondary_enabled`) to disable
   recently-promoted behavior without revision rollback.
4. **DB migration rollback boundaries** — `pg_partman` retention,
   `audit_chain_anchors` immutability, the ~14-day rollback window;
   when a migration is *not* rollback-safe and requires forward fix.
5. **Anchor verification** — quick sanity script (or pointer to
   `tool/audit_anchor/verify`) to confirm chain integrity post-rollback.
6. **Communication** — who to ping, where to file the post-mortem.

Length cap: 200 lines. The runbook references existing source files;
it does not duplicate code.

## Out of Scope

- `/metrics` Prometheus endpoint — Phase E.2.
- OpenTelemetry trace export — Phase E.2.
- Alert rules in Cloud Monitoring — Phase E.2.
- Dashboards — Phase E.2.
- Error-tracking SaaS (Sentry, Rollbar) — post-launch.
- Synthetic uptime probes — post-launch.

## Test Surface

- Unit tests for `log` module:
  - JSON envelope shape, severity mapping, sensitive-field redaction.
  - Correlation ID propagation: header-in → field-in → header-out.
- Test that startup with `PROXY_ENVIRONMENT=prod` and missing GCP vars
  exits 78 with the required event.
- Test that staging with missing GCP vars still starts and logs
  `startup.kms_stub_active`.
- Tests asserting timeouts fire on simulated slow Postgres/Firebase/HIBP
  (mock with `Future.delayed`).
- `dart analyze --fatal-infos`.
- Runbook exists at `docs/runbooks/proxy_rollback_runbook.md` and links
  resolve.

## Codex Acceptance

- [ ] All proxy `stdout.writeln` / `stderr.writeln` (after startup banner)
      replaced with `log()` calls.
- [ ] `X-Correlation-Id` header read in and echoed out; generated when missing.
- [ ] Each outbound surface listed has explicit `.timeout(Duration)`.
- [ ] Postgres acquire timeout yields exit 78 at startup.
- [ ] `PROXY_ENVIRONMENT=prod` + missing GCP vars + KMS flag enabled →
      exit 78 with correct event.
- [ ] Sensitive fields never appear in any log line (test asserts).
- [ ] `docs/runbooks/proxy_rollback_runbook.md` exists with all six
      sections.
- [ ] All listed tests pass; `dart analyze --fatal-infos` clean.
