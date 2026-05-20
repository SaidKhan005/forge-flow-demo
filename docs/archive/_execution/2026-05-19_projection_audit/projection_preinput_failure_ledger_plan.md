# Projection Pre-Input Failure Ledger Plan

Created: 2026-05-19

## Plain English Summary

- Gap: the durable projection retry ledger records failures after a
  `CanonicalFactPostCommitInput` exists.
- Risk: if business timing or service-period resolution fails while building
  that input, the saved vendor facts remain durable but the projection failure
  has no durable audit row.
- Fix: add a small pre-input failure record to the existing projection retry
  recorder and store it in `canonical_fact_projection_retry_jobs` as a
  dead-letter audit row. This avoids sending non-replayable rows through the
  current retry worker.
- Safety rule: vendor fact writes still succeed. Recording the failure remains
  best effort and cannot break ingestion.

## Audit Findings

- `ProjectingCanonicalSink` and `BufferedCanonicalFactProjectionTap` both catch
  projection errors, but they only record durable retry rows when a full
  `CanonicalFactPostCommitInput` was already built.
- Production projector wiring resolves business timing and service periods in
  `_ProductionCanonicalFactPeriodResolver` before the input is built.
- `connector_sync_log` is append-only and useful for sync outcomes, but it does
  not carry replay context and its event-kind contract is not a fit for
  projection pre-input failures.
- `audit_logs` is for operator/service actions, not projection retry payloads.
- `canonical_fact_projection_retry_jobs` already has the tenant, connection,
  category, error, and payload columns needed for a minimal durable record.

## Scope

1. Add a pre-input failure record model and recorder method.
2. Have both projection drain paths record pre-input failures when projection
   input construction fails.
3. Keep those rows out of the replay queue by inserting them with
   `status = 'dead_lettered'`.
4. Make production missing business timing and missing service-period
   resolution throw explicit pre-input failures instead of returning a silent
   null drop.
5. Add focused tests for the new recording path and keep existing post-input
   retry behavior unchanged.

## Non-Goals

- Do not edit Account or org-unit business timing authoring.
- Do not change retry admin visibility.
- Do not touch the retry drain worker.
- Do not add a migration unless the existing retry table cannot hold the
  smallest safe record.

## Verification Plan

- Focused Flutter tests for `ProjectingCanonicalSink` and
  `CanonicalFactProjectionRetryRecord`.
- Focused analyzer on changed Dart files.
- `dart run tool/ux_em_dash_lint.dart`.
- Migration drift and cutoff checks only if a migration becomes necessary.
- `git diff --check`.
