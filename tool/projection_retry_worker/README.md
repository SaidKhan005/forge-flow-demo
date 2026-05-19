# Projection Retry Worker

Cloud Run Job entrypoint for draining due rows from
`canonical_fact_projection_retry_jobs`.

## Modes

```bash
dart run tool/projection_retry_worker/main.dart runOnce
dart run tool/projection_retry_worker/main.dart daemon
```

`runOnce` is the intended production mode for Cloud Scheduler and is the
Dockerfile default. `daemon` is available for local or platform setups that
expect a loop.

Production deploys should use `scripts/deploy_projection_retry_worker.ps1`,
which creates a Cloud Run Job plus Cloud Scheduler trigger and pins
`--args runOnce`.

## Required Env

- `POSTGRES_URL`

## Optional Env

- `PROJECTION_RETRY_WORKER_MAX_JOBS_PER_TICK`, default `50`
- `PROJECTION_RETRY_WORKER_POLL_SECONDS`, default `300` in daemon mode
- `PROJECTION_RETRY_WORKER_ID_PREFIX`, default `projection-retry`
- `POSTGRES_POOL_MAX_CONNECTIONS`, shared Postgres pool override

## Behavior

- Finds due operator/location scopes with a bounded system read.
- Claims and updates each retry job through
  `CanonicalFactProjectionRetryRepository` under tenant context.
- Replays projection with default Phase 8 production projector wiring.
- Exits cleanly when no jobs exist.
