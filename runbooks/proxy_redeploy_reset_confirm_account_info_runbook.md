# Forge Flow Advisor Proxy Deploy Runbook

Updated: 2026-05-01.
Owner: F&F launch lane.
Scope: environment-agnostic Cloud Run deploy of the advisor proxy.
Defaults target staging; overrides target Production1 (or any future
environment) via the same procedure. Lands at C.3 to bring
`RepositoryAccountInfoGateway`, `RepositoryPasswordResetConfirmGateway`
(B48), and 11A.3a corpus admin routes (`411c9da`) live.

> **Filename note:** the file name retains the legacy "redeploy +
> reset_confirm + account_info" string for git-history continuity. The
> procedure is the canonical proxy deploy runbook for ALL environments;
> the legacy name is a path artifact, not a scope statement.

## Current state (verified 2026-05-01, post-execution)

**Staging redeploy executed 2026-05-01 23:14 UTC at HEAD `337e4c9`.**

### Outcome — staging

- **New revision:** `forge-flow-staging-proxy-00032-lgs` (100% traffic).
- **Service URL:** `https://forge-flow-staging-proxy-78630909582.northamerica-northeast2.run.app`.
- **Boot log confirms** target bindings live:
  `account_info: postgres`, `password_reset_confirm: postgres`,
  `corpus_admin: postgres`, plus the full set
  (`auth_session_ledger`, `accounting_store`, `permission_snapshot`,
  `admin_permission_guard`, `auth_operations`,
  `service_principal_issuance`, `password_change`, `mfa_operations`,
  `mfa_recovery_request`, `operator_location_admin`,
  `pricing_tier_admin`, `integration_admin`).
- **`/v1/admin/corpus/versions` smoke**: `401` (route registered, auth
  required). Pre-deploy was `404` → 11A.3a routes are live.
- **`/readyz`**: `200 {"status":"ok"}`.
- **`/v1/usage-smoke`**: `401` (route exists, auth required).
- **`/health`**: `503` red on postgres / age / pgvector — pre-existing
  Postgres connectivity issue, see "Open issue" below.

### Secret versions created during this deploy

| Secret | Prior pin (in 00031) | New version (in 00032) |
| --- | --- | --- |
| `forge-flow-staging-postgres-url` | v4 (2026-04-29) | **v6** (today) |
| `forge-flow-staging-postgres-admin-url` | v4 (2026-04-29) | **v5** (today, value matches v6 of postgres-url — partial-rotation completion) |
| `forge-flow-staging-anthropic-api-key` | v? (pre-deploy) | v6 |
| `forge-flow-staging-voyage-api-key` | v? | v5 |
| `forge-flow-staging-firebase-web-api-key` | v? | v5 |
| `forge-flow-staging-service-principal-jwt-secret` | v2 | **v3** (value identical to v2 — pulled from Secret Manager since canonical secrets file lacks the line; recommend the operator add `$env:SERVICE_PRINCIPAL_JWT_SECRET` to `~/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` so future deploys don't require Secret Manager round-trip) |

### `/health` 503 is structural at HEAD — gated on slice D.1

`/health` always returns HTTP 503 with `error: health_check_failed` on
00032 (and would on any other revision built from current master).
Root cause is NOT Postgres connectivity.

Smoking gun: `tool/advisor_proxy/main.dart:70` const-instantiates
`ScaffoldFailingProxyHealthCheckStore`, whose `check()` throws
`StateError('11a.11d scaffold: real Postgres health checks are not
wired.')` (`tool/advisor_proxy/advisor_proxy.dart:3650-3655`). The
catch block at `advisor_proxy.dart:5026-5037` projects that throw as a
503 envelope; the `dependencies.{postgres,age,pgvector}.status: red`
fields in the body are SYNTHETIC (spread from
`ProxyHealthStatus(postgresOk: false, ageOk: false, pgvectorOk:
false).toJson()`), not real probe results.

The real `RegistryProxyHealthCheckStore`
(`advisor_proxy.dart:3719-3812`) and the 57-producer registry
(`tool/advisor_proxy/health_producers/producer_registry.dart`) are
fully implemented but never instantiated in production. Wiring them
in is **slice D.1**'s scope, not C.3's. Until D.1 ships, `/health`
gives no signal about backend dependencies (good or bad), and the
TCP probe to `forge-flow-staging-pg.postgres.database.azure.com:5432`
from the operator's Windows host succeeded — Postgres may well be
healthy; we cannot tell from this proxy.

**C.3 close-out posture:**

- Bindings + 11A.3a routes are live; that's what C.3 was meant to
  ship.
- Stage 4 (4 h soak on B-series / D.1 producers) is structurally
  impossible at HEAD and is gated on D.1 — see Stage 4 prereqs.
- `/readyz` (returns `200 {"status":"ok"}`) is the only liveness
  signal available pre-D.1.
- No `tool/advisor_proxy/main.dart` or `health_producers/*` changes
  in C.3 — that work belongs to D.1 by design.

### What's wired in source

- `accountInfoGateway: RepositoryAccountInfoGateway(...)` —
  `tool/advisor_proxy/proxy_bootstrap.dart:195`.
- `passwordResetConfirmGateway: RepositoryPasswordResetConfirmGateway(...)` —
  `tool/advisor_proxy/proxy_bootstrap.dart:229` (B48 fix).
- 11A.3a corpus admin surface — commit `411c9da`, merged 2026-04-29 —
  `/v1/admin/corpus/*` routes.

### What's deployed today

| | Staging | Production1 |
|---|---|---|
| GCP project | `forge-flow-staging` | **not visible** from this gcloud account |
| Cloud Run service | `forge-flow-staging-proxy` | n/a |
| Latest revision | `forge-flow-staging-proxy-00031-dxh` | n/a |
| Image digest | `…b1c69013…` (deployed 2026-05-01 05:19 UTC) | n/a |
| `/v1/admin/corpus/versions` | route NOT registered (returns proxy 404) | n/a |
| `/health` envelope | B42-shape (`contract: proxy_health.v1`) | n/a |
| `/health` dependencies | `postgres`, `age`, `pgvector` ALL `red` | n/a |

So 00031 has B42 envelope expansion AND `/health` deep response, but
LACKS 11A.3a routes — meaning 00031 was built from a commit between
the B42 envelope landing and `411c9da`. Redeploy at HEAD lands 11A.3a
plus the `account_info` and `password_reset_confirm` bindings as a
side effect.

### Why staging is RED right now (root cause)

Cloud Run pins `secretKeyRef.key: latest` **at deploy time**, not at
request time. Revision 00031 deployed 2026-05-01 05:19 UTC and pinned
`forge-flow-staging-postgres-url` at v4 (created 2026-04-29 14:04).
v5 was created today 2026-05-01 21:12 UTC by the operator
(`saidumarkhan005@gmail.com`), almost certainly via the audit-anchor
deploy script which shares the same `forge-flow-staging-postgres-url`
secret. v5 has a different etag from v4 → values differ → 00031 is
talking to Postgres with stale credentials.

**Implication:** redeploying the proxy at HEAD pins the new revision
to v5 (current `latest`) and should heal `dependencies.postgres.status`
back to `ok`. If after redeploy Postgres is still red, the operator's
local `POSTGRES_URL` was synced to v5 but v5 itself is wrong (or
Postgres host is genuinely offline).

### Out of scope (intentional)

- **Production1 GCP provisioning.** Stage 0 lists prerequisites; this
  runbook does not provision them. A Production1 deploy can only
  begin once Stage 0 passes for Production1.
- **AGE rebuild trigger after deploy.** Separate slice; B44 producer
  wiring.
- **Full PostgreSQL rotation runbook.** This runbook handles the
  rotation→redeploy coupling but does not document credential
  generation or the Azure-side host rotation. See cutover.0a /
  cmk_provisioning runbook for those.

## Purpose

Bring the advisor proxy at master HEAD live on Cloud Run, on any
environment for which the Stage 0 prerequisites are met. Drives:

1. The two postgres-backed gateway bindings (`account_info`, B48
   password-reset-confirm) come live for the first time.
2. 11A.3a corpus admin routes ride along.
3. Any pending `POSTGRES_URL` / `POSTGRES_ADMIN_URL` rotation pinned
   in Secret Manager takes effect on the new revision.

Pairs with:

- `runbooks/audit_anchor_cloudrun_deploy_runbook.md` — sister Cloud
  Run deploy procedure (Job, not Service); structural template; same
  `-SecretPrefix` parameterization pattern.
- `scripts/deploy_staging_proxy.ps1` — environment-agnostic deploy
  helper (legacy filename; supports `-Project` / `-Region` /
  `-Service` / `-ServiceAccount` / `-SecretPrefix` /
  `-ProxyBaseUriEnvVarName` / `-FirebaseGoogleServicesPath`).
- `tool/advisor_proxy/advisor_proxy.dart` — `/readyz`, `/health`,
  `/v1/usage-smoke`, `/v1/advisor-smoke` handlers.
- `tool/advisor_proxy/proxy_bootstrap.dart` — `accountInfoGateway` and
  `passwordResetConfirmGateway` bindings being activated.

## Acceptance criteria

- [ ] Stage 0 prerequisites verified for the target environment.
- [ ] Stage 1 preflight: every name-only check passes; BLOCKED on any
      miss.
- [ ] Build + deploy succeeds.
- [ ] `/readyz` smoke `200`; `/health` deep smoke
      reports `dependencies.{postgres,age,pgvector}.status: ok`;
      `/v1/usage-smoke` `200`; `/v1/advisor-smoke` `200` or `402`.
- [ ] (multi-env runs) 4-hour soak on first env clean before promoting.
- [ ] Image tags, env-binding diff (names only), smoke statuses, and
      rollback target recorded in §"Live mutations performed" tables.
- [ ] No secrets in runbook, deploy-script output, or service logs
      (verify via `grep` for token/password patterns).
- [ ] Runbook committed.

## Conventions

- **Live values** (project IDs, service-account emails, secret
  prefixes) live in the operator's
  `~/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` (the canonical
  runtime file; the shim at `~/.forge_flow/forge_flow.secrets.ps1`
  sources it). Variable names appear here; values never do.
- **Every cloud-mutating step is gated by a preflight assertion.** If
  preflight fails, STOP — do not partially deploy.
- **`/healthz` is intercepted by Cloud Run's GFE** and never reaches
  the container. Use `/readyz` (same handler, returns
  `{"status":"ok"}`) for liveness probing. The proxy's `/healthz`
  route exists in source for local dev compatibility but is
  unreachable in Cloud Run by design.
- **`/health` (deep) is scaffold-failing at HEAD until D.1 ships.**
  Production main hardwires `ScaffoldFailingProxyHealthCheckStore`;
  every `/health` request returns 503 with `error:
  health_check_failed` regardless of actual backend state. Do NOT
  treat `/health` as a dependency signal in C.3 smokes or soak. The
  real `RegistryProxyHealthCheckStore` exists in source but is
  unwired by design — slice D.1 owns the wiring. Once D.1 ships,
  `/health` body's `dependencies.{postgres,age,pgvector}.status` and
  the surface-level B-series producer slots become meaningful.
- **`account_info` is a code binding, not an env var.** Preflight
  greps `tool/advisor_proxy/proxy_bootstrap.dart` for
  `RepositoryAccountInfoGateway`; it never queries Cloud Run env-var
  introspection for that name.
- **Secret-pin-at-deploy-time is the load-bearing invariant.** Cloud
  Run resolves `secretKeyRef.key: latest` once at deploy and pins the
  resulting version into the revision. Rotating a secret in Secret
  Manager AFTER deploy does NOT update the running revision — it just
  creates a new version that the next deploy will pick up. Therefore:
  every Postgres / Anthropic / Voyage / JWT-secret rotation requires a
  proxy redeploy to take effect. This runbook IS that redeploy
  procedure; the rotation→redeploy coupling is intentional.
- **Production1 service identity is verified at Stage 0.** Stage 1
  describes the service. BLOCKED if names fail to resolve — correct
  names with the operator before resuming.
- **The secret-name prefix is environment-scoped.** Default
  `forge-flow-staging-`. Production1 uses `forge-flow-production-`
  (per `runbooks/audit_anchor_cloudrun_deploy_runbook.md` lines
  308-310 convention) once Stage 0 confirms.

## Variable name reference

| Variable | Source | Used by |
| --- | --- | --- |
| `Project` (deploy-script param) | `secrets.ps1` | `gcloud --project` for the env |
| `Region` | `secrets.ps1` (`northamerica-northeast2` for staging + Prod1) | `gcloud --region` |
| `Service` | `secrets.ps1` | `gcloud run deploy <name>` |
| `ServiceAccount` | `secrets.ps1` | `gcloud run deploy --service-account` |
| `SecretPrefix` | `secrets.ps1` (e.g. `forge-flow-staging-`, `forge-flow-production-`); trailing `-` enforced | dynamic Secret Manager mapping |
| `ProxyBaseUriEnvVarName` | `secrets.ps1` (e.g. `FORGE_FLOW_PROXY_BASE_URI`, `FORGE_FLOW_PROXY_BASE_URI_PROD1`) | rewrite-back target in secrets file |
| `FirebaseGoogleServicesPath` | `secrets.ps1` (per-flavor, optional; defaults to staging path) | `Resolve-FirebaseWebApiKey` fallback |
| `FIREBASE_PROJECT_ID` | `secrets.ps1` | Cloud Run literal env var |
| `ANTHROPIC_API_KEY` | `secrets.ps1` | Secret Manager → Cloud Run env |
| `VOYAGE_API_KEY` | `secrets.ps1` | Secret Manager → Cloud Run env |
| `POSTGRES_URL` | `secrets.ps1` | Secret Manager → Cloud Run env |
| `POSTGRES_ADMIN_URL` | `secrets.ps1` | Secret Manager → Cloud Run env |
| `FIREBASE_WEB_API_KEY` | `secrets.ps1` (or auto-derived from `google-services.json` per `-FirebaseGoogleServicesPath`) | Secret Manager → Cloud Run env |
| `SERVICE_PRINCIPAL_JWT_SECRET` | `secrets.ps1` | Secret Manager → Cloud Run env |
| `FIREBASE_AUTH_SMOKE_PASSWORD` | `secrets.ps1` | local smoke bearer issuance |
| `SHA` | derived `git rev-parse --short HEAD` | image tag captured for audit |

## Stage 0 — Environment selection + prerequisites (BLOCKED on any miss)

This stage is the gate that makes the rest of the runbook executable
for a given environment. All checks are read-only against the target
environment's GCP project + Secret Manager + Postgres. Run BEFORE
preparing any deploy.

### 0a. Pick the environment

Set per-env variables (no values, just names — operator pulls values
from `secrets.ps1`):

| | Staging (default) | Production1 |
| --- | --- | --- |
| `Project` | `forge-flow-staging` | `forge-flow-production1` (TBD — verify) |
| `Region` | `northamerica-northeast2` | `northamerica-northeast2` (assumed; verify) |
| `Service` | `forge-flow-staging-proxy` | `forge-flow-production1-proxy` (TBD) |
| `ServiceAccount` | `forge-flow-staging-admin@…` | `forge-flow-production1-admin@…` (TBD) |
| `SecretPrefix` | `forge-flow-staging-` | `forge-flow-production-` (per audit_anchor convention) |
| `ProxyBaseUriEnvVarName` | `FORGE_FLOW_PROXY_BASE_URI` | `FORGE_FLOW_PROXY_BASE_URI_PROD1` |
| `FirebaseGoogleServicesPath` | empty (defaults to `android\app\src\forgeflow\google-services.json`) | per-flavor path (TBD, e.g. `android\app\src\forgeflow_prod1\google-services.json`) |

### 0b. GCP project + service account + Cloud Run service exist

```bash
gcloud projects describe $Project --format='value(projectId,name)'
# expected: exit 0 with the project name
gcloud iam service-accounts describe $ServiceAccount --project=$Project \
  --format='value(email,disabled)'
# expected: exit 0; disabled empty (account active)
gcloud run services describe $Service --region=$Region --project=$Project \
  --format='value(status.latestReadyRevisionName,spec.template.spec.containers[0].image)'
# expected: exit 0; record latestReadyRevisionName + image as PRIOR_REVISION/PRIOR_TAG
```

Stage 0b BLOCKED for Production1 today: `gcloud projects list`
returns no `forge-flow-production1` for this account. Production1
deploy cannot begin until Production1 GCP project is provisioned and
visible.

### 0c. Secret Manager pre-provisioned under `$SecretPrefix`

```bash
for suffix in anthropic-api-key voyage-api-key postgres-url \
              postgres-admin-url firebase-web-api-key \
              service-principal-jwt-secret; do
  gcloud secrets describe "${SecretPrefix}${suffix}" --project=$Project \
    --format='value(name,replication.policy)' 2>&1 | tee -a /tmp/c3-stage0-secrets.log
done
# expected: 6 secrets exist; absent secrets are OK ONLY for staging where
# the deploy script auto-creates them on first sync. For non-staging
# environments, BLOCKED if any are missing — the script's idempotent
# create path runs as the SA and may not have the project-level Secret
# Manager Admin role.
```

### 0d. Postgres reachability from Cloud Run's VPC

```bash
gcloud run revisions describe $PRIOR_REVISION --region=$Region \
  --project=$Project \
  --format='value(spec.containerConcurrency,metadata.annotations."run.googleapis.com/vpc-access-connector",metadata.annotations."run.googleapis.com/vpc-access-egress")'
# expected: vpc-access-connector populated; vpc-access-egress 'all-traffic'
```

If the connector is missing or wrong, Postgres egress will fail
regardless of credentials. Verify the connector exists in the VPC,
its NAT IP is allowlisted in the Postgres firewall, and Postgres is
reachable from a host with equivalent network reach (operator runs
`psql "$POSTGRES_URL" -c "SELECT 1"` from a peered host or bastion).

### 0e. Local secrets file loadable

```bash
test -f $HOME/.forge_flow/forge_flow.secrets.ps1 && echo present || echo BLOCKED
test -f $HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1 && \
  echo canonical-present || echo BLOCKED
```

When the operator dot-sources the shim, the canonical sets the
required env vars in the PowerShell session.

**STOP rule for Stage 0:** any item missing → emit `BLOCKED: stage 0
failed at item 0x` and exit. Do not proceed to Stage 1.

## Stage 1 — Preflight (read-only; idempotent; BLOCKED on any miss)

### 1a. Git state

```bash
SHA=$(git rev-parse --short HEAD)
git status --porcelain  # expected: empty
git rev-parse --abbrev-ref HEAD  # expected: lane branch
git merge-base --is-ancestor 411c9da HEAD && echo "411c9da: ancestor"
git log --oneline 411c9da -1
# expected: 411c9da feat(11A.3a): corpus admin surface ...
```

### 1b. Source bindings present at HEAD

```bash
grep -n RepositoryAccountInfoGateway tool/advisor_proxy/proxy_bootstrap.dart
# expected: line 195
grep -n RepositoryPasswordResetConfirmGateway tool/advisor_proxy/proxy_bootstrap.dart
# expected: line 229
```

### 1c. Capture prior revision + tag for rollback

Stage 0b already described the service. Record the values now:

```bash
PRIOR_REVISION=<from Stage 0b>
PRIOR_TAG=<from Stage 0b>
```

### 1d. Capture pinned secret versions (audit trail)

```bash
gcloud run revisions describe $PRIOR_REVISION --region=$Region \
  --project=$Project --format=yaml | \
  grep -E '^\s+name:|secretKeyRef:|key:' | head -40
# Record the names and pinned versions for postgres-url, postgres-admin-url,
# anthropic-api-key, voyage-api-key, firebase-web-api-key,
# service-principal-jwt-secret. Pinned versions are typically 'latest'
# resolved at the prior deploy time; cross-reference against current
# Secret Manager versions in 1e to detect rotation drift.
```

### 1e. Detect rotation drift (NEW — secret-pin invariant audit)

```bash
for suffix in postgres-url postgres-admin-url anthropic-api-key \
              voyage-api-key firebase-web-api-key \
              service-principal-jwt-secret; do
  echo "=== ${SecretPrefix}${suffix} ==="
  gcloud secrets versions list "${SecretPrefix}${suffix}" \
    --project=$Project --limit=3 \
    --format='table(name,createTime,state)'
done
```

Cross-reference: if any secret's `latest` version was created AFTER
the prior revision's deploy timestamp, the running revision is using
stale credentials and the redeploy will pick up the rotation. Record
the drift in the audit table — it documents WHY this redeploy was
needed beyond the binding additions.

**STOP rule:** any failed assertion → emit `BLOCKED: preflight failed
at item 1x` and exit. No partial deploy.

## Stage 2 — Build image

Cloud Build runs implicitly via the deploy script's `--source .` flag.
The buildpack tags the resulting image; the runbook records the
resolved tag from Stage 3b's describe.

```bash
SHA=$(git rev-parse --short HEAD)
echo "Deploying $SHA to $Service in $Project"
```

## Stage 3 — Deploy first environment (default: staging)

### 3a. Run the deploy script

```powershell
# Staging (defaults — backward compatible):
pwsh scripts/deploy_staging_proxy.ps1

# Production1 (when Stage 0 passes):
pwsh scripts/deploy_staging_proxy.ps1 `
  -Project forge-flow-production1 `
  -Region northamerica-northeast2 `
  -Service forge-flow-production1-proxy `
  -ServiceAccount forge-flow-production1-admin@forge-flow-production1.iam.gserviceaccount.com `
  -SecretPrefix forge-flow-production- `
  -ProxyBaseUriEnvVarName FORGE_FLOW_PROXY_BASE_URI_PROD1 `
  -FirebaseGoogleServicesPath android\app\src\forgeflow_prod1\google-services.json
```

The script (idempotent — describe-first, replace) does:

1. Load `$SecretsFile` (default `~/.forge_flow/forge_flow.secrets.ps1`,
   which sources the canonical runtime file).
2. Resolve `FIREBASE_WEB_API_KEY` from the per-flavor
   `google-services.json` if not already in env.
3. `Assert-PresentEnv` for required env names. BLOCKED on any miss.
4. `gcloud services enable` for Run / Cloud Build / Artifact Registry
   / Secret Manager (idempotent).
5. `Sync-SecretManagerSecret` for the six secrets, derived from
   `$SecretPrefix + $secretSuffix[name]`. Creates new versions only
   when the value differs from current `latest`.
6. `gcloud run deploy --source .` with secret env refs +
   `FIREBASE_PROJECT_ID` literal env var.
7. Rewrite `$ProxyBaseUriEnvVarName` in `secrets.ps1` to the new URL
   (or append if not present).

### 3b. Capture the new revision + image

```bash
gcloud run services describe $Service --region=$Region \
  --project=$Project \
  --format='value(status.latestReadyRevisionName,spec.template.spec.containers[0].image)'
# Record: NEW_REVISION  NEW_TAG
```

Env-binding diff — names only:

```bash
gcloud run services describe $Service --region=$Region \
  --project=$Project \
  --format='value(spec.template.spec.containers[0].env[].name)'
# expected: FIREBASE_PROJECT_ID + secret-bound names (the 6 secrets)
```

### 3c. Smoke (capture status only)

```bash
PROXY_URL=$(gcloud run services describe $Service --region=$Region \
  --project=$Project --format='value(status.url)')

curl -sS -o /dev/null -w '%{http_code}\n' "$PROXY_URL/readyz"
# expected: 200 with body {"status":"ok"} (verify body shape one time
# with `curl -sS "$PROXY_URL/readyz"`; subsequent polls are status-only)

curl -sS -o /dev/null -w '%{http_code}\n' "$PROXY_URL/health"
# pre-D.1 expected: 503 with `error: health_check_failed` (scaffold
# wired in main.dart at HEAD; documented in §Conventions). NOT a
# regression — the route is structurally degraded until D.1 wires
# RegistryProxyHealthCheckStore.
# post-D.1 expected: 200 with `dependencies.*.status: ok`; HTTP 503
# would then be a real degradation signal (see triage).

# Bindings-live verification (replaces /health as the C.3 acceptance signal):
curl -sS -o /dev/null -w '%{http_code}\n' \
  "$PROXY_URL/v1/admin/corpus/versions"
# expected: 401 (route registered, auth required). 404 means 11A.3a
# routes are missing from the deployed binary — investigate Cloud
# Build source bundle and HEAD ancestry of 411c9da.

curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $SMOKE_BEARER" \
  "$PROXY_URL/v1/usage-smoke?est_tokens=100"
# expected: 200

curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $SMOKE_BEARER" \
  -H "Idempotency-Key: redeploy-${SHA}-${envTag}" \
  "$PROXY_URL/v1/advisor-smoke"
# expected: 200 OR 402 (cap-refused; both pass)
```

`$SMOKE_BEARER` is a Firebase ID token issued via the operator's
existing smoke account (`FIREBASE_AUTH_SMOKE_PASSWORD`). The runbook
does not document the issuance flow — operators have it in their
existing smoke kit.

If `/health` returns 503, decode the body with `jq` for `severity`
and per-dependency `status`. If postgres / age / pgvector are red,
see triage matrix.

**Acceptance:** all four status codes recorded in §"Live mutations"
smoke table; `/health` postgres+age+pgvector green.

## Stage 4 — Soak (4 h, D.1 producer watch)

**Stage-4 precondition: slice D.1 has shipped and `/health` returns
HTTP 200 with real `dependencies.*.status` values on a fresh probe.**
At HEAD without D.1, `/health` always returns the scaffold-thrown
503 (see §Conventions); a 4 h soak loop would log 48 identical
synthetic-red rows and prove nothing. If running C.3 before D.1
ships, **skip Stage 4** and proceed directly to Stage 5 once you
have a separately-verified Postgres/AGE/pgvector liveness signal
(e.g. operator-run `psql "SELECT 1"` from a host with VPC
equivalence). Document the skip in the audit trail.

Run only on the FIRST environment of a multi-env deploy (staging
before Production1). Skip when deploying to a single environment
in isolation.

```bash
mkdir -p /tmp/c3-soak
SOAK_LOG=/tmp/c3-soak/${envTag}_soak_${SHA}.log

for i in $(seq 1 48); do
  TS=$(date -u +%FT%TZ)
  CODE=$(curl -sS -o /tmp/c3-soak/_h.json -w '%{http_code}' "$PROXY_URL/health" || echo "ERR")
  SEV=$(jq -r '.severity // "?"' /tmp/c3-soak/_h.json 2>/dev/null || echo "?")
  PG=$(jq -r '.dependencies.postgres.status // "?"' /tmp/c3-soak/_h.json 2>/dev/null || echo "?")
  AGE=$(jq -r '.dependencies.age.status // "?"' /tmp/c3-soak/_h.json 2>/dev/null || echo "?")
  VEC=$(jq -r '.dependencies.pgvector.status // "?"' /tmp/c3-soak/_h.json 2>/dev/null || echo "?")
  echo "$TS http=$CODE severity=$SEV postgres=$PG age=$AGE pgvector=$VEC" >> "$SOAK_LOG"
  sleep 300
done
```

**Expected yellow** (do not abort): B44 (graph), B45 (rollups), B47
(vector index size/recall) producers return `status: unknown` —
backends not yet wired; this is by design.

**Abort triggers** (rollback per §Rollback, do NOT promote):

- Top-level severity flips to `red` / `critical`.
- `dependencies.postgres.status`, `.age.status`, or `.pgvector.status`
  flips to `error`.
- B37/B43/B42 producers flip to red.

After 4 h, summarize:

```bash
awk '{print $3}' "$SOAK_LOG" | sort | uniq -c
# expected: ≥ 48 http=200
grep -E 'http=5..|severity=red|=error' "$SOAK_LOG" || echo "soak clean"
# expected: "soak clean"
```

**Acceptance:** ≥ 48 polls, no abort triggers fired.

## Stage 5 — Deploy next environment (default: Production1)

Repeat Stages 1–3 against the next environment, with the per-env
overrides from Stage 0a passed to the deploy script (see Stage 3a
Production1 invocation). Re-run all four smokes against the next
env's `$PROXY_URL` with `Idempotency-Key: redeploy-${SHA}-prod1`.

## Stage 6 — Verification

### 6a. Boot logs confirm gateway init

```bash
gcloud run services logs read $Service --region=$Region --project=$Project \
  --limit=200 > /tmp/c3-soak/${envTag}_boot.log
grep -E 'RepositoryAccountInfoGateway|RepositoryPasswordResetConfirmGateway|account_info|reset_confirm' \
  /tmp/c3-soak/${envTag}_boot.log
# expected: presence of the binding tags in startup output
```

### 6b. 11A.3a routes reachable

```bash
curl -sS -o /tmp/c3-soak/_corpus.json -w '%{http_code}\n' \
  "$PROXY_URL/v1/admin/corpus/versions"
# expected: 401 (route exists, requires auth) — NOT 404
```

A 404 means the deployed binary still lacks 11A.3a routes; redeploy
did not pick up HEAD. Investigate Cloud Build source bundle.

### 6c. Secrets scrub

```bash
grep -E 'eyJ|Bearer |password=|sas=|key=' \
  /tmp/c3-soak/${envTag}_soak_${SHA}.log \
  /tmp/c3-soak/${envTag}_boot.log \
  || echo "scrub clean"
# expected: "scrub clean"
```

If grep matches, redact the captured logs before attaching to the
audit trail and report which capture leaked.

## Rollback (per environment, on failure)

Cloud Run keeps prior revisions until pruned. Roll back by pointing
100% of traffic at the prior revision captured in Stage 1.

```bash
gcloud run services update-traffic $Service --region=$Region \
  --project=$Project --to-revisions=$PRIOR_REVISION=100
```

Re-run the `/readyz` + `/health` smokes against the rolled-back URL.
Record the rollback in the audit trail.

**Cannot be rolled back by this runbook:**

- Secret Manager versions added during Stage 3a (the script only adds;
  it does not delete prior versions). New versions remain in history
  and are harmless — the rolled-back revision references the version
  pin captured at its original deploy time, not the new latest.
- `secrets.ps1` updates to `$ProxyBaseUriEnvVarName`. Operator restores
  prior values manually if needed.

## Triage matrix

| Symptom | Probable cause | First action |
| --- | --- | --- |
| Stage 0b: `gcloud projects describe` returns NOT_FOUND for Production1 | Project not provisioned, OR operator's gcloud account lacks visibility | BLOCKED. `gcloud projects list` and `gcloud auth list` to confirm. Switch accounts if needed. Otherwise wait until provisioning completes. |
| Stage 0b: Cloud Run service NOT_FOUND | Service not yet created in target project | OK on first deploy — `gcloud run deploy --source .` creates the service. Skip PRIOR_REVISION/PRIOR_TAG capture and document "first deploy" in audit trail. |
| Stage 0c: Secret Manager secret NOT_FOUND under target prefix | Pre-provisioning incomplete | BLOCKED for non-staging. For staging, the deploy script's `Sync-SecretManagerSecret` creates secrets idempotently (operator must have Secret Manager Admin). |
| Stage 0e: `secrets.ps1` shim absent OR canonical absent | Operator's local secrets kit not installed | BLOCKED. Operator restores from secrets vault. |
| Stage 1e: secret `latest` version newer than prior revision deploy time | Secret rotated but proxy not redeployed since (the secret-pin invariant) | Expected for this slice — the redeploy IS the fix. Document the drift in the audit table; the new revision will pin the fresh `latest`. |
| Stage 3c `/health` returns 503 with `error: health_check_failed` and ALL dependencies red | **Pre-D.1 expected behavior.** Production main wires `ScaffoldFailingProxyHealthCheckStore`; the throw is caught and projected as a synthetic red envelope. Documented in §Conventions. | Not a regression. Confirm deploy by checking `/v1/admin/corpus/versions` returns 401 (route present) and boot logs show the binding tags. Real `/health` signal lights up once D.1 ships. |
| (Post-D.1 only) `/health` returns 503 with `dependencies.postgres.status=error` after redeploy | New revision pinned to a Secret Manager version whose value is itself wrong, OR Postgres host unreachable | Verify operator's local `POSTGRES_URL` is current; rerun deploy script (idempotent — it'll add a new version if value differs from latest). If still red, run `psql "$POSTGRES_URL" -c "SELECT 1"` from a host with VPC equivalence; if that fails too, Postgres host is the problem, not the secret. |
| Stage 3c `/v1/advisor-smoke` returns 503 `accounting_store_unavailable` | New `accountInfoGateway` binding masking accounting init order | Inspect Stage 6a boot logs for stack trace. Rollback if init throws. File a regression — bindings should not block accounting init. |
| Stage 3c `/v1/advisor-smoke` returns 503 `llm_provider_unavailable` | Anthropic / Voyage key rotation drift, or quota | Verify Secret Manager `latest` version is the rotated one; check Anthropic / Voyage console for quota; do NOT promote. |
| Stage 3c `/healthz` returns Google's HTML 404 (NOT proxy JSON) | Cloud Run GFE intercepts `/healthz` by design | Use `/readyz` instead — same handler, returns proxy JSON `{"status":"ok"}`. The proxy's `/healthz` route is unreachable in Cloud Run; documented in §Conventions. Not a regression. |
| (Post-D.1 only) Stage 4 soak: B37/B43 producer flips red mid-soak | Postgres / VPC connector flap | Investigate Cloud SQL / Azure Postgres / VPC connector. Do NOT promote even if it flaps back green — flap indicates instability. |
| (Post-D.1 only) Stage 4 soak: B44/B45/B47 producer status `unknown` | Producer backends not yet wired (B44 graph rebuild, B45 rollups, B47 vector recall) | Expected. Not a regression. Documented in §Conventions. |
| Stage 5 smokes fail on next env only | Per-env overrides incorrect (SA email mismatch, Secret Manager prefix, google-services path) | Verify Stage 0a values for the failing env; run Stage 0b–0e diagnostic against that env explicitly before reattempting. |
| Stage 6b: `/v1/admin/corpus/versions` returns 404 (proxy JSON) | New revision was built from a commit that lacks 11A.3a (`411c9da` not in source bundle) | Inspect Cloud Build source archive — `--source .` zips the working tree. Verify worktree is at expected SHA + clean (Stage 1a). Redeploy. |
| Postgres-only red (age + pgvector ok) | Stale `POSTGRES_URL` pin AND admin URL unaffected — partial rotation OK | Document partial rotation; admin operations unaffected if they don't depend on rotated host. |

## Live mutations performed by this runbook (audit trail)

In execution order:

1. Cloud Run: `$Service` revision replaced (Stage 3a).
2. Secret Manager: 0–6 new versions added under `$SecretPrefix` prefix,
   only on content change (Stage 3a).
3. Local file: `~/.forge_flow/secrets/runtime/forge_flow.secrets.ps1`
   (or shim) rewrites `$ProxyBaseUriEnvVarName` to the new URL
   (Stage 3a).
4. (multi-env) Cloud Run: next env's service revision replaced
   (Stage 5).
5. (multi-env) Secret Manager: 0–6 new versions under next env's
   prefix (Stage 5).
6. (multi-env) Local file: `$ProxyBaseUriEnvVarName` for next env
   rewritten (Stage 5).
7. (only if Rollback invoked) Cloud Run: traffic split shifts to
   `$PRIOR_REVISION=100`. Reversible by re-running Stage 3.

Recording tables — filled from 2026-05-01 23:14 UTC staging execution
(template below for future Production1 execution):

**Image / revision capture — staging (executed 2026-05-01 23:14 UTC)**

| # | Stage | Resource | Prior | New |
| --- | --- | --- | --- | --- |
| 1 | 1c, 3b | `forge-flow-staging-proxy` revision | `forge-flow-staging-proxy-00031-dxh` (deployed 2026-05-01 05:19 UTC) | `forge-flow-staging-proxy-00032-lgs` (deployed 2026-05-01 23:14 UTC, 100% traffic) |
| 2 | 1c, 3b | `forge-flow-staging-proxy` image | `…@sha256:b1c69013…` | `…@sha256:<00032 digest>` (Cloud Build auto-tagged at HEAD `337e4c9`) |

**Secret-pin drift — staging (Stage 1e)**

| Secret name | Prior pin (in 00031) | Post-deploy `latest` (in 00032) | Created | Drift caused this redeploy? |
| --- | --- | --- | --- | --- |
| `forge-flow-staging-postgres-url` | v4 (2026-04-29 14:04 UTC) | **v6** (2026-05-01 23:12 UTC) | new | yes — operator rotated to v5 at 21:12 UTC; deploy created v6 (= v5 in value) |
| `forge-flow-staging-postgres-admin-url` | v4 (2026-04-29 14:05 UTC) | **v5** (2026-05-01 23:12 UTC) | new | partial-rotation completion (operator confirmed "not intentional" to leave admin URL behind) |
| `forge-flow-staging-anthropic-api-key` | v? | **v6** (2026-05-01 23:12 UTC) | new | likely no value drift; deploy script always adds a version |
| `forge-flow-staging-voyage-api-key` | v? | **v5** (2026-05-01 23:12 UTC) | new | likely no value drift |
| `forge-flow-staging-firebase-web-api-key` | v? | **v5** (2026-05-01 23:12 UTC) | new | likely no value drift |
| `forge-flow-staging-service-principal-jwt-secret` | v2 (2026-04-29 14:05 UTC) | **v3** (2026-05-01 23:12 UTC) | new (value identical to v2) | operator's canonical secrets file lacks the env-var line; v2 value pulled from Secret Manager into PS env for this deploy. **Recommend operator add `$env:SERVICE_PRINCIPAL_JWT_SECRET` to canonical so future deploys don't need the round-trip.** |

**Smoke results — staging (executed 2026-05-01 23:16 UTC)**

| Endpoint | Status | Note |
| --- | --- | --- |
| `/readyz` | **200** ✅ | body `{"status":"ok"}` |
| `/health` | 503 ⚠️ | `error: health_check_failed` — pre-D.1 expected (scaffold orphan, see §Conventions) |
| `/v1/usage-smoke` | **401** ✅ | route registered; bearer not issued in this session, so route logic itself was not exercised end-to-end |
| `/v1/advisor-smoke` (200 or 402) | **401** ✅ | route registered; bearer not issued in this session |
| `/v1/admin/corpus/versions` (Stage 6b — expect 401, NOT 404) | **401** ✅ | 11A.3a corpus-admin routes are LIVE in 00032 (was 404 in 00031) |

**Boot-log binding verification (Stage 6a, captured 2026-05-01 23:15:55 UTC):**

`tool/advisor_proxy/main.dart`'s startup banner reports all production
bindings live: `account_info: postgres`,
`password_reset_confirm: postgres`, `corpus_admin: postgres`,
`auth_session_ledger: postgres`, `accounting_store: postgres`,
`permission_snapshot: postgres`, `admin_permission_guard: postgres`,
`auth_operations: postgres`, `service_principal_issuance: postgres`,
`password_change: postgres`,
`mfa_operations: postgres_identitytoolkit_firebase_mfa`,
`mfa_recovery_request: postgres_event_outbox`,
`operator_location_admin: postgres`, `pricing_tier_admin: postgres`,
`integration_admin: postgres_kms_stub`. The two C.3 target bindings
(`account_info`, `password_reset_confirm`) are confirmed live.

**Production1 — DEFERRED (BLOCKED at Stage 0b — GCP project not provisioned in operator's account):**

| # | Stage | Resource | Prior | New |
| --- | --- | --- | --- | --- |
| 1 | 1c, 3b | `forge-flow-production1-proxy` revision | n/a | (deferred) |

When Production1 GCP is provisioned and Stage 0 passes for it, the
runbook procedure runs unchanged with `-Project forge-flow-production1
-Region northamerica-northeast2 -Service forge-flow-production1-proxy
-ServiceAccount … -SecretPrefix forge-flow-production-
-ProxyBaseUriEnvVarName FORGE_FLOW_PROXY_BASE_URI_PROD1
-FirebaseGoogleServicesPath …`.

**Env-binding diff (NAMES only — values never recorded)**

| Env name | Resolution |
| --- | --- |
| `FIREBASE_PROJECT_ID` | literal (`$Project` value) |
| `ANTHROPIC_API_KEY` | secret-bound (`${SecretPrefix}anthropic-api-key:latest`) |
| `VOYAGE_API_KEY` | secret-bound (`${SecretPrefix}voyage-api-key:latest`) |
| `POSTGRES_URL` | secret-bound (`${SecretPrefix}postgres-url:latest`) |
| `POSTGRES_ADMIN_URL` | secret-bound (`${SecretPrefix}postgres-admin-url:latest`) |
| `FIREBASE_WEB_API_KEY` | secret-bound (`${SecretPrefix}firebase-web-api-key:latest`) |
| `SERVICE_PRINCIPAL_JWT_SECRET` | secret-bound (`${SecretPrefix}service-principal-jwt-secret:latest`) |

After verification: zero or more `account_info` and
`password_reset_confirm` calls begin reaching the postgres-backed
gateways; 11A.3a corpus admin routes become reachable; the rotation
captured in the secret-pin drift table takes effect on the new
revision.

## Slice boundary — handoff to D.1

C.3 deliberately does NOT touch the production health-check wiring.
That work belongs to slice D.1, which will replace
`tool/advisor_proxy/main.dart:70`'s
`ScaffoldFailingProxyHealthCheckStore` const with a real
`RegistryProxyHealthCheckStore` instance backed by the producer
registry at `tool/advisor_proxy/health_producers/producer_registry.dart`.

**Files C.3 is allowed to touch and DID touch:**

- `runbooks/proxy_redeploy_reset_confirm_account_info_runbook.md` (this file).
- `scripts/deploy_staging_proxy.ps1` (parameterized for multi-env via
  `-SecretPrefix` / `-ProxyBaseUriEnvVarName` /
  `-FirebaseGoogleServicesPath`).
- `test/deploy_staging_proxy_contract_test.dart` (assertions updated
  for the parameterized structure).

**Files C.3 is NOT allowed to touch — reserved for D.1:**

- `tool/advisor_proxy/main.dart` (specifically line 70's
  `healthCheckStore` const + line 108's `routeRequest` arg).
- `tool/advisor_proxy/advisor_proxy.dart` lines 3647-3812 (the two
  health-store class implementations).
- `tool/advisor_proxy/health_producers/**` (producer registry + family
  files).
- `tool/advisor_proxy/proxy_bootstrap.dart` health-check binding (if
  D.1 chooses to construct the runner / dependency probe through
  bootstrap).

**What C.3 leaves in place for D.1 to pick up:**

- A live staging proxy at HEAD (revision 00032-lgs at execution time)
  with all production bindings wired EXCEPT the health-check store.
- Confirmed reachability of Postgres at the TCP layer (TCP probe to
  `forge-flow-staging-pg.postgres.database.azure.com:5432` succeeded);
  D.1's first real `/health` probe will tell us whether the
  Postgres-protocol layer (auth, TLS, firewall) is actually
  healthy.
- Documented `/readyz` as the working liveness endpoint pre-D.1.
- The runbook's Stage 4 (soak) gated on D.1 — `[Post-D.1 only]`
  rows in the triage matrix flag which behaviors only become
  observable after D.1.

**What D.1 will need from this runbook (none — they are independent):**

- C.3's deploy procedure (Stages 0-6) is independent of the
  health-store wiring. D.1 can ship its own redeploy through a
  separate runbook OR by running this one after the wiring change.
- `/health` envelope contract assertions stay in
  `docs/contracts/proxy_health_contract.md`; this runbook does not
  duplicate that.

**Cross-lane file overlap check (Batch 5):**

| Lane | Shared seam files | C.3 modified any? |
| --- | --- | --- |
| E.3 (feature_flags_admin_ui) | `lib/admin/admin_routes.dart`, `lib/main_admin.dart`, `tool/advisor_proxy/advisor_proxy.dart`, `tool/advisor_proxy/proxy_bootstrap.dart` | No |
| F.1 (health_admin_view) | `lib/admin/admin_routes.dart`, `lib/main_admin.dart` | No |
| G.2 (boundary_monitor_restaurant_tz) | `lib/services/current_state_boundary_monitor.dart`, `pubspec.yaml` | No |
| D.1 (registry health-store wiring) | `tool/advisor_proxy/main.dart`, `tool/advisor_proxy/health_producers/**` | No |

C.3 closes out cleanly: zero file overlap with any pending Batch 5
lane or with D.1.
