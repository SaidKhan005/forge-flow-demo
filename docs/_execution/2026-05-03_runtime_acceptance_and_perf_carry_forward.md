# 2026-05-03 Runtime Acceptance And Performance Carry-Forward

Status: Active reference
Last updated: 2026-05-03
Canonical contract: `docs/contracts/slice_runtime_acceptance_contract.md`

This note preserves the execution-report detail that should not live in
`PROJECT_TRACKER.md` or `CLAUDE.md`. The tracker stays as the routing map; this
file holds the evidence and carry-forward lessons.

## Executive Summary

Future slices must be accepted as end-to-end system slices:

1. Branch code exists.
2. Build context includes runtime files.
3. Deployed image/storage contains those files.
4. Live route works from the real browser origin.
5. Health reflects real producer state.
6. Runbooks explain yellow/red recovery.
7. Migration/docs drift is scanned after schema changes.

Performance lesson:

Do not let expensive truth become automatic UI refresh. Cheap readiness stays
separate from deep diagnostics; expensive checks are manual, confirmed, scoped,
deferred, queued, paginated, or measured.

## Staging Runtime Remediation Facts

- Corpus -> Graph candidates 503 was a packaging miss, not a route bug. The
  backend route was valid, but sanitized candidate files were absent from the
  deployed advisor proxy image.
- Branch fix packages
  `tool/advisor_proxy/graphify_candidates/candidates/*` into
  `/app/graphify-out/candidates`, the Cloud Run path read by
  `RepositoryGraphCandidatesProxyGateway`.
- Raw `graphify-out/graph.json`, cache, and converted source files remain
  ignored and must not be committed.
- `audit_chain_lag_seconds` was a real producer/ops-data gap, not future admin
  UI wiring.
- After action-time approval, staging Cloud Run execution
  `forge-flow-audit-anchor-zmsvj` resolved one staging operator, anchored the
  2026-05-02 chain, and made `audit_chain_lag_seconds` green.
- Overall staging health remained yellow because other producer/ops-data
  signals were still outside that branch's requested fixes.

Canonical runbooks:

- `runbooks/audit_anchor_cloudrun_deploy_runbook.md`
- `runbooks/audit_chain_verify_runbook.md`
- `runbooks/admin_provider_credentials_kms_rollout_runbook.md`
- `runbooks/admin_console_browser_qa_runbook.md`

## Staging Performance Branch Facts

Branch/PR:

- Branch: `codex/staging-perf-audit`
- PR: #68

Tested deployed admin URL:

- `https://forge-flow-admin-console-rf7nosnoka-pd.a.run.app`
- Latest redeploy: `forge-flow-admin-console-00004-6xw`
- Latest image tag: `20260503033441`
- Prior measured baseline: `forge-flow-admin-console-00003-shn`
- Prior image tag: `20260503025703`

Tested local browser-served audit URL:

- `http://127.0.0.1:7362/?audit=after`

Tested proxy URL:

- `https://forge-flow-staging-proxy-rf7nosnoka-pd.a.run.app`
- Proxy revision: `forge-flow-staging-proxy-00051-7x5`
- Proxy digest:
  `sha256:f4dbd6c7a95c1efeb74322c8ae65655341e762dabb96244d1b037de02cecc668`

Observed changes:

- Graph candidates fetch is deferred until the Graph candidates tab is visited.
- Overlapping `/health` polls are prevented.
- Health became a manual confirmed diagnostic; opening the Health screen does
  not call `/health`.
- The operator sees a read-only check warning that staging dependencies can
  take 15-30+ seconds before choosing to run the check.
- Live browser-served smoke after redeploy loaded the staging sign-in screen
  from `00004-6xw` with HTTP 200, no console errors, no failed requests, and
  zero `/health` requests before sign-in.

Safe staging load results:

- Admin index c4 p95: `330.4ms`
- Gzip `main.dart.js` c4 p95: `978.9ms`
- Gzip transfer: `995111` bytes
- Proxy `/readyz` c4 p95: `171.3ms`
- Proxy `/health` was intentionally not escalated after c1/c2 showed real
  instability/timeouts:
  - c1 p50 `14575.6ms`, 60% non-green
  - c2 p50 `20479.4ms`, 83.3% non-green

Repeatable performance script:

```powershell
dart run tool/perf_gate/staging_console_probe.dart --run --admin-url=<url> --proxy-url=<url>
```

Release/PR gates should add:

```powershell
--enforce-budgets
```

Use `--include-health` only for a deliberate, bounded health probe. Do not
mask red/yellow `/health` producer state as a frontend performance fix.

Current starting guardrails:

- Admin index p95 <= `750ms`
- `main.dart.js` gzip p95 <= `1500ms`
- `main.dart.js` gzip transfer <= `1.25MB`
- Proxy `/readyz` p95 <= `500ms`

Post-manual-health redeploy verification at `2026-05-03T03:41:29Z`:

- Admin index c4 p95: `184.1ms`
- `main.dart.js` gzip c4 p95: `1191.1ms`
- `main.dart.js` gzip transfer: `995566` bytes
- Proxy `/readyz` c4 p95: `238.8ms`
- Default probe error rate: `0%`

Open evidence:

- Authenticated screen/action timing remains pending explicit
  credential-send approval in the in-app browser.

## Migration Drift Scanner

After any slice adds or changes `db/migrations/*.sql`, run:

```powershell
dart run tool/migration_drift_scanner.dart --fix --strict-docs
dart run tool/migration_cutoff_lint.dart
```

The scanner compares the newest migration with the staging setup cutoff, can
update `scripts/postgres_staging_setup.ps1`, writes
`build/reports/migration_drift_report.md`, and flags watched authority docs
that still need manual queue/count wording refresh. The cutoff lint remains
the hard gate.

Current clean state verified on 2026-05-03:

- Latest migration:
  `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`
- Staging setup cutoff:
  `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`
- Production1 apply state: completed 2026-05-03 for 27 migrations,
  `202604280014` through `202605021900`; future migrations after this cutoff
  belong to a later apply event.

## Phase Carry-Forward

- Production1 and B43: the queued migrations are applied; before corpus or
  runtime deploy, re-run drift/schema verification, then do not close audit
  health until production anchor lag is green or explicitly deferred.
- 11A: debug, observability, replay, provider usage, status, and health
  surfaces must be filtered, paginated, scoped, and manually refreshed when
  checks are expensive. Unknown metrics stay neutral; populated bad metrics
  degrade health.
- 10a: `NOTIFY` is only a wake-up signal. Durable truth comes from
  `event_outbox`; protect replay, reconnect, dead-letter, retention, and
  duplicate polling.
- 10.5: daypart is additive to whole-day truth. Watch timezone, business-date,
  DST, late-night, boundary tie-break, correction replay, and non-service gaps.
- 7.58/7.61: unknown driver keys stay explicit unavailable/degraded states,
  not silent safe defaults.
- 8/8R/8.5: vendor adapters are canonical producers. Require stable source
  ids, idempotency, correction handling, timezone normalization, privacy
  readiness, capped backfills, bad-record quarantine, and visible freshness.
- 11b: advisor work should be explicit, cached where allowed, circuit-broken,
  operator-scoped, measured, provenance-backed, bounded, and refusal-aware.
  Use approved graph tables only.
- 12: workflows stay disabled by default until approvals, caps, idempotency,
  audit logs, artifact storage, Cloud Run jobs, and throttled pollers are
  proven. Irreversible actions require explicit consent.
- 9.5/9.75: staff views must not load manager/admin data by accident; local
  identity assumptions must not leak into production paths.
- 9.8: legal text, T&C acceptance, privacy views, GDPR flows, processor chain,
  and re-acceptance gates must be real before customer-data cutover.
- Production cutover: verify deployed production state, migrations, packaged
  artifacts, health producers, provider approvals, rollback, CORS, auth roles,
  graph corpus, legal gates, performance gate, smoke tests, revision identity,
  and stability watch.

## Slice Prompt Checklist

Before implementing a runtime-exposed slice, answer:

1. What runtime files or data must exist after deployment?
2. Which migration or producer makes the behavior real?
3. What health metric proves it is working?
4. What browser origin will QA use?
5. What failure should the user/admin see?
6. What runbook fixes the failure?
7. What performance guardrail prevents accidental load?
8. What docs/tracker lines must be updated before acceptance?
