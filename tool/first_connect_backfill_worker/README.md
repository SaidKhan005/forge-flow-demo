# first_connect_backfill_worker — operator runbook

Cloud Run-deployable Dart worker that drains
`public.connector_backfill_jobs` so first-connection OAuth events are
not "complete and then empty data forever". Closes Phase 8 gap-2.

## Pieces in scope

```
tool/first_connect_backfill_worker/
  main.dart        # entrypoint + retry-cap + audit-log dead-letter
  Dockerfile       # mirrors tool/audit_anchor/Dockerfile
  README.md        # this file

scripts/deploy_first_connect_backfill_worker.ps1
                   # Cloud Run Job + Cloud Scheduler trigger
test/tool/first_connect_backfill_worker/main_test.dart
```

These compose existing master-side pieces:

* `db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql`
  creates the queue + RLS policy + claim/status indexes.
* `tool/integration_sync_worker/backfill_dispatch.dart` is the
  per-job dispatcher (claim → dispatch adapter.backfill →
  mark succeeded/resumable/failed). The worker composes it; it does
  not re-implement.
* `lib/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart`
  is the repository the dispatcher's `BackfillJobStore` interface
  expects. The worker wraps it with `RetryCappingBackfillJobStore`
  for the cap-and-dead-letter path.

## Deploy shape: Cloud Run Job invoked by Cloud Scheduler every 60s

The deploy lands the worker as a **Cloud Run Job** (not a Service)
fired by a **Cloud Scheduler** trigger every 60 seconds. The job
runs `runOnce`, drains every claimable scope's queue (up to
`MAX_JOBS_PER_TICK` per scope), and exits.

Why Job + Scheduler over Service-with-always-on:

1. **Bounded per-invocation cost.** Cloud Run Jobs bill only while
   the container runs. A 60-second cadence drains the queue with
   the same latency budget the harness targets, but pays nothing
   in between. An always-on Service with min-instances=1 bills 24/7
   for empty-queue ticks.
2. **No SIGTERM gymnastics.** The worker's `runOnce` mode exits as
   soon as the tick finishes; Cloud Run's default 30-minute job
   timeout (set to 600s here, well below queue scale) is the only
   drain semantics needed. The `daemon` mode still exists for local
   dev and ad-hoc runs but is not the production deploy shape.
3. **Reclaim already covers crash cases.** The repository's
   `claimNext` SQL re-claims any `running` row whose `claimed_at` is
   older than `claimStaleAfter` (default 15 min). A Cloud Run Job
   pod killed by Cloud Run for resource pressure leaves the row in
   `running` state; the next 60s firing reclaims it. No custom
   SIGTERM handler is required for correctness.
4. **Mirrors `audit_anchor`.** The Phase 9 audit chain anchorer is
   the closest production analogue — daily Cloud Run Job +
   scheduler, same secret-handling posture, same VPC connector.
   Reusing the pattern keeps the F&F deploy story coherent.

The `daemon` mode is documented for local dev (`flutter pub run
tool/first_connect_backfill_worker/main.dart daemon`); production
never uses it.

## Required env (NAMES only — values flow through Secret Manager)

| Env name | Purpose |
|---|---|
| `POSTGRES_URL` | Same secret the audit_anchor + advisor proxy already mount; reused so connection-string drift never occurs. |
| `FIRST_CONNECT_BACKFILL_WORKER_POLL_SECONDS` (optional) | Daemon-mode tick interval. Default 30. Production ignores it (Cloud Scheduler controls the cadence). |
| `FIRST_CONNECT_BACKFILL_WORKER_MAX_JOBS_PER_TICK` (optional) | Per-scope cap of jobs per tick. Default 5. |
| `FIRST_CONNECT_BACKFILL_WORKER_MAX_ATTEMPTS` (optional) | Retry cap before dead-letter. Default 10. |
| `FIRST_CONNECT_BACKFILL_WORKER_CLAIM_STALE_SECONDS` (optional) | Staleness window for re-claim. Default 900s. |
| `FIRST_CONNECT_BACKFILL_WORKER_ID_PREFIX` (optional) | `worker_id` prefix; default `first-connect-backfill`. The pid+timestamp suffix is appended automatically. |

Secret values are NEVER printed. Startup logs the loaded env NAMES
only — same posture as `tool/audit_anchor/main.dart` and
`scripts/deploy_audit_anchor_job.ps1`.

## Retry cap + dead-letter

Each `markFailed` call increments the row's `attempt_count` (the
repository SQL does it inside `claimNext`'s CTE). When a `markFailed`
reads back `attempt_count >= MAX_ATTEMPTS`, the worker:

1. Writes a second `markFailed` with `last_error` prefixed
   `dead_lettered:cap_reached:<original-reason>`. The migration's
   `status` CHECK constraint admits only
   `(pending, running, succeeded, failed)`, so terminal stays
   `failed` — see DEVIATION below.
2. Inserts exactly one `public.audit_logs` row with
   `action='backfill_dead_lettered'`, scoped to the job's
   `(operator_id, location_id)`, with the vendor / category /
   attempt_count / reason in the JSON payload.

Operator-facing copy keys off the `dead_lettered:cap_reached`
prefix in `last_error`. The `connector_backfill_jobs_active_uq`
UNIQUE blocks new active rows for the same `(connection, window)`
until an explicit operator replay enqueues a fresh row.

### DEVIATION: dead_lettered status

The slice prompt requested `status='dead_lettered'`. The migration's
CHECK constraint
(`db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql`,
line 38) admits only `(pending, running, succeeded, failed)`. The
prompt also marked the migration READ-ONLY. Adding a 5th status
would touch the migration. The encoding chosen — terminal
`failed + last_error marker + audit row` — preserves both
constraints AND surfaces the dead-letter event in two queryable
places (the row's `last_error` and the audit chain). A follow-up
slice can widen the CHECK if a separate dead-letter status proves
more useful.

## Cloud Scheduler trigger

The deploy script registers the schedule. Manual command shape:

```sh
gcloud scheduler jobs create http forge-flow-first-connect-backfill-trigger \
  --project forge-flow-staging \
  --location northamerica-northeast1 \
  --schedule '*/1 * * * *' \
  --time-zone 'Etc/UTC' \
  --uri https://northamerica-northeast2-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/forge-flow-staging/jobs/forge-flow-first-connect-backfill:run \
  --http-method POST \
  --oauth-service-account-email forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com \
  --attempt-deadline 600s
```

Cloud Scheduler is not available in `northamerica-northeast2` today,
so the trigger lives in `northamerica-northeast1` while the Job
itself runs in `northamerica-northeast2`. Same constraint as
`scripts/deploy_audit_anchor_job.ps1`.

## Adapter factory wiring

The worker entrypoint expects a `WorkerBackfillAdapterFactory` —
the closure that materializes the per-vendor adapter for one
claimed job. Production now wires `BinderBackedAdapterFactory`
(see `tool/first_connect_backfill_worker/main.dart`) which closes
over the same per-vendor map the proxy binder builds via
`buildPhase8VendorIntegrationFactoriesFromCredentials` in
`tool/advisor_proxy/phase_8_vendor_integration_factories.dart`.
The worker therefore shares the proxy's broker / credential bridges
/ Postgres canonical sinks per vendor, and its
`PGCRYPTO_ENVELOPE_KEY` env variable is now required at boot.

Disabled vendors (warn-disabled in the binder because optional
static app credentials or async-only location config are missing)
surface to the worker as `BackfillVendorDisabledException`. The
dispatcher records that as a per-job failure with a clean
`vendor "<id>" not active in binder; missing app credentials`
message; the cap-and-dead-letter path then dead-letters the job
once retries exceed `MAX_ATTEMPTS`.

In test paths the factory is injected via
`runCli(adapterFactoryOverride: ...)` so the worker's claim /
dispatch / cap-and-audit paths can be exercised end-to-end without
real adapters. The legacy `kScaffoldRejectingAdapterFactory`
remains as a defensive fallback for paths that bypass both
production wiring and test overrides; reaching it indicates a
caller bug, not a configuration miss.

## Local dev

Run `runOnce` once against a local Postgres:

```ps1
$env:POSTGRES_URL = "postgres://forge_admin@localhost:5432/forge_flow_dev"
flutter pub run tool/first_connect_backfill_worker/main.dart runOnce
```

`daemon` mode polls every 30s by default; SIGINT (Ctrl+C) drains
between ticks and exits cleanly.

## Test surface

`test/tool/first_connect_backfill_worker/main_test.dart` covers:

* Single happy-path job: claim → dispatch → mark succeeded → demo
  flip + watermark advance + sync log on the canonical sink.
* SKIP LOCKED contention: two parallel runs against a single
  available job — only one claims it (the in-memory fake mirrors
  the migration's `FOR UPDATE SKIP LOCKED` semantics).
* Cap-and-dead-letter: a job that fails 11 times ends terminal
  `failed` with `last_error` prefixed `dead_lettered:cap_reached`
  AND a single `public.audit_logs` row with
  `action='backfill_dead_lettered'`.
* SIGTERM mid-tick: in-flight job's transaction rolls back and the
  row stays claimable on the next tick.

The tests use a fake `PostgresPool` + `BackfillJobStore` rather
than touching live Postgres. The repository / migration / dispatcher
have their own existing test surfaces on master.
