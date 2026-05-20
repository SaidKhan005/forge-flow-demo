# Projection Retry Drain Worker Plan

Created: 2026-05-19

## Plain English Summary

- Gap: `canonical_fact_projection_retry_jobs` can now store failed projector
  inputs, but production has no worker that claims and replays those rows.
- Risk: raw vendor facts remain durable, but the derived shift/open-period
  projection can stay stale until another write happens to touch the same
  business period.
- Fix: add a small bounded Cloud Run Job entrypoint that builds the existing
  Phase 8 production projector wiring, creates a
  `CanonicalFactProjectionRetryDispatcher`, and drains a limited number of due
  retry jobs.
- Safety rule: every claimed job still runs through
  `CanonicalFactProjectionRetryRepository` and tenant-scoped transactions. The
  only system-scope read is a bounded due-scope scan so the worker can find
  which operator/location pairs have work.

## Scope

- Add `tool/projection_retry_worker/main.dart` with:
  - `runOnce` and optional `daemon` modes, matching existing worker style.
  - bounded `--max-jobs-per-tick` processing.
  - structured stdout outcome counts.
  - safe no-job behavior.
- Add a small Dockerfile/README if needed for Cloud Run Job deployment parity.
- Add focused tests for CLI parsing, no-job ticks, bounded draining, failure
  counts, and due-scope iteration.
- Keep code changes out of Account, Business Timing editor, Data Accuracy,
  schema migrations, admin visibility, and pre-input failure ledgers.

## Non-Goals

- Do not change the retry table schema.
- Do not add admin/operator visibility for pending or dead-lettered rows.
- Do not invent a separate projector stack.
- Do not retry failures that happen before a projector input can be built.

## Execution Steps

1. Add the plan doc.
2. Implement the worker around the existing dispatcher and default Phase 8
   projector wiring.
3. Add a bounded due-scope source for production and in-memory fakes for tests.
4. Add focused tests under `test/tool/projection_retry_worker`.
5. Run focused tests, focused analyzer, UX copy lint, and `git diff --check`.
6. Commit, push, open a ready PR, and stop.

## Runbook Notes

- Production should run this as a scheduled Cloud Run Job, not a long-lived
  service, unless the deploy environment explicitly needs `daemon` mode.
- Start with a conservative batch cap. The default keeps the job bounded and
  lets Cloud Scheduler retry naturally on infrastructure failures.
- Failure outcomes are written back through the retry repository. Rows
  transition to pending for later retry or dead-lettered after the existing
  attempt cap.
