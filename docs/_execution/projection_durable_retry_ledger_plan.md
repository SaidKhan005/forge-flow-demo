# Projection Durable Retry Ledger Plan

Created: 2026-05-19

## Plain English Summary

- Gap: saved vendor facts could be written successfully, then the follow-up projection could fail and disappear from memory.
- Risk: the app would keep the raw facts, but the derived shift projections could stay stale until a later sync happened to touch the same period again.
- Fix: store the failed projector input in Postgres, then let a replay dispatcher claim and retry it later.
- Safety rule: the original vendor write must still succeed. Projection retry recording is best effort and must not break ingestion.
- Gate: this adds a new database table, so the PR must stop for explicit operator approval before merge.

## Scope

- Add a tenant-scoped retry ledger table for canonical fact projection failures.
- Capture the exact projector input after the canonical fact write commits.
- Keep the current non-blocking projection behavior: vendor ingestion does not fail because projection failed.
- Add a small replay dispatcher that claims one due job, reruns the projector, and marks the job succeeded, pending, or dead-lettered.
- Wire the retry recorder into proxy webhooks, sync worker, and first-connect backfill worker production projection taps.
- Add focused unit tests for record serialization, dispatcher behavior, and failed projection recording.
- Add a migration-shape test so RLS, operator-leading indexes, and payload checks stay pinned.

## Non-Goals

- Do not add a live scheduler loop in this slice. The dispatcher is intentionally ready for a follow-up worker or Cloud Scheduler hook.
- Do not retry failures that happen before a projector input can be built, such as timing profile resolution failures.
- Do not change the projection output model or user-facing UX in this slice.
- Do not dedupe retry rows yet. The input hash is stored now so future replay tooling can dedupe or inspect safely.

## Execution Steps

1. Create the migration for `canonical_fact_projection_retry_jobs`.
2. Add the retry record, job store interface, and dispatcher service.
3. Add the Postgres repository with tenant-scoped insert, claim, success, and failure updates.
4. Attach the retry recorder to both projection wrapper types.
5. Wire production proxy and worker factory paths to pass the recorder.
6. Add focused tests and migration guard coverage.
7. Run Dart format, analyzer, focused tests, migration guardrails, and repo lint checks.
8. Commit, push, and open a PR that stops at the schema approval gate.

## Residual Follow-Up

- Add the scheduler hook that periodically calls `CanonicalFactProjectionRetryDispatcher.dispatchNext`.
- Decide the worker owner for that hook: sync worker tick, a dedicated Cloud Run job, or a pg-cron notification bridge.
- Add operator/admin visibility for pending and dead-lettered projection retry rows once the scheduler lands.
