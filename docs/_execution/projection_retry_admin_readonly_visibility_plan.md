# Projection Retry Admin Read-Only Visibility Plan

Created: 2026-05-19

## Plain English Summary

- Gap: `canonical_fact_projection_retry_jobs` rows can now be drained by the
  projection retry worker, but F&F admins cannot see pending, running, or
  dead-lettered rows without direct SQL.
- Fix: extend the existing read-only admin observability proxy route
  (`GET /v1/admin/observability`) with projection retry status counts plus
  bounded recent and dead-letter row lists.
- Safety rule: this is visibility only. No writes, no migrations, no retry
  draining behavior, and no operator-account or business-timing changes.

## Scope

- Add a structured projection retry summary to the admin observability
  envelope:
  - counts for all known job statuses.
  - a bounded recent list for active retry rows.
  - a bounded dead-letter list for failed rows needing triage.
- Reuse the existing admin observability authorization pattern:
  `super_admin` and `ff_support` only, routed through the proxy admin gateway.
- Run the reads through the existing admin `runAsSystem` path, using bound SQL
  parameters for any scope filters.
- Add focused tests for role gating, response shape, status counts, and list
  bounds.

## Non-Goals

- Do not add write routes or replay actions.
- Do not alter `canonical_fact_projection_retry_jobs` schema or migrations.
- Do not change the projection retry worker or dispatcher.
- Do not add Account, Business Timing editor, Data Accuracy, or pre-input
  failure capture changes.

## Execution Steps

1. Persist this plan before implementation.
2. Extend `RepositoryObservabilityAdminProxyGateway.fetch` with bounded
   projection retry queries and JSON shaping helpers.
3. Add an admin route test that proves `ff_support` can read and non-admin
   callers cannot.
4. Add a gateway test with a fake Postgres executor proving counts, bounded
   rows, scope parameters, and safe read-only query shape.
5. Run focused tests, focused analyzer, UX em dash lint, and
   `git diff --check`.
6. Commit, push, open a ready PR, and stop.
