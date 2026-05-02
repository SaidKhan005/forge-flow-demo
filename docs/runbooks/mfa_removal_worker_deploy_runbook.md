# MFA Removal Worker — Deploy Runbook

Operational runbook for the `mfa_removal_worker` Cloud Run Job that
completes due 24-hour MFA removal requests in bounded batches. Code
lives in [`tool/mfa_removal_worker/main.dart`](../../tool/mfa_removal_worker/main.dart);
container build is owned by [`tool/mfa_removal_worker/Dockerfile`](../../tool/mfa_removal_worker/Dockerfile)
and [`tool/mfa_removal_worker/cloudbuild.yaml`](../../tool/mfa_removal_worker/cloudbuild.yaml).

The worker is **safe to retry**: rows are claimed with
`SELECT ... FOR UPDATE SKIP LOCKED` and each completion update is
guarded by pending state. Cloud Scheduler retries cannot double-process.

## Authority

- `tool/mfa_removal_worker/main.dart` — entrypoint contract (env
  vars, CLI flags, exit codes).
- `tool/mfa_removal_worker/Dockerfile` — image surface.
- `tool/mfa_removal_worker/cloudbuild.yaml` — build pipeline.
- `db/migrations/202604300000_phase_9_mfa_factor_removal_requests.sql`
  — request table the worker processes.
- `lib/services/mfa/mfa_removal_worker.dart` — `processDue` semantics.
- `CLAUDE.md` ("F&F holds all provider keys server-side"; "Postgres
  host = Azure DB Flexible Server, Canada Central, PG 16") for the
  network and identity posture this runbook inherits.

## Region

| Setting | Value |
| ------- | ----- |
| Cloud Run Job region | `northamerica-northeast1` (matches advisor proxy + audit anchor) |
| Artifact Registry repo | `northamerica-northeast1-docker.pkg.dev/<project>/forge-flow` |
| Postgres host | `forge-flow-staging-pg` / `forge-flow-production1-pg` (Canada Central) |

If a multi-region rollout is needed later, the cloudbuild
substitutions accept `_REGION=...`; the runbook's job spec must be
re-evaluated for that region's egress posture before deployment.

## Build

Submit via Cloud Build from the repository root:

```bash
gcloud builds submit . \
  --config=tool/mfa_removal_worker/cloudbuild.yaml \
  --substitutions=_REGION=northamerica-northeast1,_REPO=forge-flow
```

The pipeline:

1. Runs `flutter analyze --fatal-infos` (gate).
2. Runs the MFA test suite (`mfa_test`, `mfa_operations_gateway_test`,
   `mfa_recovery_request_rate_limiter_test`,
   `proxy_mfa_operations_gateway_test`) (gate).
3. Builds the image from `tool/mfa_removal_worker/Dockerfile`.
4. Pushes both `:${SHORT_SHA}` and `:latest` tags.

A failing analyze or test step never produces an image. The
`docker build` stage uses digest-pinned base images; refresh the
digests in the Dockerfile when the upstream `:stable` / `:nonroot`
tags rotate.

### Local smoke

The Dockerfile is buildable locally for review purposes:

```bash
docker build -f tool/mfa_removal_worker/Dockerfile -t mfa-removal-worker:dev .
```

This is documentation-only — production deploys go through Cloud
Build so the resulting digest is recorded in the artifact registry.
If Docker is not installed in CI, the cloudbuild gate is the only
required smoke and the local `docker build` line above can be
skipped.

## Runtime env contract

The worker boots `ProxyConfig.fromEnvironment(Platform.environment)`
(see [`tool/mfa_removal_worker/main.dart`](../../tool/mfa_removal_worker/main.dart))
and then `buildProxyProductionBindings(config)` — the same wiring
the advisor proxy uses. That means **every required name in
`ProxySecretNames.required` must be present** even though the worker
only exercises the Postgres + Identity Toolkit MFA seams; missing
names raise `ProxyConfigError` and the job exits 78 (`EX_CONFIG`)
before processing any rows.

| Env name | Required? | Source | Reason worker needs it |
| -------- | --------- | ------ | ---------------------- |
| `POSTGRES_URL` | yes | Secret Manager | Per-tenant reads/writes (RLS-respecting). |
| `POSTGRES_ADMIN_URL` | yes | Secret Manager | Admin-scoped writes the removal worker performs (state transitions on `mfa_factor_removal_requests`). |
| `FIREBASE_WEB_API_KEY` | yes | Secret Manager | Identity Toolkit calls that clear the Firebase MFA factor. |
| `FIREBASE_PROJECT_ID` | yes for live MFA | Cloud Run env (plain) | Identity Platform JWT verification + Identity Toolkit project routing. Required by the production bootstrap before binding port; for the worker the same bootstrap path runs. |
| `SERVICE_PRINCIPAL_JWT_SECRET` | yes (config gate) | Secret Manager | Loaded by `ProxyConfig.fromEnvironment` even though the worker never issues `sp:` tokens. Absent → startup error. |
| `ANTHROPIC_API_KEY` | yes (config gate) | Secret Manager | Same — loaded but unused by the worker. Pin to the same secret the advisor proxy uses. |
| `VOYAGE_API_KEY` | yes (config gate) | Secret Manager | Same. |
| `GEMINI_API_KEY` | optional | Secret Manager | Loaded when present; unused by this worker. |
| `MFA_REMOVAL_BATCH_SIZE` | optional | Cloud Run env (plain) | Defaults to 50 in the worker (see `_batchSize` in main.dart). |
| `PORT` | unused | — | Cloud Run Jobs do not bind a port; the worker ignores `PORT`. |

If `ProxyConfig.fromEnvironment` is later loosened to allow a
worker-only subset, the table above shrinks to Postgres + Firebase.
Until then, the full required set is mandatory.

## Cloud Run Job spec

```bash
gcloud run jobs deploy mfa-removal-worker \
  --region=northamerica-northeast1 \
  --image=northamerica-northeast1-docker.pkg.dev/${PROJECT_ID}/forge-flow/mfa-removal-worker:${SHORT_SHA} \
  --service-account=mfa-removal-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --task-timeout=5m \
  --max-retries=2 \
  --parallelism=1 \
  --tasks=1 \
  --memory=512Mi \
  --cpu=1 \
  --set-env-vars=FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID},MFA_REMOVAL_BATCH_SIZE=50 \
  --set-secrets=POSTGRES_URL=forge-flow-postgres-url:latest \
  --set-secrets=POSTGRES_ADMIN_URL=forge-flow-postgres-admin-url:latest \
  --set-secrets=FIREBASE_WEB_API_KEY=forge-flow-firebase-web-api-key:latest \
  --set-secrets=SERVICE_PRINCIPAL_JWT_SECRET=forge-flow-service-principal-jwt-secret:latest \
  --set-secrets=ANTHROPIC_API_KEY=forge-flow-anthropic-api-key:latest \
  --set-secrets=VOYAGE_API_KEY=forge-flow-voyage-api-key:latest \
  --vpc-connector=projects/${PROJECT_ID}/locations/northamerica-northeast1/connectors/forge-flow-vpc \
  --vpc-egress=private-ranges-only
```

Repeated `--set-secrets` flags are concatenated by `gcloud`; the
form above mirrors the advisor proxy deploy. If your gcloud version
prefers the comma-joined form, collapse them:
`--set-secrets=POSTGRES_URL=…:latest,POSTGRES_ADMIN_URL=…:latest,…`.

Key choices:

| Field | Value | Why |
| ----- | ----- | --- |
| `--task-timeout` | `5m` | The worker processes one bounded batch per invocation; 5 min is generous. Anything longer indicates Postgres latency drift and should page rather than hang the job. |
| `--max-retries` | `2` | The worker is idempotent (`FOR UPDATE SKIP LOCKED` + state-guarded updates). Two retries cover transient Postgres reconnects; more retries would mask real failures. |
| `--parallelism` | `1` | Single instance per scheduled run. Concurrent instances are safe (SKIP LOCKED claims disjoint rows) but contribute no throughput because the workload is small. |
| `--tasks` | `1` | Same reason — one task per execution. |
| `--memory` | `512Mi` | Dart AOT binary plus tenant-context working set. Headroom for occasional batch-size overrides. |
| `--cpu` | `1` | The job is I/O-bound (Postgres) — single CPU is correct. |
| `--vpc-connector` | `forge-flow-vpc` | Required for the private-IP Azure Postgres reach. |
| `--vpc-egress` | `private-ranges-only` | All traffic stays inside the connector; no internet egress from the job. |
| Service account | `mfa-removal-worker-sa` | See IAM table below. |

## IAM grants on `mfa-removal-worker-sa`

The worker hits Secret Manager (env injection), Cloud Logging
(stdout/stderr), and Firebase Identity Toolkit (`accounts:update`,
`accounts:lookup`). Identity Toolkit lives behind Firebase Admin
SDK calls authenticated by the Cloud Run service account's ADC.

| Role | Scope | Reason |
| ---- | ----- | ------ |
| `roles/secretmanager.secretAccessor` | each of `forge-flow-postgres-url`, `forge-flow-postgres-admin-url`, `forge-flow-firebase-web-api-key`, `forge-flow-service-principal-jwt-secret`, `forge-flow-anthropic-api-key`, `forge-flow-voyage-api-key` | Cloud Run injects `--set-secrets` values at boot; the SA must read each secret version. |
| `roles/logging.logWriter` | project | stdout/stderr from the AOT binary lands in Cloud Logging. |
| `roles/firebaseauth.admin` | Firebase project (same as `FIREBASE_PROJECT_ID`) | Identity Toolkit `accounts:update` + `accounts:lookup` to clear the Firebase MFA factor. Without this role, Identity Toolkit returns `PERMISSION_DENIED` and the worker reports `failed=N` per batch. |
| (optional) `roles/cloudtrace.agent` | project | If Cloud Trace is wired into the proxy bindings later. Not required today. |

Grant via:

```bash
for ROLE in roles/logging.logWriter roles/firebaseauth.admin; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:mfa-removal-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="${ROLE}"
done

for SECRET in forge-flow-postgres-url forge-flow-postgres-admin-url \
              forge-flow-firebase-web-api-key forge-flow-service-principal-jwt-secret \
              forge-flow-anthropic-api-key forge-flow-voyage-api-key; do
  gcloud secrets add-iam-policy-binding "${SECRET}" \
    --member="serviceAccount:mfa-removal-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role=roles/secretmanager.secretAccessor
done
```

## Cloud Scheduler trigger

The Cloud Run Jobs `:run` endpoint is hosted on `*.googleapis.com`,
which Google APIs authenticate with **OAuth access tokens** — not
OIDC ID tokens. (OIDC is for arbitrary HTTPS targets like a Cloud
Run *service*; Google API targets need OAuth so the access token
carries the requesting principal.) The runbook uses the v2 path
(`https://run.googleapis.com/v2/projects/.../locations/.../jobs/...:run`),
which is the global endpoint — no regional shell substitution
needed in the URI.

```bash
LOCATION=northamerica-northeast1
JOB_NAME=mfa-removal-worker

gcloud scheduler jobs create http mfa-removal-worker-tick \
  --location="${LOCATION}" \
  --schedule="*/10 * * * *" \
  --time-zone=Etc/UTC \
  --uri="https://run.googleapis.com/v2/projects/${PROJECT_ID}/locations/${LOCATION}/jobs/${JOB_NAME}:run" \
  --http-method=POST \
  --oauth-service-account-email="mfa-removal-worker-scheduler-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform" \
  --attempt-deadline=120s \
  --max-retry-attempts=3 \
  --min-backoff=30s \
  --max-backoff=600s \
  --max-doublings=4
```

The scheduler service account needs `roles/run.invoker` on the job
(or on the project, scoped to the job) so its OAuth token is
authorized to call `:run`:

```bash
gcloud run jobs add-iam-policy-binding "${JOB_NAME}" \
  --region="${LOCATION}" \
  --member="serviceAccount:mfa-removal-worker-scheduler-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role=roles/run.invoker
```

Key choices:

| Field | Value | Why |
| ----- | ----- | --- |
| `--schedule` | `*/10 * * * *` | Every 10 minutes. Within the worker's accepted window of "every 5–15 minutes" per the entrypoint header. |
| `--time-zone` | `Etc/UTC` | Cron expressions evaluated in UTC. The worker's batch eligibility is timestamp-based and tenant-timezone-agnostic, so a UTC trigger keeps schedule reasoning trivial. |
| `--uri` | `https://run.googleapis.com/v2/...:run` | Cloud Run Jobs v2 API, global endpoint. No regional shell substitution required. |
| `--oauth-service-account-email` | `mfa-removal-worker-scheduler-sa` | Scheduler SA distinct from the job SA; OAuth (not OIDC) because the target is a Google API. |
| `--oauth-token-scope` | `https://www.googleapis.com/auth/cloud-platform` | Scope required to call any Google Cloud API; narrower scopes are not exposed for `run.googleapis.com` today. |
| `--attempt-deadline` | `120s` | Scheduler's wait for the run-trigger ACK. The actual job runs asynchronously up to the job's `--task-timeout`. |
| `--max-retry-attempts` | `3` | Retries the trigger HTTP call only — not the job itself. Job-level retries are governed by `--max-retries=2` above. |
| Backoff | exponential, 30s → 600s, 4 doublings | Standard production-grade exponential backoff. |

If the trigger fails immediately with `PERMISSION_DENIED`, verify
(a) the scheduler SA has `roles/run.invoker` on the job, and (b) the
SA has `roles/iam.serviceAccountTokenCreator` on itself (required
for OAuth token minting from Cloud Scheduler).

## Failure alerting

Direct Cloud Run Job execution failures and Cloud Scheduler trigger
failures into the existing `forgeflow-cmk-alerts` notification
channel:

```bash
gcloud alpha monitoring policies create \
  --notification-channels=projects/${PROJECT_ID}/notificationChannels/${FORGEFLOW_CMK_ALERTS_CHANNEL} \
  --display-name="mfa-removal-worker job failures" \
  --condition-display-name="job execution failed" \
  --condition-threshold-filter='resource.type="cloud_run_job" AND resource.labels.job_name="mfa-removal-worker" AND metric.type="run.googleapis.com/job/completed_task_attempt_count" AND metric.labels.result="failed"' \
  --condition-threshold-comparison=COMPARISON_GT \
  --condition-threshold-value=0 \
  --condition-threshold-duration=300s

gcloud alpha monitoring policies create \
  --notification-channels=projects/${PROJECT_ID}/notificationChannels/${FORGEFLOW_CMK_ALERTS_CHANNEL} \
  --display-name="mfa-removal-worker scheduler trigger failures" \
  --condition-display-name="scheduler attempt failed" \
  --condition-threshold-filter='resource.type="cloud_scheduler_job" AND resource.labels.job_id="mfa-removal-worker-tick" AND metric.type="cloudscheduler.googleapis.com/job/attempt_count" AND metric.labels.response_code!~"^2.."' \
  --condition-threshold-comparison=COMPARISON_GT \
  --condition-threshold-value=0 \
  --condition-threshold-duration=300s
```

The CMK alerts channel ID lives in the project's secret env (Vanessa
keeps the canonical mapping). Substitute
`${FORGEFLOW_CMK_ALERTS_CHANNEL}` at apply time; do not commit the
channel ID into this repo.

## Smoke after deploy

1. Trigger one execution by hand:
   ```bash
   gcloud run jobs execute mfa-removal-worker \
     --region=northamerica-northeast1 --wait
   ```
2. Tail the execution log; expect a single line:
   ```
   mfa removal worker completed: claimed=N completed=M failed=0
   ```
3. If `failed > 0`, the exit code is `1`; the alerting policy above
   pages on the resulting `result="failed"` task attempt.
4. Confirm the Scheduler trigger is firing:
   ```bash
   gcloud scheduler jobs describe mfa-removal-worker-tick \
     --location=northamerica-northeast1 \
     --format='value(state,lastAttemptTime,nextScheduleTime)'
   ```
   `state` should be `ENABLED` and `lastAttemptTime` within the last
   10 minutes.

## Rollback

Rolling back is a job-image swap; it does not touch the Postgres
state.

```bash
gcloud run jobs update mfa-removal-worker \
  --region=northamerica-northeast1 \
  --image=northamerica-northeast1-docker.pkg.dev/${PROJECT_ID}/forge-flow/mfa-removal-worker:${PREVIOUS_SHORT_SHA}
```

If the regression is severe and pausing processing is preferable to
running the rolled-back binary, disable the trigger:

```bash
gcloud scheduler jobs pause mfa-removal-worker-tick \
  --location=northamerica-northeast1
```

The `mfa_factor_removal_requests` table will accumulate due rows
while paused; resume the trigger once the binary is healthy and the
worker drains the backlog within a few executions.

## Out of scope

- Changing the 24-hour wait window — that lives in the request
  enqueue path (`MfaOperationsGateway.requestFactorRemoval`), not in
  this worker.
- Cross-region failover — staging and Production1 both run in
  Canada Central today; multi-region requires a separate decision.
- Tenant-scoped batch sizing — `MFA_REMOVAL_BATCH_SIZE` is global
  per-execution; per-tenant throttling would require schema changes
  and is not in scope for this runbook.
