# p3d_operator_scoped_isolation_under_concurrency — Phase 3D tenant-isolation pressure

**Runner:** `test/pressure/p3d_operator_scoped_isolation_under_concurrency_test.dart`
(in-process tenant-scoped store model; DB harness env-gated).

**What it pressures:** the
`OperatorScopedRepository.withTenant(context, body)` contract in
`lib/infrastructure/persistence/postgres/operator_scoped_repository.dart`.
Under concurrent writes from different operators to the same table,
no row leaks across tenant boundaries. The in-memory model
faithfully mirrors the SET LOCAL GUC + transactional commit/rollback
semantics that the production `TenantTransactionWrapper` provides.

**Status at branch fork point:** PASS. In-memory pressure runs
under default `flutter test`; live-Postgres harness skips behind
its env gate.

## Inputs

- Env gate (DB portion): `FF_RUN_PRESSURE_P3D_TENANT_ISO=1` plus a
  local Postgres.
- In-memory inputs: 50 distinct TenantContexts built from
  deterministic UUIDs that pass the strict 8-4-4-4-12 lowercase
  validation.

## What it asserts

- 50 operators writing concurrently — each sees only their own row
  inside `withTenant`.
- 100 interleaved context flips — the observed "current operator"
  inside each body always matches the TenantContext passed in.
- Body exceptions roll back — a thrown exception inside `withTenant`
  does not leave the pending row visible to subsequent reads.
- `withSystem` bypasses tenant scoping (admin path) AND requires a
  non-blank reason; blank reason raises ArgumentError.

## How to read the output

- Healthy run: 4 in-memory test cases pass; the env-gate test skips.
- Regression: a failure means the tenant-context propagation model
  is broken — under concurrency, one body could observe another
  body's GUC. This is RLS-critical; escalate per CLAUDE.md
  auth/RLS gate.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #4.

## Backlog

Live-Postgres harness — 50 concurrent operators writing the same
fact table with RLS enabled; assert via per-tenant `SELECT count(*)`
that no rows leak across boundaries.
