# integration_sync_worker — operator runbook

Cloud Run-deployable Dart worker that drains every connected
`public.connector_connection` row on a recurring cadence so polling
vendors (Oracle MICROS Simphony, Humanity, Agendrix, Push Operations,
QuickBooks Time) stay current AND hybrid vendors (Toast, Square,
Lightspeed LSK, 7shifts, Clover, ...) get a catch-up sweep when a
webhook drops.

Closes the recurring-poll wire-in for Phase 8 Wave B
`8.spine-bridge.0`.

## Pieces in scope

```
tool/integration_sync_worker/
  main.dart                          # entrypoint + run-once + daemon loop
  postgres_sync_worker_source.dart   # cross-tenant SELECT seam
  dispatch.dart                      # per-row dispatcher (existing)
  backfill_dispatch.dart             # backfill dispatcher (sibling)
  Dockerfile                         # mirrors tool/first_connect_backfill_worker/
  README.md                          # this file

scripts/deploy_integration_sync_worker.ps1
                                     # Cloud Run Job + Cloud Scheduler
test/tool/integration_sync_worker/main_test.dart
test/tool/integration_sync_worker/postgres_sync_worker_source_test.dart
test/tool/integration_sync_worker/dispatch_test.dart
test/tool/integration_sync_worker/backfill_dispatch_test.dart
```

These compose existing master-side pieces:

* `tool/integration_sync_worker/dispatch.dart`
  [`IntegrationSyncWorkerDispatch`] (untouched by this slice). Owns
  the registry-lookup / sanity-hook / watermark-advance / sync-log
  writeback contract.
* `tool/advisor_proxy/phase_8_vendor_integration_factories.dart`
  [`buildPhase8VendorIntegrationFactoriesFromCredentials`]. Same
  per-vendor map the proxy installs into
  `Phase80IntegrationRoutes.globalBindings` for inbound webhooks.
  The worker reuses it so per-tenant credential bridges and Postgres
  sinks stay single-sourced.
* `lib/services/integration/canonical_sink.dart`
  [`CanonicalSink`]. The worker ships its own
  [`IntegrationSyncCanonicalSink`] implementation that handles
  `advanceWatermark` / `appendSyncLog` writes; per-vendor adapters
  write canonical fact rows through their own sinks.

## Deploy shape: Cloud Run Job invoked by Cloud Scheduler every 5 minutes

The deploy lands the worker as a **Cloud Run Job** (not a Service)
fired by a **Cloud Scheduler** trigger every 5 minutes. The job runs
`runOnce`, drains every connected vendor's connection through the
dispatcher, and exits.

Why Job + Scheduler over Service-with-always-on (rationale matches
`tool/first_connect_backfill_worker/README.md`):

1. **Bounded per-invocation cost.** Cloud Run Jobs bill only while
   the container runs.
2. **No SIGTERM gymnastics.** V1 lean cut #2 explicitly REMOVED the
   custom SIGTERM graceful-drain handler. The dispatcher's per-batch
   watermark commit is what makes restart resilient — Cloud Run's
   default 30-minute job timeout (set to 600s here) is the only drain
   semantics needed.
3. **Dispatcher already covers crash cases.** If a Cloud Run Job pod
   is killed mid-row, the next 5-minute firing re-reads the same
   row from `connector_connection`, the watermark cursor still points
   at the last fully-committed batch, and the adapter resumes from
   there.
4. **Mirrors the audit_anchor + first_connect_backfill_worker
   pattern.** Same VPC connector, same secret-handling posture, same
   region split between the Job and the Scheduler.

The `daemon` mode is documented for local dev (`flutter pub run
tool/integration_sync_worker/main.dart daemon`); production never uses
it.

## Required env (NAMES only — values flow through Secret Manager)

| Env name | Purpose |
|---|---|
| `POSTGRES_URL` | Same secret the audit_anchor + advisor proxy + first-connect backfill worker mount; reused so connection-string drift never occurs. |
| `PGCRYPTO_ENVELOPE_KEY` | Required by [`VendorCredentialBroker`] for ciphertext decrypt before each adapter poll. Same secret the proxy reads. |

## Optional env

| Env name | Default | Purpose |
|---|---|---|
| `INTEGRATION_SYNC_WORKER_POLL_SECONDS` | `300` | Daemon-mode tick interval. Production ignores it (Cloud Scheduler controls the cadence). |
| `INTEGRATION_SYNC_WORKER_MAX_ROWS_PER_TICK` | `1000` | Per-tick row cap. |
| `INTEGRATION_SYNC_WORKER_ID_PREFIX` | `integration-sync` | `worker_id` prefix; pid+timestamp suffix is appended automatically. |
| `FF_WEBHOOK_PUBLIC_BASE_URI` | `https://api.forgeflow.app` | Public webhook base URI threaded into the binder builder. |

Optional vendor app-credential bundles mirror
`tool/first_connect_backfill_worker/main.dart`. Each bundle is
OPTIONAL at boot; absence leaves the matching vendor on the binder's
`disabledVendors` warn list, and any connected row for that vendor
surfaces a `poll_error` sync_log row at dispatch time:

* `ALOHA_NCR_VOYIX_CLIENT_ID` / `ALOHA_NCR_VOYIX_CLIENT_SECRET` /
  `ALOHA_NCR_VOYIX_APPLICATION_KEY` /
  `ALOHA_NCR_VOYIX_ORGANIZATION_ID`
* `SQUARE_CLIENT_ID` / `SQUARE_CLIENT_SECRET` /
  `SQUARE_NOTIFICATION_URL_HOST`
* `CLOVER_APP_TOKEN` / `CLOVER_APP_ID`

Secret values are NEVER printed. Startup logs the loaded env NAMES
plus the wired-vendors / disabled-vendors lists only — same posture
as `tool/oauth_refresh_worker/main.dart` and
`tool/first_connect_backfill_worker/main.dart`.

## Tick lifecycle (what one invocation does)

1. **Boot log.** Single JSON line carrying `event=boot`,
   `loaded_secret_names`, `wired_vendors`, `disabled_vendors`,
   `max_rows_per_tick`, `poll_interval_seconds`.
2. **Source read.** [`PostgresSyncWorkerSource.connectedConnections`]
   issues a single `runAsSystem` SELECT joining
   `public.connector_connection` against
   `public.connector_sync_watermark`. The cross-tenant scan is the
   only privileged read — per-row dispatch flows through tenant-
   scoped paths under the dispatcher's hood.
3. **Per-row dispatch.** For each yielded
   [`ConnectorConnectionRow`], the runner awaits the binder-backed
   resolver to materialise the per-tenant adapter, then hands the
   resolved instance to
   [`IntegrationSyncWorkerDispatch.dispatchPollTick`]:
   * On success → `connector_sync_watermark` upsert (resource=`poll`)
     + `connector_sync_log` `event_kind='poll_success'`.
   * On adapter throw → `connector_sync_log` `event_kind='poll_error'`.
     Watermark NOT advanced.
   * On vendor not registered in the category registry →
     `connector_sync_log` `event_kind='vendor_not_registered'`.
   * On binder-disabled vendor → `connector_sync_log`
     `event_kind='poll_error'` with the disable reason in
     `error_message`.
4. **Exit log.** Single JSON line carrying `event=exit`,
   `mode=runOnce|daemon`, plus the tick tally
   (`processed`, `succeeded`, `failed`, `watermark_advanced`,
   `skipped`).

## Idempotency

The dispatcher's per-batch watermark commit is the only correctness-
critical step. A second run of the same tick re-reads the same rows
from `connector_connection` but the watermark advance from the prior
tick is already persisted, so the adapter's
`pollIncremental` resumes from the new cursor and emits an empty
result for rows that have no new data.

## Cloud Scheduler trigger

The deploy script registers the schedule. Manual command shape:

```sh
gcloud scheduler jobs create http forge-flow-integration-sync-trigger \
  --project forge-flow-staging \
  --location northamerica-northeast1 \
  --schedule '*/5 * * * *' \
  --time-zone 'Etc/UTC' \
  --uri https://northamerica-northeast2-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/forge-flow-staging/jobs/forge-flow-integration-sync:run \
  --http-method POST \
  --oauth-service-account-email forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com \
  --attempt-deadline 600s
```

Cloud Scheduler is not available in `northamerica-northeast2` today,
so the trigger lives in `northamerica-northeast1` while the Job
itself runs in `northamerica-northeast2`. Same constraint as
`scripts/deploy_audit_anchor_job.ps1`.

## Local dev

Run `runOnce` against a local Postgres:

```ps1
$env:POSTGRES_URL = "postgres://forge_admin@localhost:5432/forge_flow_dev"
$env:PGCRYPTO_ENVELOPE_KEY = "dev-key"
flutter pub run tool/integration_sync_worker/main.dart runOnce
```

`daemon` mode polls every 300s by default; SIGINT (Ctrl+C) drains
between rows and exits cleanly.

## Test surface

* `test/tool/integration_sync_worker/main_test.dart` — happy path
  tick, partial failure tick, disabled vendor surface, not-wired
  vendor surface, max-rows-per-tick cap, shouldStop interrupt, and
  `runCli` overrides path returning exit code 0 with the JSON exit
  log carrying the tally.
* `test/tool/integration_sync_worker/postgres_sync_worker_source_test.dart` —
  row mapping (cursor join, last_modified_seen fallback, category
  coercion, status filter).
* `test/tool/integration_sync_worker/dispatch_test.dart` — pre-existing
  dispatcher tests still pass.
* `test/tool/integration_sync_worker/backfill_dispatch_test.dart` —
  pre-existing backfill dispatcher tests still pass.

The tests use a fake `PostgresPool` + recording sinks rather than
touching live Postgres. The dispatcher / source / canonical-sink
contracts have their own existing test surfaces on master.
