# Slice Runtime Acceptance Contract

Status: Active
Last updated: 2026-05-03

This contract captures the staging-console remediation and performance lessons
from the 2026-05-03 execution reports. It applies to every future slice that
adds runtime behavior, migrations, operator/admin UI, health metrics, packaged
artifacts, vendor/AI work, workflow execution, or production-cutover evidence.

## Core Rule

Every feature slice is an end-to-end system slice.

Do not accept a slice only because local code and local tests pass. Acceptance
must prove the path from branch to deployed runtime to real browser origin to
health/runbook truth.

## Required Acceptance Path

Before acceptance, identify and verify:

1. The code exists on the branch.
2. The build context includes every runtime file the deployed image needs.
3. The deployed image actually contains those runtime files.
4. The live route works from the real browser origin used for QA.
5. Health metrics represent real producer state, not placeholder UI state.
6. Runbooks explain how to recover when a metric goes yellow or red.
7. Migration/docs drift has been scanned after schema changes.

If any step cannot be proven, report `FOLLOW-UP NEEDED` and keep the slice
active or explicitly defer the missing proof to a named future gate.

## Runtime Artifact Packaging

Any slice that depends on non-code runtime artifacts must name and verify those
artifacts in the build/deploy path.

Examples:

- graph candidates
- corpus manifests
- prompt packs
- embeddings or vector artifacts
- legal/T&C documents
- workflow templates
- seed data
- replay fixtures
- static admin assets

The branch test is not enough. The acceptance evidence must prove the artifact
is present in the deployed runtime image or in the deployed storage location
that the runtime reads.

## Live Staging Proof

Local success is necessary but not sufficient.

For browser-exposed work, test the deployed Cloud Run revision from the actual
browser origin used for QA. The QA origin must be named exactly; `localhost`
and `127.0.0.1` are different origins for CORS and browser storage.

When browser or service-worker cache can hide the deployed state, use a fresh
URL, revision capture, cache-busting query, or browser context and record which
runtime revision was tested.

Use Browser Use as the default browser acceptance harness when available.
Browser-exposed slices should include a route sweep, one primary click path,
desktop evidence, mobile-width evidence when UI layout is in scope, and an
explicit safe-action boundary. The reusable evidence shape lives in
`runbooks/browser_use_acceptance_harness_runbook.md`; admin-console-specific
build/origin notes live in `runbooks/admin_console_browser_qa_runbook.md`.

## Health And Producer Truth

Health red/yellow means "find the producer," not "hide the UI state."

Every live health metric needs:

- owner
- producer
- source table/service/job
- threshold
- runbook or recovery command
- evidence that red/yellow/unknown state is classified correctly

Unknown metrics stay neutral. Populated bad metrics degrade health. UI code may
explain the state, but it must not convert a real backend red/yellow state into
green.

Classify safe errors before fixing them:

- missing artifact
- missing migration
- missing producer
- bad permission/grant
- bad CORS origin
- real application bug
- expected empty state

## Performance Defaults

Do not let expensive truth become automatic UI refresh.

Cheap readiness stays separate from expensive diagnostics. Expensive work is
manual, confirmed, deferred, queued, paginated, or scoped unless the product
freshness requirement truly demands automatic refresh.

Required performance posture:

- cheap page load first
- scoped data only
- no automatic polling of expensive endpoints by default
- no stacked in-flight duplicate requests
- pagination/filtering/virtualization for large admin tables
- manual confirmed diagnostics for deep health/debug/replay work
- timeouts, safe errors, and recovery copy for slow calls
- metrics captured before and after performance-sensitive changes
- deployed revision verified, not just local build verified

Admin/operator convenience surfaces are high-risk load generators. Treat debug
consoles, observability dashboards, advisor panels, vendor sync views, replay
tools, exports, and workflow monitors as performance-sensitive by default.

## Phase Attention Map

### Production1 Migration Apply And B43

Apply migrations in documented order, run the drift scanner, then verify
Production1 health. Audit health is not complete until production anchor lag is
green or explicitly deferred with an owner and recovery path.

### 11A Operations Console

Debug, observability, audit, replay, provider usage, status-page, and health
surfaces must be scoped, filtered, paginated, and manually refreshed when deep
checks are expensive. Any diagnostic or replay action needs scope, auditability,
and clear failure/recovery copy.

### 10a Realtime Push

`NOTIFY` is a wake-up signal only. Durable truth comes from `event_outbox`.
Protect against reconnect storms, duplicate polling loops, missing replay,
dead-letter gaps, retention drift, and health tripwire blind spots.

### 10.5 Daypart And Service Periods

Whole-day facts remain authoritative. Daypart is an additive lens. Watch
timezone, business-date, DST, late-night, boundary tie-break, correction replay,
and non-service-gap behavior. Avoid repeated large client-side recomputation.

### 7.58 / 7.61 Cleanup

Unknown driver keys and missing driver data must become explicit unavailable or
degraded states, not silent defaults. Phase 8 writers must respect the final
driver-key contract.

### 8 / 8R / 8.5 Vendor Data

Vendor adapters are canonical data producers. Backend/proxy owns vendor calls;
secrets never enter Flutter. Require stable source ids, idempotency,
correction handling, timezone normalization, privacy readiness, capped
backfills, quarantine for bad records, and visible freshness.

### 11b Advisor UX

Advisor work should be explicit, cached where behavior allows, circuit-broken,
operator-scoped, and measured. Use approved graph tables, not draft Graphify
artifacts. Require provenance, bounded traversal, cross-operator isolation,
confidence-aware answers, and refusal behavior.

### 12 Workflow Platform

Workflows remain disabled by default until approvals, caps, idempotency,
append-only audit logs, artifact storage, throttled pollers, and Cloud Run job
execution are proven. Irreversible actions require explicit consent.

### 9.5 / 9.75 Identity And Staff Companion

Staff views must not load manager/admin data by accident. Demo or local identity
assumptions must not leak into production paths.

### 9.8 Compliance

Legal text is not complete until founder/counsel review. T&C acceptance,
privacy views, GDPR request/deletion flows, processor chain, and re-acceptance
gates must be real before customer-data cutover. Compliance/audit history is
paginated from the beginning.

### Production Cutover

Re-check deployed production state: migrations, packaged artifacts, health
producers, provider approvals, rollback plan, CORS, auth roles, graph corpus,
legal gates, performance gate, smoke tests, revision identity, and stability
watch.

## Migration Drift Scanner

After any slice adds or changes `db/migrations/*.sql`, run:

```powershell
dart run tool/migration_drift_scanner.dart --fix --strict-docs
```

The scanner:

- compares the newest migration with the staging setup cutoff
- updates `scripts/postgres_staging_setup.ps1` when `--fix` is used
- writes `build/reports/migration_drift_report.md`
- flags watched tracker/runbook/phase docs that still need manual
  queue/count wording refresh

Then run:

```powershell
dart run tool/migration_cutoff_lint.dart
```

The scanner helps repair drift; the cutoff lint remains the hard gate.

## Slice Prompt Checklist

Before implementing a future slice, answer:

1. What runtime files or data must exist after deployment?
2. Which migration or producer makes the behavior real?
3. What health metric proves it is working?
4. What browser origin will QA use?
5. What failure should the user/admin see?
6. What runbook fixes the failure?
7. What performance guardrail prevents accidental load?
8. What docs/tracker lines must be updated before acceptance?

If a prompt cannot answer these for a runtime-exposed slice, fix the prompt or
phase doc before implementation starts.
