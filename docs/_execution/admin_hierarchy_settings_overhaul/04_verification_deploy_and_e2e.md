# 04 - Verification, Deploy, And E2E

## Test Gates

Minimum gates after the full implementation:

- `flutter analyze`
- Admin screen/gateway tests touched by each slice
- Proxy route tests for auth, hierarchy, members, roles, sessions, audit,
  timing, data accuracy, polling/pricing, integrations, health, and startup when
  touched
- Repository and migration tests for every schema change
- Operator web parity tests when shared settings behavior changes
- Release web builds for affected consoles
- Performance probe with JSON evidence and budgets enforced where applicable

## Mutation E2E Policy

The final Browser Use sweep must test mutating functionality, but the database
mode decides how:

- Data-isolated preview: perform the full approved mutation sweep.
- Runtime-isolated preview sharing staging secrets: create or use an explicit
  test business only after action-time approval, or stop with a clear blocked
  note.
- Production: never use for this overhaul verification.

Every mutation should prove:

- correct enabled/disabled state
- correct role gate
- confirmation copy
- audit reason if required
- idempotency key on write
- success state
- refresh/reload persistence
- audit/log evidence where routed

## Browser Use Checklist

Use fresh cache-bust preview URLs. Capture:

- page title and shell load
- auth state and forbidden state where possible
- Business Accounts selection
- hierarchy add/move/edit/supported lifecycle states
- Account profile edit
- People/access/roles
- Security/audit/sessions
- Support logs
- Timing
- Data accuracy
- Polling/pricing
- Integrations location-required behavior
- loading, empty, error, and disabled states
- filters/search and large scrolling
- repeated route switching
- console warning/error logs
- mobile viewport checks

## Performance Framework Checklist

Measure and fix:

- startup time and first usable console state
- duplicate proxy requests
- repeated route switching
- refresh behavior
- bounded list rendering
- polling/intervals
- hierarchy tree scrolling
- modal/scope prompt latency
- bundle/build regressions where relevant

Attach the performance JSON path in the PR comment and final execution note.

## Preview Deploy Notes

Follow `runbooks/preview_environment_runbook.md` and the deploy framework if it
exists under `docs/frameworks`.

When preview shares staging Postgres and connection pressure exists, deploy the
proxy with DB-safe startup mode:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName backend-surface-additions `
  -DeferProxyStartupDatabase `
  -ProxyMaxInstances 1 `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

Verify `/readyz` for startup liveness. `/health` is a deep dependency envelope
and may fail if dependencies are unavailable; do not use `/health` as the
startup pass/fail signal.

## Final Evidence Note

Create or update an execution note with:

- source commit(s)
- PR links and merge commits
- admin/operator web/proxy preview URLs
- database mode
- route-by-route Browser Use evidence
- mutation evidence and approval notes
- framework checklist results
- tests/builds/perf commands and outcomes
- performance JSON path
- bugs found/fixed
- intentionally gated or unsurfaced items
- residual risks
