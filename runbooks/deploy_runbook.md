# Deploy Framework

Status: Active
Last updated: 2026-05-08

This framework is the repeatable guide for deploying or redeploying Forge &
Flow end to end so the mobile app, operator web console, admin console, proxy,
database, secrets, auth, CORS, background workers, and observability surfaces
are all using compatible revisions.

Use it when a prompt mentions deploy, redeploy, preview, staging, production,
Cloud Run, proxy, admin console, operator web, mobile, Firebase auth,
Postgres, CORS, health checks, smoke tests, rollback, "end to end", or "make
sure everything is up to date."

## Core Promise

A deploy is not complete when Cloud Run says "ready."

A deploy is complete when the current branch, built artifacts, deployed
revisions, runtime env vars, secrets, database mode, browser/mobile clients,
auth state, CORS origins, route smoke tests, background-worker posture, health
signals, and rollback path all agree.

Every deploy pass follows this order:

1. Confirm source branch, source commit, target environment, and data mode.
2. Confirm what is allowed to mutate in the target environment.
3. Inspect pending migrations, required secrets, service accounts, and CORS
   origins before deploying.
4. Check database connection budget before starting a proxy deploy.
5. Deploy backend/proxy first, then deploy clients against that proxy URL.
6. Verify cheap readiness before deep dependency health.
7. Verify browser/mobile routes from the real deployed origins.
8. Verify auth, role, permission, tenant, and forbidden-state behavior.
9. Verify background workers/listeners are either intentionally running or
   intentionally deferred.
10. Record source commit, revisions, URLs, traffic, database mode, tests,
    smoke results, residual risks, and rollback command.

## Golden Rule

Deploy the communication graph, not just the service.

The app stack works only when every edge is current:

- admin console -> proxy
- operator web -> proxy
- mobile app -> proxy/Firebase/Auth links
- proxy -> Postgres
- proxy -> Firebase Admin / Identity Toolkit
- proxy -> Secret Manager / KMS
- proxy -> provider credentials and webhooks
- proxy -> background workers, outboxes, audit anchors, and health producers

If one edge still points at an old URL, old revision, stale service worker,
wrong secret namespace, missing migration, or exhausted database pool, the
deploy is not done.

## Hard Boundaries

Allowed:

- Deploy preview and staging services using repo scripts.
- Shift Cloud Run traffic to a healthy target revision.
- Cap preview/staging max instances to protect Postgres.
- Use `/readyz` for cheap liveness/startup verification.
- Use `/health` as a deep dependency signal after startup is healthy.
- Run read-only smoke tests against staging data.
- Run approved mutation smokes when action-time approval exists.
- Roll back Cloud Run traffic to a previously ready revision.
- Document intentionally deferred or unsurfaced backend capabilities.

Not allowed without explicit approval:

- Deploying production.
- Applying production migrations.
- Pointing preview at production secrets.
- Running writes against staging secrets without exact action-time approval.
- Running aggressive load tests.
- Terminating database sessions without confirming exact stale PIDs.
- Changing billing, provider credentials, Firebase auth domains, feature
  flags, or Cloud Armor enforcement as a side effect of a deploy.
- Treating `/` proxy 404 as a deploy failure. The proxy root is not the app.

## Intake Checklist

Before deploying, answer:

1. Which branch and commit are being deployed?
2. Is the worktree clean except for known unrelated files?
3. Which environment is the target: preview, shared staging, or production?
4. Which secret prefix is in use?
5. Is the target database shared staging data or isolated preview data?
6. Are writes allowed? If yes, which exact actions are approved?
7. Which services are in scope: proxy, admin console, operator web, mobile,
   workers, jobs, webhooks?
8. Which migrations are required and already applied?
9. Which origins must be in CORS?
10. What is the rollback revision for each Cloud Run service?

If any answer is unknown, discover it before deploying.

## Preflight Matrix

Capture this before changing traffic:

| Area | Required check |
| --- | --- |
| Source | `git status --short`, branch, HEAD, `origin/master` |
| Scripts | correct deploy script and target service names |
| Secrets | secret prefix, required secret names, no values logged |
| Database | data mode, migration state, connection budget |
| CORS | admin, operator, Firebase auth action hosts, local dev if needed |
| Auth | Firebase project, action domain, service-principal secret |
| Scale | min instances, max instances, old + new revision overlap |
| Health | `/readyz` for startup, `/health` for deep dependencies |
| Clients | admin/operator proxy base URI and cache-bust URL |
| Safety | write approval, rollback revision, cleanup owner |

## Database And Startup Rule

Cloud Run deploys can temporarily run old and new revisions at the same time.
That means database connections can double during rollout.

Before proxy deploy:

1. Know max instances for the old serving revision.
2. Know max instances for the new revision.
3. Know per-instance Postgres pool size.
4. Include background listeners and workers in the connection count.
5. Compare old + new worst-case connections against Postgres capacity.

If the target is preview/staging and Postgres is already near the connection
limit, use the preview DB-safe startup posture:

If the target branch does not yet include these deploy switches, stop and land
the proxy deferred-startup fix first. Do not improvise a DB-heavy proxy deploy
into a saturated database.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName <preview-name> `
  -DeferProxyStartupDatabase `
  -ProxyMaxInstances 1 `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

For a direct preview/staging proxy deploy:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_staging_proxy.ps1 `
  -Service <proxy-service> `
  -ProxyEnvironment <non-prod-env> `
  -DeferStartupDatabase `
  -MaxInstances 1 `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

Deferred startup is not production mode. It allows HTTP to bind without
startup-only DB checks and background consumers. Route-level DB access remains
real and can still fail normally if Postgres is unavailable.

## Deploy Order

### Preview

1. Fetch latest `origin/master`.
2. Create or confirm a separate worktree and branch.
3. Confirm branch, status, diff, and source commit.
4. Confirm secret prefix:
   - `forge-flow-staging-`: runtime-isolated preview, read-only by default.
   - `forge-flow-preview-`: data-isolated preview if provisioned.
5. Deploy preview proxy.
6. Capture proxy URL, revision, traffic, image digest, env vars, max instances,
   and database mode.
7. Deploy admin console with the preview proxy URL.
8. Deploy operator web with the preview proxy URL.
9. Redeploy proxy CORS if client origins changed.
10. Hard refresh clients with cache-bust URLs.
11. Run route, auth, CORS, UI, and performance smokes.
12. Record evidence under `docs/_execution/`.

### Shared Staging

1. Promote only after preview proof is recorded.
2. Confirm no unintended writes are queued against staging secrets.
3. Deploy proxy first.
4. Deploy admin console and operator web against the staging proxy URL.
5. Verify Cloud Run traffic is 100 percent on latest ready revisions.
6. Verify `/readyz`, then `/health`.
7. Run staging console and operator web Browser Use smokes.
8. Run the performance probe when the deployed surface changed.
9. Record revisions, URLs, source commits, and rollback revisions.

### Production

Production deploys are gated by production cutover runbooks. Do not use
preview-only deferred startup, staging secrets, demo auth, fixture data, or
readiness shortcuts in production.

Production requires:

- merged source on `master`
- production migration approval and evidence
- production secret namespace
- production Firebase auth domain and callback URI
- production CORS origins
- production rollback plan
- production smoke and monitoring owner

## Runtime Smoke Matrix

Every end-to-end deploy should verify:

| Surface | Smoke |
| --- | --- |
| Proxy liveness | `GET /readyz` returns 200 |
| Proxy root | `GET /` may return API 404; this is expected |
| Deep health | `GET /health` returns dependency truth, not startup truth |
| Admin CORS | OPTIONS from admin origin to admin routes returns 204 |
| Operator CORS | OPTIONS from operator origin to `/v1/auth/*` returns 204 |
| Auth no-token | protected routes return 401, not 503 |
| Forbidden role | known forbidden user returns 403 where expected |
| Admin console | shell loads, configured proxy URL is current |
| Operator web | shell loads, configured proxy URL is current |
| Mobile | installed build points at correct backend/auth config |
| Mutations | disabled or confirmed unless approval exists |
| Background work | workers/listeners running or documented as deferred |
| Browser cache | cache-bust URL or hard refresh proves fresh assets |

## Console And Mobile Proof

Use this framework with:

- `runbooks/mobile_web_console_e2e_runbook.md`
- `runbooks/performance_audit_runbook.md`
- `runbooks/ux_adjustment_runbook.md`

Minimum web proof:

- page title and shell load
- auth state
- primary navigation
- one protected route
- one forbidden route if possible
- one safe refresh/filter/search path
- console/network errors

Minimum mobile proof:

- installed build identifier
- Firebase/Auth config
- login or approved auth path
- backend/proxy route reachability
- notification/deep-link behavior only where safely testable

## Rollback

Before deploying, capture the currently serving revisions:

```powershell
gcloud run services describe <service> `
  --project <project> `
  --region <region> `
  --format "value(status.traffic[0].revisionName,status.traffic[0].percent)"
```

Rollback traffic:

```powershell
gcloud run services update-traffic <service> `
  --project <project> `
  --region <region> `
  --to-revisions <previous-ready-revision>=100
```

After rollback, rerun `/readyz`, CORS preflights, auth no-token smoke, and the
client shell load.

## Troubleshooting Guide

| Symptom | Most likely meaning | First check |
| --- | --- | --- |
| Proxy `/` returns 404 JSON | API root has no route | Check `/readyz` |
| New revision never ready | startup did not bind port | Cloud Run logs for startup failure |
| `53300 remaining connection slots` | Postgres saturated | old + new revision overlap and pools |
| CORS error in browser | origin missing or stale client origin | OPTIONS from exact deployed origin |
| Browser still hits old proxy | stale web asset/service worker | cache-bust and inspect built env |
| `/health` 503 but `/readyz` 200 | dependency is red, startup is ok | inspect health envelope |
| protected route 503 | route dependency unavailable | route logs and Postgres health |
| protected route 401 | auth missing/invalid | token and Firebase project |
| protected route 403 | auth ok, permission/scope denied | role, operator, location scope |

## Evidence Template

Every deploy execution note should include:

- branch and source commit
- PR number if available
- deploy command or script
- environment and secret prefix
- database mode and write posture
- proxy URL, revision, image digest, traffic split
- admin URL, revision, traffic split
- operator web URL, revision, traffic split
- mobile build identifier if in scope
- CORS origins
- `/readyz` result
- `/health` result or reason skipped
- auth/forbidden smoke results
- Browser Use or mobile evidence
- performance probe JSON path if required
- background worker posture
- rollback revision and command
- bugs found and fixed
- intentionally deferred, gated, or unsurfaced items
- residual risks

## Closeout

A deploy can be called complete only when:

- the serving revisions match the intended source
- all required clients point at the intended proxy
- readiness and route-level smoke tests pass
- background worker posture is explicit
- rollback is known
- evidence is committed or linked
- any remaining red/yellow signal is named and owned
